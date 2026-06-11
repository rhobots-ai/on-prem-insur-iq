# insur-iq Deployment Docs

Deployment artifacts for running **insur-iq** on a customer-managed AWS account.

This documentation covers everything a DevOps engineer needs to provision infrastructure and deploy the application from scratch. Two deployment paths are supported:

- **EKS** — Kubernetes + Helm; elastic, multi-AZ, autoscaling.
- **EC2** — Docker Compose on two EC2 boxes behind an ALB; smallest operational surface.

## Quick links

- [EKS Deployment Guide](eks-deployment-guide.md) — end-to-end runbook (Kubernetes)
- [EC2 Deployment Guide](ec2-deployment-guide.md) — end-to-end runbook (Docker Compose + ALB)
- [Infrastructure Overview](infra/terraform.md) — Terraform modules
- [Resource Requirements](resource-requirements.md) — node sizing and capacity

## Architecture

Single ALB, path-based routing into one namespace (`insur-iq`):

| Path | Service | Port |
| ---- | ------- | ---- |
| `/` | web (Nuxt SSR) | 3000 |
| `/service-api/` | backend (Django + gunicorn) | 8000 |
| `/auth/` | auth (Better Auth) | 10000 |

Celery workers (`default`, `policy_extract`, `commission_intake`, `beat`) consume a Redis broker and write to Django ORM.

**Data plane:** RDS Postgres 16 (via RDS Proxy) · ElastiCache Redis 7 · S3
