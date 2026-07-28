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

# ── 배포 전 git 동기화 ──
sync_repo() {
  local dir="$1" name="$2"
  cd "$dir"
  if [ -n "$(git status --porcelain)" ]; then
    echo "  ⚠ $name 에 미커밋 변경이 있습니다:"
    git status --short
    echo ""
    # OPS.md 가 안내하는 nohup 백그라운드 실행에는 stdin 이 없다.
    # 그대로 read 를 부르면 EOF 로 실패하고 set -e 가 이유도 없이 스크립트를 죽인다.
    # (stdout 이 /dev/null 이면 운영자는 아무것도 못 본다)
    # 읽기 자체가 실패하면 = 물어볼 수단이 없다는 뜻이므로 중단한다 — fail-closed.
    # `[ -t 0 ]` 대신 read 실패로 판정하는 이유: 그러면 `echo y | ...` 같은
    # 파이프 입력은 그대로 동작한다. TTY 검사는 이것까지 막아버린다.
    if ! read -r -p "  이대로 빌드하시겠습니까? (y/N) " ans; then
      echo "  비대화형 실행이라 확인을 받을 수 없어 중단합니다."
      echo "  커밋하거나 되돌린 뒤 다시 실행하세요."
      echo "  미커밋 상태 그대로 빌드하려면 터미널에서 직접 실행하세요."
      exit 1
    fi
    if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
      echo "  중단합니다."
      exit 1
    fi
  fi
  echo "  git pull ($name)..."
  git checkout dev && git pull origin dev
  echo "  ✓ $name → $(git rev-parse --short HEAD)"
}

echo "── 저장소 동기화 ──"
if [ "$TARGET" = "all" ] || [ "$TARGET" = "worker" ]; then
  sync_repo "$WORKER_DIR" "Worker"
fi
if [ "$TARGET" = "all" ] || [ "$TARGET" = "core" ]; then
  sync_repo "$CORE_DIR" "Core"
fi
echo ""

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

  docker build --platform linux/amd64 -t "$WORKER_ECR:$SHA_W" . 2>&1 | tail -3
  echo "  빌드 ✓"

  echo "── Worker 푸시 ──"
  docker push "$WORKER_ECR:$SHA_W" 2>&1 | grep -E "digest|Pushed|exists" | tail -3
  # ECR 서버사이드 retag (Docker Desktop containerd 태그 버그 완전 회피)
  MANIFEST_W=$(aws ecr batch-get-image --repository-name "${WORKER_ECR##*/}" --region "$REGION" \
    --image-ids imageTag="$SHA_W" --query 'images[0].imageManifest' --output text)
  aws ecr put-image --repository-name "${WORKER_ECR##*/}" --region "$REGION" \
    --image-tag latest --image-manifest "$MANIFEST_W" >/dev/null 2>&1
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
  docker build --platform linux/amd64 -t "$CORE_ECR:$SHA_C" . 2>&1 | tail -3
  echo "  빌드 ✓"

  echo "── Core 푸시 ──"
  docker push "$CORE_ECR:$SHA_C" 2>&1 | grep -E "digest|Pushed|exists" | tail -3
  # ECR 서버사이드 retag (Docker Desktop containerd 태그 버그 완전 회피)
  MANIFEST_C=$(aws ecr batch-get-image --repository-name "${CORE_ECR##*/}" --region "$REGION" \
    --image-ids imageTag="$SHA_C" --query 'images[0].imageManifest' --output text)
  aws ecr put-image --repository-name "${CORE_ECR##*/}" --region "$REGION" \
    --image-tag latest --image-manifest "$MANIFEST_C" >/dev/null 2>&1
  echo "  푸시 ✓ ($CORE_ECR:$SHA_C + latest)"
fi

# deploy.sh 실행
echo ""
echo "── 배포 시작 (deploy.sh $TARGET) ──"
cd "$INFRA_DIR"
./deploy.sh "$TARGET"
