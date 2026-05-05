# on-prem-insur-iq

Deployment artifacts for running Insur-IQ on a customer-managed AWS account (EKS).

## Layout

| Path | Purpose |
| --- | --- |
| [`infra/terraform/`](infra/terraform/) | Terraform for VPC, EKS, RDS, RDS Proxy, ElastiCache, S3, ECR, ACM, Pod Identity, Secrets Manager. |
| [`helm/insur-iq/`](helm/insur-iq/) | Helm chart for the application workloads (web, backend, auth, celery, celery-beat). |
| [`scripts/`](scripts/) | Operator scripts: preflight checks, infra verification, secret seeding, local kind cluster. |
| [`docs/deployment/`](docs/deployment/) | Deployment runbooks. Start with [`eks-deployment-guide.md`](docs/deployment/eks-deployment-guide.md). |

## Quick start

1. `./scripts/preflight.sh` — verify local tools and AWS credentials.
2. `cd infra/terraform && terraform init && terraform apply` — provision AWS infra.
3. `./scripts/seed-secrets.sh` — populate Secrets Manager entries.
4. `./scripts/verify-infra.sh` — confirm AWS resources are healthy.
5. Render `helm/insur-iq/my-values.yaml` from Terraform outputs and `helm install`.

Full walkthrough: [`docs/deployment/eks-deployment-guide.md`](docs/deployment/eks-deployment-guide.md).

## Conventions

- **Never commit** `terraform.tfstate*`, `*.tfplan`, `helm/*/my-values.yaml`, or `scripts/seed-secrets.env` — they are gitignored.
- Local kind cluster for development: `./scripts/create-kind-cluster.sh`.
