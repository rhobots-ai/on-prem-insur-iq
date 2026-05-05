#!/usr/bin/env bash
# verify-infra.sh — post-Terraform infra check before `helm install insur-iq`.
# Run this AFTER `terraform apply` succeeds. For pre-Terraform local-env
# checks (tooling, AWS creds), see preflight.sh.
#
# Exit codes: 0 = all pass; 1 = at least one check failed.
#
# Usage:
#   ENV=prod \
#   AWS_REGION=ap-south-1 \
#   CLUSTER_NAME=insur-iq-prod \
#   NAMESPACE=insur-iq \
#   DOMAIN=insuriq.acmecorp.com \
#   ACM_CERT_ARN=arn:aws:acm:ap-south-1:123:certificate/xxx \
#   RDS_PROXY_ENDPOINT=insur-iq-prod-proxy.proxy-xxx.ap-south-1.rds.amazonaws.com \
#   REDIS_ENDPOINT=xxx.aps1.cache.amazonaws.com:6379 \
#   S3_BUCKET=acmecorp-insur-iq-uploads \
#   ./verify-infra.sh
#
# Tip: feed Terraform outputs directly:
#   ACM_CERT_ARN=$(terraform output -raw acm_certificate_arn) \
#   RDS_PROXY_ENDPOINT=$(terraform output -raw rds_proxy_endpoint) \
#   ... ./verify-infra.sh

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

: "${ENV:?must set ENV}"
: "${AWS_REGION:?must set AWS_REGION}"
: "${CLUSTER_NAME:?must set CLUSTER_NAME}"
: "${NAMESPACE:=insur-iq}"
: "${DOMAIN:?must set DOMAIN}"
: "${ACM_CERT_ARN:?must set ACM_CERT_ARN}"
: "${RDS_PROXY_ENDPOINT:?must set RDS_PROXY_ENDPOINT}"
: "${REDIS_ENDPOINT:?must set REDIS_ENDPOINT}"
: "${S3_BUCKET:?must set S3_BUCKET}"

echo "── Tooling ──"
check "aws CLI installed"                          "command -v aws"
check "kubectl installed"                          "command -v kubectl"
check "helm installed"                             "command -v helm"
check "aws caller identity"                        "aws sts get-caller-identity --output text"

echo "── Cluster ──"
check "EKS cluster exists ($CLUSTER_NAME)"         "aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query cluster.status --output text | grep -q ACTIVE"
check "kubectl context reachable"                  "kubectl get ns >/dev/null"
check "Pod Identity addon installed"               "aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name eks-pod-identity-agent --region $AWS_REGION --query addon.status --output text | grep -q ACTIVE"
check "VPC CNI prefix delegation"                  "aws eks describe-addon-configuration --addon-name vpc-cni --addon-version \$(aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name vpc-cni --region $AWS_REGION --query addon.addonVersion --output text) --region $AWS_REGION >/dev/null"

echo "── Cluster controllers ──"
check "AWS Load Balancer Controller running"       "kubectl -n kube-system get deploy aws-load-balancer-controller >/dev/null"
check "External Secrets Operator running"          "kubectl -n external-secrets get deploy external-secrets >/dev/null"

echo "── App namespace ──"
check "Namespace $NAMESPACE exists"                "kubectl get ns $NAMESPACE"
check "Namespace has PSA restricted label"         "kubectl get ns $NAMESPACE -o jsonpath='{.metadata.labels.pod-security\\.kubernetes\\.io/enforce}' | grep -q restricted"

echo "── Managed infra ──"
check "RDS Proxy endpoint resolves"                "getent hosts $RDS_PROXY_ENDPOINT || nslookup $RDS_PROXY_ENDPOINT"
check "Redis endpoint resolves"                    "getent hosts \${REDIS_ENDPOINT%%:*} || nslookup \${REDIS_ENDPOINT%%:*}"
check "S3 bucket exists ($S3_BUCKET)"              "aws s3api head-bucket --bucket $S3_BUCKET --region $AWS_REGION"
check "ACM cert is ISSUED"                         "aws acm describe-certificate --certificate-arn $ACM_CERT_ARN --region $AWS_REGION --query Certificate.Status --output text | grep -q ISSUED"

echo "── Secrets Manager ──"
for grp in backend db redis auth llm; do
  check "SM secret insur-iq/$ENV/$grp exists"     "aws secretsmanager describe-secret --secret-id insur-iq/$ENV/$grp --region $AWS_REGION"
done

echo "── ClusterSecretStore ──"
check "ClusterSecretStore aws-secretsmanager"     "kubectl get clustersecretstore aws-secretsmanager"

echo
echo "── Summary ── $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 1
