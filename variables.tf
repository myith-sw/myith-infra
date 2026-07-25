variable "domain_name" {
  description = "가비아에서 구매한 도메인"
  type        = string
  default     = "myith.store"
}

variable "db_password" {
  description = "RDS 마스터 비밀번호. 영문+숫자 8자 이상, / @ \" 공백 사용 불가"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "ssh-keygen 으로 만든 .pub 파일 내용 전체"
  type        = string
}

variable "ssh_allowed_cidr" {
  description = "SSH 허용 대역. 본인 IP로 좁히려면 curl ifconfig.me 결과에 /32 를 붙여서 입력"
  type        = string
  default     = "0.0.0.0/0"
}

variable "app_port" {
  description = "Core 애플리케이션이 리스닝하는 포트"
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "ALB 헬스체크 경로. Actuator 미사용이면 실제 존재하는 GET 200 경로로 변경 필수"
  type        = string
  default     = "/api/health"
}

variable "core_instance_type" {
  type    = string
  default = "t3.small"
}

variable "worker_instance_type" {
  type    = string
  default = "t3.small"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "redis_node_type" {
  type    = string
  default = "cache.t4g.micro"
}
