# insur-iq — AWS EC2 + Load Balancer Deployment Guide

This guide covers the **EC2 / Docker Compose** deployment path — a simpler
alternative to the [EKS path](eks-deployment-guide.md) for customers who do not
run Kubernetes. It is both an **architecture reference** and an **operator
runbook**: read §1–§4 to understand what gets built and why, then follow §5–§12
to stand it up.

The topology follows the same pattern used for the PB Partners on-prem
deployment, with one change: **Rhobots Extract OCR runs on a dedicated GPU box**, separate
from the app box, so the two scale and fail independently.

---

## Table of Contents

1. [Overview — EC2 vs EKS](#1-overview-ec2-vs-eks)
2. [Architecture](#2-architecture)
3. [Resource Configuration](#3-resource-configuration)
4. [Security Architecture](#4-security-architecture)
5. [Pre-requisite Checklist](#5-pre-requisite-checklist)
6. [Provision Infra (Terraform)](#6-provision-infra-terraform)
7. [DNS & ACM](#7-dns-acm)
8. [Configure the Instances](#8-configure-the-instances)
9. [Bring Up the Stack](#9-bring-up-the-stack)
10. [Verification](#10-verification)
11. [Upgrades & Rollback](#11-upgrades-rollback)
12. [Failover, Availability & Day-2](#12-failover-availability-day-2)
13. [Cost Reference](#13-cost-reference)
14. [Appendix A — Environment Variables](#appendix-a-environment-variables)
15. [Appendix B — Security Group Rules](#appendix-b-security-group-rules)
16. [Appendix C — Decision Log](#appendix-c-decision-log)

---

## 1. Overview — EC2 vs EKS

Both paths run the identical container images (`backend`, `web`, `auth`) and the
same data plane shape (Postgres + Redis + S3). They differ only in the runtime.

| | **EC2 (this guide)** | **EKS** ([guide](eks-deployment-guide.md)) |
| --- | --- | --- |
| Orchestration | Docker Compose on 2 EC2 boxes | Kubernetes (Helm chart) |
| Routing | nginx on the app box, behind an ALB | ALB Ingress (LBC) |
| Redis | container on the app box | ElastiCache |
| DB access | direct to RDS (TLS) | RDS Proxy |
| Secrets | `.env` files on the instances | External Secrets Operator + Secrets Manager |
| Identity | one EC2 instance profile | EKS Pod Identity (per-workload roles) |
| Scaling | vertical (resize the box) | HPA + Cluster Autoscaler |
| Best for | single-tenant, low-ops, "looks like on-prem" | multi-tenant, elastic, HA |

Choose EC2 when the customer wants the smallest possible operational surface and
does not need horizontal autoscaling or multi-AZ compute. Choose EKS for
elasticity and high availability.

---

## 2. Architecture

```
                         Internet
                            │
                            ▼
                 ┌──────────────────────┐
                 │   Route 53 ALIAS      │
                 │ insuriq.acmecorp.com │
                 └──────────┬───────────┘
                            ▼
                 ┌──────────────────────┐
                 │    ALB + ACM cert    │  TLS terminates here; idle_timeout=300s
                 │   :443 → app box :80 │
                 └──────────┬───────────┘
                            ▼  HTTP :80
   ┌──── App EC2 (private subnet) — Docker Compose ──────────────────┐
   │  nginx  /→web  /service-api→backend  /auth→auth                 │
   │  ┌──────┐   ┌──────────┐   ┌──────┐                             │
   │  │ web  │   │ backend  │   │ auth │                             │
   │  │ Nuxt │   │ Django   │   │Better│                             │
   │  │ :3000│   │ :8000    │   │ :10000                             │
   │  └──────┘   └────┬─────┘   └──────┘                             │
   │  celery: default · policy_extract · commission_intake · beat   │
   │  redis (broker, container)                                      │
   └────────┬────────────────────────────┬──────────────────────────┘
            │ :8000 (Rhobots Extract HTTP)         │ :5432 (TLS)
            ▼                             ▼
   ┌──────────────────┐         ┌──────────────────┐    ┌────────────┐
   │ GPU EC2 (private)│         │ RDS Postgres 16  │    │ S3 bucket  │
   │ Rhobots Extract OCR       │         │  insure_iq       │    │ uploads    │
   │ g5.2xlarge A10G  │         │  auth            │    └────────────┘
   └──────────────────┘         └──────────────────┘
```

**Request flow:** ALB terminates TLS and forwards HTTP to nginx on the app box.
nginx routes by path. The `policy_extract` celery worker drives the extraction
pipeline: it calls **Rhobots Extract** on the GPU box to parse the PDF to Markdown, then
calls the **LLM** (Gemini by default) to extract and map fields, and writes
results to RDS. Uploads and artefacts live in S3, reached via the instance
profile.

**Services on the app box (`docker-compose.app.yml`):**

| Service | Purpose |
| --- | --- |
| nginx | Reverse proxy / path routing |
| web | Nuxt SSR dashboard (:3000) |
| backend | Django + gunicorn REST API (:8000) |
| auth | Better Auth — JWT issuance & sessions (:10000) |
| celery-default | General background tasks |
| celery-policy-extract | AI extraction pipeline (concurrency 10) |
| celery-commission-intake | Commission intake queue |
| celery-beat | Scheduled task runner (singleton) |
| redis | Celery broker (container) |

**On the GPU box (`docker-compose.gpu.yml`):** `rhobots-extract` — GPU-accelerated
PDF→Markdown parser on :8000.

---

## 3. Resource Configuration

### 3.1 App EC2

| Parameter | Value |
| --- | --- |
| Instance type | `m6i.xlarge` (4 vCPU / 16 GB) — no GPU |
| Root volume | 100 GB gp3, encrypted |
| OS | Ubuntu 24.04 LTS (Noble) |
| Runs | nginx, web, backend, auth, celery x4, redis |

### 3.2 GPU EC2

| Parameter | Value |
| --- | --- |
| Instance type | `g5.2xlarge` (8 vCPU / 32 GB / 1× NVIDIA A10G 24 GB) |
| Root volume | 200 GB gp3, encrypted |
| OS | Ubuntu 24.04 LTS (Noble) + NVIDIA driver + container toolkit |
| Runs | Rhobots Extract OCR |

> ⚠️ The A10G GPU is required for Rhobots Extract. CPU-only parsing is far too slow for
> production insurance documents.

### 3.3 RDS — PostgreSQL 16

| Parameter | Value |
| --- | --- |
| Engine | PostgreSQL **16** (the repo standard; the PB Partners doc used 17) |
| Instance | `db.t4g.medium` (configurable), 100 GB gp3, encrypted |
| Availability | Single-AZ (set `rds_multi_az=true` for HA) |
| Backups | Daily, 7-day retention; PITR enabled |
| TLS | Enforced (`rds.force_ssl=1`) |
| Logical DBs | `insure_iq` (app) · `auth` (Better Auth) |

No RDS Proxy — the fixed set of instances opens few connections and connects
directly over TLS.

### 3.4 S3 & Redis

- **S3**: one bucket `insur-iq-<env>-ec2-uploads`, SSE-S3, reached via the VPC
  gateway endpoint (no NAT egress cost).
- **Redis**: a container on the app box, broker only — task results persist in
  Postgres. No ElastiCache.

---

## 4. Security Architecture

- **Identity & access** — Users authenticate via Better Auth (email/password,
  JWT, short-lived tokens). One **EC2 instance profile** grants the boxes S3
  access, ECR pull, and SSM Session Manager. No long-lived AWS keys on disk.
- **Network isolation** — Both EC2 boxes live in **private subnets**. Only the
  ALB is public. Security groups are least-privilege:
  - ALB ← internet on 80/443
  - app ← ALB on 80 only
  - GPU ← app on 8000 only
  - RDS ← app on 5432 only
- **TLS coverage**

  | Connection | Protocol |
  | --- | --- |
  | User → ALB | HTTPS / TLS 1.2+ (TLS13 policy) |
  | ALB → nginx (app box) | HTTP, inside the VPC |
  | app box → RDS | TLS (enforced) |
  | app box → Rhobots Extract (GPU box) | HTTP, inside the VPC |
  | app box → LLM API | HTTPS (outbound only) |

- **Secrets** — config lives in `.env` files on the instances (gitignored), not
  in source. For tighter governance you can store the same values in **SSM
  Parameter Store** (SecureString) and render `app.env` at boot — optional, not
  required.

Full SG matrix in [Appendix B](#appendix-b-security-group-rules).

---

## 5. Pre-requisite Checklist

| # | Requirement |
| --- | --- |
| 1 | AWS account + credentials (`aws sts get-caller-identity` works) |
| 2 | Terraform ≥ 1.6, AWS CLI v2 installed locally |
| 3 | A registered domain + Route53 hosted zone (or external DNS you control) |
| 4 | ECR repos exist: `insur-iq/backend`, `insur-iq/web`, and `insur-iq/rhobots-extract` (managed outside Terraform — they outlive any environment) |
| 5 | Image tags pushed to ECR by CI |
| 6 | OAuth / LLM (Gemini) API keys on hand for the `.env` files |

Set shell vars once per terminal:

```bash
export AWS_REGION=ap-south-1
export DOMAIN=insuriq.acmecorp.com
```

---

## 6. Provision Infra (Terraform)

The EC2 path has its **own Terraform root**: `infra/terraform-ec2/` (separate
from the EKS `infra/terraform/`). Use one or the other per environment.

```bash
cd infra/terraform-ec2
terraform init
terraform plan \
  -var "domain=$DOMAIN" \
  -var "region=$AWS_REGION" \
  -out tfplan
terraform apply tfplan
```

This provisions: VPC (3 AZ, public/private/db subnets, single NAT, S3 gateway
endpoint), the ALB + target group + listeners, the app and GPU EC2 instances
(with Docker/NVIDIA bootstrapped via cloud-init), the instance profile, RDS
Postgres 16, the S3 bucket, and the ACM cert.

Key outputs:

```bash
terraform output alb_dns_name        # point DNS here if not using Route53
terraform output app_private_ip
terraform output gpu_private_ip      # becomes MINERVA_API_URL
terraform output rds_master_secret_arn
terraform output -raw app_env_snippet > ../../deploy/ec2/app.env
```

---

## 7. DNS & ACM

- **ACM**: if you did not pass `acm_certificate_arn`, Terraform requested a new
  DNS-validated cert. Create the validation CNAME shown in the ACM console (or
  via `aws acm describe-certificate`) and wait for status **ISSUED**.
- **DNS**: if you passed `route53_zone_id`, Terraform already created the ALIAS
  A-record. Otherwise create a CNAME/ALIAS for `$DOMAIN` → `alb_dns_name` in
  your provider.

---

## 8. Configure the Instances

Connect to the app box via SSM Session Manager (no SSH, no bastion):

```bash
aws ssm start-session --target "$(terraform output -raw app_instance_id)"
```

On the app box:

```bash
# Copy deploy/ec2/ to the box (scp via SSM tunnel, git clone, or S3).
cd /opt/insur-iq/deploy/ec2

# Fill app.env (start from the Terraform snippet, then add secrets).
cp app.env.example app.env   # or use the app_env_snippet output
$EDITOR app.env              # fill DB_PASSWORD (from rds_master_secret_arn), SECRET_KEY,
                             # BETTER_AUTH_SECRET, GEMINI_API_KEY, MINERVA_API_URL

# Log Docker in to ECR.
source app.env
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
```

Fetch the DB password from the RDS master secret:

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw rds_master_secret_arn)" \
  --query SecretString --output text | jq -r .password
```

On the GPU box (same `start-session` with `gpu_instance_id`): confirm the GPU,
then fill `gpu.env`:

```bash
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
cp gpu.env.example gpu.env && $EDITOR gpu.env   # set RHOBOTS_EXTRACT_IMAGE
```

---

## 9. Bring Up the Stack

**GPU box first** (the app box's extraction worker depends on it):

```bash
docker compose -f docker-compose.gpu.yml --env-file gpu.env up -d
```

**App box** — create the `auth` logical DB once, then start:

```bash
# Ensure the `auth` database exists on RDS (one-shot).
docker compose -f docker-compose.app.yml --env-file app.env run --rm authdb

docker compose -f docker-compose.app.yml --env-file app.env up -d
```

The backend image's `entrypoint.sh prod` mode runs Django migrations and
`collectstatic` (into the shared `operator-static` volume that nginx serves at
`/service-api/static/`) on boot. Better Auth runs its own schema migrations on
first boot against the `auth` DB.

> **Web image is built per-domain.** The Nuxt `NUXT_PUBLIC_*` URLs are baked at
> **build** time (build args), not read at runtime — CI must build
> `insur-iq/web` with `NUXT_PUBLIC_API_BASE_URL=<domain>/service-api`,
> `NUXT_PUBLIC_AUTH_BASE_URL=https://<domain>/auth/api/auth`,
> `NUXT_PUBLIC_APP_BASE_URL=https://<domain>`, `NUXT_PUBLIC_API_SCHEME=https`.

---

## 10. Verification

```bash
curl -fsS https://$DOMAIN/service-api/api/health/
curl -fsS https://$DOMAIN/auth/api/auth/ok
curl -fsS https://$DOMAIN/ -o /dev/null
```

All three returning 2xx means the deploy is live. Also confirm the ALB target is
healthy:

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$(aws elbv2 describe-target-groups \
      --names insur-iq-${ENV:-prod}-app --query 'TargetGroups[0].TargetGroupArn' --output text)"
```

The target-group health check hits `/healthz` (answered directly by nginx).

---

## 11. Upgrades & Rollback

Roll a new image tag:

```bash
# On the app box — bump the tag in app.env, then:
source app.env
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
docker compose -f docker-compose.app.yml --env-file app.env run --rm migrate   # if the release has migrations
docker compose -f docker-compose.app.yml --env-file app.env pull
docker compose -f docker-compose.app.yml --env-file app.env up -d
```

**Rollback**: set the previous tag in `app.env` and re-run `pull` + `up -d`.
Compose recreates only the changed services. For a full-box failure, replace the
instance from its AMI — no DNS, IAM, or SG changes are needed (the ALB
re-registers the new instance once it is healthy).

---

## 12. Failover, Availability & Day-2

| Area | Mechanism |
| --- | --- |
| App health | ALB health check on `/healthz`; unhealthy targets are drained |
| Compute recovery | Replace EC2 from an AMI; re-attach to the target group |
| Database recovery | Daily RDS snapshots + PITR (`rds_multi_az=true` for AZ failover) |
| In-flight tasks | Fail safely; completed results persist in RDS + S3 |

**Day-2 runbooks:**

```bash
# Logs
docker compose -f docker-compose.app.yml logs -f backend
docker compose -f docker-compose.app.yml logs -f celery_policy_extract

# Restart a service
docker compose -f docker-compose.app.yml --env-file app.env restart backend

# Scale extraction throughput — worker concurrency is set inside the image's
# entrypoint.sh (celery-policy-extract mode). For more headroom, resize the app
# box (vertical) or run the GPU box on a larger instance. There is no HPA here.

# GPU sanity
nvidia-smi
docker compose -f docker-compose.gpu.yml logs -f rhobots-extract
```

---

## 13. Cost Reference

Indicative on-demand monthly cost (ap-south-1, 730 h; excludes data transfer &
LLM API usage):

| Resource | Spec | Notes |
| --- | --- | --- |
| App EC2 | m6i.xlarge | Always-on |
| GPU EC2 | g5.2xlarge | Largest line item; stop when idle to save |
| RDS | db.t4g.medium, 100 GB gp3 | Single-AZ; ~2× for Multi-AZ |
| ALB | 1 ALB | + LCU usage |
| S3 | Standard | Usage-based |
| NAT Gateway | single | Hourly + per-GB |

The GPU instance dominates. If extraction is bursty, stop the GPU box between
batches (the app box queues tasks; they run when Rhobots Extract is back).

---

## Appendix A — Environment Variables

Authoritative templates: [`deploy/ec2/app.env.example`](../deploy/ec2/app.env.example)
and [`deploy/ec2/gpu.env.example`](../deploy/ec2/gpu.env.example).

| Variable | Where | Meaning |
| --- | --- | --- |
| `ECR_REGISTRY`, `*_TAG` | app | Image registry + per-image tags |
| `DOMAIN` | app | Public FQDN; drives derived URLs |
| `SECRET_KEY`, `WEBHOOK_SECRET_KEY` | app | Django secrets |
| `DB_HOST/PORT/USER/PASSWORD/NAME` | app | RDS connection (`DB_NAME_AUTH` = `auth`) |
| `CELERY_BROKER_URL` | app | `redis://redis:6379/0` (local container) |
| `AWS_REGION`, `AWS_STORAGE_BUCKET_NAME` | app | S3 uploads |
| `MINERVA_API_URL` | app | `http://<gpu_private_ip>:8000` |
| `BETTER_AUTH_SECRET` | app | Better Auth signing secret; auth's `DATABASE_STRING` is composed from `DB_*` + `DB_NAME_AUTH` |
| `REQUIRE_EMAIL_VERIFICATION`, `*_CLIENT_ID/SECRET`, `AWS_SENDER_EMAIL` | app | Auth OAuth providers + transactional email |
| `LLM_PROVIDER`, `GOOGLE_API_KEY`, `GEMINI_API_KEY`, `GEMINI_MODEL` | app | Extraction LLM (`GOOGLE_API_KEY` = the Gemini key the backend reads) |
| `RHOBOTS_EXTRACT_IMAGE`, `RHOBOTS_EXTRACT_PORT` | gpu | Rhobots Extract container image + port |

> The Nuxt `NUXT_PUBLIC_*` URLs are **not** in `app.env` — they are baked into
> the `web` image at build time (see §9).

---

## Appendix B — Security Group Rules

**ALB SG**

| Dir | Port | Source / Dest |
| --- | --- | --- |
| In | 80, 443 | `0.0.0.0/0` |
| Out | all | `0.0.0.0/0` |

**App SG**

| Dir | Port | Source / Dest |
| --- | --- | --- |
| In | 80 | ALB SG only |
| Out | all | `0.0.0.0/0` (LLM API, ECR, S3, Rhobots Extract, RDS) |

**GPU SG**

| Dir | Port | Source / Dest |
| --- | --- | --- |
| In | 8000 | App SG only |
| Out | all | `0.0.0.0/0` |

**RDS SG**

| Dir | Port | Source / Dest |
| --- | --- | --- |
| In | 5432 | App SG only |
| Out | all | `0.0.0.0/0` |

---

## Appendix C — Decision Log

- **Split GPU box** — Rhobots Extract runs on its own `g5.2xlarge` instead of sharing the
  app box (as PB Partners did). Lets the expensive GPU instance be stopped when
  idle without touching the always-on app services, and isolates GPU driver/OOM
  failures from the web/API tier.
- **Redis as a container, not ElastiCache** — the broker holds transient queue
  state only (results live in Postgres); a local container removes a managed
  service and its cost.
- **Direct RDS, no Proxy** — a fixed, small set of instances opens few
  connections; RDS Proxy's pooling/failover-muxing buys little here and adds a
  hop. TLS is still enforced.
- **`.env` files, not ESO/Secrets Manager projection** — without Kubernetes
  there is no ESO; instance-local env files are the simplest secure option, with
  SSM Parameter Store available for stricter governance.
- **Instance profile, not Pod Identity** — one IAM role on the boxes (S3 + ECR +
  SSM) replaces the per-workload Pod Identity roles of the EKS path.
- **nginx does path routing, not the ALB** — keeps ALB config trivial (one TLS
  listener → one target group) and mirrors the `/`, `/service-api`, `/auth`
  split the EKS ingress performs.
- **PostgreSQL 16, not 17** — matches the repo standard and the EKS path; the PB
  Partners reference doc specified 17.
