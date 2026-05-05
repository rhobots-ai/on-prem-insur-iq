# Terraform skeleton — insur-iq AWS managed infra

This skeleton provisions everything outside the EKS cluster that the Helm chart depends on:

| Module | Provisions |
|---|---|
| `vpc` | 3-AZ VPC, public + private subnets, NAT/AZ, S3 gateway endpoint |
| `eks` | EKS 1.35 cluster + system + app managed node groups (fixed size), OIDC, access entries |
| `rds` | RDS Postgres 16 single-AZ + parameter group + secrets in Secrets Manager |
| `rds_proxy` | RDS Proxy fronting the instance, IAM role, security group |
| `elasticache` | Redis 7 single-node cache cluster |
| `s3` | App uploads bucket, SSE-S3 |
| `ecr` | Two private repos (backend, web) + pull-through cache for Docker Hub |
| `secrets_manager` | 5 SM secrets seeded with placeholder values (operator fills via CLI) |
| `iam_pod_identity` | EKS Pod Identity associations: backend, celery, ESO, EBS CSI, LBC, external-dns |
| `acm` | Regional cert for `app.<domain>` validated via Route53 DNS |
| `route53` | Hosted zone (or data-source if pre-existing) |

## Layout

```
terraform/
├── README.md                # this file
├── main.tf                  # module wiring
├── variables.tf             # all inputs
├── outputs.tf               # values consumed by the Helm values file
├── providers.tf             # aws + kubernetes + helm providers
├── versions.tf              # required_version + required_providers
└── modules/                 # custom modules (rds_proxy, iam_pod_identity, etc.)
```

## Apply order

```
terraform init
terraform plan -var "domain=$DOMAIN" -var "region=$AWS_REGION" -out tfplan
terraform apply tfplan
```

Because the `eks` module emits the cluster name and `kubeconfig`, downstream modules depending on the cluster (Pod Identity associations, ACM cert validation via Route53) auto-sequence. If you split into multiple workspaces, apply in the order: `vpc → eks → rds → rds_proxy → elasticache → s3 → ecr → secrets_manager → iam_pod_identity → acm → route53`.

## Outputs consumed by Helm

After `terraform apply`, copy these outputs into your `values.<env>.yaml`:

| Terraform output | Helm value |
|---|---|
| `vpc_id`, `private_subnet_ids` | (informational) |
| `rds_proxy_endpoint` | `secrets.db.DB_HOST` (in SM, key `DB_HOST`) |
| `redis_endpoint` | `secrets.redis.CELERY_BROKER_URL` (in SM, used to compose the broker URL) |
| `s3_bucket_name` | `config.AWS_STORAGE_BUCKET_NAME` |
| `acm_certificate_arn` | `ingress.certificateArn` |
| `pod_identity_backend_role_arn` | `serviceAccount.podIdentityAssociations.backendRoleArn` (informational; SA association created by Terraform) |
| `pod_identity_celery_role_arn` | `serviceAccount.podIdentityAssociations.celeryRoleArn` (informational) |
| `rds_subnet_cidrs` | `networkPolicy.allowedEgress.rdsCidrs` |
| `elasticache_subnet_cidrs` | `networkPolicy.allowedEgress.redisCidrs` |

## Variables

See `variables.tf`. Core inputs:

```hcl
variable "name"        { default = "insur-iq" }
variable "env"         { default = "prod" }
variable "region"      { default = "ap-south-1" }
variable "domain"      {}                            # e.g. "insuriq.acmecorp.com"
variable "route53_zone_id" { default = "" }          # leave blank to create
variable "vpc_cidr"    { default = "10.20.0.0/16" }
variable "azs"         { default = ["ap-south-1a", "ap-south-1b", "ap-south-1c"] }
variable "rds_instance_class" { default = "db.t4g.medium" }
variable "rds_storage_gb"     { default = 100 }
variable "redis_node_type"    { default = "cache.t4g.small" }
```

## CLI/Console fallback

If your team doesn't run Terraform, `cli-fallback.md` (sibling file) walks the same steps with `aws ...` commands. Same outputs, more clicks.
