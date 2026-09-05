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
| `docker-compose.override.yml` | app box | *optional, untracked* — site-local changes; see below |

> **Never commit `app.env` or `gpu.env`** — they hold DB passwords, auth secrets,
> and LLM keys. Both are gitignored (`deploy/ec2/*.env`).

### Site-local overrides

If `docker-compose.override.yml` exists in this directory, `update.sh` passes it
to every compose command. Put anything site-specific there — published ports,
bind mounts, disabling a service via `profiles:` — and leave
`docker-compose.app.yml` pristine so `git pull` can never revert a deployment
decision.

Compose does **not** pick this file up on its own here: it only auto-loads an
override next to a *default-named* base file (`docker-compose.yml`), and this
project's base file is `docker-compose.app.yml`. So a hand-run
`docker compose -f docker-compose.app.yml ...` silently ignores the override and
can undo a site's configuration. Either use `update.sh`, or pass both files:

```bash
docker compose -f docker-compose.app.yml -f docker-compose.override.yml \
  --env-file app.env ps
```

A service held behind a profile does not start by default; run it on demand with
`--profile <name> up -d <service>`.

Quick start (on the app box, after Terraform has provisioned infra):

```bash
terraform -chdir=infra/terraform-ec2 output -raw app_env_snippet > deploy/ec2/app.env
# fill the __FILL__ placeholders. Vertex AI is on by default — place the GCP
# service-account key at /home/ubuntu/.gcp/sa-key.json (the GCP_CREDENTIALS_DIR,
# mounted read-only to /secrets/gcp). To skip Vertex, blank GOOGLE_GENAI_USE_VERTEXAI
# and fill GOOGLE_API_KEY/GEMINI_API_KEY instead. Then:
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
