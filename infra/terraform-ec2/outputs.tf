output "vpc_id" { value = module.vpc.vpc_id }
output "alb_dns_name" { value = aws_lb.this.dns_name }
output "app_instance_id" { value = aws_instance.app.id }
output "app_private_ip" { value = aws_instance.app.private_ip }
output "gpu_instance_id" { value = aws_instance.gpu.id }
output "gpu_private_ip" { value = aws_instance.gpu.private_ip }

output "rds_endpoint" { value = module.rds.db_instance_endpoint }
output "rds_master_secret_arn" { value = module.rds.db_instance_master_user_secret_arn }

output "s3_bucket_name" { value = aws_s3_bucket.uploads.id }
output "acm_certificate_arn" { value = local.acm_certificate_arn }
output "instance_profile" { value = aws_iam_instance_profile.instance.name }

output "ecr_registry" {
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

# app.env-ready snippet — fill the remaining secrets (auth, LLM) by hand.
# Run: terraform -chdir=infra/terraform-ec2 output -raw app_env_snippet > deploy/ec2/app.env
output "app_env_snippet" {
  value = <<-EOT
    # ---- Generated from `terraform output app_env_snippet` --------------------
    # Image registry + tags
    ECR_REGISTRY=${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com
    BACKEND_TAG=1.0.0
    WEB_TAG=1.0.0
    AUTH_TAG=latest

    # Public host
    DOMAIN=${var.domain}

    # Database — direct to RDS (no Proxy). Fetch DB_PASSWORD from the master
    # secret: aws secretsmanager get-secret-value --secret-id ${module.rds.db_instance_master_user_secret_arn}
    DB_HOST=${split(":", module.rds.db_instance_endpoint)[0]}
    DB_PORT=5432
    DB_USER=insur_iq
    DB_PASSWORD=__FILL_FROM_SECRETS_MANAGER__
    DB_NAME=insure_iq
    DB_NAME_AUTH=auth

    # Redis runs as a container on this box.
    CELERY_BROKER_URL=redis://redis:6379/0

    # S3
    AWS_REGION=${var.region}
    AWS_STORAGE_BUCKET_NAME=${aws_s3_bucket.uploads.id}

    # Rhobots Extract OCR on the GPU box
    MINERVA_API_URL=http://${aws_instance.gpu.private_ip}:8000

    # ---- Fill these by hand (auth + LLM) -------------------------------------
    SECRET_KEY=__FILL__
    WEBHOOK_SECRET_KEY=__FILL__
    BETTER_AUTH_SECRET=__FILL__
    REQUIRE_EMAIL_VERIFICATION=false
    LLM_PROVIDER=gemini
    GOOGLE_API_KEY=__FILL__
    GEMINI_API_KEY=__FILL__
    GEMINI_MODEL=gemini-2.5-flash
  EOT
}
