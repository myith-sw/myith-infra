terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

# ============================================================
# 0. Route53 — 가장 먼저 apply해서 NS 값을 가비아에 등록
#    terraform apply -target=aws_route53_zone.main
# ============================================================

resource "aws_route53_zone" "main" {
  name = var.domain_name
}

output "route53_name_servers" {
  description = "가비아 > 도메인 관리 > 네임서버 설정 > 타사 네임서버 사용 에 1~4차로 입력"
  value       = aws_route53_zone.main.name_servers
}

# ============================================================
# 1. 네트워크
# ============================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "myith-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "myith-igw" }
}

resource "aws_subnet" "public_2a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true
  tags                    = { Name = "myith-public-2a" }
}

resource "aws_subnet" "public_2c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = true
  tags                    = { Name = "myith-public-2c" }
}

resource "aws_subnet" "private_2a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = "ap-northeast-2a"
  tags              = { Name = "myith-private-2a" }
}

resource "aws_subnet" "private_2c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "ap-northeast-2c"
  tags              = { Name = "myith-private-2c" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "myith-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_2a.id
  tags          = { Name = "myith-nat" }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "myith-public-rt" }
}

resource "aws_route_table_association" "public_2a" {
  subnet_id      = aws_subnet.public_2a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2c" {
  subnet_id      = aws_subnet.public_2c.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "myith-private-rt" }
}

resource "aws_route_table_association" "private_2a" {
  subnet_id      = aws_subnet.private_2a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_2c" {
  subnet_id      = aws_subnet.private_2c.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-northeast-2.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]
  tags              = { Name = "myith-s3-endpoint" }
}

# ============================================================
# 2. 보안 그룹
# ============================================================

resource "aws_security_group" "alb" {
  name        = "myith-alb-sg"
  description = "ALB - 인터넷 80/443"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "myith-alb-sg" }
}

resource "aws_security_group" "core" {
  name        = "myith-core-sg"
  description = "Core EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "ALB에서만 앱 포트 허용"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH - var.ssh_allowed_cidr 로 제한 권장"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "myith-core-sg" }
}

# Worker는 프라이빗 서브넷이라 공인 IP가 없음 → SSH 규칙 없음.
# 접속은 SSM Session Manager로만 (IAM에 SSM 정책 부착되어 있음)
resource "aws_security_group" "worker" {
  name        = "myith-worker-sg"
  description = "Worker EC2 - 인터넷 인바운드 없음, Core에서만 접근"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Core -> RabbitMQ AMQP"
    from_port       = 5672
    to_port         = 5672
    protocol        = "tcp"
    security_groups = [aws_security_group.core.id]
  }

  ingress {
    description     = "Core -> RabbitMQ 관리콘솔"
    from_port       = 15672
    to_port         = 15672
    protocol        = "tcp"
    security_groups = [aws_security_group.core.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "myith-worker-sg" }
}

resource "aws_security_group" "rds" {
  name        = "myith-rds-sg"
  description = "RDS PostgreSQL"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.core.id, aws_security_group.worker.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "myith-rds-sg" }
}

resource "aws_security_group" "redis" {
  name        = "myith-redis-sg"
  description = "ElastiCache Redis"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.core.id, aws_security_group.worker.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "myith-redis-sg" }
}

# ============================================================
# 3. IAM
# ============================================================

resource "aws_iam_role" "ec2_role" {
  name = "myith-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Worker가 S3 업로드 파일을 읽어야 하므로 S3 접근 권한 부여
resource "aws_iam_role_policy" "s3_access" {
  name = "myith-s3-access"
  role = aws_iam_role.ec2_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.uploads.arn,
        "${aws_s3_bucket.uploads.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "myith-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# ============================================================
# 4. ECR
# ============================================================

resource "aws_ecr_repository" "core" {
  name         = "myith-core-app"
  force_delete = true
}

resource "aws_ecr_repository" "worker" {
  name         = "myith-worker-app"
  force_delete = true
}

# ============================================================
# 5. EC2
# ============================================================

resource "aws_key_pair" "myith" {
  key_name   = "myith-key"
  public_key = var.ssh_public_key
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "core" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.core_instance_type
  subnet_id              = aws_subnet.public_2a.id
  vpc_security_group_ids = [aws_security_group.core.id]
  key_name               = aws_key_pair.myith.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = file("${path.module}/scripts/bootstrap.sh")
  tags      = { Name = "myith-core" }

  # 컨테이너 안의 AWS SDK가 인스턴스 자격증명(S3 Presigned URL 발급용)을
  # 받으려면 hop limit 이 2 여야 한다. 기본값 1 이면 Docker 브리지 네트워크를
  # 한 번 거치는 순간 IMDS(169.254.169.254) 호출이 차단된다.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # bootstrap.sh 가 apt/docker 를 인터넷에서 받는다. 라우팅이 붙기 전에
  # 부팅하면 set -e 로 스크립트가 중단되어 Docker 가 설치되지 않는다.
  depends_on = [aws_route_table_association.public_2a]
}

resource "aws_instance" "worker" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.worker_instance_type
  subnet_id              = aws_subnet.private_2a.id
  vpc_security_group_ids = [aws_security_group.worker.id]
  key_name               = aws_key_pair.myith.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = file("${path.module}/scripts/bootstrap.sh")
  tags      = { Name = "myith-worker" }

  # Core 와 동일한 이유. Worker 컨테이너가 S3 에서 PDF 를 읽으려면
  # 컨테이너 안에서 IMDS 로 자격증명을 받아야 한다.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # Worker 는 NAT 없이는 인터넷이 전혀 없다. NAT 라우팅이 붙은 뒤에 부팅해야
  # bootstrap.sh 의 apt-get / SSM 등록이 성공한다. (SSM 이 유일한 접속 경로)
  depends_on = [aws_route_table_association.private_2a]
}

# ============================================================
# 6. ALB — Core만 등록
# ============================================================

resource "aws_lb" "main" {
  name               = "myith-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_2a.id, aws_subnet.public_2c.id]
  tags               = { Name = "myith-alb" }
}

resource "aws_lb_target_group" "core" {
  name        = "myith-core-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = var.health_check_path
    matcher             = "200-399"
    healthy_threshold   = 2
    unhealthy_threshold = 5
    interval            = 30
    timeout             = 10
  }
  tags = { Name = "myith-core-tg" }
}

resource "aws_lb_target_group_attachment" "core" {
  target_group_arn = aws_lb_target_group.core.arn
  target_id        = aws_instance.core.id
  port             = var.app_port
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.main.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.core.arn
  }
}

# ============================================================
# 7. ACM
#    주의: 가비아 NS 위임이 전파된 뒤에 apply해야 함.
#         전파 전이면 validation이 20분 대기 후 실패함.
# ============================================================

resource "aws_acm_certificate" "main" {
  domain_name       = "api.${var.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
  zone_id         = aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]

  timeouts {
    create = "20m"
  }
}

# ============================================================
# 8. Route53 레코드
# ============================================================

resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# ============================================================
# 9. RDS
#    engine_version "16" — 16.1~16.7은 2026-05-01부터 신규 생성 불가(deprecated)
# ============================================================

resource "aws_db_subnet_group" "main" {
  name       = "myith-db-subnet-group"
  subnet_ids = [aws_subnet.private_2a.id, aws_subnet.private_2c.id]
  tags       = { Name = "myith-db-subnet-group" }
}

# 한국 시간대 설정용 파라미터 그룹
# name 대신 name_prefix 를 쓴다: create_before_destroy 와 고정 name 을 함께 쓰면
# 교체 시 "새 것 생성 → 옛 것 삭제" 순서라 이름이 충돌해 apply 가 실패한다.
resource "aws_db_parameter_group" "main" {
  name_prefix = "myith-pg16-"
  family      = "postgres16"

  parameter {
    name  = "timezone"
    value = "Asia/Seoul"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "main" {
  identifier     = "myith-db"
  engine         = "postgres"
  engine_version = "16" # 메이저만 지정 -> AWS가 사용 가능한 최신 마이너 선택
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "myith"
  username = "myith_admin"
  password = var.db_password

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name
  parameter_group_name   = aws_db_parameter_group.main.name

  publicly_accessible        = false
  multi_az                   = false
  skip_final_snapshot        = true
  auto_minor_version_upgrade = true

  tags = { Name = "myith-db" }
}

# ============================================================
# 10. ElastiCache Redis
# ============================================================

resource "aws_elasticache_subnet_group" "main" {
  name       = "myith-redis-subnet-group"
  subnet_ids = [aws_subnet.private_2a.id, aws_subnet.private_2c.id]
}

resource "aws_elasticache_cluster" "main" {
  cluster_id         = "myith-redis"
  engine             = "redis"
  engine_version     = "7.1"
  node_type          = var.redis_node_type
  num_cache_nodes    = 1
  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]
  tags               = { Name = "myith-redis" }
}

# ============================================================
# 11. S3
# ============================================================

resource "aws_s3_bucket" "uploads" {
  bucket_prefix = "myith-uploads-"
  force_destroy = true
  tags          = { Name = "myith-uploads" }
}

resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST"]
    allowed_origins = ["*"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================
# 12. Outputs
# ============================================================

output "api_url" {
  value = "https://api.${var.domain_name}"
}

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "core_public_ip" {
  description = "SSH 접속용"
  value       = aws_instance.core.public_ip
}

output "core_instance_id" {
  description = "SSM 접속용"
  value       = aws_instance.core.id
}

output "worker_instance_id" {
  description = "Worker는 프라이빗이라 SSM으로만 접속 가능"
  value       = aws_instance.worker.id
}

output "worker_private_ip" {
  description = "docker-compose.core.yml 의 WORKER_PRIVATE_IP"
  value       = aws_instance.worker.private_ip
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "redis_endpoint" {
  value = aws_elasticache_cluster.main.cache_nodes[0].address
}

output "ecr_core_repository_url" {
  value = aws_ecr_repository.core.repository_url
}

output "ecr_worker_repository_url" {
  value = aws_ecr_repository.worker.repository_url
}

output "s3_uploads_bucket" {
  value = aws_s3_bucket.uploads.bucket
}
