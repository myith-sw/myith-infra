# MYiTH 인프라

Core(Spring Boot) + Worker(FastAPI) 백엔드를 AWS에 배포하는 Terraform 코드.
설계 배경과 결정 근거는 `CLAUDE.md` 참조.

## 파일 구성

```
myith-infra/
├── CLAUDE.md                    ← 설계 결정·근거·미해결 항목 (먼저 읽을 것)
├── main.tf                      전체 인프라 정의
├── variables.tf                 변수
├── terraform.tfvars.example     값 입력 템플릿 (복사해서 terraform.tfvars 로)
├── docker-compose.core.yml      Core EC2 배포용
├── docker-compose.worker.yml    Worker EC2 배포용 (RabbitMQ 포함)
├── scripts/bootstrap.sh         EC2 부팅 시 Docker 자동 설치
└── .gitignore
```

## 사전 준비 (사람이 하는 것)

```bash
# 1. 도구 설치 (Mac)
brew install terraform awscli

# 2. AWS 자격증명
aws configure
#   region: ap-northeast-2

# 3. SSH 키
ssh-keygen -t ed25519 -f ~/.ssh/myith-key -C myith
cat ~/.ssh/myith-key.pub   # 이 값을 tfvars 에 넣음

# 4. 변수 파일
cp terraform.tfvars.example terraform.tfvars
#   terraform.tfvars 열어서 db_password, ssh_public_key 채우기
```

## 배포

```bash
terraform init

# Step 1 — Route53 존만 먼저 (NS 값 확보)
terraform apply -target=aws_route53_zone.main
terraform output route53_name_servers
```

**→ 가비아: 도메인 관리 > 네임서버 설정 > "타사 네임서버 사용" 선택 후 NS 4개 입력**
("가비아 네임서버 사용" 아님)

```bash
# Step 2 — 전파 확인 (awsdns 값 나올 때까지, 보통 1시간 이내)
dig NS myith.store +short

# Step 3 — 전체 배포
terraform plan     # 먼저 오류 확인 (리소스 안 만듦, 비용 0)
terraform apply
terraform output   # 엔드포인트 값들 확인
```

## 앱 배포

```bash
# 이미지 빌드 & 푸시
CORE_URI=$(terraform output -raw ecr_core_repository_url)
WORKER_URI=$(terraform output -raw ecr_worker_repository_url)
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin $CORE_URI

docker build -t $CORE_URI:latest ../myith-core && docker push $CORE_URI:latest
docker build -t $WORKER_URI:latest ../myith-worker && docker push $WORKER_URI:latest
```

각 EC2에서 (Core는 SSH, Worker는 SSM Session Manager로 접속):
`terraform output` 값들을 환경변수로 export 후 `docker compose -f docker-compose.xxx.yml up -d`

## 확인

```bash
curl https://api.myith.store/api/health
```

## 종료

```bash
terraform destroy
```

## 주의

- `terraform.tfvars` 와 `*.tfstate` 는 DB 비밀번호를 포함한다. 절대 커밋 금지.
- 시연 종료 즉시 destroy. stop만으로는 EBS·EIP·NAT 과금이 계속된다.
- AWS Budgets에 월 $50 알림 설정 권장.
- ALB 헬스체크 경로는 `/api/health`로 설정됨 (Core의 실제 경로와 일치). 변경 불필요.
  단, Spring Security가 이 경로를 막으면 401이 떠서 unhealthy가 된다. `permitAll()` 확인 필수.
