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
