# on-prem-insur-iq

Deployment artifacts for running Insur-IQ on a customer-managed AWS account.
Two paths: **EKS** (Kubernetes + Helm) and **EC2** (Docker Compose + ALB).

## Layout

| Path | Purpose |
| --- | --- |
| [`infra/terraform/`](infra/terraform/) | **EKS path** Terraform: VPC, EKS, RDS, RDS Proxy, ElastiCache, S3, ECR, ACM, Pod Identity, Secrets Manager. |
| [`infra/terraform-ec2/`](infra/terraform-ec2/) | **EC2 path** Terraform: VPC, ALB, app + GPU EC2, instance profile, RDS, S3, ACM. |
| [`helm/insur-iq/`](helm/insur-iq/) | Helm chart for the application workloads (web, backend, auth, celery, celery-beat). |
| [`deploy/ec2/`](deploy/ec2/) | EC2 Docker Compose stack, nginx config, and `.env` templates. |
| [`scripts/`](scripts/) | Operator scripts: preflight checks, infra verification, secret seeding, local kind cluster. |
| [`docs/`](docs/) | Deployment runbooks: [`eks-deployment-guide.md`](docs/eks-deployment-guide.md) and [`ec2-deployment-guide.md`](docs/ec2-deployment-guide.md). |

## Quick start (EKS)

1. `./scripts/preflight.sh` — verify local tools and AWS credentials.
2. `cd infra/terraform && terraform init && terraform apply` — provision AWS infra.
3. `./scripts/seed-secrets.sh` — populate Secrets Manager entries.
4. `./scripts/verify-infra.sh` — confirm AWS resources are healthy.
5. Render `helm/insur-iq/my-values.yaml` from Terraform outputs and `helm install`.

Full walkthrough: [`docs/eks-deployment-guide.md`](docs/eks-deployment-guide.md).

## Quick start (EC2)

1. `cd infra/terraform-ec2 && terraform init && terraform apply -var "domain=$DOMAIN" -var "region=$AWS_REGION"`.
2. `terraform output -raw app_env_snippet > ../../deploy/ec2/app.env`, then fill secrets.
3. On the GPU box: `docker compose -f deploy/ec2/docker-compose.gpu.yml --env-file gpu.env up -d`.
4. On the app box: `docker compose -f deploy/ec2/docker-compose.app.yml --env-file app.env up -d`.

Full walkthrough: [`docs/ec2-deployment-guide.md`](docs/ec2-deployment-guide.md).

## Conventions

- **Never commit** `terraform.tfstate*`, `*.tfplan`, `helm/*/my-values.yaml`, or `scripts/seed-secrets.env` — they are gitignored.
- Local kind cluster for development: `./scripts/create-kind-cluster.sh`.
