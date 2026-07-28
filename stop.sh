#!/bin/bash
# 시간당 과금의 약 70% 를 차지하는 리소스만 삭제한다.
#
#   ./stop.sh          확인 프롬프트 있음
#   ./stop.sh --yes    확인 없이 진행
#
# 남기는 것과 그 이유:
#   Route53 존  — 지우면 NS 가 새로 발급되어 가비아 재등록 + 전파 대기가 필요
#   ACM 인증서  — 무료. 검증 상태 유지
#   RDS / Redis — skip_final_snapshot=true 라 지우면 데이터 복구 불가
#   VPC·서브넷·SG·ECR·S3 — 무료이거나 무시할 수준
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
AUTO=""
[ "${1:-}" = "--yes" ] && AUTO="-auto-approve"
start_logging "stop.sh"
preflight
echo "══ 정지 ══"
echo "  타겟 4개: Core EC2, Worker EC2, NAT Gateway, ALB   (약 \$0.156/시간)"
echo "  연쇄 삭제 8개: ALB 리스너 2, 타겟그룹 연결, api A레코드,"
echo "                 프라이빗 라우트테이블+연결 2, S3 VPC 엔드포인트"
echo "  => terraform plan 에는 12 to destroy 로 나온다. 정상이다."
echo ""
echo "  유지: Route53 존, ACM 인증서(검증 상태 포함), RDS, Redis,"
echo "        VPC/서브넷/보안그룹, 타겟그룹, NAT용 EIP, ECR, S3"
echo ""
echo "  ⚠️  https://api.myith.store 가 응답하지 않게 됩니다."
echo "      프론트가 붙어 있는 시간대인지 확인하세요."
echo ""
terraform destroy $AUTO \
  -target=aws_instance.core \
  -target=aws_instance.worker \
  -target=aws_nat_gateway.main \
  -target=aws_lb.main
cat <<'MSG'
════════════════════════════════════════
 정지 완료. 다시 켤 때는:
   ./start.sh          (또는 ./start.sh --yes 로 무인 실행)
 DB 데이터·도메인·인증서·ECR 이미지는 그대로 보존됩니다.
════════════════════════════════════════
MSG
finish_logging STOP
