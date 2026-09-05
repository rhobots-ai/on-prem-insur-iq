#!/usr/bin/env bash
# update.sh — roll a new release on the EC2 app box (Docker Compose path).
#
# Wraps the manual upgrade sequence from docs/ec2-deployment-guide.md §11:
# ECR login → pull the tags pinned in app.env → recreate changed services.
# Django migrations run automatically inside `entrypoint.sh prod` when the
# backend container boots, so there is no separate migrate step.
#
# Run this ON the app box, from this directory (deploy/ec2/), after bumping
# BACKEND_TAG / WEB_TAG / AUTH_TAG in app.env to the release you want live.
#
# Usage:
#   ./update.sh                       # pull + recreate, then smoke-check
#   ENV_FILE=app.env ./update.sh      # custom env file (default: app.env)
#   ./update.sh --no-check            # skip the post-deploy health curls
#   ./update.sh --pull-only           # pull images, do not recreate
#
# Exit codes: 0 = updated and healthy; 1 = a step or health check failed.
#
# Rollback: set the previous *_TAG values in app.env and re-run this script.

set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")"

ENV_FILE="${ENV_FILE:-app.env}"
COMPOSE_FILE="docker-compose.app.yml"
DO_CHECK=1
PULL_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --no-check)  DO_CHECK=0 ;;
    --pull-only) PULL_ONLY=1 ;;
    -h|--help)   grep '^#' "$SELF" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found (run from deploy/ec2/, or set ENV_FILE=)" >&2
  exit 1
fi

# An optional docker-compose.override.yml is honoured when present. Compose only
# auto-loads that file when the base file has the default name, and this project
# does not, so it has to be passed explicitly -- without this, a site-local
# override is silently ignored by every command below.
COMPOSE_FILES=(-f "$COMPOSE_FILE")
OVERRIDE_FILE="docker-compose.override.yml"
if [[ -f "$OVERRIDE_FILE" ]]; then
  COMPOSE_FILES+=(-f "$OVERRIDE_FILE")
fi

compose() { docker compose "${COMPOSE_FILES[@]}" --env-file "$ENV_FILE" "$@"; }

# Pull ECR_REGISTRY / AWS_REGION / DOMAIN out of the env file without leaking
# the rest of it into this shell.
ECR_REGISTRY="$(grep -E '^ECR_REGISTRY=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
AWS_REGION="$(grep -E '^AWS_REGION='   "$ENV_FILE" | head -1 | cut -d= -f2-)"
DOMAIN="$(grep -E '^DOMAIN='           "$ENV_FILE" | head -1 | cut -d= -f2-)"

if [[ -z "${ECR_REGISTRY:-}" || -z "${AWS_REGION:-}" ]]; then
  echo "error: ECR_REGISTRY and AWS_REGION must be set in $ENV_FILE" >&2
  exit 1
fi

echo "==> ECR login ($ECR_REGISTRY)"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "==> Pulling images pinned in $ENV_FILE"
compose pull

if [[ "$PULL_ONLY" == 1 ]]; then
  echo "==> --pull-only: images pulled, services NOT recreated."
  exit 0
fi

echo "==> Recreating changed services (migrations run on backend boot)"
compose up -d

if [[ "$DO_CHECK" == 0 ]]; then
  echo "==> --no-check: skipping health checks."
  exit 0
fi

# Smoke-check through nginx on the app box (TLS terminates at the ALB, so the
# box itself serves plain HTTP on :80). Same endpoints as CLAUDE.md's smoke test.
echo "==> Health check (waiting up to 120s)"
endpoints=(
  "http://127.0.0.1:80/service-api/api/health/"
  "http://127.0.0.1:80/auth/api/auth/ok"
  "http://127.0.0.1:80/"
)

deadline=$(( $(date +%s) + 120 ))
for ep in "${endpoints[@]}"; do
  printf "    %-45s " "$ep"
  while true; do
    if curl -fsS -o /dev/null --max-time 5 "$ep"; then
      printf "\033[32mOK\033[0m\n"
      break
    fi
    if (( $(date +%s) >= deadline )); then
      printf "\033[31mFAIL\033[0m\n"
      echo "error: $ep did not become healthy in time." >&2
      echo "       check: docker compose ${COMPOSE_FILES[*]} --env-file $ENV_FILE ps" >&2
      echo "       logs:  docker compose ${COMPOSE_FILES[*]} --env-file $ENV_FILE logs --tail=50" >&2
      echo "       rollback: restore previous *_TAG in $ENV_FILE and re-run ./update.sh" >&2
      exit 1
    fi
    sleep 3
  done
done

echo "==> Update complete${DOMAIN:+ — https://$DOMAIN}"
