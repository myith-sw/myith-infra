#!/bin/bash
# 이미지 빌드 + ECR 푸시 + deploy.sh 까지 한 번에 실행한다.
#
#   ./build-and-deploy.sh          Worker + Core 둘 다
#   ./build-and-deploy.sh core     Core 만
#   ./build-and-deploy.sh worker   Worker 만
#
# 필수: Docker Desktop 실행 중, AWS CLI 설정 완료, terraform init 완료
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="/Users/sungyoon/Desktop/sw-contest/myith-core"
WORKER_DIR="/Users/sungyoon/Desktop/sw-contest/myith-worker/myith-worker"
INFRA_DIR="$SCRIPT_DIR"

TARGET="${1:-all}"
case "$TARGET" in all|core|worker) ;; *) echo "사용법: ./build-and-deploy.sh [all|core|worker]"; exit 1 ;; esac

# terraform output 에서 ECR URL 가져오기
cd "$INFRA_DIR"
CORE_ECR=$(terraform output -raw ecr_core_repository_url)
WORKER_ECR=$(terraform output -raw ecr_worker_repository_url)
REGION=ap-northeast-2
REGISTRY="${CORE_ECR%%/*}"

echo "════════════════════════════════════════"
echo " MYiTH 빌드 + 배포 ($TARGET)"
echo "════════════════════════════════════════"
echo ""

# ECR 로그인
echo "── ECR 로그인 ──"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY" 2>/dev/null
echo "  ✓"

# Worker 빌드 + 푸시
if [ "$TARGET" = "all" ] || [ "$TARGET" = "worker" ]; then
  echo ""
  echo "── Worker 이미지 빌드 ──"
  cd "$WORKER_DIR"
  SHA_W=$(git rev-parse --short HEAD)
  echo "  SHA: $SHA_W"

  docker build --platform linux/amd64 -t "$WORKER_ECR:$SHA_W" -t "$WORKER_ECR:latest" . 2>&1 | tail -3
  echo "  빌드 ✓"

  echo "── Worker 푸시 ──"
  docker push "$WORKER_ECR:$SHA_W" 2>&1 | grep -E "digest|Pushed|exists" | tail -3
  docker push "$WORKER_ECR:latest" 2>&1 | grep -E "digest|Pushed|exists" | tail -3
  echo "  푸시 ✓ ($WORKER_ECR:$SHA_W + latest)"
fi

# Core 빌드 + 푸시
if [ "$TARGET" = "all" ] || [ "$TARGET" = "core" ]; then
  echo ""
  echo "── Core 이미지 빌드 ──"
  cd "$CORE_DIR"
  SHA_C=$(git rev-parse --short HEAD)
  echo "  SHA: $SHA_C"

  ./gradlew bootJar -q
  docker build --platform linux/amd64 -t "$CORE_ECR:$SHA_C" -t "$CORE_ECR:latest" . 2>&1 | tail -3
  echo "  빌드 ✓"

  echo "── Core 푸시 ──"
  docker push "$CORE_ECR:$SHA_C" 2>&1 | grep -E "digest|Pushed|exists" | tail -3
  docker push "$CORE_ECR:latest" 2>&1 | grep -E "digest|Pushed|exists" | tail -3
  echo "  푸시 ✓ ($CORE_ECR:$SHA_C + latest)"
fi

# deploy.sh 실행
echo ""
echo "── 배포 시작 (deploy.sh $TARGET) ──"
cd "$INFRA_DIR"
./deploy.sh "$TARGET"
