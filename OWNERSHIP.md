# 저장소 소유권과 경계

MYiTH 는 저장소 3개로 나뉘어 있고 각각 다른 Claude Code 세션이 담당한다.
"이건 어디서 고쳐야 하나"에서 반복해서 시간을 쓰고 있어 이 문서를 정본으로 둔다.

배포 순서와 환경변수 계약은 **여기가 정본이다.** 다른 문서와 어긋나면 이 문서를 따른다.

---

## 1. 저장소별 소유 범위

| 저장소 | 스택 | 소유하는 것 |
|---|---|---|
| **myith-infra** | Terraform + bash | AWS 리소스 전부(`main.tf`) · `docker-compose.{core,worker}.yml` · 배포 스크립트 전부<br>ECR 리포지토리 · S3 버킷 · IAM · 보안그룹 · 인스턴스 타입 · 스왑 설정 |
| **myith-worker** | Python / FastAPI | 공유 테이블 DDL(Alembic) · 시드 데이터 · 외부 API 수집 · LLM 호출 |
| **myith-core** | Java 21 / Spring Boot | Core 소유 테이블(Flyway: users·roadmap·quest·star 등) · REST API · SSE |

**배포는 전부 myith-infra 가 수행한다.** Core·Worker 저장소는 컨테이너 이미지만
만들고, 빌드 → ECR 푸시 → S3 설정 업로드 → SSM 원격 실행까지 전부
`myith-infra/build-and-deploy.sh` 한 줄에서 돈다.

경계가 헷갈릴 때의 판단 기준:

- **AWS 콘솔에 보이는 것** → myith-infra
- **컨테이너 안에서 도는 것** → 해당 앱 저장소
- **컨테이너에 전달되는 값** → myith-infra (compose 와 deploy.sh 가 소유)
- **테이블 스키마** → 그 테이블을 만든 쪽 (아래 2번 참조)

---

## 2. 배포 순서 — 바꾸지 말 것

Core 의 `application.yml` 은 `ddl-auto: validate` 다. 그리고 Core 에는
**Worker 소유 테이블 6개**를 매핑하는 `@Entity` 가 있다.

```
job · job_profile · ncs_unit · ncs_certification · skill_ncs_map · user_competency
```

Core 의 Flyway 는 이 테이블들을 만들지 않는다. Worker 의 Alembic 이 만든다.

> **Worker 의 `alembic upgrade head` 가 먼저 돌지 않으면 Core 는 기동 자체가 실패한다.**
> `SchemaManagementException` 이 뜨고, 런타임 500 이 아니라 **컨테이너가 안 뜬다.**

따라서 순서는 고정이다:

```
Worker alembic upgrade head
  → Worker seed (python -m app.seed.load_all)
    → Core 부팅
      → Worker 컨테이너(uvicorn) 기동
```

`deploy.sh` 의 `remote_script()` 가 이미 이 순서로 되어 있다
([deploy.sh:126-150](deploy.sh#L126-L150)). Worker 를 Core 보다 먼저 배포하는 것은
RabbitMQ 가 Worker EC2 에 동거하기 때문이기도 하다.

**이 순서를 바꾸지 마라.**

---

## 3. 환경변수 계약 — 이름을 바꾸면 조용히 깨진다

여기가 가장 사고가 잦은 지점이다. 두 가지 규칙이 겹쳐 있다.

1. **compose 의 `environment:` 에 없는 변수는 컨테이너에 전달되지 않는다.**
   `.env` 파일에 값이 있어도 소용없다. compose 가 매핑해야 들어간다.
2. **`deploy.sh` 의 `get()` 승계 목록에 없는 키는 다음 배포에서 지워진다.**
   `deploy.sh` 는 매번 `deploy/env.*` 를 히어독으로 통째로 다시 쓴다.
   손으로 넣은 값도 승계 목록에 없으면 그때 사라진다.

### 새 환경변수를 추가할 때 — 세 곳을 반드시 같이 고친다

| # | 파일 | 고칠 것 |
|---|---|---|
| ① | `deploy.sh` | `get()` 승계 라인 추가 — `X=$(get X env.worker)` |
| ② | `deploy.sh` | `env.core` / `env.worker` 히어독에 `X=$X` 추가 |
| ③ | `docker-compose.{core,worker}.yml` | `environment:` 에 `X: ${X}` 추가 |

하나라도 빠뜨리면 증상이 다르다. 이게 진단을 어렵게 만든다:

- **①만 빠짐** → 첫 배포는 되는데 다음 배포에서 값이 사라진다
- **③만 빠짐** → `.env` 에는 값이 있고 `deploy.sh` 도 "값 있음"으로 통과하는데
  컨테이너 안에서는 비어 있다. **겉으로는 정상으로 보인다.**
  실제로 `CORS_ALLOWED_ORIGINS` 가 이 상태였다

### 이름이 다른 것 — 의도된 것이다

```
Core 앱이 읽는 이름      RABBITMQ_USERNAME
env 파일에 쓰는 이름     RABBITMQ_USER

docker-compose.core.yml 이 RABBITMQ_USERNAME: ${RABBITMQ_USER} 로 매핑한다.
둘 중 하나로 통일하지 마라. compose 매핑이 다리 역할이다.
```

### 현재 승계되는 키 (2026-07 기준)

```
env.core     JWT_SECRET · RABBITMQ_USER · RABBITMQ_PASSWORD
             GOOGLE_CLIENT_ID · GOOGLE_DESKTOP_CLIENT_ID
             CORS_ALLOWED_ORIGINS
             MYITH_DEMO_ENABLED · MYITH_DEMO_TOKEN
env.worker   LLM_PROVIDER · LLM_API_KEY · LLM_MODEL · LLM_MODEL_LIGHT
             NCS_SERVICE_KEY · WANTED_API_KEY · GITHUB_TOKEN
```

나머지(RDS·Redis·S3·ECR 엔드포인트, 인스턴스 ID)는 승계가 아니라
매번 `terraform output` 에서 새로 읽는다. 인프라를 `stop.sh`/`start.sh` 로
재생성하면 값이 바뀌기 때문이다.

`GOOGLE_DESKTOP_CLIENT_ID` 출처: Google Cloud Console 의 **Desktop application**
OAuth Client ID 다. 웹 Client 와 **같은 프로젝트에 생성해야** OAuth 동의 화면과
테스트 사용자 목록을 공유한다. 다른 프로젝트에 만들면 동의 화면 설정과
테스트 사용자를 따로 관리해야 하고, 미승인 앱 경고가 따로 뜬다.

Electron 은 웹이 아니라 Desktop Client 로 로그인하므로 ID Token 의 `aud` 가
웹 Client ID 와 다르다. Core 가 두 audience 를 모두 허용해야 통과한다.
**비어 있어도 Core 는 정상 기동한다** — 빈 값을 걸러내도록 구현돼 있어,
미설정 시 웹 로그인만 동작하고 Electron 로그인만 실패한다. 그래서
`deploy.sh` 의 경고 루프에는 넣지 않았다. Electron 을 쓰지 않는 배포에서도
정상인 값이라 매번 경고하면 노이즈가 된다.

`LLM_PROVIDER` 주의: Worker `config/settings.py` 의 기본값이 `"vertex"` 다.
명시하지 않으면 API 키가 있어도 Vertex 경로로 붙으려다 실패한다.
GCP 결제 프로필 문제로 Anthropic 직접 API 로 전환했으므로 `anthropic` 이어야 한다.

`MYITH_DEMO_*` 주의: 시연 전용 넛지 API(`POST /api/demo/nudge`)를 켜는 스위치다.
Core 의 `DemoController` 가 `@ConditionalOnProperty(havingValue = "true")` 라
**꺼져 있으면 빈 자체가 등록되지 않고 404 가 난다.** 500 이나 401 이 아니라 404 이므로
"경로를 잘못 썼나"로 오진하기 쉽다.

**기본값은 `false` 다. 시연 직전에만 켠다.** `SecurityConfig` 가 `/api/demo/**` 를
permitAll 로 열어두기 때문에, 켜는 순간 인증을 통과한 사용자가 아니어도 경로에 닿는다.
**유일한 방어선이 `X-Demo-Token` 헤더 검증 하나뿐이다.**

토큰을 비워두면 어떻게 되는지는 알아둘 것: `DemoController` 가
`demoToken.isBlank()` 를 먼저 보고 403 을 던진다(fail-closed). 즉 빈 토큰이
API 를 열어버리지는 않고, 대신 **무슨 요청을 보내도 403 이라 시연이 안 된다.**
무대 위에서 403 을 보고 원인을 찾는 상황이 최악이므로 `ENABLED=true` 와
`TOKEN` 은 항상 같이 설정한다.

증상별 원인 구분:

| 응답 | 원인 |
|---|---|
| `404` | `MYITH_DEMO_ENABLED` 가 false/미전달 — 빈 자체가 없다 |
| `400` | `X-Demo-Token` 헤더 자체를 안 보냈다 |
| `403` | 토큰 불일치, **또는 서버측 `MYITH_DEMO_TOKEN` 이 비어 있다** |
| `404` + `User not found` | 켜진 건 맞고 `userId` 가 없다 |

```bash
# deploy/env.core 에 추가한 뒤  ./deploy.sh core
MYITH_DEMO_ENABLED=true
MYITH_DEMO_TOKEN=<임의의 긴 문자열>
```

토큰 값은 스크립트나 compose 에 하드코딩하지 않는다. `deploy/env.core` 에만 둔다.
시연이 끝나면 `MYITH_DEMO_ENABLED=false` 로 되돌리고 다시 배포한다.

---

## 4. 자주 틀리는 것

| 증상 | 원인 | 대응 |
|---|---|---|
| `exec format error` | `--platform linux/amd64` 누락 | 빌드 시 플랫폼 명시. 맥은 arm64 라 그냥 빌드하면 EC2 에서 안 돈다 |
| 태그가 `...appatest` 로 깨짐 | zsh 에서 `"$VAR:latest"` 중괄호 누락 | `"${VAR}:latest"` 로 쓴다 |
| `no basic auth credentials` | ECR 토큰 12시간 만료 | `aws ecr get-login-password ... \| docker login` 재실행 |
| Worker 에 SSH 가 안 됨 | 프라이빗 서브넷이라 공인 IP 자체가 없다 | SSM Session Manager 만 가능. 접속 후 `sudo su - ubuntu` |
| SSM 붙자마자 명령이 로컬에서 실행됨 | 세션이 열리기 전에 붙여넣음 | `aws ssm start-session` 후 **`$` 프롬프트가 뜬 뒤에** 붙여넣는다. 여러 줄은 특히 주의 |
| `.env` 에 값이 있는데 컨테이너에 없음 | compose `environment:` 누락 | 위 3번 ③ 참조 |
| 손으로 넣은 값이 배포 후 사라짐 | `deploy.sh` 의 `get()` 승계 누락 | 위 3번 ① 참조 |
| **고쳤는데 반영이 안 된다** | 로컬 pull 누락. `build-and-deploy.sh` 는 원격이 아니라 **로컬 작업 트리**를 빌드한다 | 스크립트가 `dev` 를 자동 pull 하지만, 다른 브랜치에서 작업했거나 push 를 안 했으면 그대로 옛 코드다. 증상이 "반영이 안 된다"로만 나와 진단이 어렵다 |
| 배포했는데 아무 일도 안 일어남 | 미커밋 변경 + 백그라운드 실행. stdin 이 없어 확인을 못 받고 중단된다 | 배포 전 `git -C "$CORE_DIR" status --porcelain` 로 두 저장소가 깨끗한지 확인. `> /dev/null` 이면 중단 사유도 안 보인다 |

---

## 5. Terraform 이 하지 않는 것 — 사람이 해야 하는 것

| 작업 | 상태 |
|---|---|
| 도메인 `myith.store` 구매 (가비아) | 완료 |
| 가비아 네임서버 위임 (타사 네임서버 사용 → NS 4개 입력) | — |
| SSH 키 생성 (`ssh-keygen`) | — |
| `terraform.tfvars` 작성 (DB 비밀번호, 공개키) | — |
| LLM / NCS / Wanted API 키 발급 → `deploy/env.worker` 에 직접 기입 | — |
| AWS 자격증명 등록 (`aws configure`) | — |

`terraform.tfvars` 와 `deploy/env.*` 는 평문 비밀번호를 담는다.
`.gitignore` 에 있지만 `git add -f` 로 강제 추가하지 마라.

---

## 6. 현재 인프라 상태

`terraform apply` 는 **이미 실행됐다.** RDS · ElastiCache · VPC · ALB · ACM ·
Route53 · ECR · S3 가 떠 있고 `api.myith.store` 가 연결돼 있다.

`start.sh` / `stop.sh` 는 시간당 과금이 큰 4개(EC2 2대 · NAT · ALB)만 켜고 끈다.
**terraform 을 새로 짜거나 전체 재적용할 일은 없다.**

### 배포 경로에 반영된 것

| 항목 | 상태 |
|---|---|
| `LLM_PROVIDER` (anthropic) | deploy.sh 승계 + compose 주입 완료 |
| `CORS_ALLOWED_ORIGINS` | deploy.sh 승계 + compose 주입 완료 |
| `MYITH_DEMO_ENABLED` / `MYITH_DEMO_TOKEN` | deploy.sh 승계 + 히어독 + compose 주입 완료. **기본 꺼짐(false)** |
| 배포 전 `dev` 자동 pull | `build-and-deploy.sh` 가 두 저장소를 동기화. 미커밋이면 중단 |

시연용 넛지 API 를 켜는 절차는 위 **3번 환경변수 계약**의 `MYITH_DEMO_*` 항목에
있다 — `deploy/env.core` 에 두 줄 추가 후 `./deploy.sh core`, 끝나면 `false` 로
되돌리고 재배포. 응답 코드(404/400/403)별 원인 구분표도 거기 있다.

운영 절차(정지·시작·배포·실패 진단)는 [OPS.md](OPS.md) 를 본다.
인프라 설계 근거와 의도적으로 제외한 항목은 [CLAUDE.md](CLAUDE.md) 를 본다.
