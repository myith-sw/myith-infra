# 인프라 운영 스크립트 가이드

## 스크립트 위치

```
INFRA_DIR=/Users/sungyoon/Desktop/sw-contest/myith-infra/myith-infra
CORE_DIR=/Users/sungyoon/Desktop/sw-contest/myith-core
WORKER_DIR=/Users/sungyoon/Desktop/sw-contest/myith-worker/myith-worker
```

`CORE_DIR`·`WORKER_DIR` 은 `build-and-deploy.sh:12-13` 과 같은 값이다.
그 스크립트가 이 두 디렉터리를 빌드하므로 배포 전 pull 대상이기도 하다.

| 스크립트 | 용도 | 소요 |
|---|---|---|
| `stop.sh --yes` | EC2·NAT·ALB 삭제 (비용 70% 절감) | 약 5분 |
| `start.sh --yes` | 인프라 복구 + 컨테이너 자동 배포 | **약 10~15분** |
| `deploy.sh [core\|worker]` | 컨테이너만 재배포 | 약 3~5분 |

`lib.sh` 는 공용 함수다. 직접 실행하지 않는다.

## stop.sh 의 plan 결과는 12 to destroy 다

타겟은 4개지만 의존 리소스 8개가 연쇄 삭제된다. 정상이며 start.sh 가 전부 복구한다.

```
타겟 4개  aws_instance.core / aws_instance.worker
          aws_nat_gateway.main / aws_lb.main
연쇄 8개  aws_lb_listener.https / http_redirect
          aws_lb_target_group_attachment.core
          aws_route53_record.api
          aws_route_table.private
          aws_route_table_association.private_2a / private_2c
          aws_vpc_endpoint.s3
```

살아남는 것 중 중요한 셋:
- `aws_acm_certificate_validation` — 리스너가 이걸 참조하는 단방향. 재발급 시 20분 소요
- `aws_lb_target_group` — VPC 만 참조. ARN 유지
- `aws_eip` (NAT용) — 독립 리소스. 아웃바운드 공인 IP 고정

`Plan: 0 to add, 0 to change, 12 to destroy.` 가 아닌 숫자가 나오면 멈추고 보고한다.
특히 `aws_db_instance` 나 `aws_route53_zone` 이 목록에 있으면 **절대 진행하지 않는다.**

## 반드시 백그라운드로 실행한다

`start.sh` 와 `stop.sh` 는 Bash 도구의 기본 타임아웃을 넘긴다.
**포그라운드로 실행하면 타임아웃으로 끊기고, 그 사이 인프라는 계속 변경되어
상태를 알 수 없게 된다.** 아래 절차를 지킨다.

### 실행

```bash
cd /Users/sungyoon/Desktop/sw-contest/myith-infra/myith-infra && \
  nohup ./start.sh --yes > /dev/null 2>&1 &
```

`stop.sh` 도 동일한 형태로 실행한다.

### 진행 확인 (30~60초 간격으로 폴링)

```bash
tail -20 /Users/sungyoon/Desktop/sw-contest/myith-infra/myith-infra/.myith-run.log
```

### 완료 판정

로그에 완료 마커가 나타나면 끝난 것이다.

```bash
grep -c 'DONE_MARKER_START' .myith-run.log    # start.sh 완료
grep -c 'DONE_MARKER_STOP'  .myith-run.log    # stop.sh 완료
grep -c 'DONE_MARKER_DEPLOY' .myith-run.log   # deploy.sh 완료
```

`1` 이면 완료, `0` 이면 아직 진행 중이다.
마커 없이 프로세스가 죽었으면 실패다. 로그 끝부분을 보고 원인을 보고한다.

### 최종 확인

`start.sh` / `deploy.sh` 후에는 반드시 API 가 살아있는지 확인한다.

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://api.myith.store/api/health
```

`200` 이어야 한다. `502` 면 아직 기동 중일 수 있으니 30초 뒤 다시 확인한다.

## 배포 전 필수: git 동기화

`build-and-deploy.sh`는 `CORE_DIR`·`WORKER_DIR`의 **로컬 작업 트리**를 빌드한다.
원격에 푸시된 코드를 pull하지 않으면 옛 코드가 배포되고, 증상이 "고쳤는데 반영이 안 된다"로 나타나 원인을 찾기 어렵다.

**`build-and-deploy.sh`가 자동으로 처리한다** — 스크립트가 빌드 전에:
1. 미커밋 변경이 있으면 멈춘다 (의도치 않은 코드 배포 방지)
2. `git checkout dev && git pull origin dev`로 최신 코드를 받는다

### 미커밋 변경이 있으면 배포가 중단된다 — 먼저 확인할 것

1번의 동작은 실행 방식에 따라 다르다. 이걸 모르면 "배포했는데 아무 일도 안 일어난다"가 된다.

| 실행 방식 | 미커밋 변경이 있을 때 |
|---|---|
| 터미널에서 직접 (`./build-and-deploy.sh`) | `(y/N)` 확인을 묻는다 |
| **`nohup ... &` (아래 권장 방식)** | **stdin 이 없어 물을 수 없으므로 중단한다** |

백그라운드 실행은 stdin 이 없어 확인을 받을 수 없다. 그래서 fail-closed 로
중단한다 — 물어보지 못한 채 의도하지 않은 코드를 배포하는 것보다 낫다.

**따라서 배포 전에 두 저장소가 깨끗한지 먼저 본다:**

```bash
git -C "$CORE_DIR" status --porcelain
git -C "$WORKER_DIR" status --porcelain
```

둘 다 **아무것도 출력하지 않아야** 정상이다. 뭔가 나오면 커밋하거나 되돌린 뒤
배포한다. **미커밋 변경을 그대로 배포해야 한다면** 백그라운드가 아니라
터미널에서 직접 실행해서 `y` 로 답한다.

> `> /dev/null 2>&1` 로 실행하면 중단 사유 메시지도 같이 버려진다.
> 원인을 봐야 할 때는 `> /tmp/deploy.log 2>&1` 로 바꿔 실행한다.

수동으로 빌드할 때는 직접 동기화해야 한다:
```bash
cd "$CORE_DIR"   && git checkout dev && git pull origin dev
cd "$WORKER_DIR" && git checkout dev && git pull origin dev
```

## 배포: build-and-deploy.sh (권장)

빌드 + 푸시 + deploy.sh를 한 번에 실행한다. **"배포해줘"면 이것만 돌리면 된다.**

```bash
cd /Users/sungyoon/Desktop/sw-contest/myith-infra/myith-infra

# Worker + Core 전부
nohup ./build-and-deploy.sh > /dev/null 2>&1 &

# Core만
nohup ./build-and-deploy.sh core > /dev/null 2>&1 &

# Worker만
nohup ./build-and-deploy.sh worker > /dev/null 2>&1 &
```

내부 동작:
1. ECR 로그인
2. Worker 빌드(linux/amd64) + SHA태그+latest 푸시
3. Core bootJar + 빌드 + 푸시
4. `deploy.sh` 호출 → Worker 마이그레이션(Alembic+시드) → Worker up → Core up → 헬스체크

### deploy.sh만 단독 실행 (이미지 빌드 없이)

ECR에 이미 최신 이미지가 올라가 있으면 deploy.sh만 돌려도 된다.

```bash
cd "$INFRA_DIR" && nohup ./deploy.sh > /dev/null 2>&1 &
```

### 수동 빌드 (개별 제어가 필요할 때)

```bash
INFRA_DIR=/Users/sungyoon/Desktop/sw-contest/myith-infra/myith-infra
CORE_ECR=$(cd "$INFRA_DIR" && terraform output -raw ecr_core_repository_url)
WORKER_ECR=$(cd "$INFRA_DIR" && terraform output -raw ecr_worker_repository_url)
REGION=ap-northeast-2
REGISTRY="${CORE_ECR%%/*}"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

# Core
cd /Users/sungyoon/Desktop/sw-contest/myith-core
./gradlew bootJar
SHA=$(git rev-parse --short HEAD)
docker buildx build --platform linux/amd64 --load -t "$CORE_ECR:$SHA" .
docker tag "$CORE_ECR:$SHA" "$CORE_ECR:latest"
docker push "$CORE_ECR:latest" && docker push "$CORE_ECR:$SHA"

# Worker
cd /Users/sungyoon/Desktop/sw-contest/myith-worker/myith-worker
SHA=$(git rev-parse --short HEAD)
docker buildx build --platform linux/amd64 --load -t "$WORKER_ECR:$SHA" .
docker tag "$WORKER_ECR:$SHA" "$WORKER_ECR:latest"
docker push "$WORKER_ECR:latest" && docker push "$WORKER_ECR:$SHA"
```

## 사용자 요청 → 동작 매핑

| 사용자가 말하면 | 실행 |
|---|---|
| "서버 꺼줘", "정지", "stop" | `stop.sh --yes` |
| "서버 켜줘", "시작", "start" | `start.sh --yes` → 완료 후 헬스체크 |
| "배포해줘" (인프라 살아있을 때) | **① `git -C "$CORE_DIR" status --porcelain` / `$WORKER_DIR` 로 깨끗한지 확인** → ② `nohup ./build-and-deploy.sh > /dev/null 2>&1 &` (dev pull 은 스크립트가 자동) |
| "Core 만 배포" | 위와 동일하게 확인 후 → `nohup ./build-and-deploy.sh core > /dev/null 2>&1 &` |
| "Worker 만 배포" | 위와 동일하게 확인 후 → `nohup ./build-and-deploy.sh worker > /dev/null 2>&1 &` |

빌드 대상은 **로컬 작업 트리**다. 스크립트가 `dev` 를 pull 하지만, 미커밋 변경이
있으면 백그라운드 실행에서는 중단된다 — 위 "배포 전 필수" 절을 볼 것.

## 실행 전 확인할 것

**`stop.sh` 를 실행하기 전에 사용자에게 한 번 확인한다.**
`https://api.myith.store` 가 응답하지 않게 되므로, 프론트엔드가 붙어 있는
시간대라면 서비스가 끊긴다. 사용자가 "그냥 꺼" 라고 하면 확인 없이 진행한다.

`start.sh` 와 `deploy.sh` 는 확인 없이 바로 실행해도 된다.

## 실패했을 때

스크립트는 실패 시 원격 stdout/stderr 를 로그에 그대로 남긴다.
`.myith-run.log` 끝 40줄을 읽고 원인을 사용자에게 보고한다. 임의로 재시도하거나
다른 명령으로 우회하지 않는다.

자주 나오는 원인:

| 로그에 보이는 것 | 원인 |
|---|---|
| `AWS 자격증명 없음` | `aws configure` 필요 |
| `.terraform 없음` | `terraform init` 필요 |
| `SSM 등록 대기 ... ✗` | 인스턴스 부팅 지연. 재실행하면 대개 해결 |
| `docker 준비 안 됨` | bootstrap.sh 가 Docker 설치 실패. 인스턴스 재생성 필요 |
| `경고: GOOGLE_CLIENT_ID 가 비어 있습니다` | `deploy/env.core` 유실. 값 복구 필요 |

## 하지 말 것

- `terraform destroy` 를 옵션 없이 실행하지 않는다.
  Route53 호스팅 영역이 사라져 네임서버가 바뀌고, 가비아 재등록과
  DNS 전파 대기(최대 1시간)가 다시 필요해진다. 반드시 `stop.sh` 를 쓴다.
- `deploy/env.core`, `deploy/env.worker` 를 커밋하지 않는다.
  DB 비밀번호와 JWT 시크릿이 평문으로 들어 있다. `.gitignore` 에 있지만
  `git add -f` 등으로 강제 추가하지 않는다.
- AWS 리소스를 이 저장소에서 만들지 않는다. 인프라는 myith-infra 소유다.

## 11. 시연 운영

### A. 명령어 사전 — 사용자가 이렇게 말하면 그 동작만 한다

| 사용자 발화 | 실행 | 비고 |
|---|---|---|
| "시연해줘" / "신호" / "넛지" / "쏴줘" | `./demo.sh nudge` | **1초. 타입 자동 회전. 배포·서버기동·git·상태확인을 끼워 넣지 마라. 시연 중엔 1초가 중요하다.** |
| (타입 지정) | `./demo.sh nudge UPSET` | ANNOYING \| UPSET \| ABSENCE_48H. 카운터 안 건드림 |
| (userId 지정) | `./demo.sh nudge ABSENCE_48H 7` | |
| "리셋" / "초기화" | `./demo.sh nudge reset` | 회전 카운터를 1회차로 초기화. 리허설 전에 |
| "서버 켜줘" / "시연 준비" | STEP 3 절차 | |
| "배포해줘" | STEP 2 절차 | |
| "도메인 붙여줘" | STEP 1 절차 | |
| "상태 확인" / "지금 되나" | `./demo.sh check` | |
| "서버 꺼줘" / "시연 끝났어" | `./demo.sh down` | |
| "userId 알려줘" | `./demo.sh users` | |

작업 디렉토리는 항상 `/Users/sungyoon/Desktop/sw-contest/myith-infra/myith-infra` 이다. 다른 곳에서 실행하지 마라.

### B. STEP 1 — 도메인 연결 ("도메인 붙여줘")

전제: 사용자가 Vercel 대시보드에서 myith.store 를 이미 추가했고,
Vercel 이 요구한 DNS 값(A 레코드 IP / CNAME)을 알려줘야 한다.
그 값을 못 받았으면 실행하지 말고 사용자에게 요청해라. 추측해서 넣지 마라.

1) CORS 에 도메인 추가 — ★ 이걸 빼면 웹이 통째로 안 뜬다
   `deploy/env.core` 의 `CORS_ALLOWED_ORIGINS` 현재 값을 먼저 읽어라.
   기존 값을 지우지 말고 뒤에 아래 둘을 콤마로 덧붙여라:
   `https://myith.store,https://www.myith.store`
   규칙:
   - 이 한 줄만 바꾼다. 다른 줄은 절대 건드리지 마라.
   - 따옴표를 붙이지 마라 (`deploy.sh` 가 `cut -d= -f2-` 로 읽는다).
   - 수정 전 백업하고, 수정 후 diff 로 그 줄만 바뀌었는지 확인해라.
     다른 줄이 바뀌었으면 되돌리고 보고해라.

2) Route53 레코드 생성
   ```bash
   ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name myith.store \
     --query 'HostedZones[0].Id' --output text | sed 's#/hostedzone/##')
   ```
   사용자가 준 Vercel 값으로 A(또는 ALIAS)·CNAME 레코드를 생성해라.
   ★ `api.myith.store` 레코드는 절대 건드리지 마라. Terraform 소유다.
   ★ NS·SOA 레코드도 건드리지 마라.
   생성 후 확인:
   ```bash
   dig +short myith.store
   dig +short www.myith.store
   ```

3) Core 재배포 (CORS 반영) — STEP 2 절차를 그대로 수행해라.

4) 검증 — 아래 3개를 실제로 돌려 결과를 보고해라
   ```bash
   curl -sI -H "Origin: https://myith.store" https://api.myith.store/api/health \
     | grep -i access-control-allow-origin
   # → https://myith.store 가 나와야 한다

   curl -sI -H "Origin: https://myith-frontend.vercel.app" https://api.myith.store/api/health \
     | grep -i access-control-allow-origin
   # → 기존 것도 여전히 통과해야 한다  ★ 이게 깨지면 즉시 되돌려라

   curl -s -o /dev/null -w '%{http_code}\n' https://myith.store
   # → 200. 아직 SSL 발급 중이면 4xx/5xx 가 나올 수 있다. 30분 뒤 재확인.
   ```

5) 실패해도 되돌리지 마라. `myith-frontend.vercel.app` 이 그대로 살아 있으므로
   시연은 그 URL 로 하면 된다. 상황만 보고해라.

⚠️ **시연 종료 후 `terraform destroy` 전에 수동 생성한 Route53 레코드를 먼저 삭제해야 한다.**
`aws_route53_zone` 에 `force_destroy` 가 없어 레코드가 남아 있으면 destroy 가 실패한다.
삭제 대상 (STEP 1 에서 수동 생성한 것):
- `A     myith.store       → 216.198.79.1`
- `CNAME www.myith.store   → ecbf808dd538f972.vercel-dns-017.com`
```bash
ZONE_ID=Z04008381GH0KXA9Z65DT
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch '{
  "Changes": [
    {"Action":"DELETE","ResourceRecordSet":{"Name":"myith.store","Type":"A","TTL":300,"ResourceRecords":[{"Value":"216.198.79.1"}]}},
    {"Action":"DELETE","ResourceRecordSet":{"Name":"www.myith.store","Type":"CNAME","TTL":300,"ResourceRecords":[{"Value":"ecbf808dd538f972.vercel-dns-017.com"}]}}
  ]
}'
```

### C. STEP 2 — 배포 ("배포해줘")

1) 두 레포가 clean + dev 브랜치인지 먼저 확인. 아니면 멈추고 보고해라.
   ```bash
   git -C /Users/sungyoon/Desktop/sw-contest/myith-core status --porcelain
   git -C /Users/sungyoon/Desktop/sw-contest/myith-worker/myith-worker status --porcelain
   ```
2) 변경 있는 쪽만 실행 (판단이 애매하면 둘 다 — 안전한 쪽이다)
   ```bash
   ./build-and-deploy.sh worker   # worker 를 먼저. alembic + load_all 이 거기서 돈다.
   ./build-and-deploy.sh core
   ```
3) 배포 후 확인해서 보고:
   - `docker compose ps` (core/worker/rabbitmq 전부 Up)
   - Core 로그의 `Google OAuth audiences configured: N` → 2 여야 한다
   - `select id, status from quest where id in (285,299,379);` → 전부 OPEN
   - `select job_code, tagline from job where job_code='security';`
     → `정보 시스템의 취약점을 진단하고 보안 대책을 수립·운영하는 직무`

### D. STEP 3 — 서버 켜기 ("서버 켜줘" / "시연 준비")

```bash
./demo.sh up        # 10~15분. 이미지 빌드 없음. ECR latest 를 받아 기동
```

끝나면 `./demo.sh check` 결과와 함께 아래 문장을 출력해라:
> "PM 에게 'npm start 하세요' 라고 알리면 됩니다."

★ 서버를 켜도 DB 데이터는 그대로다. `stop.sh` 는 EC2·NAT·ALB 만 destroy 하고
RDS·Redis·S3·ECR·Route53·ACM 은 유지한다.

### E. 넛지 회전 규칙

무대에서는 `./demo.sh nudge` 만 친다 (인자 없이).
스크립트가 타입을 자동 회전시킨다:

| 회차 | 타입 | 문구 |
|---|---|---|
| 1 | ABSENCE_48H | 이틀 동안 못 봤어요. 오늘 퀘스트 하나만 해볼까요? |
| 2 | UPSET | 하루 종일 안 보이네요. 잠깐이라도 들러줄래요? |
| 3 | ANNOYING | 완료하지 않은 퀘스트가 기다리고 있어요. |
| 4 | → 1로 순환 | |

- 리허설 전에는 `./demo.sh nudge reset` 으로 카운터를 초기화한다
- 특정 타입을 꼭 써야 하면 `./demo.sh nudge UPSET` 으로 명시 지정한다 — 카운터를 건드리지 않는다
- 매 발사마다 문구에 보이지 않는 문자(U+200B)가 붙어 앱이 중복으로 판정하지 않는다
  → 앱 재시작 없이 같은 타입도 무한 반복 가능

### F. 넛지 동작 원리

서버는 신호를 메모리 큐(`ConcurrentHashMap`)에 넣는다.
앱이 `POST /api/heartbeat` 를 보내는 순간 consume(remove) 되어 화면이 바뀐다.
- 큐는 만료되지 않는다 → 앱이 물어보기만 하면 반드시 전달된다
- `queue()` 가 put 이라 여러 번 쏴도 하나로 덮인다. 연타 무의미
- 메모리에 있으므로 **★ 넛지를 쏜 뒤에는 절대 재배포·재시작하지 마라**

200 인데 화면이 안 바뀌면 앱이 안 물어보는 것이다. 아래를 안내만 해라:
1. PM 노트북에 앱이 떠 있나 (터미널 창 닫으면 죽는다)
2. 앱이 로그인돼 있나
3. 로그인 계정이 지정한 userId 와 같은가 ← 가장 흔한 원인
4. 폴링 주기가 긴가 (30초면 최대 30초)

HTTP 코드: 403=토큰불일치 / 404=userId없음·데모모드꺼짐 / 000=서버꺼짐

### F. 절대 규칙

- **`deploy/env.core` 를 절대 지우지 마라.**
  `deploy.sh` 는 배포마다 이 파일을 다시 쓰는데 값을 이 파일 자신에서 승계한다.
  JWT_SECRET·DB_PASSWORD·GOOGLE_*·MYITH_DEMO_*·CORS 의 유일한 원본이다.
  지우면 전부 빈 값이 되고 데모 엔드포인트가 404 가 된다.
- `start.sh` / `stop.sh` / `deploy.sh` / `build-and-deploy.sh` 를 수정하지 마라. 실행만.
- `terraform apply`·`destroy` 를 직접 부르지 마라.
- DB 를 사용자 승인 없이 수정하지 마라 (SELECT 는 자유).
- Vercel DNS 값을 추측하지 마라. 사용자가 준 값만 쓴다.
- 실패하면 멈추고 로그를 보고해라. 다른 방법을 임의로 시도하지 마라.
