#!/bin/bash
# stop.sh / start.sh / deploy.sh 가 공용으로 쓰는 함수와 설정.
# 단독 실행하지 않는다. source 로만 불러온다.

REGION="ap-northeast-2"

# 어느 위치에서 호출하든 스크립트가 있는 디렉토리(=레포 루트)로 이동한다.
# 심볼릭 링크로 실행해도 실제 경로를 찾는다.
resolve_repo_root() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ $src != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

REPO_ROOT="$(resolve_repo_root)"
cd "$REPO_ROOT"

RUN_LOG="$REPO_ROOT/.myith-run.log"

# 모든 출력을 로그 파일에도 남긴다.
# start.sh 는 10분 이상 걸려 AI 에이전트의 명령 타임아웃을 넘기므로,
# 백그라운드로 돌리고 이 로그를 폴링하는 방식이 필요하다.
start_logging() {
  : > "$RUN_LOG"
  exec > >(tee -a "$RUN_LOG") 2>&1
  echo "[$(date '+%F %T')] $* 시작   (로그: $RUN_LOG)"
}

finish_logging() {
  echo "[$(date '+%F %T')] $* — DONE_MARKER_$1"
}

# ── 사전 점검 ────────────────────────────────────────────────
preflight() {
  local missing=0
  for c in terraform aws docker python3; do
    command -v "$c" >/dev/null 2>&1 || { echo "  !! $c 없음"; missing=1; }
  done
  [ -f main.tf ]           || { echo "  !! main.tf 없음 (레포 루트가 아님: $REPO_ROOT)"; missing=1; }
  [ -f terraform.tfvars ]  || { echo "  !! terraform.tfvars 없음"; missing=1; }
  [ -d .terraform ]        || { echo "  !! .terraform 없음. terraform init 먼저"; missing=1; }
  aws sts get-caller-identity >/dev/null 2>&1 \
    || { echo "  !! AWS 자격증명 없음. aws configure 먼저"; missing=1; }
  [ "$missing" = "0" ] || { echo ""; echo "사전 점검 실패. 위 항목을 해결하세요."; exit 1; }
}

tfout() { terraform output -raw "$1" 2>/dev/null; }

# ── SSM ──────────────────────────────────────────────────────

# SSM 에이전트가 등록될 때까지 대기. 새 인스턴스는 1~2분 걸린다.
wait_ssm() {
  local iid="$1" name="$2"
  printf "  %s SSM 등록 대기" "$name"
  for _ in $(seq 1 60); do
    local n
    n=$(aws ssm describe-instance-information --region "$REGION" \
          --filters "Key=InstanceIds,Values=$iid" \
          --query 'length(InstanceInformationList)' --output text 2>/dev/null || echo 0)
    [ "$n" = "1" ] && { echo " ✓"; return 0; }
    printf "."
    sleep 5
  done
  echo " ✗ (5분 초과)"
  return 1
}

# stdin 으로 받은 스크립트를 원격에서 실행하고 완료까지 기다린다.
# 따옴표·백슬래시가 섞여도 안전하도록 JSON 은 python3 로 만든다.
ssm_run() {
  local iid="$1" label="$2" script params cid status
  script="$(cat)"
  params="$(python3 -c 'import json,sys; print(json.dumps({"commands":[sys.stdin.read()]}))' <<<"$script")"

  cid=$(aws ssm send-command --region "$REGION" \
          --instance-ids "$iid" \
          --document-name AWS-RunShellScript \
          --comment "$label" \
          --timeout-seconds 600 \
          --parameters "$params" \
          --query Command.CommandId --output text) || return 1

  printf "  %s 실행 중" "$label"
  for _ in $(seq 1 120); do
    status=$(aws ssm get-command-invocation --region "$REGION" \
               --command-id "$cid" --instance-id "$iid" \
               --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in
      Success) echo " ✓"; return 0 ;;
      Failed|Cancelled|TimedOut) echo " ✗ ($status)"; break ;;
    esac
    printf "."
    sleep 5
  done

  echo ""
  echo "  ── stdout ──"
  aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
    --instance-id "$iid" --query StandardOutputContent --output text | sed 's/^/    /'
  echo "  ── stderr ──"
  aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
    --instance-id "$iid" --query StandardErrorContent --output text | sed 's/^/    /'
  return 1
}

# ALB 를 통해 200 이 돌아올 때까지 대기.
# 컨테이너 기동 약 22초 + ALB healthy 판정 최대 60초.
wait_alb() {
  local url="$1"
  printf "  ALB 응답 대기 (최대 3분)"
  for _ in $(seq 1 36); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url")" = "200" ]; then
      echo " ✓"; return 0
    fi
    printf "."
    sleep 5
  done
  echo " ✗"
  return 1
}
