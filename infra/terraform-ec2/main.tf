################################################################################
# EC2 + ALB deployment of insur-iq — an alternative to the EKS path.
#
# Topology: a single app EC2 (Docker Compose: nginx, web, backend, auth, celery,
# redis) behind an ALB, plus a dedicated GPU EC2 running Rhobots Extract OCR. RDS Postgres
# and S3 round out the data plane. No EKS, no ElastiCache, no RDS Proxy.
#
# This is a SEPARATE Terraform root from infra/terraform (the EKS path). Use one
# or the other per environment — never both against the same VPC CIDR.
################################################################################

################################################################################
# VPC — 3 AZs, public + private + database subnets, single NAT, S3 endpoint.
# Mirrors infra/terraform but without the EKS/cluster-autoscaler subnet tags.
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.name}-${var.env}-ec2"
  cidr = var.vpc_cidr
  azs  = var.azs

  public_subnets   = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets  = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 4, i + 4)]
  database_subnets = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)
  tags              = { Name = "${var.name}-${var.env}-ec2-s3" }
}

################################################################################
# Security groups.
#   alb → app:80   (TLS terminates at the ALB; nginx on the app box speaks HTTP)
#   app → gpu:8000 (Rhobots Extract HTTP API)
#   app → rds:5432 (Postgres over TLS)
################################################################################
resource "aws_security_group" "alb" {
  name        = "${var.name}-${var.env}-alb"
  description = "Public ingress to the ALB"
  vpc_id      = module.vpc.vpc_id
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
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
}

resource "aws_security_group" "app" {
  name        = "${var.name}-${var.env}-app"
  description = "App EC2 — Docker Compose stack"
  vpc_id      = module.vpc.vpc_id
  ingress {
    description     = "nginx from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "gpu" {
  name        = "${var.name}-${var.env}-gpu"
  description = "GPU EC2 — Rhobots Extract OCR"
  vpc_id      = module.vpc.vpc_id
  ingress {
    description     = "Rhobots Extract HTTP from app box"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-${var.env}-rds"
  description = "RDS — Postgres from app box only"
  vpc_id      = module.vpc.vpc_id
  ingress {
    description     = "Postgres from app box"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

################################################################################
# IAM — one instance profile shared by both boxes: S3 (uploads) + ECR pull +
# SSM Session Manager (so operators reach private instances without a bastion).
################################################################################
resource "aws_iam_role" "instance" {
  name = "${var.name}-${var.env}-ec2"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "instance_s3" {
  name = "s3-uploads"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.uploads.arn, "${aws_s3_bucket.uploads.arn}/*"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "instance_ecr" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-${var.env}-ec2"
  role = aws_iam_role.instance.name
}

################################################################################
# EC2 instances — both Ubuntu 24.04 (Noble). GPU box additionally installs the
# NVIDIA driver + container toolkit via user_data (see cloud-init/gpu.sh).
################################################################################
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.app_instance_type
  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  key_name               = var.ssh_key_name != "" ? var.ssh_key_name : null
  user_data              = file("${path.module}/cloud-init/app.sh")

  root_block_device {
    volume_size = var.app_root_gb
    volume_type = "gp3"
    encrypted   = true
  }
  tags = { Name = "${var.name}-${var.env}-app" }
}

resource "aws_instance" "gpu" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.gpu_instance_type
  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.gpu.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  key_name               = var.ssh_key_name != "" ? var.ssh_key_name : null
  user_data              = file("${path.module}/cloud-init/gpu.sh")

  root_block_device {
    volume_size = var.gpu_root_gb
    volume_type = "gp3"
    encrypted   = true
  }
  tags = { Name = "${var.name}-${var.env}-gpu" }
}

################################################################################
# ALB — public, TLS-terminating. Forwards HTTP to nginx on the app box. Path
# routing lives in nginx, not in ALB listener rules.
################################################################################
resource "aws_lb" "this" {
  name               = "${var.name}-${var.env}"
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.alb.id]
  idle_timeout       = 300 # large PDF uploads; mirrors the EKS ingress idle_timeout
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name}-${var.env}-app"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = module.vpc.vpc_id
  health_check {
    path                = "/healthz" # nginx returns 200 directly (see nginx/insur-iq.conf)
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app.id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
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
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.acm_certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

################################################################################
# RDS Postgres 16 — single instance, direct TLS from the app box (no Proxy).
# The `auth` logical DB is created by the app-box bootstrap, same as the EKS path.
################################################################################
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.7"

  identifier           = "${var.name}-${var.env}-ec2"
  engine               = "postgres"
  engine_version       = "16"
  family               = "postgres16"
  major_engine_version = "16"

  instance_class    = var.rds_instance_class
  allocated_storage = var.rds_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  db_name                     = "insure_iq"
  username                    = "insur_iq"
  manage_master_user_password = true

  multi_az = var.rds_multi_az

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = module.vpc.database_subnet_group_name

  backup_retention_period      = 7
  backup_window                = "03:00-04:00"
  maintenance_window           = "Mon:04:00-Mon:05:00"
  performance_insights_enabled = true

  parameters = [
    { name = "rds.force_ssl", value = "1" },
    { name = "log_min_duration_statement", value = "500" },
  ]
}

################################################################################
# S3 — uploads bucket (same shape as the EKS path).
################################################################################
resource "aws_s3_bucket" "uploads" {
  bucket = "${var.name}-${var.env}-ec2-uploads"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

################################################################################
# ACM cert — request a new DNS-validated cert, or use a BYO ARN. Mirrors the
# request-or-BYO local from infra/terraform.
################################################################################
resource "aws_acm_certificate" "app" {
  count             = var.acm_certificate_arn == "" ? 1 : 0
  domain_name       = var.domain
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

locals {
  acm_certificate_arn = var.acm_certificate_arn != "" ? var.acm_certificate_arn : aws_acm_certificate.app[0].arn
}

################################################################################
# Route53 — ALIAS A-record to the ALB (only when a zone ID is supplied).
################################################################################
resource "aws_route53_record" "app" {
  count   = var.route53_zone_id == "" ? 0 : 1
  zone_id = var.route53_zone_id
  name    = var.domain
  type    = "A"
  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
