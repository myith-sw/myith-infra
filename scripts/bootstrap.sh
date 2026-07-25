#!/bin/bash
set -e
exec > >(tee /var/log/bootstrap.log) 2>&1

echo "=== bootstrap 시작: $(date) ==="

# --- SSM Agent ---
# Worker는 프라이빗 서브넷이라 SSH 불가. SSM Session Manager가 유일한 접속 경로.
snap install amazon-ssm-agent --classic || true
systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true

# --- 기본 패키지 ---
apt-get update -y
apt-get install -y unzip curl ca-certificates gnupg

# --- AWS CLI v2 ---
curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -o -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update

# --- Docker + Compose plugin ---
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker ubuntu
systemctl enable --now docker

# --- Swap 2GB (128M x 16 = 2048M) ---
# t3.small 메모리 2GB. 컨테이너 다중 실행 시 OOM 방지용.
if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=128M count=16
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
fi

# ECR 로그인은 여기서 하지 않음.
# 토큰 유효기간이 12시간이라 부팅 시점에 받아두면 배포 시점엔 이미 만료됨.
# 배포 직전에 아래 명령을 직접 실행할 것:
#   aws ecr get-login-password --region ap-northeast-2 \
#     | docker login --username AWS --password-stdin <ECR_URI>

echo "=== bootstrap 완료: $(date) ==="
