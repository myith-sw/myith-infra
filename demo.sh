#!/usr/bin/env bash
# MYiTH 시연 운영 스크립트. myith-infra 레포 루트에서 실행한다.
#
#   ./demo.sh up            서버 켜기 → 준비 완료까지 대기 → 점검표 출력
#   ./demo.sh check         현재 상태만 점검 (서버 안 건드림)
#   ./demo.sh nudge         넛지 발사 (기본 ABSENCE_48H)
#   ./demo.sh nudge UPSET   타입 지정
#   ./demo.sh nudge ABSENCE_48H 3   타입 + userId
#   ./demo.sh users         존재하는 userId 탐색
#   ./demo.sh down          서버 끄기 (과금 중단)
#
# ▼ 시연 전에 이 값만 자기 userId 로 바꿔두면 nudge 에 인자를 안 써도 된다
USER_ID_DEFAULT=1

API="${API:-https://api.myith.store}"
WEB="${WEB:-https://myith.store}"
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ENVFILE="deploy/env.core"
ok(){ printf "  \033[32m✅\033[0m %s\n" "$1"; }
no(){ printf "  \033[31m✗\033[0m  %s\n" "$1"; }
wa(){ printf "  \033[33m▲\033[0m  %s\n" "$1"; }
hd(){ printf "\n\033[1m──── %s ────\033[0m\n" "$1"; }

getenvv(){ [ -f "$ENVFILE" ] && grep "^$1=" "$ENVFILE" 2>/dev/null | head -1 | cut -d= -f2- || true; }

health(){ curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$API/api/health" 2>/dev/null; }

do_check(){
  local fail=0
  hd "서버"
  local c; c=$(health)
  if [ "$c" = "200" ]; then ok "API 200 — $API"; else no "API 응답 $c — 꺼져 있다. ./demo.sh up"; fail=1; fi

  hd "데모 모드"
  local en tk; en=$(getenvv MYITH_DEMO_ENABLED); tk=$(getenvv MYITH_DEMO_TOKEN)
  if [ ! -f "$ENVFILE" ]; then no "$ENVFILE 없음 — myith-infra 루트에서 실행해라"; return 1; fi
  [ "${en:-}" = "true" ] && ok "MYITH_DEMO_ENABLED=true" || { no "MYITH_DEMO_ENABLED 가 true 가 아니다 (넛지 엔드포인트 404)"; fail=1; }
  [ -n "${tk:-}" ] && ok "MYITH_DEMO_TOKEN 설정됨 (${#tk}자)" || { no "MYITH_DEMO_TOKEN 비어 있음"; fail=1; }
  if [ "$c" = "200" ] && [ -n "${tk:-}" ]; then
    local pc; pc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST \
      -H "X-Demo-Token: WRONG_TOKEN_PROBE" "$API/api/demo/nudge?userId=1" 2>/dev/null)
    case "$pc" in
      403) ok "넛지 엔드포인트 살아있음 (토큰 검증 동작)" ;;
      404) no "넛지 엔드포인트 404 — 서버에 데모 모드가 안 들어갔다. 재배포 필요"; fail=1 ;;
      *)   wa "넛지 엔드포인트 응답 $pc — 확인 필요" ;;
    esac
  fi

  hd "구글 로그인 (Electron)"
  if [ "$c" = "200" ]; then
    local gd; gd=$(getenvv GOOGLE_DESKTOP_CLIENT_ID)
    [ -n "${gd:-}" ] && ok "GOOGLE_DESKTOP_CLIENT_ID 설정됨 (...${gd: -24})" \
      || { no "GOOGLE_DESKTOP_CLIENT_ID 비어 있음 — Electron 로그인 불가"; fail=1; }
    wa "서버 로그의 'Google OAuth audiences configured: 2' 는 배포 시 확인했다면 통과로 본다"
  fi

  hd "웹"
  local wc; wc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$WEB" 2>/dev/null)
  [ "$wc" = "200" ] || [ "$wc" = "304" ] && ok "웹 $wc — $WEB" || wa "웹 응답 $wc"

  hd "결과"
  [ "$fail" = "0" ] && ok "시연 가능" || no "위 ✗ 항목을 먼저 해결해라"
  return "$fail"
}

do_up(){
  hd "사전 확인"
  command -v terraform >/dev/null || { no "terraform 없음"; exit 1; }
  aws sts get-caller-identity >/dev/null 2>&1 && ok "AWS 자격증명 정상" || { no "aws configure 필요"; exit 1; }
  [ -f terraform.tfvars ] && ok "terraform.tfvars 있음" || { no "terraform.tfvars 없음"; exit 1; }

  if [ "$(health)" = "200" ]; then
    ok "이미 켜져 있다. 점검으로 넘어간다"
  else
    hd "서버 켜기 (10~15분)"
    echo "  start.sh 실행 — 인스턴스 생성 → Docker 설치 → deploy.sh all"
    ./start.sh --yes || { no "start.sh 실패. 위 로그를 확인해라"; exit 1; }
    hd "헬스체크 대기"
    for i in $(seq 1 60); do
      local c; c=$(health)
      [ "$c" = "200" ] && { ok "API 200 (${i}회 시도)"; break; }
      [ "$i" = "60" ] && { no "10분 내 200 이 안 나왔다. docker compose ps 를 확인해라"; exit 1; }
      printf "  대기 %2d/60  (현재 %s)\r" "$i" "$c"; sleep 10
    done
    echo
  fi
  do_check
  hd "시연 직전 체크리스트 (사람이 할 일)"
  cat <<'MSG'
  1. Electron 앱 실행 — PM 노트북에서 npm start
  2. Electron 과 웹을 같은 구글 계정으로 로그인   ★ 다르면 넛지가 안 뜬다
  3. 웹에서 새 캐릭터 생성부터 시작              ★ 기존 로드맵은 옛 문구
  4. 자가진단 후 서술형 + 포트폴리오 첨부         ★ 없으면 AI 가 아예 안 돈다
  5. userId 확인 → 이 스크립트 상단 USER_ID_DEFAULT 에 박아두기
  6. 넛지 보여줄 때: ./demo.sh nudge
MSG
}

do_users(){
  local tk; tk=$(getenvv MYITH_DEMO_TOKEN)
  [ -z "${tk:-}" ] && { no "MYITH_DEMO_TOKEN 없음"; exit 1; }
  hd "userId 탐색 (1~15)"
  wa "존재하는 userId 에는 넛지가 큐에 쌓인다. 다음 heartbeat 에서 소비되니 무해하다"
  local found=""
  for id in $(seq 1 15); do
    local c; c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X POST \
      -H "X-Demo-Token: $tk" "$API/api/demo/nudge?userId=$id" 2>/dev/null)
    [ "$c" = "200" ] && { printf "  userId=%-3s 존재\n" "$id"; found="$found $id"; }
  done
  [ -n "$found" ] && ok "존재:$found" || no "1~15 에 사용자가 없다"
  echo
  echo "  어느 게 내 계정인지는 웹 로그인 후 개발자도구 → Network →"
  echo "  /api/users/me 응답의 userId(usr_3 → 3) 로 확인해라."
}

do_nudge(){
  local tk; tk=$(getenvv MYITH_DEMO_TOKEN)
  local type="${1:-ABSENCE_48H}" uid="${2:-$USER_ID_DEFAULT}"
  [ -z "${type:-}" ] && type=ABSENCE_48H
  [ -z "${uid:-}" ] && uid=$USER_ID_DEFAULT
  case "$type" in ANNOYING|UPSET|ABSENCE_48H) ;; *) no "type: ANNOYING | UPSET | ABSENCE_48H"; exit 1 ;; esac
  [ -z "${tk:-}" ] && { no "MYITH_DEMO_TOKEN 없음 — deploy/env.core 확인"; exit 1; }

  hd "넛지 발사  userId=$uid  type=$type"
  local t0 r b s
  t0=$(date +%H:%M:%S)
  r=$(curl -s -w $'\n%{http_code}' --max-time 10 -X POST \
      -H "X-Demo-Token: $tk" "$API/api/demo/nudge?userId=${uid}&type=${type}" 2>/dev/null)
  b=$(printf '%s' "$r" | sed '$d'); s=$(printf '%s' "$r" | tail -1)
  echo "  $t0   HTTP $s"
  echo "  $b"
  echo
  case "$s" in
    200) ok "서버 큐에 등록됨"
         echo
         echo "  이제 앱이 다음 heartbeat 를 보내는 순간 화면이 바뀐다."
         echo "  큐는 만료되지 않는다 — 앱이 물어보기만 하면 반드시 전달된다."
         echo
         echo "  안 뜨면 신호가 사라진 게 아니라 앱이 안 물어보고 있는 것이다. 순서대로 확인:"
         echo "    1. PM 노트북에 앱이 떠 있나 (터미널 창을 닫지 않았나)"
         echo "    2. 앱이 로그인돼 있나"
         echo "    3. 로그인한 구글 계정이 userId=$uid 와 같은가  ← 제일 흔한 원인"
         echo "       → ./demo.sh users 로 존재하는 userId 확인"
         echo "    4. 앱 폴링 주기가 긴가 (30초면 최대 30초 기다려야 한다)"
         echo
         wa "쏜 뒤에 서버를 재배포·재시작하지 마라. 큐는 메모리에 있어 재시작하면 사라진다"
         wa "여러 번 쏴도 하나로 덮인다(put). 연타는 의미 없다 — 위 4가지를 확인해라" ;;
    403) no "토큰 불일치 — 서버에 주입된 값과 deploy/env.core 의 MYITH_DEMO_TOKEN 이 다르다"
         echo "     → deploy/env.core 를 고치고 ./build-and-deploy.sh core 로 재배포" ;;
    404) no "userId=$uid 가 없거나 데모 모드가 꺼져 있다"
         echo "     → ./demo.sh users 로 존재하는 userId 확인"
         echo "     → 데모 모드는 ./demo.sh check 로 확인" ;;
    400) no "type 이 잘못됐다: $type" ;;
    000) no "응답 없음 — 서버가 꺼져 있다"
         echo "     → ./demo.sh up (10~15분 소요)" ;;
    *)   no "예상 밖 응답 $s" ;;
  esac
}

do_down(){
  hd "서버 끄기"
  wa "EC2·NAT·ALB 를 destroy 한다. RDS·Redis·Route53·ACM·ECR·S3 는 유지된다"
  wa "다시 켜려면 ./demo.sh up (10~15분 소요)"
  ./stop.sh --yes
  ok "정지 완료. 시간당 약 \$0.156 절약"
}

case "${1:-}" in
  up)    do_up ;;
  check) do_check ;;
  users) do_users ;;
  nudge|demo|show) shift; do_nudge "${1:-}" "${2:-}" ;;
  down)  do_down ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
