# MYiTH 인프라 — 작업 컨텍스트

이 문서는 Claude Code가 이 레포에서 작업할 때 필요한 배경과 결정 사항을 담는다.
코드만 봐서는 알 수 없는 "왜 이렇게 했는지"가 여기 있다.

---

## 프로젝트 개요

**MYiTH(신화)** — 데스크톱 상주형 AI 커리어 로드맵 서비스. SW 공모전 출품작.

- 4인 팀, 나는 백엔드 담당 (Core + Worker 양쪽)
- **Core**: Java 21 / Spring Boot — 사용자 요청 처리, CQRS
- **Worker**: Python / FastAPI — LLM 호출, 외부 API 수집
- **Electron**: 데스크톱 컴패니언 (캐릭터 성장, 퀘스트)
- 데이터 소스: 원티드 채용공고 + NCS 표준

---

## 현재 상태

| 항목 | 상태 |
|---|---|
| 도메인 `myith.store` | 가비아에서 **구매 완료** |
| 가비아 네임서버 위임 | **미완료** — Route53 존 생성 후 진행 예정 |
| Terraform apply | **미실행** |
| `terraform plan` 검증 | **미실행** — 이게 다음 할 일 |

---

## 인프라 설계 결정과 근거

### 서버 구조

```
사용자/Electron
    ↓ https://api.myith.store
Route53 → ALB (퍼블릭 서브넷 2a/2c)
    ↓
Core EC2 (퍼블릭 2a, t3.small)
    ↓ RabbitMQ (내부 통신)
Worker EC2 (프라이빗 2a, t3.small) ── RabbitMQ 컨테이너 동거
    ↓ NAT Gateway
외부 API (원티드 / NCS / LLM)

RDS PostgreSQL (프라이빗) ← Core, Worker
ElastiCache Redis (프라이빗) ← Core, Worker
S3 (Presigned URL 업로드)
```

### 핵심 원칙 — 이건 바꾸지 말 것

**아웃바운드 격리**: Core는 외부 API를 직접 호출하지 않는다. 원티드·NCS·LLM 호출은
오직 Worker와 Scheduler만 NAT Gateway를 통해 수행한다.
→ 외부 시스템의 장애나 지연이 사용자 요청 경로로 전이될 통로를 물리적으로 차단.

**역방향도 성립**: Worker는 인바운드를 받지 않는다.
→ Worker는 ALB 대상그룹에 등록하지 않고, Route53 레코드도 만들지 않는다.
→ 도메인이 1개만 필요한 이유. `api.myith.store` 하나로 끝.

**비동기 처리**: 로드맵 생성은 LLM 대기가 30초 이상이라 동기 처리 불가.
Core가 요청 접수 후 즉시 202 반환 → 큐에 적재 → Worker가 처리 → 결과 DB 저장.
Outbox 패턴으로 브로커 장애 시에도 이벤트 유실 방지.

---

## 의도적으로 제외한 것 — 다시 넣자고 제안하지 말 것

발표가 **정해진 시간에 1회 시연**으로 끝나고, 서버는 **1주일만 가동**한다.
심사위원이 발표 후 자유 접속하지 않는다. 이 조건에서 아래는 비용/복잡도 대비 이득이 없다.

| 제외 항목 | 근거 |
|---|---|
| Auto Scaling Group | 발표 중 부하가 튈 일이 없음. 다이어그램에는 "확장 설계"로 표기하되 코드에는 없음 |
| CloudFront | 랜딩페이지 없음. Electron이 API만 호출 |
| RDS Multi-AZ | 발표 도중 AZ 장애 확률 ~0, 비용은 2배 |
| RDS Read Replica | 실부하 없음 |
| NAT Gateway 이중화 | NAT 1개로 충분. 시간당 $0.045 절감 |
| Amazon MQ | RabbitMQ를 Worker EC2에 Docker로 자체 호스팅 (월 $25 절감) |
| ECS / Fargate | EC2 + docker-compose로 충분. 오케스트레이션 학습 비용 회피 |

**다이어그램에는 ASG가 그려져 있고 코드에는 없다.** 이건 의도된 것이다.
발표 시 "현재는 최소 구성 1대로 운영 중이며, 트래픽 증가 시 확장되도록 설계했습니다"로 설명한다.

---

## 미해결 항목 — 작업 시 확인 필요

### 1. ALB 헬스체크 경로 (해결됨)
`var.health_check_path` 기본값은 `/api/health`로 설정됨.
Core 앱에 실제로 존재하는 경로는 `GET /api/health` 하나뿐이며, 이 값과 일치한다.
경로를 바꾸지 말 것. 앱에 `/api/health`가 있으므로 ALB 타겟그룹이 정상 healthy 판정된다.

**단, 인증은 별개 문제다.** Spring Security가 `/api/health`를 막으면 ALB는
인증 헤더 없이 호출하므로 401/403을 받는다. matcher가 `200-399`라 이 경우
영구 unhealthy가 된다. `permitAll()` 처리 여부를 반드시 확인할 것.

### 2. Scheduler 미구현
원래 아키텍처 다이어그램에는 Scheduler(주기적 채용공고 수집·푸시)가 있는데
Terraform에는 없다. Worker EC2에 컨테이너로 추가하는 방향이 적절하다.
ECR 리포지토리도 core/worker 2개뿐이라, 추가 시 리포지토리도 함께 만들어야 한다.

### 3. terraform plan 미실행
컨테이너 환경 제약으로 `terraform validate`를 돌리지 못했다.
정적 검사(중괄호 균형, 리소스 참조 정합성, 변수 정의/사용 일치)는 통과했으나
AWS 스키마 위반(속성명 오타, 잘못된 enum 값)은 `terraform plan`을 돌려야 나온다.
**`plan`은 실제 리소스를 만들지 않으므로 비용 0원이다. 먼저 돌릴 것.**

---

## 이미 검증한 것 — 다시 의심하지 말 것

| 항목 | 검증 결과 |
|---|---|
| `engine_version = "16"` | 16.1~16.7은 2026-05-01부터 신규 생성 불가(deprecated). 메이저만 지정하면 AWS가 최신 마이너 자동 선택 |
| Worker SG에 SSH 없음 | 프라이빗 서브넷이라 공인 IP가 없어 SSH 자체가 불가능. SSM Session Manager가 유일한 경로 |
| bootstrap.sh 스왑 2GB | `bs=128M count=16` = 2048M. t3.small 메모리 2GB에 대한 OOM 방지용 |
| ECR 로그인을 부팅 시 안 함 | 토큰 유효기간 12시간. 부팅 때 받으면 배포 시점엔 이미 만료 |
| S3 IAM 정책 | Worker가 Presigned로 업로드된 PDF를 읽어야 하므로 필수 |
| S3 VPC Gateway Endpoint | NAT 경유 시 GB당 $0.045 과금. Endpoint는 시간당·전송 요금 모두 0원 |

---

## 코드에 의도적으로 넣은 보정 — 되돌리지 말 것

| 보정 | 이유 |
|---|---|
| EC2 `depends_on = [aws_route_table_association.*]` | Terraform은 서브넷 의존성만 보고 라우팅 연결과 인스턴스를 **병렬로** 만든다. 인스턴스가 먼저 부팅하면 bootstrap.sh의 `apt-get`이 인터넷에 못 나가고 `set -e`로 중단 → Docker 미설치. 특히 Worker는 NAT가 유일한 경로라 치명적 |
| `aws_db_parameter_group`에 `name_prefix` | 고정 `name` + `create_before_destroy` 조합은 교체 시 "새로 만들고 옛것 삭제" 순서라 이름이 충돌해 apply 실패 |
| RDS `storage_encrypted = true` | gp3 20GB 기준 추가 비용 없음. 끄고 얻을 이득이 없음 |

---

## 수작업 vs Terraform — 경계를 명확히

### 사람이 직접 하는 것 (Terraform이 못 하는 것)

| 작업 | 어디서 | 이미 완료? |
|---|---|---|
| 도메인 `myith.store` 구매 | 가비아 | **완료** |
| 가비아에서 "타사 네임서버 사용" 선택 후 NS 4개 입력 | 가비아 도메인 관리 > 네임서버 설정 | 미완료 |
| NS 전파 대기 (`dig NS myith.store +short`) | 로컬 터미널 | 미완료 |
| AWS 자격증명 등록 (`aws configure`) | 로컬 | 확인 필요 |
| SSH 키 생성 (`ssh-keygen`) | 로컬 | 미완료 |
| `terraform.tfvars` 작성 (비밀번호, 공개키) | 로컬 | 미완료 |
| 이미지 빌드 후 ECR push | 로컬 | 배포 시 |
| 각 EC2에서 `docker compose up -d` | SSH/SSM | 배포 시 |
| (팀 사용 시) S3 backend용 버킷·DynamoDB 테이블 선생성 | 콘솔 | 선택 |

### Terraform이 자동으로 하는 것

VPC·서브넷·IGW·NAT·라우팅, 보안그룹 5개, IAM 역할/정책, ECR 2개,
EC2 2대(부팅 시 Docker 자동 설치), ALB·타겟그룹·리스너,
**ACM 인증서 발급 + DNS 검증 자동**, Route53 존 + api 레코드,
RDS PostgreSQL(파라미터 그룹으로 Asia/Seoul), ElastiCache Redis,
S3 버킷 + CORS + VPC Endpoint.

→ 콘솔로 클릭했던 작업(호스팅 영역 생성, 인증서 요청,
   DNS 레코드 생성, 리스너에 인증서 연결)이 전부 코드로 대체됨.

### 가비아 네임서버 위임 — 실제 절차 (검증된 방식)

1. Terraform으로 `aws_route53_zone.main` 생성 → NS 4개 발급됨
   (`ns-XXXX.awsdns-XX.com` 형태)
2. 가비아 My가비아 > 도메인 관리 > 네임서버 설정
3. **"타사 네임서버 사용"** 선택 (기본값인 "가비아 네임서버 사용" 아님)
4. NS 4개를 1차~4차 칸에 순서대로 입력, 저장
5. `dig NS myith.store +short`로 awsdns 값 확인되면 위임 완료

이 방식이 검증됨: 가비아 네임서버를 Route53으로 위임하면
이후 ACM 검증 CNAME과 api 레코드가 Route53 안에서 자동 처리됨.

---

## 배포 순서 — 순서를 지킬 것

```bash
# 1) Route53 존만 먼저 생성
terraform init
terraform apply -target=aws_route53_zone.main
terraform output route53_name_servers

# 2) 가비아: 도메인 관리 > 네임서버 설정 > "타사 네임서버 사용"
#    위에서 나온 NS 4개를 1~4차 칸에 순서대로 입력

# 3) 전파 확인 (필수)
dig NS myith.store +short
#    awsdns 값이 나와야 함. 보통 1시간 이내.

# 4) 전체 apply
terraform plan     # 먼저 이걸로 오류 확인
terraform apply

# 5) 이미지 빌드/푸시 후 각 인스턴스에서 docker compose up -d
```

**3번을 건너뛰면 `aws_acm_certificate_validation`이 20분 대기 후 실패한다.**
ACM DNS 검증은 공인 DNS에서 CNAME이 조회돼야 통과하는데,
네임서버 위임 전이면 Route53에 레코드를 만들어도 인터넷에서 안 보인다.

---

## 비용 제약

- 1주일(168시간) 가동 기준 **약 $33~75**
- 시간당 과금 주범: NAT Gateway($0.045/h), ALB, RDS
- **인프라비보다 LLM API 비용이 더 클 수 있다.** 로드맵 200건 생성 시 $25~30.
  같은 LLM 호출을 두 번 하지 않는 것이 비용 설계의 핵심.
  → 직무 프로필은 사용자별이 아니라 **직무별로 생성해 캐싱**(TTL 24h)
  → 멱등성 키로 중복 생성 요청 차단
- **시연 종료 즉시 `terraform destroy`**. 인스턴스를 stop해도 EBS·EIP·NAT는 계속 과금된다.
- AWS Budgets에 월 $50 알림을 걸어둘 것.

---

## 코드 스타일 / 작업 원칙

- 이 레포는 **인프라 전용**이다. 앱 코드(Core/Worker)는 별도 레포.
- `terraform.tfstate`에 DB 비밀번호가 평문으로 들어간다. **절대 커밋 금지.**
- 팀원 여러 명이 apply할 경우 S3 backend + DynamoDB 락 활성화 필요
  (사전에 버킷/테이블을 콘솔로 먼저 생성해야 함 — 닭과 달걀 문제)
- 리소스 이름은 전부 `myith-` 접두어로 통일한다.
- 변경 제안 시 **트레이드오프를 명시**할 것. "이게 더 좋습니다"가 아니라
  "A는 X를 얻고 Y를 잃습니다"로.

---

## 인프라 운영

"서버 켜줘/꺼줘/배포해줘" 요청 시 이 파일과 같은 디렉토리의 `OPS.md`를 읽고 지시를 따른다.

## 저장소 경계

저장소가 3개(core/worker/infra)다. "이건 어디 일인가"가 헷갈리면 `OWNERSHIP.md`를 본다.
**배포 순서와 환경변수 계약은 `OWNERSHIP.md`가 정본이다.** 특히 환경변수를 추가할 때는
`deploy.sh` 승계 · `deploy.sh` 히어독 · `docker-compose.*.yml` 세 곳을 반드시 같이 고친다.
