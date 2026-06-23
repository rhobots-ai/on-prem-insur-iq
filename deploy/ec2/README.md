# deploy/ec2 — Docker Compose deployment artifacts

These files run insur-iq on plain EC2 (no Kubernetes), behind an ALB. Full
runbook: [`../../docs/ec2-deployment-guide.md`](../../docs/ec2-deployment-guide.md).

| File | Runs on | Purpose |
| ---- | ------- | ------- |
| `docker-compose.app.yml` | app box | nginx, web, backend, auth, celery x4, redis |
| `docker-compose.gpu.yml` | GPU box | Rhobots Extract OCR (A10G) |
| `nginx/insur-iq.conf` | app box | path routing `/`→web, `/service-api`→backend, `/auth`→auth |
| `app.env.example` | app box | copy → `app.env`, fill secrets |
| `gpu.env.example` | GPU box | copy → `gpu.env`, set Rhobots Extract image |
| `update.sh` | app box | roll a new release: ECR login → pull → recreate → health-check |

> **Never commit `app.env` or `gpu.env`** — they hold DB passwords, auth secrets,
> and LLM keys. Both are gitignored (`deploy/ec2/*.env`).

Quick start (on the app box, after Terraform has provisioned infra):

```bash
terraform -chdir=infra/terraform-ec2 output -raw app_env_snippet > deploy/ec2/app.env
# fill the __FILL__ placeholders, then:
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
# Create the `auth` logical DB on RDS (one-shot, before first up):
docker compose -f docker-compose.app.yml --env-file app.env run --rm authdb
docker compose -f docker-compose.app.yml --env-file app.env up -d
```

Django migrations run automatically on backend boot (`entrypoint.sh prod`);
there is no separate migrate step.

## Updating to a new release

Bump `BACKEND_TAG` / `WEB_TAG` / `AUTH_TAG` in `app.env`, then:

```bash
./update.sh            # ECR login → pull pinned tags → recreate → smoke-check
```

Rollback: restore the previous `*_TAG` values and re-run `./update.sh`.
