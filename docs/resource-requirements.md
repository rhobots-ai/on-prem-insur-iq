# insur-iq — AWS Infrastructure Requirements

## EKS Cluster (Kubernetes)

| Node Group | Instance Type | vCPU | RAM | Min | Max | Desired |
| --- | --- | --- | --- | --- | --- | --- |
| system | t3.medium | 2 | 4 GB | 1 | 2 | 1 |
| app | t3.xlarge | 4 | 16 GB | 1 | 3 | 1 |
| gpu | g5.2xlarge | 8 | 32 GB | 1 | 2 | 1 |

- **system** nodes run Kubernetes infrastructure: CoreDNS, VPC CNI, kube-proxy, ALB Controller, Cluster Autoscaler, External Secrets Operator, CloudWatch Agent
- **app** nodes run application workloads: backend, web, auth, celery workers
- **gpu** nodes run GPU-accelerated workloads (1x NVIDIA A10G GPU); Cluster Autoscaler scales up to 2 nodes under load
- Starts at 2 nodes; Cluster Autoscaler scales app nodes up to 3 automatically under load

### Application Pod Scaling

| Workload | Min Replicas | Max Replicas | Scale Trigger |
| --- | --- | --- | --- |
| backend (Django) | 1 | 4 | CPU > 70% |
| web (Nuxt SSR) | 1 | 2 | CPU > 70% |
| auth | 1 | 2 | CPU > 70% |
| celery-default | 1 | 1 | Fixed |
| celery-policyExtract | 1 | 1 | Fixed |
| celery-commissionIntake | 1 | 1 | Fixed |
| celery-beat | 1 | 1 | Singleton — never scale |

---

## RDS — PostgreSQL 17

| Parameter | Value |
| --- | --- |
| Instance | db.t4g.medium |
| vCPU / RAM | 2 vCPU / 4 GB |
| Storage | 100 GB (gp3, encrypted) |
| Multi-AZ | No (single-AZ to start) |
| Connection pooling | RDS Proxy (included) |
| Logical databases | `insure_iq` (Django) + `auth` (Better Auth) |
| Backups | 7-day retention |

---

## ElastiCache — Redis 7

| Parameter | Value |
| --- | --- |
| Node type | cache.t4g.small |
| vCPU / RAM | 2 vCPU / 1.37 GB |
| Nodes | 1 |
| Purpose | Celery task broker |

---

## S3

| Parameter | Value |
| --- | --- |
| Buckets | 1 (uploads) |
| Encryption | AES-256 SSE |
| Storage cost | Pay-per-use |
| Access | Via VPC Gateway Endpoint (no internet egress) |

---

## Supporting AWS Services

| Service | Purpose |
| --- | --- |
| Application Load Balancer (1x) | Single entry point, path-based routing to all services |
| ACM Certificate (1x) | TLS termination for the domain |
| NAT Gateway (1x) | Outbound internet for private subnets |
| Secrets Manager (5 secrets) | App credentials and API keys |
| ECR (2 repositories) | Container image registry (backend + web) |
| CloudWatch | Centralized logs and metrics |

---

## Upgrade Path

| When | Change | Why |
| --- | --- | --- |
| Production go-live | Enable RDS Multi-AZ | Database HA — standby replica in second AZ |
| Multi-AZ resilience needed | Switch to 3 NAT Gateways | Per-AZ outbound redundancy |
| Higher document throughput | Increase `celery-policyExtract` replicas to 2 | Parallel AI processing |
| Data growth | Increase RDS storage or upgrade to `db.t4g.large` | More RAM = better query performance |
