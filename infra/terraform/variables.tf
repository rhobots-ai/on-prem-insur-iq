variable "name"   { default = "insur-iq" }
variable "env"    { default = "prod" }
variable "region" { default = "ap-south-1" }
variable "debug"  { default = "False" }

variable "domain" {
  type        = string
  description = "Public hostname for the app (e.g. insuriq.acmecorp.com)"
}

variable "route53_zone_id" {
  type        = string
  default     = ""
  description = "Existing Route53 hosted zone ID. Leave blank to create."
}

variable "acm_certificate_arn" {
  type        = string
  default     = ""
  description = <<-EOT
    Optional ARN of an existing ACM certificate (regional, in var.region) that
    covers var.domain. If set, Terraform will use it as-is and will NOT create
    or manage a certificate. If left blank, Terraform requests a new DNS-validated
    cert for var.domain (you then create the validation CNAME — see §4a of the
    deployment guide).
  EOT
}

variable "vpc_cidr" { default = "10.20.0.0/16" }
variable "azs"      { default = ["ap-south-1a", "ap-south-1b", "ap-south-1c"] }

variable "eks_version" { default = "1.35" }

variable "rds_instance_class" { default = "db.t4g.medium" }
variable "rds_storage_gb"     { default = 100 }
variable "rds_multi_az"       { default = false }

variable "redis_node_type"  { default = "cache.t4g.small" }

variable "tags" {
  type    = map(string)
  default = { Project = "insur-iq" }
}
