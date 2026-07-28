#!/bin/bash
# 컨테이너 배포. 인프라는 이미 떠 있다고 가정한다.
#
#   ./deploy.sh          Worker + Core 둘 다
#   ./deploy.sh core     Core 만
#   ./deploy.sh worker   Worker 만
#
# 하는 일:
#   1. terraform output 에서 엔드포인트를 읽고 .env 를 만든다
#      (시크릿은 기존 deploy/env.* 에서 승계 — 다시 입력할 필요 없음)
#   2. compose + .env 를 S3 에 올린다
#   3. SSM 으로 각 인스턴스에서 내려받아 컨테이너를 띄운다
#   4. ALB 200 을 확인한다
#   5. S3 에 올린 .env 를 지운다 (비밀번호 포함이라 남기지 않는다)
#
# SSH 를 쓰지 않고 SSM 만 쓴다. 인스턴스를 재생성하면 SSH 호스트 키가 바뀌어
# known_hosts 충돌이 나는데, SSM 은 그 문제가 없다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TARGET="${1:-all}"
case "$TARGET" in all|core|worker) ;; *) echo "사용법: ./deploy.sh [all|core|worker]"; exit 1 ;; esac

start_logging "deploy.sh"
preflight

echo "══ 1/5  값 수집 ══"
RDS=$(tfout rds_endpoint);            REDIS=$(tfout redis_endpoint)
BUCKET=$(tfout s3_uploads_bucket);    WIP=$(tfout worker_private_ip)
CORE_ECR=$(tfout ecr_core_repository_url)
WORKER_ECR=$(tfout ecr_worker_repository_url)
CORE_ID=$(tfout core_instance_id);    WORKER_ID=$(tfout worker_instance_id)
API_URL=$(tfout api_url)
REGISTRY="${CORE_ECR%%/*}"

for v in RDS REDIS BUCKET WIP CORE_ID WORKER_ID; do
  [ -n "${!v}" ] || { echo "  !! terraform output 에 $v 없음. 인프라가 떠 있나요?"; exit 1; }
done

DBPW=$(grep '^db_password' terraform.tfvars | sed 's/.*=[[:space:]]*"//; s/"[[:space:]]*$//')
[ -n "$DBPW" ] || { echo "  !! terraform.tfvars 에서 db_password 를 못 읽음"; exit 1; }

# 기존 env 파일에서 시크릿 승계. 파일이나 키가 없으면 빈 값.
get() { grep "^$1=" "deploy/$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
JWT=$(get JWT_SECRET env.core)
MQUSER=$(get RABBITMQ_USER env.core)
MQPASS=$(get RABBITMQ_PASSWORD env.core)
GOOGLE=$(get GOOGLE_CLIENT_ID env.core)
CORS=$(get CORS_ALLOWED_ORIGINS env.core)
DEMOEN=$(get MYITH_DEMO_ENABLED env.core)
DEMOTK=$(get MYITH_DEMO_TOKEN env.core)
LLMP=$(get LLM_PROVIDER env.worker)
LLM=$(get LLM_API_KEY env.worker);        LLMM=$(get LLM_MODEL env.worker)
LLML=$(get LLM_MODEL_LIGHT env.worker);   NCS=$(get NCS_SERVICE_KEY env.worker)
WANTED=$(get WANTED_API_KEY env.worker);  GHT=$(get GITHUB_TOKEN env.worker)

mkdir -p deploy
cat > deploy/env.core <<EOF
ECR_CORE_URI=$CORE_ECR
RDS_ENDPOINT=$RDS
REDIS_ENDPOINT=$REDIS
WORKER_PRIVATE_IP=$WIP
S3_UPLOADS_BUCKET=$BUCKET
DB_PASSWORD=$DBPW
RABBITMQ_USER=$MQUSER
RABBITMQ_PASSWORD=$MQPASS
JWT_SECRET=$JWT
GOOGLE_CLIENT_ID=$GOOGLE
CORS_ALLOWED_ORIGINS=$CORS
MYITH_DEMO_ENABLED=${DEMOEN:-false}
MYITH_DEMO_TOKEN=$DEMOTK
EOF

cat > deploy/env.worker <<EOF
ECR_WORKER_URI=$WORKER_ECR
RDS_ENDPOINT=$RDS
REDIS_ENDPOINT=$REDIS
S3_UPLOADS_BUCKET=$BUCKET
DB_PASSWORD=$DBPW
RABBITMQ_USER=$MQUSER
RABBITMQ_PASSWORD=$MQPASS
LLM_PROVIDER=${LLMP:-anthropic}
LLM_API_KEY=$LLM
LLM_MODEL=$LLMM
LLM_MODEL_LIGHT=$LLML
NCS_SERVICE_KEY=$NCS
WANTED_API_KEY=$WANTED
GITHUB_TOKEN=$GHT
EOF

# 비면 배포는 되지만 기능이 죽는 값들 — 경고만 하고 진행한다.
warned=0
for k in JWT_SECRET RABBITMQ_PASSWORD GOOGLE_CLIENT_ID CORS_ALLOWED_ORIGINS; do
  [ -z "$(grep "^$k=" deploy/env.core | cut -d= -f2-)" ] && { echo "  !! 경고: $k 가 비어 있습니다"; warned=1; }
done
[ "$warned" = "0" ] && echo "  필수 시크릿 4종 승계 완료"
echo "  GOOGLE_CLIENT_ID 길이: ${#GOOGLE} (정상 72)"

echo "══ 2/5  S3 업로드 ══"
aws s3 cp docker-compose.core.yml   "s3://$BUCKET/deploy/" --only-show-errors
aws s3 cp docker-compose.worker.yml "s3://$BUCKET/deploy/" --only-show-errors
aws s3 cp deploy/env.core           "s3://$BUCKET/deploy/" --only-show-errors
aws s3 cp deploy/env.worker         "s3://$BUCKET/deploy/" --only-show-errors
echo "  완료"

# 원격 배포 스크립트를 만든다. $1=역할(core|worker)
remote_script() {
  local role="$1" compose="docker-compose.$1.yml" envfile="env.$1"
  cat <<EOS
set -e
# bootstrap.sh 가 Docker 를 까는 데 시간이 걸린다. 새 인스턴스면 기다린다.
for i in \$(seq 1 60); do
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && break
  [ "\$i" = "60" ] && { echo "docker 준비 안 됨 (5분 초과)"; exit 1; }
  sleep 5
done

cd /home/ubuntu
aws s3 cp s3://$BUCKET/deploy/$compose . --only-show-errors
aws s3 cp s3://$BUCKET/deploy/$envfile ./.env --only-show-errors
chown ubuntu:ubuntu $compose .env

aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin $REGISTRY

docker compose -f $compose pull
EOS

  # Worker 배포 시: RabbitMQ 먼저 띄우고, 마이그레이션+시드를 일회성으로 실행한 뒤 앱 기동
  if [ "$role" = "worker" ]; then
    cat <<EOS

# --- Worker 마이그레이션 + 시드 (Core validate 통과를 위해 반드시 먼저 실행) ---
# RabbitMQ 를 먼저 올린다. worker 컨테이너의 depends_on 조건 충족 필요.
docker compose -f $compose up -d rabbitmq
echo "  RabbitMQ healthy 대기..."
for i in \$(seq 1 30); do
  docker compose -f $compose exec rabbitmq rabbitmq-diagnostics -q ping >/dev/null 2>&1 && break
  [ "\$i" = "30" ] && { echo "RabbitMQ 가 30회 내 healthy 안 됨"; exit 1; }
  sleep 2
done
echo "  RabbitMQ ready ✓"

echo "  Alembic 마이그레이션 실행..."
docker compose -f $compose run --rm worker alembic upgrade head
echo "  Alembic ✓"

echo "  시드 적재..."
docker compose -f $compose run --rm worker python -m app.seed.load_all
echo "  시드 ✓"
# --- 마이그레이션 완료. 이제 앱(uvicorn) 기동 ---

EOS
  fi

  cat <<EOS
docker compose -f $compose up -d
docker image prune -f >/dev/null 2>&1 || true

echo "--- 컨테이너 상태 ---"
docker compose -f $compose ps
EOS
}

if [ "$TARGET" = "all" ] || [ "$TARGET" = "worker" ]; then
  # Worker 를 먼저 띄운다. RabbitMQ 가 여기 있어서 Core 가 이걸 필요로 한다.
  echo "══ 3/5  Worker 배포 ══"
  wait_ssm "$WORKER_ID" "Worker"
  remote_script worker | ssm_run "$WORKER_ID" "Worker 컨테이너"
else
  echo "══ 3/5  Worker 건너뜀 ══"
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "core" ]; then
  echo "══ 4/5  Core 배포 ══"
  wait_ssm "$CORE_ID" "Core"
  remote_script core | ssm_run "$CORE_ID" "Core 컨테이너"
  wait_alb "$API_URL/api/health"
else
  echo "══ 4/5  Core 건너뜀 ══"
fi

echo "══ 5/5  S3 시크릿 정리 ══"
aws s3 rm "s3://$BUCKET/deploy/env.core"   --only-show-errors 2>/dev/null || true
aws s3 rm "s3://$BUCKET/deploy/env.worker" --only-show-errors 2>/dev/null || true
echo "  완료 (compose 파일만 남김)"

echo ""
echo "════════════════════════════════════════"
echo " 배포 완료"
echo "   API      $API_URL/api/health"
echo "   Swagger  $API_URL/swagger-ui.html"
echo "   Core     $CORE_ID  /  $(tfout core_public_ip)"
echo "   Worker   $WORKER_ID  /  $WIP"
echo "════════════════════════════════════════"

finish_logging DEPLOY
