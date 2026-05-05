output "vpc_id"             { value = module.vpc.vpc_id }
output "private_subnet_ids" { value = module.vpc.private_subnets }
output "private_subnet_cidrs" { value = module.vpc.private_subnets_cidr_blocks }

output "eks_cluster_name"     { value = module.eks.cluster_name }
output "eks_cluster_endpoint" { value = module.eks.cluster_endpoint }
output "eks_oidc_provider_arn" { value = module.eks.oidc_provider_arn }

output "rds_endpoint"            { value = module.rds.db_instance_endpoint }
output "rds_proxy_endpoint"      { value = aws_db_proxy.this.endpoint }
output "rds_master_secret_arn"   { value = module.rds.db_instance_master_user_secret_arn }

output "redis_endpoint" {
  value = "${aws_elasticache_cluster.redis.cache_nodes[0].address}:${aws_elasticache_cluster.redis.cache_nodes[0].port}"
}

output "s3_bucket_name" { value = aws_s3_bucket.uploads.id }
output "s3_bucket_arn"  { value = aws_s3_bucket.uploads.arn }

output "acm_certificate_arn" { value = local.acm_certificate_arn }

output "pod_identity_backend_role_arn" { value = aws_iam_role.backend_pod.arn }
output "pod_identity_celery_role_arn"  { value = aws_iam_role.celery_pod.arn }

# Cluster controller role ARNs (created by Terraform, consumed by helm installs in §5).
output "cluster_autoscaler_role_arn"           { value = aws_iam_role.cluster_autoscaler.arn }
output "aws_load_balancer_controller_role_arn" { value = aws_iam_role.aws_load_balancer_controller.arn }
output "external_secrets_role_arn"             { value = aws_iam_role.external_secrets.arn }

output "secrets_arns" {
  value = {
    backend = aws_secretsmanager_secret.backend.arn
    db      = aws_secretsmanager_secret.db.arn
    redis   = aws_secretsmanager_secret.redis.arn
    auth    = aws_secretsmanager_secret.auth.arn
    llm     = aws_secretsmanager_secret.llm.arn
  }
}

# Helm-ready snippet — paste into values.<env>.yaml after `terraform apply`.
# Run: terraform output -raw helm_values_snippet > my-values.yaml
output "helm_values_snippet" {
  value = <<-EOT
    global:
      awsAccountId: "${data.aws_caller_identity.current.account_id}"
      awsRegion: ${var.region}
      domain: ${var.domain}

    config:
      AWS_STORAGE_BUCKET_NAME: ${aws_s3_bucket.uploads.id}
      DEBUG: "${var.debug}"

    ingress:
      certificateArn: ${local.acm_certificate_arn}

    networkPolicy:
      allowedEgress:
        rdsCidrs:   ${jsonencode(module.vpc.private_subnets_cidr_blocks)}
        redisCidrs: ${jsonencode(module.vpc.private_subnets_cidr_blocks)}

    # ECR image repos are managed outside Terraform. Repository URLs are
    # derived from the account ID and region above. `tag` defaults to `dev`;
    # CI overrides it per release (e.g. --set image.backend.tag=git-<sha>).
    image:
      backend:
        repository: ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/insur-iq/backend
        tag: dev
      web:
        repository: ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/insur-iq/web
        tag: dev

    # Pod Identity role ARNs for app workloads. The chart's ServiceAccounts
    # don't need any annotations for Pod Identity (unlike IRSA); the binding
    # is configured by Terraform via aws_eks_pod_identity_association.
    # These are exposed for visibility / reference only.
    serviceAccount:
      backend:
        roleArn: ${aws_iam_role.backend_pod.arn}
      celery:
        roleArn: ${aws_iam_role.celery_pod.arn}

    # Opt out of CloudWatch OTel Java auto-instrumentation injected by the
    # amazon-cloudwatch-observability EKS addon. The stack is Python/Node;
    # the Java init container violates the namespace's restricted PodSecurity.
    backend:
      podAnnotations:
        instrumentation.opentelemetry.io/inject-java: "false"
    web:
      podAnnotations:
        instrumentation.opentelemetry.io/inject-java: "false"
    auth:
      podAnnotations:
        instrumentation.opentelemetry.io/inject-java: "false"
    celery:
      podAnnotations:
        instrumentation.opentelemetry.io/inject-java: "false"
  EOT
}

# Helm install commands for cluster controllers — paste/run after `terraform apply`.
# Run: terraform output -raw cluster_controllers_install
output "cluster_controllers_install" {
  value = <<-EOT
    # Idempotent: each step uses `helm upgrade --install` so re-running the
    # script after a partial failure (or just to verify) is safe — no errors
    # on already-installed releases.

    # AWS Load Balancer Controller — install FIRST and WAIT for it to be Ready.
    # LBC installs a mutating webhook that intercepts every Service create
    # cluster-wide; if the webhook pods aren't Ready yet, subsequent helm
    # installs fail with "no endpoints available for service
    # aws-load-balancer-webhook-service".
    helm repo add eks https://aws.github.io/eks-charts && helm repo update

    # Skip LBC upgrade if already deployed. The chart's built-in cert generator
    # rotates the webhook TLS keypair on every `helm upgrade`; the running pods
    # don't reload the new cert from the secret, so they keep serving the old
    # one while the MutatingWebhookConfiguration's caBundle points at the new
    # CA — breaking every subsequent webhook call with x509 "unknown authority".
    # If you genuinely need to upgrade LBC, do it deliberately outside this
    # script and follow up with `kubectl rollout restart`.
    if helm status aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
      echo "AWS Load Balancer Controller already installed, skipping upgrade."
    else
      helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName=${module.eks.cluster_name} \
        --set region=${var.region} \
        --set vpcId=${module.vpc.vpc_id} \
        --set serviceAccount.create=true \
        --set serviceAccount.name=aws-load-balancer-controller
    fi

    echo "Waiting for AWS Load Balancer Controller deployment to be Available..."
    kubectl -n kube-system wait --for=condition=Available \
      deploy/aws-load-balancer-controller --timeout=180s

    # Deployment Available is necessary but not sufficient — the webhook Service
    # endpoints lag the pod's Ready status by a few seconds. Without this poll,
    # subsequent helm installs race ahead and fail with
    # "no endpoints available for service aws-load-balancer-webhook-service".
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

    # metrics-server (required for HPA)
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ && helm repo update
    helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system

    # Cluster Autoscaler
    helm repo add autoscaler https://kubernetes.github.io/autoscaler && helm repo update
    helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler -n kube-system \
      --set autoDiscovery.clusterName=${module.eks.cluster_name} \
      --set awsRegion=${var.region} \
      --set rbac.serviceAccount.create=true \
      --set rbac.serviceAccount.name=cluster-autoscaler \
      --set extraArgs.balance-similar-node-groups=true \
      --set extraArgs.scale-down-unneeded-time=10m
  EOT
}
