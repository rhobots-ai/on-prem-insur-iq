# insur-iq Deployment Docs

Deployment artifacts for running **insur-iq** on a customer-managed AWS account (EKS).

This documentation covers everything a DevOps engineer needs to provision infrastructure and deploy the application from scratch.

## Quick links

- [Deployment Guide](eks-deployment-guide.md) — end-to-end runbook
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
