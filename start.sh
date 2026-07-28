#!/bin/bash
# 인프라 복구 + 컨테이너 배포까지 한 번에.
#
#   ./start.sh          terraform apply 확인 프롬프트 있음
#   ./start.sh --yes    확인 없이 진행 (완전 무인)
#
# stop.sh 로 내린 EC2·NAT·ALB 를 다시 만들고, deploy.sh 로 컨테이너까지 띄운다.
# 시크릿은 deploy/env.* 에서 자동 승계되므로 손으로 넣을 값이 없다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTO=""
[ "${1:-}" = "--yes" ] && AUTO="-auto-approve"

start_logging "start.sh"
preflight

echo "══ 인프라 복구 ══"
echo "  생성: Core EC2, Worker EC2, NAT Gateway, ALB"
echo "  (RDS·Redis·Route53·ACM 은 유지된 상태)"
echo ""
terraform apply $AUTO

echo ""
echo "  새 인스턴스가 부팅하며 Docker 를 설치합니다 (약 2분)."
echo "  deploy.sh 가 준비될 때까지 자동으로 기다립니다."
echo ""

# 재생성으로 Core 공인 IP 가 바뀐다. 옛 SSH 호스트 키를 지워
# 나중에 수동 ssh 할 때 경고가 뜨지 않게 한다.
CORE_IP=$(tfout core_public_ip)
[ -n "$CORE_IP" ] && ssh-keygen -R "$CORE_IP" >/dev/null 2>&1 || true

./deploy.sh all

cat <<MSG

════════════════════════════════════════
 CI/CD 를 쓰고 있다면 워크플로의 INSTANCE_ID 를 갱신하세요.
   Core   $(tfout core_instance_id)
   Worker $(tfout worker_instance_id)
════════════════════════════════════════
MSG

finish_logging START
