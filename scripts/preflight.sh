#!/usr/bin/env bash
# preflight.sh — local-environment check before running Terraform.
# Verifies the operator's machine has the right tools and credentials.
#
# Run this BEFORE `terraform apply`. For post-Terraform infra checks, see
# verify-infra.sh.
#
# Exit codes: 0 = all pass; 1 = at least one check failed.
#
# Usage:
#   AWS_REGION=ap-south-1 ./preflight.sh
#
# Optional:
#   AWS_PROFILE=<profile>   # if not using default creds

set -uo pipefail

PASS=0
FAIL=0

check() {
  local label="$1" cmd="$2"
  printf "%-60s " "$label"
  if eval "$cmd" >/dev/null 2>&1; then
    printf "\033[32mOK\033[0m\n"
    PASS=$((PASS+1))
  else
    printf "\033[31mFAIL\033[0m\n"
    FAIL=$((FAIL+1))
  fi
}

: "${AWS_REGION:?must set AWS_REGION (e.g. ap-south-1)}"

echo "── Tooling ──"
check "aws CLI installed"                          "command -v aws"
check "kubectl installed"                          "command -v kubectl"
check "helm installed"                             "command -v helm"
check "terraform installed"                        "command -v terraform"
check "jq installed"                               "command -v jq"

echo "── AWS credentials ──"
check "aws caller identity resolves"               "aws sts get-caller-identity --output text"
check "aws region is set"                          "[ -n \"$AWS_REGION\" ]"
check "EC2 describe-regions works in $AWS_REGION"  "aws ec2 describe-regions --region $AWS_REGION --output text"

echo "── Quotas / capacity (advisory) ──"
check "EKS service available in $AWS_REGION"      "aws eks list-clusters --region $AWS_REGION --output text"
check "RDS service available in $AWS_REGION"      "aws rds describe-db-engine-versions --engine postgres --region $AWS_REGION --max-records 20 --output text"

echo
echo "── Summary ── $PASS pass, $FAIL fail"
if [ "$FAIL" -eq 0 ]; then
  echo "Preflight passed. You can now run \`terraform apply\` in infra/terraform/."
else
  exit 1
fi
