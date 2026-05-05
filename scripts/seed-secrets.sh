#!/usr/bin/env bash
# seed-secrets.sh — seed AWS Secrets Manager for §6 of the EKS deployment guide.
#
# Reads a flat KEY=VALUE env file (scripts/seed-secrets.env), auto-fetches
# Terraform-known values (RDS proxy endpoint, RDS master password, Redis
# endpoint), optionally generates random app secrets, and groups everything
# into the 5 JSON-shaped Secrets Manager entries consumed by ESO:
#
#   insur-iq/<env>/backend   SECRET_KEY, WEBHOOK_SECRET_KEY
#   insur-iq/<env>/db        DB_HOST, DB_PORT, DB_USER, DB_PASSWORD,
#                            DB_NAME, DB_NAME_AUTH, DATABASE_STRING_AUTH
#   insur-iq/<env>/redis     CELERY_BROKER_URL
#   insur-iq/<env>/auth      BETTER_AUTH_SECRET, WEBHOOK_SECRET_KEY, OAuth provider IDs/secrets
#   insur-iq/<env>/llm       LLM_PROVIDER, GEMINI/OPENAI/ANTHROPIC_API_KEY+_MODEL,
#                            GOOGLE_API_KEY, LANGFUSE_* keys
#
# Usage:
#   cp scripts/seed-secrets.example.env scripts/seed-secrets.env
#   $EDITOR scripts/seed-secrets.env
#   ENV=prod ./scripts/seed-secrets.sh
#
# Inputs (env vars, with defaults):
#   ENV         — environment name (default: prod)
#   AWS_REGION  — AWS region (default: ap-south-1)
#   ENV_FILE    — path to the populated env file (default: scripts/seed-secrets.env)
#   TF_DIR      — Terraform directory (default: infra/terraform)

set -euo pipefail

ENV="${ENV:-prod}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
ENV_FILE="${ENV_FILE:-scripts/seed-secrets.env}"
TF_DIR="${TF_DIR:-infra/terraform}"

err() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[34m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
for cmd in aws jq terraform openssl; do
  command -v "$cmd" >/dev/null 2>&1 || err "$cmd not found on PATH"
done

[ -f "$ENV_FILE" ] || err "env file not found: $ENV_FILE
  copy the template first:
    cp scripts/seed-secrets.example.env $ENV_FILE
    \$EDITOR $ENV_FILE"

# Refuse to run if the env file is tracked by git (caught a real secret in source).
if git ls-files --error-unmatch "$ENV_FILE" >/dev/null 2>&1; then
  err "$ENV_FILE is tracked by git — remove it and ensure scripts/seed-secrets.env is in .gitignore"
fi

[ -d "$TF_DIR" ] || err "Terraform dir not found: $TF_DIR"

# ── Load env file ─────────────────────────────────────────────────────────────
# `set -a` exports every variable that gets assigned while it's on, so the
# values become available to this script's environment.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ── Auto-generate app secrets (and persist back to ENV_FILE) ──────────────────
# We persist generated values so re-runs don't keep rotating them, which would
# invalidate user sessions (Better Auth) and Django signed tokens (SECRET_KEY).
gen_if_blank() {
  local var="$1"
  local current="${!var-}"
  if [ -z "$current" ]; then
    local value
    value=$(openssl rand -hex 32)
    # Replace `VAR=` (possibly with trailing comment) — anchored to start of line.
    # Using a temp file keeps this portable across BSD/GNU sed.
    awk -v var="$var" -v val="$value" '
      BEGIN { found = 0 }
      $0 ~ "^"var"=" {
        # Preserve any trailing inline comment after whitespace.
        comment = ""
        if (match($0, /[ \t]+#.*/)) comment = substr($0, RSTART)
        print var"="val comment
        found = 1
        next
      }
      { print }
      END { if (!found) print var"="val }
    ' "$ENV_FILE" > "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    eval "$var=\$value"
    info "generated $var (persisted to $ENV_FILE)"
  fi
}

gen_if_blank SECRET_KEY
gen_if_blank WEBHOOK_SECRET_KEY
gen_if_blank BETTER_AUTH_SECRET

# ── Fetch Terraform outputs ───────────────────────────────────────────────────
tf_out() {
  local name="$1"
  local val
  val=$(terraform -chdir="$TF_DIR" output -raw "$name" 2>/dev/null) \
    || err "terraform output '$name' missing — run 'terraform apply' in $TF_DIR first"
  [ -n "$val" ] || err "terraform output '$name' is empty"
  printf '%s' "$val"
}

info "reading Terraform outputs from $TF_DIR"
DB_HOST=$(tf_out rds_proxy_endpoint)
RDS_MASTER_SECRET_ARN=$(tf_out rds_master_secret_arn)
REDIS_ENDPOINT=$(tf_out redis_endpoint)

# ── Fetch DB master password from RDS-managed secret ──────────────────────────
info "fetching DB master password from RDS master secret"
DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$RDS_MASTER_SECRET_ARN" \
  --region "$AWS_REGION" \
  --query SecretString --output text 2>/dev/null \
  | jq -r '.password // empty') \
  || err "could not read RDS master secret ($RDS_MASTER_SECRET_ARN)"
[ -n "$DB_PASSWORD" ] || err "RDS master secret has no .password field"

# ── Compute derived values ────────────────────────────────────────────────────
# URL-encode the password so special chars (: @ # etc.) don't break the DSN parser.
DB_PASSWORD_ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$DB_PASSWORD")
DATABASE_STRING_AUTH="postgresql://${DB_USER}:${DB_PASSWORD_ENCODED}@${DB_HOST}:${DB_PORT}/${DB_NAME_AUTH}?sslmode=require"
CELERY_BROKER_URL="redis://${REDIS_ENDPOINT%:*}:${REDIS_ENDPOINT##*:}/${REDIS_DB_INDEX}"
# If REDIS_ENDPOINT lacks a port (shouldn't, but be defensive), %:* leaves the
# whole string and ##*: gives the same — fall back to 6379.
case "$REDIS_ENDPOINT" in
  *:*) ;;
  *) CELERY_BROKER_URL="redis://${REDIS_ENDPOINT}:6379/${REDIS_DB_INDEX}" ;;
esac

# ── Build JSON payloads (jq drops empty values for optional keys) ─────────────
# `--arg` strings are always quoted as JSON strings; empty optional keys are
# omitted via `with_entries(select(.value != ""))` so SM doesn't store "".
build_json() {
  jq -n "$@" '$ARGS.named | with_entries(select(.value != ""))'
}

backend_json=$(build_json \
  --arg SECRET_KEY         "$SECRET_KEY" \
  --arg WEBHOOK_SECRET_KEY "$WEBHOOK_SECRET_KEY")

db_json=$(build_json \
  --arg DB_HOST              "$DB_HOST" \
  --arg DB_PORT              "$DB_PORT" \
  --arg DB_USER              "$DB_USER" \
  --arg DB_PASSWORD          "$DB_PASSWORD" \
  --arg DB_NAME              "$DB_NAME" \
  --arg DB_NAME_AUTH         "$DB_NAME_AUTH" \
  --arg DATABASE_STRING_AUTH "$DATABASE_STRING_AUTH")

redis_json=$(build_json \
  --arg CELERY_BROKER_URL "$CELERY_BROKER_URL")

auth_json=$(build_json \
  --arg BETTER_AUTH_SECRET      "$BETTER_AUTH_SECRET" \
  --arg WEBHOOK_SECRET_KEY      "$WEBHOOK_SECRET_KEY" \
  --arg GOOGLE_CLIENT_ID        "${GOOGLE_CLIENT_ID-}" \
  --arg GOOGLE_CLIENT_SECRET    "${GOOGLE_CLIENT_SECRET-}" \
  --arg GITHUB_CLIENT_ID        "${GITHUB_CLIENT_ID-}" \
  --arg GITHUB_CLIENT_SECRET    "${GITHUB_CLIENT_SECRET-}" \
  --arg MICROSOFT_CLIENT_ID     "${MICROSOFT_CLIENT_ID-}" \
  --arg MICROSOFT_CLIENT_SECRET "${MICROSOFT_CLIENT_SECRET-}")

llm_json=$(build_json \
  --arg LLM_PROVIDER         "${LLM_PROVIDER-}" \
  --arg GEMINI_API_KEY       "${GEMINI_API_KEY-}" \
  --arg GEMINI_MODEL         "${GEMINI_MODEL-}" \
  --arg OPENAI_API_KEY       "${OPENAI_API_KEY-}" \
  --arg OPENAI_MODEL         "${OPENAI_MODEL-}" \
  --arg ANTHROPIC_API_KEY    "${ANTHROPIC_API_KEY-}" \
  --arg ANTHROPIC_MODEL      "${ANTHROPIC_MODEL-}" \
  --arg GOOGLE_API_KEY       "${GOOGLE_API_KEY-}" \
  --arg LANGFUSE_PUBLIC_KEY  "${LANGFUSE_PUBLIC_KEY-}" \
  --arg LANGFUSE_SECRET_KEY  "${LANGFUSE_SECRET_KEY-}")

# ── Push to Secrets Manager ───────────────────────────────────────────────────
put() {
  local grp="$1" json="$2"
  local id="insur-iq/$ENV/$grp"
  local count
  count=$(printf '%s' "$json" | jq 'length')
  aws secretsmanager put-secret-value \
    --secret-id "$id" \
    --region "$AWS_REGION" \
    --secret-string "$json" >/dev/null \
    || err "put-secret-value failed for $id (does the secret exist? run 'terraform apply')"
  ok "seeded $id ($count keys)"
}

put backend "$backend_json"
put db      "$db_json"
put redis   "$redis_json"
put auth    "$auth_json"
put llm     "$llm_json"

echo
ok "all 5 secrets seeded for ENV=$ENV in $AWS_REGION"
echo "   verify with:"
echo "     ENV=$ENV ./scripts/verify-infra.sh"
