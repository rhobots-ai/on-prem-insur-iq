################################################################################
# VPC — 3 AZs, public + private subnets, single NAT gateway, S3 gateway endpoint.
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.name}-${var.env}"
  cidr = var.vpc_cidr
  azs  = var.azs

  public_subnets   = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets  = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 4, i + 4)]
  database_subnets = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags  = { "kubernetes.io/role/elb"           = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb"  = "1" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)
  tags              = { Name = "${var.name}-${var.env}-s3" }
}

################################################################################
# EKS — 1.35 cluster + system managed node group + access entries.
################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "${var.name}-${var.env}"
  kubernetes_version = var.eks_version

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  endpoint_public_access = true
  authentication_mode    = "API"

  enable_cluster_creator_admin_permissions = true

  addons = {
    # These three must be installed BEFORE node groups exist, otherwise nodes
    # join NotReady (no CNI) and other addons can't schedule.
    vpc-cni = {
      most_recent          = true
      before_compute       = true
      configuration_values = jsonencode({ env = { ENABLE_PREFIX_DELEGATION = "true" } })
    }
    kube-proxy = {
      most_recent    = true
      before_compute = true
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }

    # These need a Ready node to schedule on.
    coredns                         = { most_recent = true }
    amazon-cloudwatch-observability = { most_recent = true }
    # aws-ebs-csi-driver intentionally omitted: prod has no PersistentVolumeClaims
    # (data lives in RDS / ElastiCache / S3). Add it back if you ever need PVCs
    # — note it requires a Pod Identity association with AmazonEBSCSIDriverPolicy.
  }

  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      labels         = { role = "system" }
      # Tags propagate to the underlying ASG. Cluster Autoscaler discovers
      # ASGs to manage by looking for these two tags.
      tags = {
        "k8s.io/cluster-autoscaler/enabled"                = "true"
        "k8s.io/cluster-autoscaler/${var.name}-${var.env}" = "owned"
      }
    }
    app = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.xlarge"]
      min_size       = 1
      max_size       = 3
      desired_size   = 1
      labels         = { role = "app" }
      tags = {
        "k8s.io/cluster-autoscaler/enabled"                = "true"
        "k8s.io/cluster-autoscaler/${var.name}-${var.env}" = "owned"
      }
    }
    gpu = {
      ami_type       = "AL2_x86_64_GPU"
      instance_types = ["g5.2xlarge"]
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      labels         = { role = "gpu" }
      taints = [{
        key    = "nvidia.com/gpu"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
      tags = {
        "k8s.io/cluster-autoscaler/enabled"                = "true"
        "k8s.io/cluster-autoscaler/${var.name}-${var.env}" = "owned"
      }
    }
  }
}

################################################################################
# RDS Postgres 16 + RDS Proxy.
################################################################################
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.7"

  identifier        = "${var.name}-${var.env}"
  engine            = "postgres"
  engine_version    = "16"
  family            = "postgres16"
  major_engine_version = "16"

  instance_class    = var.rds_instance_class
  allocated_storage = var.rds_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "insure_iq"
  username = "insur_iq"
  manage_master_user_password = true

  multi_az = var.rds_multi_az

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = module.vpc.database_subnet_group_name

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"
  performance_insights_enabled = true

  parameters = [
    { name = "rds.force_ssl",                value = "1" },
    { name = "log_min_duration_statement",   value = "500" },
  ]
}

resource "aws_security_group" "rds" {
  name   = "${var.name}-${var.env}-rds"
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    cidr_blocks     = module.vpc.private_subnets_cidr_blocks
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS Proxy
resource "aws_db_proxy" "this" {
  name                   = "${var.name}-${var.env}-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_subnet_ids         = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.rds.id]
  require_tls            = true
  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = module.rds.db_instance_master_user_secret_arn
  }
}

resource "aws_db_proxy_default_target_group" "this" {
  db_proxy_name = aws_db_proxy.this.name
  connection_pool_config {
    max_connections_percent      = 100
    max_idle_connections_percent = 50
  }
}

resource "aws_db_proxy_target" "this" {
  db_proxy_name          = aws_db_proxy.this.name
  target_group_name      = aws_db_proxy_default_target_group.this.name
  db_instance_identifier = module.rds.db_instance_identifier
}

resource "aws_iam_role" "rds_proxy" {
  name = "${var.name}-${var.env}-rds-proxy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Effect = "Allow", Principal = { Service = "rds.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "rds_proxy_secrets" {
  name = "secrets-access"
  role = aws_iam_role.rds_proxy.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "kms:Decrypt"]
      Resource = "*"
    }]
  })
}

################################################################################
# ElastiCache Redis 7.
################################################################################
resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.name}-${var.env}"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "redis" {
  name   = "${var.name}-${var.env}-redis"
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
  }
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${var.name}-${var.env}"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.redis_node_type
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [aws_security_group.redis.id]
}

################################################################################
# S3 — uploads bucket.
################################################################################
resource "aws_s3_bucket" "uploads" {
  bucket = "${var.name}-${var.env}-uploads"
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
# ECR repos are managed outside this Terraform — they outlive any single
# environment so we don't want `terraform destroy` to touch them. Create them
# once via the AWS Console / CLI and reference their URLs in helm values.
################################################################################

################################################################################
# Secrets Manager — placeholder secrets. Operator fills values via aws CLI.
################################################################################
resource "aws_secretsmanager_secret" "backend" {
  name                    = "${var.name}/${var.env}/backend"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.name}/${var.env}/db"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "redis" {
  name                    = "${var.name}/${var.env}/redis"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "auth" {
  name                    = "${var.name}/${var.env}/auth"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "llm" {
  name                    = "${var.name}/${var.env}/llm"
  recovery_window_in_days = 0
}

################################################################################
# Pod Identity associations.
################################################################################
locals {
  pod_identity_assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  pod_s3_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.uploads.arn, "${aws_s3_bucket.uploads.arn}/*"]
    }]
  })
}

resource "aws_iam_role" "backend_pod" {
  name               = "${var.name}-${var.env}-backend"
  assume_role_policy = local.pod_identity_assume_role_policy
}

resource "aws_iam_role_policy" "backend_pod_s3" {
  name   = "s3-and-secrets"
  role   = aws_iam_role.backend_pod.id
  policy = local.pod_s3_policy
}

resource "aws_iam_role" "celery_pod" {
  name               = "${var.name}-${var.env}-celery"
  assume_role_policy = local.pod_identity_assume_role_policy
}

resource "aws_iam_role_policy" "celery_pod_s3" {
  name   = "s3-and-secrets"
  role   = aws_iam_role.celery_pod.id
  policy = local.pod_s3_policy
}

resource "aws_eks_pod_identity_association" "backend" {
  cluster_name    = module.eks.cluster_name
  namespace       = var.name
  service_account = "${var.name}-${var.name}-backend"
  role_arn        = aws_iam_role.backend_pod.arn
}
resource "aws_eks_pod_identity_association" "celery" {
  cluster_name    = module.eks.cluster_name
  namespace       = var.name
  service_account = "${var.name}-${var.name}-celery"
  role_arn        = aws_iam_role.celery_pod.arn
}

################################################################################
# Cluster Autoscaler — IAM role + Pod Identity association.
# The CA controller pod (installed by `helm install` in §5 of the deployment
# guide) uses this role to scale the node group ASGs up/down based on pending
# pods. Discovery uses the `k8s.io/cluster-autoscaler/*` tags set above.
################################################################################
resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${var.name}-${var.env}-cluster-autoscaler"
  assume_role_policy = local.pod_identity_assume_role_policy
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "asg-management"
  role = aws_iam_role.cluster_autoscaler.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.name}-${var.env}" = "owned"
          }
        }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "cluster_autoscaler" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.cluster_autoscaler.arn
}

################################################################################
# AWS Load Balancer Controller — IAM role + Pod Identity association.
# The controller pod (installed by `helm install` in §5) reads Ingress / Service
# resources and provisions ALBs/NLBs. The policy is the AWS-published one for
# LBC v3.x, fetched from kubernetes-sigs/aws-load-balancer-controller releases.
################################################################################
resource "aws_iam_role" "aws_load_balancer_controller" {
  name               = "${var.name}-${var.env}-aws-lbc"
  assume_role_policy = local.pod_identity_assume_role_policy
}

data "http" "aws_lbc_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.2.2/docs/install/iam_policy.json"
}

resource "aws_iam_role_policy" "aws_load_balancer_controller" {
  name   = "alb-ingress"
  role   = aws_iam_role.aws_load_balancer_controller.id
  policy = data.http.aws_lbc_policy.response_body
}

resource "aws_eks_pod_identity_association" "aws_load_balancer_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.aws_load_balancer_controller.arn
}

################################################################################
# External Secrets Operator — IAM role + Pod Identity association.
# Reads from Secrets Manager and projects values into K8s Secret objects.
# Scoped to the insur-iq/* namespace so it cannot read unrelated secrets.
################################################################################
resource "aws_iam_role" "external_secrets" {
  name               = "${var.name}-${var.env}-external-secrets"
  assume_role_policy = local.pod_identity_assume_role_policy
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "secretsmanager-read"
  role = aws_iam_role.external_secrets.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.name}/*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}

################################################################################
# ACM cert for the app.
################################################################################
data "aws_route53_zone" "this" {
  count   = var.route53_zone_id == "" ? 0 : 1
  zone_id = var.route53_zone_id
}

resource "aws_acm_certificate" "app" {
  count             = var.acm_certificate_arn == "" ? 1 : 0
  domain_name       = var.domain
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

# Resolved ACM cert ARN — either the one the operator passed in (BYO) or the
# one Terraform just requested. Everything downstream (outputs, ingress) reads
# this local so the rest of the config doesn't care which path was taken.
locals {
  acm_certificate_arn = var.acm_certificate_arn != "" ? var.acm_certificate_arn : aws_acm_certificate.app[0].arn
}
