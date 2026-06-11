variable "name" { default = "insur-iq" }
variable "env" { default = "prod" }
variable "region" { default = "ap-south-1" }

variable "domain" {
  type        = string
  description = "Public hostname for the app (e.g. insuriq.acmecorp.com)"
}

variable "route53_zone_id" {
  type        = string
  default     = ""
  description = <<-EOT
    Existing Route53 hosted zone ID for var.domain. If set, Terraform creates an
    ALIAS A-record pointing the domain at the ALB. Leave blank if DNS lives
    elsewhere (Cloudflare, a separate account) — then create the record manually
    against the `alb_dns_name` output.
  EOT
}

variable "acm_certificate_arn" {
  type        = string
  default     = ""
  description = <<-EOT
    Optional ARN of an existing ACM certificate (regional, in var.region) that
    covers var.domain. If set, Terraform uses it as-is. If blank, Terraform
    requests a new DNS-validated cert (you then create the validation CNAME —
    see the EC2 deployment guide).
  EOT
}

variable "vpc_cidr" { default = "10.30.0.0/16" }
variable "azs" { default = ["ap-south-1a", "ap-south-1b", "ap-south-1c"] }

# --- Compute ---------------------------------------------------------------
# App box runs the full Docker Compose stack EXCEPT Rhobots Extract. No GPU needed.
variable "app_instance_type" { default = "m6i.xlarge" } # 4 vCPU / 16 GB
variable "app_root_gb" { default = 100 }

# GPU box runs Rhobots Extract OCR only. A10G is required — CPU parsing is too slow.
variable "gpu_instance_type" { default = "g5.2xlarge" } # 8 vCPU / 32 GB / 1x A10G
variable "gpu_root_gb" { default = 200 }

# Optional SSH keypair name for break-glass access. Both instances live in
# private subnets — prefer SSM Session Manager (enabled via instance profile)
# over opening port 22. Leave blank to omit a key entirely.
variable "ssh_key_name" { default = "" }

# --- Data plane ------------------------------------------------------------
variable "rds_instance_class" { default = "db.t4g.medium" }
variable "rds_storage_gb" { default = 100 }
variable "rds_multi_az" { default = false }

variable "tags" {
  type    = map(string)
  default = { Project = "insur-iq" }
}
