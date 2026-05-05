# insur-iq — AWS EKS Deployment Guide

This guide is **self-contained**: a DevOps engineer who has never seen the project should be able to deploy insur-iq on a fresh AWS account by following this document end-to-end.

The deployment is **configuration-driven**. You will edit one Helm values file (15–20 lines) and run a small set of commands.

---

## Table of Contents

1. [Quickstart (30 minutes)](#1-quickstart-30-minutes)
2. [Architecture](#2-architecture)
3. [Pre-requisite Checklist](#3-pre-requisite-checklist)
4. [Provisioning AWS Infra (Terraform)](#4-provisioning-aws-infra-terraform)
5. [Cluster Bootstrap](#5-cluster-bootstrap)
6. [Secrets Manager Seeding](#6-secrets-manager-seeding)
7. [Helm Values Walkthrough](#7-helm-values-walkthrough)
8. [First Install](#8-first-install)
9. [Verification](#9-verification)
10. [Upgrades & Rollback](#10-upgrades--rollback)
11. [Teardown & Decommission](#11-teardown--decommission)
12. [Day-2 Runbooks](#12-day-2-runbooks)
13. [Cost Reference](#13-cost-reference)
14. [Appendix A — Environment Variable Reference](#appendix-a--environment-variable-reference)
15. [Appendix B — IAM Policy JSONs](#appendix-b--iam-policy-jsons)
16. [Appendix C — CloudWatch Alarms](#appendix-c--cloudwatch-alarms)
17. [Appendix D — Decision Log](#appendix-d--decision-log)

---

## 1. Quickstart (30 minutes)

Skip to [§3 Pre-requisite Checklist](#3-pre-requisite-checklist) for the full step-by-step. If your AWS infra is already provisioned (Terraform applied) and the cluster has the controllers from [§5](#5-cluster-bootstrap):

```bash
# 0. Set once per terminal — every step below reads these.
#    Copy the template, fill in values, and source it. See §3 step 0.
cp deploy.example.env deploy.env
$EDITOR deploy.env
source ./deploy.env

# 1. Generate my-values.yaml from Terraform outputs.
#    Run from the repo root — the redirect path is relative to your CWD.
#    (See §4 for what this file contains and §7 for what to edit in it.)
cd /path/to/on-prem-insur-iq    # repo root
terraform -chdir=infra/terraform output -raw helm_values_snippet \
  > helm/insur-iq/my-values.yaml

# 2. Edit helm/insur-iq/my-values.yaml to add image tags from CI.
#    The file is gitignored — never commit it.

# 3. Seed Secrets Manager (one-time per env). See §6 for the env file layout.
cp scripts/seed-secrets.example.env scripts/seed-secrets.env
$EDITOR scripts/seed-secrets.env       # fill OAuth/LLM keys; the rest is auto-filled
./scripts/seed-secrets.sh

# 4. Install
kubectl create namespace $NAMESPACE \
  --dry-run=client -o yaml \
  | kubectl label --local -f - pod-security.kubernetes.io/enforce=restricted -o yaml \
  | kubectl apply -f -

helm install insur-iq ./helm/insur-iq \
  --namespace $NAMESPACE \
  --values helm/insur-iq/my-values.yaml \
  --rollback-on-failure --timeout 10m

# 5. Smoke test
curl -fsS https://$DOMAIN/service-api/api/health/
curl -fsS https://$DOMAIN/auth/api/auth/ok
curl -fsS https://$DOMAIN/ -o /dev/null
```

If all three return 2xx, the deploy is live.

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
         │    ALB + ACM cert    │   idle_timeout=300s, target-type=ip
         └──────────┬───────────┘
                    │  path-based routing
   ┌────────────────┼─────────────────┐
   │                │                 │
   ▼ /              ▼ /service-api/   ▼ /auth/
 ┌──────┐         ┌──────────┐     ┌──────┐
 │ web  │         │ backend  │     │ auth │
 │ Nuxt │         │ Django   │     │Better│
 │ :3000│         │ :8000    │     │ Auth │
 └──────┘         └────┬─────┘     │:10000│
                       │           └──┬───┘
                       ▼              │
                ┌──────────────┐      │
                │ celery x4    │◄─────┘
                │  default     │
                │  policy_extr │
                │  comm_intake │
                │  beat        │
                └──┬───────┬───┘
                   │       │
                   ▼       ▼
   ┌────────────────┐  ┌──────────────┐  ┌────────────┐
   │ ElastiCache    │  │ RDS Proxy    │  │ S3 bucket  │
   │ Redis 7        │  │     │        │  │ uploads    │
   │ (broker)       │  │     ▼        │  └────────────┘
   └────────────────┘  │ RDS Postgres │
                       │  insure_iq   │
                       │  auth        │
                       └──────────────┘
```

External egress: LLM provider APIs (Gemini/OpenAI/Anthropic), Langfuse, ECR, Secrets Manager — all over `0.0.0.0/0:443`.

---

## 3. Pre-requisite Checklist

### Step 0 — Set up your shell environment

Every command in this guide (terraform, aws, kubectl, helm, `scripts/*.sh`) reads a small set of shell variables. Set them once per terminal by copying the template and sourcing it:

```bash
cp deploy.example.env deploy.env       # repo root; deploy.env is gitignored
$EDITOR deploy.env                     # set ENV, AWS_REGION, DOMAIN, etc.
source ./deploy.env

# sanity check — none of these should be empty
echo "ENV=$ENV AWS_REGION=$AWS_REGION CLUSTER_NAME=$CLUSTER_NAME DOMAIN=$DOMAIN"
```

Re-run `source ./deploy.env` in any new terminal you open during the deploy. An empty `$AWS_REGION` (or any other variable) will surface as errors like `argument --region: expected one argument` from the AWS CLI.

**Bring-your-own ACM cert (optional).** `deploy.env` ships with `ACM_CERTIFICATE_ARN=` blank — that means Terraform will *request* a new regional cert for `$DOMAIN` and you'll create the validation CNAME in [§4a](#4a-create-dns-records-manual). If you already have an `ISSUED` regional cert in `$AWS_REGION` covering `$DOMAIN`, set its ARN here before running Terraform; the cert resource is then skipped entirely (no new request, no validation CNAME needed) and the same `acm_certificate_arn` output is emitted from your value. `terraform destroy` will not touch a BYO cert.

After [§4 Terraform](#4-provisioning-aws-infra-terraform) applies, uncomment the **Post-Terraform** block in `deploy.env` and `source ./deploy.env` again — that exports `ACM_CERT_ARN`, `RDS_PROXY_ENDPOINT`, `REDIS_ENDPOINT`, and `S3_BUCKET` from Terraform outputs, which §4a and §8 require.

### Step 1 — Run preflight

Run [`./scripts/preflight.sh`](./scripts/preflight.sh) to confirm your local machine has the right tools and AWS credentials. It does not touch AWS infra.

```bash
./scripts/preflight.sh                 # reads $AWS_REGION from deploy.env
```

Provision the items below **before** running `helm install`. Each item is independent — many can be parallelized. The Terraform skeleton in [§4](#4-provisioning-aws-infra-terraform) does items 1–11 in one apply.

| # | Item | Completion criterion |
|---|---|---|
| 1 | AWS account with admin access; chosen region | `aws sts get-caller-identity` returns expected account |
| 2 | VPC: 3 AZs, public + private subnets, NAT/AZ, S3 gateway endpoint | `aws ec2 describe-vpcs` shows the VPC |
| 3 | EKS 1.35 cluster, OIDC provider, access entries (no aws-auth), managed node groups (system: 1× t3.medium, app: 1× t3.large — both auto-scalable up to 2/3 nodes) | `aws eks describe-cluster` shows status `ACTIVE`; `aws eks describe-nodegroup` shows both groups `ACTIVE` |
| 4 | Add-ons: VPC CNI (prefix delegation ON), CoreDNS, kube-proxy, EBS CSI, Pod Identity Agent | `aws eks describe-addon ... --query addon.status` returns `ACTIVE` for each |
| 5 | Cluster controllers: AWS Load Balancer Controller, External Secrets Operator, metrics-server (CloudWatch observability is installed by the EKS addon in Terraform) | each Deployment has Ready replicas |
| 6 | RDS Postgres 16 (`db.t4g.medium`, single-AZ, 100GB gp3, `force_ssl=1`) with two DBs: `insure_iq`, `auth` | `psql` connects from a bastion / cloudshell |
| 7 | RDS Proxy fronting the instance, security group allows :5432 from EKS pod subnets | `aws rds describe-db-proxies` shows `available` |
| 8 | ElastiCache Redis 7 (`cache.t4g.small`), security group allows :6379 from EKS pod subnets | `redis-cli -h <endpoint> ping` returns `PONG` |
| 9 | S3 bucket (SSE-S3) | `aws s3api head-bucket` succeeds |
| 10 | ACM regional cert for `<domain>` (validated via Route53 DNS) — or set `ACM_CERTIFICATE_ARN` to reuse an existing one (see [§4a](#4a-create-dns-records-manual)) | `aws acm describe-certificate` shows `ISSUED` |
| 11 | Route53 hosted zone for `<domain>` | `aws route53 list-hosted-zones-by-name` shows the zone |
| 12 | ECR repos: `insur-iq/backend`, `insur-iq/web`; pull-through cache for Docker Hub (Better Auth) | `aws ecr describe-repositories` lists both |
| 13 | EKS Pod Identity associations: `insur-iq-backend` (S3 RW + SM read), `insur-iq-celery` (S3 RW + SM read) in namespace `insur-iq` | `aws eks list-pod-identity-associations` shows both |
| 14 | Secrets Manager entries: 5 secrets under `insur-iq/<env>/{backend,db,redis,auth,llm}` populated (see [§6](#6-secrets-manager-seeding) — `./scripts/seed-secrets.sh` does this in one pass) | `aws secretsmanager get-secret-value` returns each |
| 15 | A `ClusterSecretStore` named `aws-secretsmanager` in the cluster, scoped to the SM secrets above | `kubectl get clustersecretstore aws-secretsmanager` |
| 16 | Namespace `insur-iq` with `pod-security.kubernetes.io/enforce=restricted` label | `kubectl get ns insur-iq -o jsonpath='{.metadata.labels}'` shows the label |

Once Terraform has applied and items 1–15 should exist, run [`./scripts/verify-infra.sh`](./scripts/verify-infra.sh) to confirm they're all healthy. (See [§8](#8-first-install) for the invocation with all required env vars.)

---

## 4. Provisioning AWS Infra (Terraform)

A working Terraform skeleton lives at `infra/terraform/`. It provisions VPC, EKS, RDS, RDS Proxy, ElastiCache, S3, ECR, ACM, Pod Identity associations, and the 5 Secrets Manager entries (empty — you fill them in [§6](#6-secrets-manager-seeding)).

```bash
cd infra/terraform
terraform init
terraform plan \
  -var "domain=$DOMAIN" \
  -var "region=$AWS_REGION" \
  -var "acm_certificate_arn=$ACM_CERTIFICATE_ARN" \
  -out tfplan
terraform apply tfplan
```

> `acm_certificate_arn` is optional — leave `ACM_CERTIFICATE_ARN` blank in `deploy.env` to have Terraform request a new cert (default), or set it to an existing regional cert ARN to skip cert creation. See the BYO note in [§3](#3-pre-requisite-checklist) and the branch in [§4a](#4a-create-dns-records-manual).

After apply:

```bash
# Configure kubectl
aws eks update-kubeconfig --name insur-iq-prod --region ap-south-1

# Generate the env-specific Helm values file, named my-values.yaml,
# from Terraform outputs. This file holds your account ID, ACM cert ARN,
# S3 bucket name, ECR repos, subnet CIDRs, and Pod Identity role ARNs.
# Run from the repo root — the redirect path (helm/insur-iq/...) is
# relative to your shell's CWD, not to the -chdir flag.
cd ../..   # back to repo root from infra/terraform
terraform -chdir=infra/terraform output -raw helm_values_snippet \
  > helm/insur-iq/my-values.yaml
```

The file `helm/insur-iq/my-values.yaml` is now created and **gitignored** — never commit it. You will edit it in [§7](#7-helm-values-walkthrough) to add the bits Terraform doesn't know (image tags from CI, OAuth client IDs, etc.).

While you're here, also save the controller install commands for [§5](#5-cluster-bootstrap):

```bash
terraform -chdir=infra/terraform output -raw cluster_controllers_install \
  > /tmp/install-controllers.sh
```

If you don't run Terraform, the AWS Console / CLI equivalents follow the same resource list. The most common pitfalls are: forgetting to enable VPC CNI **prefix delegation** (you'll hit pod IP exhaustion on dense nodes), and forgetting to associate the OIDC provider with the cluster (Pod Identity won't work).

### 4a. Create DNS records (manual)

Terraform outputs Helm values but does **not** write any records into Route 53 (or your DNS provider). Up to two records are your responsibility, depending on whether Terraform created the cert or you brought your own:

| # | Record | When | Why |
| --- | --- | --- | --- |
| 1 | ACM validation CNAME | Right after `terraform apply` — **only if Terraform requested the cert** | ACM stays `PENDING_VALIDATION` until this CNAME resolves; without it the cert never issues and the ALB can't terminate TLS in [§8](#8-first-install). Skip this row entirely if you set `ACM_CERTIFICATE_ARN` (the cert is already `ISSUED`). |
| 2 | ALB alias A-record (`<domain> → <alb-dns>`) | After `helm install` (the ALB doesn't exist until then) — **always required** | Routes user traffic to your ingress. Covered in [§8](#8-first-install). |

> **Did you set `ACM_CERTIFICATE_ARN` in `deploy.env`?** Skip Record 1 below and jump to [§5 Cluster Bootstrap](#5-cluster-bootstrap) — the cert is already issued, so there's no validation CNAME to create. (You'll still need Record 2 in §8.)

**Record 1 — fetch the validation CNAME and create it now (Terraform-managed cert path only):**

> Now that Terraform has applied, uncomment the **Post-Terraform** block in `deploy.env` and re-source it so `$ACM_CERT_ARN` (and the other Terraform outputs) are populated:
>
> ```bash
> $EDITOR deploy.env       # uncomment the Post-Terraform exports
> source ./deploy.env
> echo "$ACM_CERT_ARN"     # must be non-empty before the commands below
> ```

```bash
# Print the CNAME name + value ACM expects.
aws acm describe-certificate \
  --certificate-arn "$ACM_CERT_ARN" \
  --region "$AWS_REGION" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord' \
  --output table
# → Name:  _abc123…<domain>.
#   Type:  CNAME
#   Value: _xyz789….acm-validations.aws.
```

Create that CNAME in your DNS provider. If the hosted zone is in the same AWS account, set `ROUTE53_ZONE_ID` in `deploy.env` and re-source it, then run:

```bash
echo "$ROUTE53_ZONE_ID"  # must be non-empty before the commands below

NAME=$(aws acm describe-certificate --certificate-arn "$ACM_CERT_ARN" --region "$AWS_REGION" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text)
VALUE=$(aws acm describe-certificate --certificate-arn "$ACM_CERT_ARN" --region "$AWS_REGION" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' --output text)

aws route53 change-resource-record-sets --hosted-zone-id "$ROUTE53_ZONE_ID" --change-batch "{
  \"Changes\": [{
    \"Action\": \"UPSERT\",
    \"ResourceRecordSet\": {
      \"Name\": \"$NAME\",
      \"Type\": \"CNAME\",
      \"TTL\": 300,
      \"ResourceRecords\": [{\"Value\": \"$VALUE\"}]
    }
  }]
}"
```

ACM polls every minute. Wait for the cert to flip to `ISSUED` before continuing:

```bash
aws acm wait certificate-validated --certificate-arn "$ACM_CERT_ARN" --region "$AWS_REGION" \
  && echo "ACM cert ISSUED"
```

If the hosted zone lives in a different AWS account or with an external provider (Cloudflare, etc.), create the same `Name → Value` CNAME there. The cert won't issue until that CNAME is resolvable from the public internet.

> **One-time fix:** if you'd rather Terraform manage these records, add `aws_route53_record` resources for both the validation CNAME and the ALB alias (the ALB DNS name comes from a `data "aws_lb"` lookup after the chart is installed). Out of scope for this guide.

---

## 5. Cluster Bootstrap

Install the cluster-wide controllers **once**, before the app. Their IAM roles + Pod Identity associations were already created in [§4](#4-provisioning-aws-infra-terraform); this step installs the actual controller pods.

The fastest way is the convenience script generated by Terraform — it pre-fills your cluster name, region, and VPC ID:

```bash
# Run from the repo root
terraform -chdir=infra/terraform output -raw cluster_controllers_install | bash
```

That installs all four: AWS Load Balancer Controller, External Secrets Operator, metrics-server, and Cluster Autoscaler. The script is **idempotent** — every step uses `helm upgrade --install`, so re-running it after a partial failure is safe.

To see what it will run without executing:

```bash
terraform -chdir=infra/terraform output -raw cluster_controllers_install
```

> **Note:** Terraform caches output values. If you (or we) ever change `outputs.tf`, run `terraform apply` again to refresh the cached output before piping it to bash — otherwise you'll get the stale snippet.

If you'd rather run them by hand (substituting your cluster name/region/VPC):

```bash
# All commands use `helm upgrade --install` so re-running the section
# (e.g. after fixing one error) is safe — no "release already exists" failures.

# AWS Load Balancer Controller — install FIRST and WAIT.
# LBC installs a mutating webhook for every Service create cluster-wide.
# If the webhook's Service has no endpoints when the next install runs, you'll
# see: "no endpoints available for service aws-load-balancer-webhook-service".
# Waiting on Deployment Available is necessary but not sufficient — the webhook
# Service endpoints lag the pod's Ready status by a few seconds.
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=insur-iq-prod \
  --set region=ap-south-1 \
  --set vpcId=<your-vpc-id> \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller

# Step 1: wait for the deployment to be healthy
kubectl -n kube-system wait --for=condition=Available \
  deploy/aws-load-balancer-controller --timeout=180s

# Step 2: wait until the webhook Service actually has endpoints (the real gate).
# Without this, the next helm install can race ahead and fail.
echo "Waiting for LBC webhook endpoints..."
until kubectl -n kube-system get endpoints aws-load-balancer-webhook-service \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q .; do
  sleep 2
done
echo "LBC webhook ready."

# External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io && helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --set installCRDs=true

# metrics-server (required for HPA — kubectl top, autoscaling.*)
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ && helm repo update
helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system

# Cluster Autoscaler — scales node groups when pods are Pending.
helm repo add autoscaler https://kubernetes.github.io/autoscaler && helm repo update
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=insur-iq-prod \
  --set awsRegion=ap-south-1 \
  --set rbac.serviceAccount.create=true \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set extraArgs.balance-similar-node-groups=true \
  --set extraArgs.scale-down-unneeded-time=10m
```

Verify all four are healthy before continuing:

```bash
# 1. AWS Load Balancer Controller — expect 2 pods 1/1 Running
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller

# 2. External Secrets Operator — expect 3 pods 1/1 Running
#    (cert-controller may take ~60s to become Ready while it bootstraps its certs)
kubectl -n external-secrets get pods

# 3. metrics-server — expect a table of CPU/MEM per node (no errors)
kubectl top nodes

# 4. Cluster Autoscaler — the chart names the deployment with the release-name
#    prefix: `cluster-autoscaler-aws-cluster-autoscaler`. Expect log lines like
#    "Starting main loop" and "Found ... availability zones for ASG ...".
kubectl -n kube-system logs deploy/cluster-autoscaler-aws-cluster-autoscaler --tail=20
```

> **How autoscaling fits together** (top-down):
> 1. **HPA** watches pod CPU% via metrics-server. When `backend` averages >70% CPU, it bumps replicas (up to `maxReplicas` in [values.yaml](../../helm/insur-iq/values.yaml)).
> 2. New replica is `Pending` if no node has room.
> 3. **Cluster Autoscaler** sees the Pending pod, finds an ASG tagged `k8s.io/cluster-autoscaler/insur-iq-prod=owned` whose template fits the pod, and calls `SetDesiredCapacity`.
> 4. AWS provisions a new EC2; once it joins the cluster (~2-3 min), the pod schedules.
> 5. When load drops, HPA shrinks replicas, CA notices the under-utilization (>10 min), drains and terminates the node.

> **Observability:** metrics + logs are handled by the `amazon-cloudwatch-observability` EKS addon, which Terraform installs automatically (see [§4](#4-provisioning-aws-infra-terraform)). It runs Fluent Bit + the CloudWatch agent as DaemonSets and ships container metrics + pod logs to CloudWatch Container Insights — no Prometheus, no Grafana, no extra pods on `system`. Alerts are CloudWatch Alarms ([Appendix C](#appendix-c--cloudwatch-alarms)). Migrate to AMP/AMG only when you need PromQL or custom application metrics.

Then create the app namespace (with PSA restricted) and the `ClusterSecretStore`:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: insur-iq
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-south-1
      # No `auth:` block on purpose. With EKS Pod Identity, the agent injects
      # AWS_CONTAINER_CREDENTIALS_FULL_URI + a projected token volume into the
      # ESO pod, and the AWS SDK's default credential chain picks them up
      # automatically. Adding `auth.jwt.serviceAccountRef` here would force the
      # IRSA (OIDC) path instead and fail with "an IAM role must be associated
      # with service account" because the SA isn't OIDC-annotated.
EOF
```

> **If you change the Pod Identity association** (e.g. point ESO at a new IAM role), restart the ESO deployment so the new credentials are picked up — the agent only injects creds at pod startup:
>
> ```bash
> kubectl rollout restart deployment -n external-secrets external-secrets
> ```

ESO needs Pod Identity to read SM. **Terraform creates this association automatically** ([main.tf](infra/terraform/main.tf) `aws_eks_pod_identity_association.external_secrets`) — verify with:

```bash
aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" --namespace external-secrets
```

If (and only if) the list is empty, recreate it manually:

```bash
aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" \
  --namespace external-secrets \
  --service-account external-secrets \
  --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-external-secrets"
```

The role must have `secretsmanager:GetSecretValue` on `arn:aws:secretsmanager:*:*:secret:insur-iq/*`.

---

## 6. Secrets Manager Seeding

Each secret is a **JSON-shaped** value. ESO extracts every JSON key into a Kubernetes Secret of the same name.

### Secret layout

| Secrets Manager path | Keys | Consumed by |
|---|---|---|
| `insur-iq/<env>/backend` | `SECRET_KEY`, `WEBHOOK_SECRET_KEY` | backend, celery, beat, migrate |
| `insur-iq/<env>/db` | `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_NAME_AUTH`, `DATABASE_STRING_AUTH` | backend, celery, beat, migrate, auth, auth-db-init |
| `insur-iq/<env>/redis` | `CELERY_BROKER_URL` | backend, celery, beat |
| `insur-iq/<env>/auth` | `BETTER_AUTH_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET` | auth |
| `insur-iq/<env>/llm` | `GEMINI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` | backend, celery |

### Seeding commands

Edit one flat env file, then run one script. The script regroups the keys into the five JSON-shaped SM entries above, auto-fills values Terraform already knows (`DB_HOST`, `DB_PASSWORD`, `CELERY_BROKER_URL`), and auto-generates `SECRET_KEY`, `WEBHOOK_SECRET_KEY`, `BETTER_AUTH_SECRET` when blank.

```bash
# 1. Copy the template and fill in OAuth/LLM keys (everything else is optional
#    or auto-filled). The real env file is gitignored.
cp scripts/seed-secrets.example.env scripts/seed-secrets.env
$EDITOR scripts/seed-secrets.env

# 2. Seed all 5 Secrets Manager entries in one pass.
ENV=prod ./scripts/seed-secrets.sh

# 3. Confirm all 5 SM entries exist (focused check; the full sweep is in §8).
for grp in backend db redis auth llm; do
  aws secretsmanager describe-secret \
    --secret-id "insur-iq/prod/$grp" --region ap-south-1 \
    --query Name --output text
done

# 4. Force ESO to re-sync now (otherwise it waits for refreshInterval, default 1h).
kubectl -n insur-iq annotate externalsecret --all force-sync=$(date +%s) --overwrite
kubectl -n insur-iq get externalsecret    # every row should show STATUS=SecretSynced
```

The flat `seed-secrets.env` shape mirrors the application's `.env.example` (in the main `insur-iq` repo); the script reshapes it into the five JSON entries that [`helm/insur-iq/templates/_helpers.tpl`](../../helm/insur-iq/templates/_helpers.tpl) (`backendEnvFrom`) wires into pods via `envFrom: secretRef`. Re-running is safe: generated random values are persisted back to `seed-secrets.env`, so subsequent runs produce byte-identical SM payloads (no version churn, no session invalidation). Keep `seed-secrets.env` in 1Password / your password manager — it's the only artifact you need to round-trip through this script.

### Rotation

| Secret | Strategy | Side effect of rotation |
|---|---|---|
| `db.DB_PASSWORD` | SM scheduled rotation (Lambda), 30-day cadence; ESO refreshes K8s Secret; restart with `kubectl rollout restart deploy -n insur-iq -l app.kubernetes.io/component in (backend,celery-default,celery-policy-extract,celery-commission-intake,celery-beat,auth)` | Rolling restart, no downtime |
| `backend.SECRET_KEY` | Manual, incident-only | Invalidates Django sessions and signed tokens — schedule maintenance window |
| `auth.BETTER_AUTH_SECRET` | Manual, incident-only | Logs every user out — schedule maintenance window |
| LLM keys | Per provider | Rolling restart of backend + celery |

---

## 7. Helm Values Walkthrough

The chart lives at [`helm/insur-iq/`](../../helm/insur-iq/). Two values files stack on `helm install -f`:

| File | Purpose | Edited by |
|---|---|---|
| `helm/insur-iq/values.yaml` | Chart defaults — production-ready (autoscaling on, ESO enabled, no in-cluster infra) | Chart maintainer — don't edit per env |
| `helm/insur-iq/my-values.yaml` | **Your environment** (account ID, ACM ARN, S3 bucket, image tags) | **You — generated in [§4](#4-provisioning-aws-infra-terraform), edited here** |

[`my-values.yaml.example`](../../helm/insur-iq/my-values.yaml.example) shows the minimal shape. Later files override earlier ones, so the install command is:

```bash
helm install insur-iq ./helm/insur-iq -n insur-iq --values helm/insur-iq/my-values.yaml --rollback-on-failure --timeout 10m
```

### What `my-values.yaml` contains after [§4](#4-provisioning-aws-infra-terraform)

Most of the file was auto-generated by `terraform output -raw helm_values_snippet`:

```yaml
global:
  awsAccountId: "123456789012"        # filled by Terraform
  awsRegion: ap-south-1
  domain: insuriq.acmecorp.com

config:
  AWS_STORAGE_BUCKET_NAME: insur-iq-prod-uploads   # filled by Terraform

ingress:
  certificateArn: arn:aws:acm:ap-south-1:.../...   # filled by Terraform

networkPolicy:
  allowedEgress:
    rdsCidrs:   ["10.20.32.0/20", "10.20.48.0/20", "10.20.64.0/20"]   # filled by Terraform
    redisCidrs: ["10.20.32.0/20", "10.20.48.0/20", "10.20.64.0/20"]

image:
  backend: { repository: 123456789012.dkr.ecr.ap-south-1.amazonaws.com/insur-iq/backend }
  web:     { repository: 123456789012.dkr.ecr.ap-south-1.amazonaws.com/insur-iq/web }
```

### What you must add manually

Append these to `my-values.yaml` after generating it. Terraform doesn't know them:

```yaml
# Image tags — set per release. CI typically does this with --set image.backend.tag=...
image:
  backend:
    tag: "git-abc1234"
  web:
    tag: "git-abc1234"

# Optional: outbound mail sender
config:
  AWS_SENDER_EMAIL: no-reply@acmecorp.com

# Optional: lock down /service-api/admin/* to your office VPN range
ingress:
  adminCidrAllowlist: ["10.0.0.0/8"]
```

### Auto-derived from `global.domain` (don't set unless overriding)

- `ALLOWED_HOSTS`, `CSRF_TRUSTED_ORIGINS`, `HOST_NAME`
- `NUXT_PUBLIC_API_BASE_URL`, `NUXT_PUBLIC_AUTH_BASE_URL`, `NUXT_PUBLIC_APP_BASE_URL`
- Auth `WEBHOOK_EP`, `TRUSTED_ORIGINS`, `BASE_DOMAIN`

### How app pods get AWS credentials (Pod Identity)

The chart creates two Kubernetes ServiceAccounts in the `insur-iq` namespace:

| ServiceAccount | Used by | IAM role bound (via Terraform) | Permissions |
|---|---|---|---|
| `insur-iq-backend` | backend Deployment | `insur-iq-prod-backend` | S3 read/write on uploads bucket |
| `insur-iq-celery` | all 4 celery Deployments (default, beat, policy-extract, commission-intake) | `insur-iq-prod-celery` | S3 read/write on uploads bucket |

The `aws_eks_pod_identity_association` resources in Terraform ([§4](#4-provisioning-aws-infra-terraform)) bind each ServiceAccount to its IAM role. When a pod runs as one of these SAs, the EKS Pod Identity Agent (a DaemonSet on every node) intercepts AWS SDK credential requests and returns short-lived credentials for the bound role.

**You don't need to do anything for this to work** — it's wired in the chart. But if you ever need to verify it after a deploy:

```bash
# Confirm the pod is using the right SA
kubectl -n insur-iq get pod -l app.kubernetes.io/component=backend -o jsonpath='{.items[0].spec.serviceAccountName}'
# → should print: insur-iq-backend

# Confirm the IAM role assumes correctly from inside the pod
kubectl -n insur-iq exec deploy/insur-iq-insur-iq-backend -- python -c "import boto3; print(boto3.client('sts').get_caller_identity())"
# → Arn should contain "assumed-role/insur-iq-prod-backend/..."
#   (NOT the node role — that means Pod Identity isn't working)
```

To grant a pod additional AWS permissions: add the action to the role's policy in [terraform/main.tf](../../infra/terraform/main.tf) (`aws_iam_role_policy.backend_pod_s3` or `aws_iam_role_policy.celery_pod_s3`), `terraform apply`. No chart change needed.

### Critical knobs

| Key | Default | When to change |
|---|---|---|
| `backend.replicas` / `autoscaling.backend.maxReplicas` | 2 / 10 | Bump max if HPA sits at max for >15 min |
| `celery.policyExtract.replicas` | 4 | Bump if `policy_extract` queue lag grows; no autoscaling on celery |
| `ingress.idleTimeoutSeconds` | 300 | Lower to default 60s only if no large uploads |
| `ingress.adminCidrAllowlist` | `[]` | **Set this** before exposing /service-api/admin/* |
| `podDisruptionBudget.*.minAvailable` | 1 | Set to `0` if you want fastest cluster upgrades |
| `topologySpread.enabled` | `true` | Disable only on single-AZ dev clusters |

---

## 8. First Install

```bash
# Load all variables from your deploy.env (must have sourced post-Terraform block).
source ./deploy.env

# Verify infra is healthy (run after `terraform apply`).
./scripts/verify-infra.sh

# Install
helm install insur-iq ./helm/insur-iq \
  --namespace insur-iq \
  --values helm/insur-iq/my-values.yaml \
  --rollback-on-failure --timeout 10m
```

What `helm install --rollback-on-failure` does:

1. Renders templates against your values.
2. Runs `pre-install` hooks: `auth-db-init` Job (idempotent CREATE DATABASE), then `migrate` Job (`python manage.py migrate --noinput`).
3. If any hook fails, **the entire release rolls back** — no Deployments are created.
4. On success, applies all Deployments / Services / Ingress / HPAs / NetworkPolicies / PDBs.
5. Waits up to 10 minutes for all Deployments to report Ready.

Watch progress in another terminal:

```bash
kubectl -n insur-iq get pods -w
kubectl -n insur-iq get jobs
```

The ALB takes 60–90s to provision after the Ingress is admitted. Get its DNS name:

```bash
kubectl -n insur-iq get ingress insur-iq-insur-iq -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Create a Route53 ALIAS A-record pointing `insuriq.acmecorp.com` at that ALB. (If you installed `external-dns`, this happens automatically.)

---

## 9. Verification

### Smoke tests

```bash
curl -fsS https://{insuriq.acmecorp.com}/service-api/api/health/   # → {"status":"ok"}
curl -fsS https://insuriq.acmecorp.com/auth/api/auth/ok          # → {"ok":true}
curl -fsS https://insuriq.acmecorp.com/ -o /dev/null -w '%{http_code}\n'  # → 200
```

### Verification matrix

| Check | Command | Expected |
|---|---|---|
| All Deployments Ready | `kubectl -n insur-iq get deploy` | `READY` column matches `UP-TO-DATE` |
| Backend probe path correct | `kubectl -n insur-iq describe deploy insur-iq-backend \| grep -A1 Liveness` | `httpGet /api/health/` |
| ALB readiness gates work | `kubectl -n insur-iq get pods -o wide` during a rollout | new pods show `1/1` only after ALB target health passes |
| ESO reconciled secrets | `kubectl -n insur-iq get externalsecret` | every row `SyncedToTarget=True` |
| Pod Identity working (backend) | `kubectl -n insur-iq exec deploy/insur-iq-backend -- aws sts get-caller-identity` | `Arn` contains `assumed-role/insur-iq-prod-backend/...`, NOT the node role |
| Pod Identity working (celery) | `kubectl -n insur-iq exec deploy/insur-iq-celery-default -- aws sts get-caller-identity` | `Arn` contains `assumed-role/insur-iq-prod-celery/...` |
| HPA reading metrics | `kubectl -n insur-iq get hpa` | `TARGETS` shows real CPU% (not `<unknown>`) for backend, web, and celery workers |
| Beat is singleton | `kubectl -n insur-iq get pods -l app.kubernetes.io/component=celery-beat` | exactly 1 pod |
| NetworkPolicies applied | `kubectl -n insur-iq get networkpolicy` | 3 policies (default-deny, allow-ingress-app, allow-egress) |
| ALB cert is ACM cert | `aws elbv2 describe-listeners ... --query 'Listeners[?Port==\`443\`].Certificates'` | matches your ACM ARN |

### CloudWatch Container Insights

Open the AWS console → **CloudWatch → Container Insights → Performance monitoring**, scope to cluster `insur-iq-prod`, namespace `insur-iq`. You get per-pod CPU/memory/network/restarts out of the box. Logs land in `/aws/containerinsights/insur-iq-prod/application` and are searchable via Logs Insights.

For a custom dashboard, the bare-minimum widgets to pin are: ALB request count + 5xx rate, RDS CPU + connections + free storage, ElastiCache CPU + evictions, and per-pod memory for `insur-iq` namespace.

---

## 10. Upgrades & Rollback

### Upgrade procedure

```bash
# 1. Build/push new images (CI does this on merge to main).
#    Tag pattern: git-<short-sha> (immutable).

# 2. Take a pre-upgrade RDS snapshot.
aws rds create-db-snapshot \
  --db-instance-identifier insur-iq-prod \
  --db-snapshot-identifier insur-iq-pre-$(date +%Y%m%d-%H%M%S)

# 3. Bump image tags in helm/insur-iq/my-values.yaml and apply.
helm upgrade insur-iq ./helm/insur-iq \
  --namespace insur-iq \
  --values helm/insur-iq/my-values.yaml \
  --atomic --timeout 10m

# 4. Verify rollout.
kubectl -n insur-iq rollout status deploy/insur-iq-backend
kubectl -n insur-iq rollout status deploy/insur-iq-web
kubectl -n insur-iq rollout status deploy/insur-iq-auth
curl -fsS https://insuriq.acmecorp.com/service-api/api/health/
```

`--atomic` rolls back the entire release (including hook Jobs) if any step fails or any Deployment fails to become Ready within `--timeout`.

### Rollback runbook (5 commands)

```bash
helm history insur-iq -n insur-iq                                  # list revisions
helm rollback insur-iq <REV> -n insur-iq --wait --timeout 10m      # revert
kubectl -n insur-iq rollout status deploy/insur-iq-backend
kubectl -n insur-iq logs -l app.kubernetes.io/component=backend --tail=50
# DB-level rollback only if migration corrupted data:
aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier insur-iq-prod --target-db-instance-identifier insur-iq-prod-restore --restore-time '2026-05-01T12:00:00Z'
```

### Migrations

- Forward migrations are run by the `migrate` Helm pre-install/pre-upgrade Job.
- A failed migration aborts the release before any pod is rolled — old pods keep serving.
- `helm rollback` does **not** reverse migrations. If a migration is destructive, fix forward with a hotfix migration, never roll back the schema.

---

## 11. Teardown & Decommission

### Partial teardown (app only — keep cluster + infra)

```bash
helm uninstall insur-iq -n insur-iq
kubectl delete namespace insur-iq
```

ALB is reaped automatically by the AWS Load Balancer Controller. Everything else (RDS, Redis, S3, ECR, SM) persists. A re-install via `helm install` restores the app in <10 minutes with no data loss.

### Full teardown (everything)

```bash
# 1. Final backups (do this before destroying state).
aws rds create-db-snapshot \
  --db-instance-identifier insur-iq-prod \
  --db-snapshot-identifier insur-iq-final-$(date +%Y%m%d)
aws s3 sync s3://acmecorp-insur-iq-uploads s3://acmecorp-insur-iq-archive

# 2. Drain the app.
kubectl scale deploy --all -n insur-iq --replicas=0
helm uninstall insur-iq -n insur-iq
kubectl delete namespace insur-iq

# 3. Remove cluster controllers.
helm uninstall external-secrets -n external-secrets
helm uninstall aws-load-balancer-controller -n kube-system

# 4. Destroy AWS infra (Terraform).
cd infra/terraform
terraform destroy -var "domain=$DOMAIN"

# 5. Manual cleanup (Terraform doesn't catch these).
aws logs delete-log-group --log-group-name /aws/eks/insur-iq-prod/insur-iq
# Secrets Manager soft-deletes for 7-30 days; force-delete only if intentional:
for s in backend db redis auth llm; do
  aws secretsmanager delete-secret --secret-id insur-iq/prod/$s --force-delete-without-recovery
done

# 6. Verify nothing left billing.
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=insur-iq
```

If `terraform destroy` fails on the S3 bucket because objects remain, empty it first:

```bash
aws s3 rm s3://acmecorp-insur-iq-uploads --recursive
```

---

## 12. Day-2 Runbooks

### Pod CrashLoopBackOff

```bash
kubectl -n insur-iq describe pod <pod>
kubectl -n insur-iq logs <pod> --previous
```

Most common causes:
- **Missing env var** → check `kubectl get externalsecret` for sync errors. If `SyncedToTarget=False`, ESO can't reach Secrets Manager (Pod Identity association missing or IAM policy too narrow).
- **OOMKilled** → `kubectl describe pod` shows `Reason: OOMKilled`. Bump memory limit in values; redeploy.
- **Image pull error** → confirm node IAM has `AmazonEC2ContainerRegistryReadOnly` and the image tag exists in ECR.

### Migration Job failed

```bash
kubectl -n insur-iq logs job/insur-iq-migrate
kubectl -n insur-iq get job insur-iq-migrate -o yaml
```

Common causes:
- **Schema lock from aborted prior migration** — `SELECT * FROM pg_locks WHERE NOT granted;` on RDS. If stuck, `SELECT pg_cancel_backend(pid)`.
- **Migration references a column manually altered** — fix forward with a new migration; re-run `helm upgrade`. **Never** `kubectl delete` mid-flight without `helm rollback` first.

### Celery queue backlog

```bash
# Check queue depth on Redis
redis-cli -h $REDIS_HOST LLEN celery
redis-cli -h $REDIS_HOST LLEN policy_extract

# Check current celery replica counts
kubectl -n insur-iq get deploy -l 'app.kubernetes.io/component in (celery-default,celery-policy-extract,celery-commission-intake)'
```

Celery workers run at fixed `replicas` — there is no autoscaling. To clear a backlog, bump the count in your values file and `helm upgrade`:

```yaml
celery:
  policyExtract: { replicas: 8 }   # was 4
```

```bash
helm upgrade insur-iq ./helm/insur-iq -n insur-iq \
  -f helm/insur-iq/my-values.yaml
```

For an emergency one-off bump (gets reverted by the next `helm upgrade`):

```bash
kubectl -n insur-iq scale deploy/insur-iq-celery-policy-extract --replicas=8
```

If the backlog persists at high replica counts, investigate downstream LLM rate limits in Langfuse rather than scaling further.

### RDS connection exhaustion

CloudWatch metric `DatabaseConnections` near `max_connections` (300):

1. **Verify RDS Proxy is in path** — `DB_HOST` in the SM `db` secret must be the Proxy endpoint (`*.proxy-*.rds.amazonaws.com`), not the instance endpoint.
2. **Check Proxy metrics** — CloudWatch namespace `AWS/RDS` for the proxy: `ClientConnections`, `DatabaseConnections`, `MaxDatabaseConnectionsAllowed`. Database connections should be much lower than client connections (multiplexing working).
3. If pinning is high (`PinnedDatabaseConnections`), check for unsupported SQL features causing connection pinning.

### Pod Identity not working (S3 access denied)

```bash
kubectl -n insur-iq exec deploy/insur-iq-backend -- aws sts get-caller-identity
```

If this returns the **node** role and not the SA role, the Pod Identity association is missing or the agent isn't running:

```bash
aws eks list-pod-identity-associations --cluster-name insur-iq-prod --namespace insur-iq
kubectl -n kube-system get daemonset eks-pod-identity-agent
```

Reapply the association via Terraform or `aws eks create-pod-identity-association`, then `kubectl rollout restart deploy/insur-iq-backend`.

### LBC webhook x509 certificate errors

Symptom: any `helm install` or `kubectl apply` of a Service or Ingress fails with:

```
failed calling webhook "mservice.elbv2.k8s.aws": ...
x509: certificate signed by unknown authority
```

Cause: The LBC webhook uses a self-signed cert that's stored in two `WebhookConfiguration` objects. If LBC was reinstalled at any point (e.g. after a partial failure) without those configs being cleaned up, the API server has the *old* CA bundle but the webhook pod serves the *new* cert. They don't match → x509 failure.

Fix:

```bash
# Delete the stale webhook configs — LBC will recreate them with the correct CA
kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook
kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook

# Wait ~10s for LBC to recreate them
sleep 10
kubectl get mutatingwebhookconfiguration aws-load-balancer-webhook
```

Then retry whatever was failing. This is safe — deleting the webhook configs only disables the admission check briefly; existing Services/Ingresses are unaffected.

### ALB 504 timeouts on uploads

Default ALB idle timeout is 60s; long PDF uploads exceed it. Set `ingress.idleTimeoutSeconds: 300` in values, `helm upgrade`. Confirm gunicorn `--timeout 300` (it is, by default).

### Beat scheduler missing

Beat is a singleton. If it's evicted and not rescheduled, scheduled tasks stop silently. Detect via the CloudWatch alarm in [Appendix C](#appendix-c--cloudwatch-alarms). Recover:

```bash
kubectl -n insur-iq rollout restart deploy/insur-iq-celery-beat
kubectl -n insur-iq logs -l app.kubernetes.io/component=celery-beat --tail=50
```

### ECR pull failure

Symptom: pods stuck in `ImagePullBackOff`. Causes:
- Node IAM role missing `AmazonEC2ContainerRegistryReadOnly`.
- Public image rate-limited (Docker Hub) — fix with the pull-through cache (already in Terraform).

```bash
kubectl describe pod <pod> | grep -A5 'Failed.*pull'
```

### Autoscaling not working (Pending pods, no new node)

Cluster Autoscaler should provision a new node within 2-3 min of a Pending pod. If pods stay `Pending` longer than that:

```bash
# 1. Confirm the symptom
kubectl get pods -A --field-selector=status.phase=Pending
kubectl describe pod <pending-pod> | grep -A10 Events

# 2. Check CA is running and not crash-looping
kubectl -n kube-system logs deploy/cluster-autoscaler --tail=100

# 3. Look for these specific log lines (in order of likelihood):
#    "Pod ... is unschedulable"      → CA saw it
#    "Scale-up: setting group ..."   → CA acted
#    "Failed to fix node group ..."  → IAM problem
#    "no expandable node groups"     → ASG already at max_size, OR tags missing
```

Common causes, in order of likelihood:

| Symptom in CA logs | Cause | Fix |
|---|---|---|
| `Failed to fix node group sizes... AccessDenied` | Pod Identity association missing or IAM policy too narrow | Re-apply Terraform; verify `aws eks list-pod-identity-associations --namespace kube-system --cluster-name insur-iq-prod` shows `cluster-autoscaler` |
| `no expandable node groups` | ASG at `max_size` already, or tags missing | Bump `max_size` in [terraform/main.tf](../../infra/terraform/main.tf) and re-apply, OR check ASG has the `k8s.io/cluster-autoscaler/enabled=true` and `k8s.io/cluster-autoscaler/insur-iq-prod=owned` tags |
| `pod didn't trigger scale-up: 1 node(s) had untolerated taint` | Pod can't schedule on the existing node group's instance type for unrelated reasons (taints, node selectors, GPU request, etc.) | Match pod requirements to node group, or add a new node group |
| CA logs are silent | CA isn't picking up the pod — usually because the pod has no `requests.cpu`/`requests.memory` (CA only acts on resource requests, not actual usage) | Add `resources.requests` to the pod spec |

### HPA stuck / scaling weirdness

```bash
kubectl -n insur-iq get hpa
kubectl -n insur-iq describe hpa backend
```

| Symptom | Cause | Fix |
|---|---|---|
| `TARGETS` column shows `<unknown>/70%` | metrics-server isn't reachable | `kubectl top nodes` should work; if it errors, reinstall metrics-server (see [§5](#5-cluster-bootstrap)) |
| HPA at `maxReplicas` for >15 min | Sustained load above what current ceiling allows | Bump `autoscaling.maxReplicas` in values, `helm upgrade`. Confirm CA can also scale nodes (no point at maxReplicas if no node has room) |
| HPA flaps (rapid up/down) | `targetCPUUtilization` too close to steady-state, or scale-down stabilization too short | Raise target to 80%, or increase `behavior.scaleDown.stabilizationWindowSeconds` |

### Manual override (emergency)

If autoscaling is broken and you need capacity *now*:

```bash
# Force a node group up immediately. CA will leave manual changes alone
# unless desired drops below min/rises above max.
aws eks update-nodegroup-config \
  --cluster-name insur-iq-prod \
  --nodegroup-name $(aws eks list-nodegroups --cluster-name insur-iq-prod \
                      --query 'nodegroups[?contains(@,`app`)] | [0]' --output text) \
  --scaling-config minSize=1,maxSize=3,desiredSize=3 \
  --region ap-south-1
```

Investigate the autoscaling failure afterwards — manual scaling is a temporary workaround, not a fix.

---

## 13. Cost Reference

Minimal-prod (ap-south-1, on-demand, monthly). Defaults match the Terraform skeleton — 1 node per group, burstable instance types:

| Line item | Cost |
|---|---|
| EKS control plane | $73 |
| System node group (1× t3.medium) | $30 |
| App node group (1× t3.large) | $60 |
| RDS db.t4g.medium single-AZ + 100 GB gp3 + backups | $85 |
| RDS Proxy | $50 |
| ElastiCache cache.t4g.small | $25 |
| ALB | $25 |
| CloudWatch (Container Insights + logs + alarms) | $25 |
| ECR + S3 + Route53 | $20 |
| Data transfer | $20 |
| **Total** | **~$413 / month** |

Levers:
- **Savings Plans (1y, no upfront): 15–30% off** EC2 + RDS.
- **Multi-AZ RDS:** +$60/mo. Enable for production HA — automatic ~60s failover instead of manual snapshot restore.
- **Bigger node groups for real load:** the defaults are sized for smoke tests / low-traffic prod. For sustained load, bump `app` to `m6i.xlarge` × 2-3 (+$200–300/mo) and `system` to `t3.large` if you self-host Prometheus later (+$30/mo). Both `min/max` already let HPA + node-group autoscaling grow up to 2 (system) / 3 (app) nodes without a Terraform change.
- **Smaller RDS (db.t4g.small):** −$60/mo. Watch DB connections and CPU.

---

## Appendix A — Environment Variable Reference

### Backend / Celery / Beat

| Env var | Source | Required | Default |
|---|---|---|---|
| `SECRET_KEY` | SM `backend` | yes | — |
| `WEBHOOK_SECRET_KEY` | SM `backend` | yes | — |
| `BETTER_AUTH_URL` | derived | yes | `http://<release>-auth:10000` |
| `DB_HOST` | SM `db` | yes | RDS Proxy endpoint |
| `DB_PORT` | SM `db` | no | `5432` |
| `DB_USER` | SM `db` | yes | — |
| `DB_PASSWORD` | SM `db` | yes | — |
| `DB_NAME` | SM `db` | yes | `insure_iq` |
| `CELERY_BROKER_URL` | SM `redis` | yes | — |
| `CELERY_RESULT_BACKEND` | configmap | no | `django-db` |
| `CELERY_CACHE_BACKEND` | configmap | no | `django-cache` |
| `AWS_REGION` | configmap | no | from `global.awsRegion` |
| `AWS_STORAGE_BUCKET_NAME` | configmap | yes | — |
| `AWS_S3_ENDPOINT_URL` | configmap | no | (blank for real S3) |
| `AWS_S3_PUBLIC_ENDPOINT_URL` | configmap | no | (blank for real S3; set when fronting MinIO) |
| `AWS_SENDER_EMAIL` | configmap | no | (blank disables outbound mail) |
| `ALLOWED_HOSTS` | derived | no | `<domain>` |
| `CSRF_TRUSTED_ORIGINS` | derived | no | `https://<domain>` |
| `HOST_NAME` | derived | no | `https://<domain>` |
| `LLM_PROVIDER` | SM `llm` | yes | `gemini` |
| `GEMINI_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` | SM `llm` | one required | — |
| `GEMINI_MODEL` / `OPENAI_MODEL` / `ANTHROPIC_MODEL` | SM `llm` | no | sane defaults |
| `GOOGLE_API_KEY` | SM `llm` | no | — |
| `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` | SM `llm` | no | — |
| `LANGFUSE_HOST` | configmap | no | `https://cloud.langfuse.com` |
| `MINERVA_API_URL` | configmap | no | — |
| `EXCEL_AI_CLASSIFICATION_ENABLED` | configmap | no | `true` |
| `POLICY_EXTRACT_CALLBACK_URL` | derived | no | `https://<domain>/service-api/policy-extract/callback/` |

### Web

| Env var | Source | Required | Default |
|---|---|---|---|
| `NUXT_PUBLIC_API_BASE_URL` | derived | yes | `<domain>/service-api` |
| `NUXT_PUBLIC_AUTH_BASE_URL` | derived | yes | `https://<domain>/auth` |
| `NUXT_PUBLIC_APP_BASE_URL` | derived | yes | `https://<domain>` |
| `NUXT_PUBLIC_API_SCHEME` | values | no | `https` |
| `NUXT_APP_BASE_URL` | values | no | `/` (Nuxt subpath) |
| `NUXT_PUBLIC_ENABLED_SOCIAL_PROVIDERS` | values | no | `""` |

### Auth (Better Auth)

| Env var | Source | Required | Default |
|---|---|---|---|
| `BETTER_AUTH_SECRET` | SM `auth` | yes | — |
| `PORT` | values | yes | `10000` |
| `DATABASE_STRING` | SM `db` (key `DATABASE_STRING_AUTH`) | yes | postgres URI to `auth` DB |
| `WEBHOOK_EP` | derived | yes | backend webhook URL |
| `WEBHOOK_SECRET_KEY` | SM `backend` | yes | shared with backend |
| `TRUSTED_ORIGINS` | derived | yes | `https://<domain>` |
| `BASE_DOMAIN` | derived | yes | `<domain>` (drives Better Auth cookie domain) |
| `REQUIRE_EMAIL_VERIFICATION` | values | no | `false` |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | SM `auth` | no | — |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | SM `auth` | no | — |
| `MICROSOFT_CLIENT_ID` / `MICROSOFT_CLIENT_SECRET` | SM `auth` | no | — |

---

## Appendix B — IAM Policy JSONs

### Backend & Celery Pod Identity role

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3Uploads",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::acmecorp-insur-iq-uploads",
        "arn:aws:s3:::acmecorp-insur-iq-uploads/*"
      ]
    }
  ]
}
```

Trust policy (same for both roles):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }
  ]
}
```

### External Secrets Operator role

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
      "Resource": "arn:aws:secretsmanager:ap-south-1:123456789012:secret:insur-iq/*"
    }
  ]
}
```

### RDS Proxy role

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "<RDS master user secret ARN>"
    },
    {
      "Effect": "Allow",
      "Action": ["kms:Decrypt"],
      "Resource": "*",
      "Condition": { "StringEquals": { "kms:ViaService": "secretsmanager.ap-south-1.amazonaws.com" } }
    }
  ]
}
```

---

## Appendix C — CloudWatch Alarms

The minimal alarm set for prod. Each alarm fires to an SNS topic (`insur-iq-prod-alerts`) which fans out to email/Slack. Container-level metrics (pod restarts, beat heartbeat) come from CloudWatch Container Insights — installed automatically via the `amazon-cloudwatch-observability` EKS addon.

**Set up the SNS topic first** (one-time):

```bash
aws sns create-topic --name insur-iq-prod-alerts --region "$AWS_REGION"
aws sns subscribe --topic-arn "arn:aws:sns:${AWS_REGION}:${AWS_ACCOUNT_ID}:insur-iq-prod-alerts" \
  --protocol email --notification-endpoint oncall@acmecorp.com
# (confirm via the email link)
```

Then create the alarms:

```bash
TOPIC="arn:aws:sns:${AWS_REGION}:${AWS_ACCOUNT_ID}:insur-iq-prod-alerts"
ALB=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[?contains(LoadBalancerName,`insur-iq`)].LoadBalancerArn' --output text | awk -F'loadbalancer/' '{print $2}')

# 1. ALB 5xx rate > 1% over 5 min
aws cloudwatch put-metric-alarm \
  --alarm-name insur-iq-alb-5xx-high \
  --metric-name HTTPCode_Target_5XX_Count --namespace AWS/ApplicationELB \
  --statistic Sum --period 300 --evaluation-periods 1 \
  --threshold 50 --comparison-operator GreaterThanThreshold \
  --dimensions Name=LoadBalancer,Value=$ALB \
  --alarm-actions $TOPIC

# 2. RDS CPU > 80% for 10 min
aws cloudwatch put-metric-alarm \
  --alarm-name insur-iq-rds-cpu-high \
  --metric-name CPUUtilization --namespace AWS/RDS \
  --statistic Average --period 300 --evaluation-periods 2 \
  --threshold 80 --comparison-operator GreaterThanThreshold \
  --dimensions Name=DBInstanceIdentifier,Value=insur-iq-prod \
  --alarm-actions $TOPIC

# 3. RDS free storage < 20 GiB
aws cloudwatch put-metric-alarm \
  --alarm-name insur-iq-rds-storage-low \
  --metric-name FreeStorageSpace --namespace AWS/RDS \
  --statistic Average --period 300 --evaluation-periods 2 \
  --threshold 21474836480 --comparison-operator LessThanThreshold \
  --dimensions Name=DBInstanceIdentifier,Value=insur-iq-prod \
  --alarm-actions $TOPIC

# 4. ElastiCache evictions (any) over 5 min
aws cloudwatch put-metric-alarm \
  --alarm-name insur-iq-redis-evictions \
  --metric-name Evictions --namespace AWS/ElastiCache \
  --statistic Sum --period 300 --evaluation-periods 1 \
  --threshold 0 --comparison-operator GreaterThanThreshold \
  --dimensions Name=CacheClusterId,Value=insur-iq-prod \
  --alarm-actions $TOPIC

# 5. Pod restart rate > 5 in 5 min, anywhere in the namespace
#    (Container Insights metric — verify it appears under ContainerInsights namespace after the addon is healthy)
aws cloudwatch put-metric-alarm \
  --alarm-name insur-iq-pod-restarts-high \
  --metric-name pod_number_of_container_restarts \
  --namespace ContainerInsights \
  --statistic Sum --period 300 --evaluation-periods 1 \
  --threshold 5 --comparison-operator GreaterThanThreshold \
  --dimensions Name=ClusterName,Value=insur-iq-prod Name=Namespace,Value=insur-iq \
  --alarm-actions $TOPIC

# 6. Celery beat singleton missing (running pods == 0)
aws cloudwatch put-metric-alarm \
  --alarm-name insur-iq-beat-down \
  --metric-name pod_number_of_running_containers \
  --namespace ContainerInsights \
  --statistic Average --period 300 --evaluation-periods 2 \
  --threshold 1 --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --dimensions Name=ClusterName,Value=insur-iq-prod Name=Namespace,Value=insur-iq Name=PodName,Value=insur-iq-celery-beat \
  --alarm-actions $TOPIC
```

| # | Alarm | Triggers when | Why |
|---|---|---|---|
| 1 | `insur-iq-alb-5xx-high` | >50 5xx in 5 min (~1% at 1k req/min) | Backend or auth crashing in flight |
| 2 | `insur-iq-rds-cpu-high` | RDS CPU >80% for 10 min | Slow queries, missing index, traffic spike |
| 3 | `insur-iq-rds-storage-low` | Free storage <20 GiB | Disk-full will silently break writes |
| 4 | `insur-iq-redis-evictions` | Any eviction in 5 min | Celery results / cache pressure — bump `cache.t4g.small` to `medium` |
| 5 | `insur-iq-pod-restarts-high` | >5 container restarts in 5 min in namespace | OOMKill or CrashLoop somewhere |
| 6 | `insur-iq-beat-down` | Celery beat pod count <1 for 10 min | Scheduled tasks have silently stopped |

**Migration backstop:** the chart's `migrate` Job sets release status to `failed` on Helm — so a failed migration aborts the deploy and old pods keep serving. No alarm needed; CI surfaces the failure. If you want belt-and-suspenders, alarm on `kube_job_failed` once you migrate to AMP.

**LLM rate-limit / cost** (queue backlog, Langfuse error rate): these don't have CloudWatch metrics today. If they matter, emit them from Django via `boto3.client('cloudwatch').put_metric_data(...)` and add alarms — that's typically the first reason teams adopt Prometheus instead.

---

## Appendix D — Decision Log

| Decision | Choice | Rationale |
|---|---|---|
| Ingress | AWS LBC + ALB (single) | ACM-native, WAF/Shield ready, no client body limit, idle timeout up to 4000s |
| TLS | ACM regional cert | Free, auto-renewed, attached to ALB |
| Host topology | Single host, path-based | Preserves Better-Auth same-origin cookies; matches app contract |
| Backend probe path | `/api/health/` | Container-native; `/service-api` prefix only exists at ALB |
| Static files | `collectstatic` baked into image (WhiteNoise) | No S3 writes at build; simplest |
| Migrations | Helm pre-install/pre-upgrade Job | Runs once per release; failure aborts rollout |
| Auth DB | Separate `auth` DB on same RDS instance | Cheaper than two instances; isolation via DB grants |
| DB pooling | RDS Proxy in front of single instance | Multiplexes Django + celery; smooths failover |
| Celery autoscaling | None — fixed `replicas` per queue | Simplest possible; LLM-bound workers make CPU HPA ineffective. Resize via `helm upgrade` when a queue is consistently backlogged |
| Backend autoscaling | HPA on CPU @70% | CPU-bound for synchronous request handling |
| Beat | Deployment replicas=1, Recreate | Singleton enforced by strategy + alert |
| Identity | EKS Pod Identity (not IRSA) | Simpler than OIDC trust dance; AWS recommended for new clusters |
| Secrets | AWS Secrets Manager + ESO | Centralized rotation + audit; no plaintext in Git |
| Cluster auth | EKS access entries | Replaces aws-auth ConfigMap |
| CNI | VPC CNI prefix delegation | Avoids pod IP exhaustion on dense nodes |
| Nodes | Fixed-size managed node groups (system + app) | Simpler ops; predictable cost; resize manually when capacity-bound |
| GitOps | Argo CD pull-based | No long-lived kubeconfig in CI; rollback via git revert |
| Image registry | ECR + pull-through cache | No Docker Hub rate limits; immutable tags |
| Logs | AWS for Fluent Bit → CloudWatch | Single add-on, 30d retention prod |
| Metrics | CloudWatch Container Insights (EKS addon) | Zero pods on cluster, AWS-native; AMP/AMG or self-hosted Prometheus is future work when custom app metrics are needed |
| Backups | RDS automated 7d + manual pre-upgrade | Plus Helm history for app rollback |
| Security baseline | PSA `restricted`, NetworkPolicy default-deny | Defense in depth with minimum operational drag |
