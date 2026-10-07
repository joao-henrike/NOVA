# CloudStart — Current MVP State Audit

> This document is an implementation inventory. It exists to answer one question precisely: **what is actually present in the repository right now?**

## 1. Source hierarchy

For current-state questions, use this order:

```text
1. Terraform resources and expressions
2. Application source and Dockerfiles
3. GitHub workflow definitions
4. Repository configuration files
5. Current documentation
6. Future planning documents are NOT current-state evidence
```

A Terraform resource proves that the repository declares that resource. It does not, by itself, prove that the corresponding resource currently exists in an AWS account.

## 2. Status legend

| Status | Meaning |
| --- | --- |
| ✅ Implemented | Present in the repository implementation |
| 🟡 Implemented with limitation | Present, but deliberately constrained or incomplete |
| ❌ Not implemented | No current implementation |
| N/A | Not a current MVP concern |

## 3. Current implementation matrix

### 3.1 Network

| Item | Status | Evidence |
| --- | --- | --- |
| Custom VPC | ✅ | `vpc.tf` |
| Dynamic AZ discovery | ✅ | `vpc.tf` |
| 2 AZ default | ✅ | `variables.tf` |
| Up to 3 AZs | ✅ | `variables.tf` |
| Public subnets | ✅ | `vpc.tf` |
| Private application subnets | ✅ | `vpc.tf` |
| Private database subnets | ✅ | `vpc.tf` |
| Internet Gateway | ✅ | `vpc.tf` |
| NAT per selected AZ | ✅ | `vpc.tf` |
| EIP per NAT | ✅ | `vpc.tf` |
| Private app default route to NAT | ✅ | `vpc.tf` |
| Private DB default internet route | ❌ | intentionally absent |
| VPC endpoints | ❌ | no resource |
| Transit Gateway | ❌ | no resource |
| Direct Connect | ❌ | no resource |
| VPN gateway | ❌ | no resource |

### 3.2 Security groups

| Item | Status |
| --- | --- |
| ALB SG | ✅ |
| Frontend SG | ✅ |
| Backend SG | ✅ |
| RDS SG | ✅ |
| Internet → ALB TCP 80 | ✅ |
| ALB → Frontend TCP 80 | ✅ |
| ALB → Backend TCP 8000 | ✅ |
| Backend → RDS TCP 5432 | ✅ |
| Frontend outbound TCP 443 | ✅ |
| Backend outbound TCP 443 | ✅ |
| RDS all outbound | ✅ |
| IP-based internal workload allowlist | ❌ |
| Private task public IPs | ❌ |

### 3.3 Load balancing

| Item | Status |
| --- | --- |
| Application Load Balancer | ✅ |
| Public ALB | ✅ |
| ALB in public subnets | ✅ |
| HTTP listener :80 | ✅ |
| Default frontend route | ✅ |
| `/api` backend rule | ✅ |
| `/api/*` backend rule | ✅ |
| HTTPS listener | ❌ |
| ACM certificate | ❌ |
| WAF | ❌ |
| CloudFront | ❌ |
| Route 53 | ❌ |

### 3.4 ECS

| Item | Status |
| --- | --- |
| ECS cluster | ✅ |
| Fargate | ✅ |
| Frontend service | ✅ |
| Backend service | ✅ |
| Task definitions | ✅ |
| Private subnets | ✅ |
| No public IP | ✅ |
| AZ spread placement | ✅ |
| Container health checks | ✅ |
| ALB target health checks | ✅ |
| Deployment circuit breaker | ✅ |
| Rollback | ✅ |
| CPU target tracking | ✅ |
| Memory target tracking | ✅ |
| Automatic development application deployment | ✅ (`Joao` → `development`) |
| EC2 capacity provider | ❌ |
| Spot capacity | ❌ |

### 3.5 Containers

| Item | Status |
| --- | --- |
| Frontend Dockerfile | ✅ |
| Backend Dockerfile | ✅ |
| Nginx frontend | ✅ |
| FastAPI backend | ✅ |
| Backend non-root user | ✅ |
| Container health checks | ✅ |
| Fixed application dependencies | ✅ |
| Local Compose | ✅ |
| SBOM generation | ❌ |
| Image signing | ❌ |
| Registry publication from CI | ❌ |

### 3.6 ECR

| Item | Status |
| --- | --- |
| Frontend repository | ✅ |
| Backend repository | ✅ |
| Immutable tags | ✅ |
| Scan on push | ✅ |
| Lifecycle policy | ✅ |
| 10-image retention policy | ✅ |
| Automatic CI push | ❌ |

### 3.7 Database

| Item | Status |
| --- | --- |
| RDS | ✅ |
| PostgreSQL | ✅ |
| PostgreSQL 16 default | ✅ |
| Multi-AZ | ✅ |
| Private subnets | ✅ |
| Public accessibility disabled | ✅ |
| Storage encryption | ✅ |
| Automated backups | ✅ |
| 7-day retention default | ✅ |
| Storage autoscaling | ✅ |
| gp3 | ✅ |
| 20 GiB default | ✅ |
| 100 GiB max default | ✅ |
| DB schema/migrations | ✅ |
| Application domain tables | 🟡 Technical `items` table; final domain not defined |
| Read replica | ❌ |
| Cross-region database | ❌ |

### 3.8 Secrets/IAM

| Item | Status |
| --- | --- |
| ECS application execution role | ✅ |
| Monitoring execution role | ✅ |
| Frontend task role | ✅ |
| Backend task role | ✅ |
| Monitoring task role | ✅ |
| Task roles with business permissions | ❌ |
| ECR pull permissions | ✅ |
| Monitoring secret read permissions | ✅ |
| Secrets Manager read permission | ✅ |
| RDS-managed master secret | ✅ |
| Application password in source | ❌ |
| Human identity system | ✅ Google + Apple + local user/session model |
| MFA | ❌ |
| OIDC CI plan job definition | ✅ |
| OIDC production deployment | ❌ |

### 3.9 Observability / monitoring

| Capability | Status | Evidence / boundary |
|---|---|---|
| Zabbix server container | ✅ | `monitoring.tf` / Docker Compose |
| Zabbix web container | ✅ | `monitoring.tf` / Docker Compose |
| Grafana container | ✅ | `monitoring.tf` / Docker Compose |
| Grafana Zabbix plugin | ✅ | `alexanderzobnin-zabbix-app@6.8.0` |
| Monitoring RDS | ✅ | Dedicated PostgreSQL instance, Multi-AZ |
| Grafana through ALB | ✅ | `/grafana/*` listener rule |
| CloudWatch monitoring resources | ❌ | Removed by design; replaced by Zabbix/Grafana |
| CloudWatch log groups | ❌ | Removed by design |
| ECS Container Insights | ❌ | Not enabled; Zabbix/Grafana monitoring task is used instead |
| Centralized application log archive | ❌ | Not provided by Zabbix/Grafana alone |
| Kubernetes monitoring | ❌ | Kubernetes is not in the current MVP |

### 3.10 Terraform

| Item | Status |
| --- | --- |
| Root Terraform configuration | ✅ |
| Bootstrap Terraform configuration | ✅ |
| Required Terraform version | ✅ |
| AWS provider constraint | ✅ |
| Dynamic AZ data source | ✅ |
| Variable validations | ✅ |
| Cross-variable checks | ✅ |
| Global tags | ✅ |
| Sensitive secret output | ✅ |
| S3 remote backend | ✅ |
| S3 lockfile | ✅ |
| Bootstrap DynamoDB table | ✅ |
| Root `.terraform.lock.hcl` committed in archive | ❌ |
| Automated apply | ❌ |

### 3.11 CI/CD

| Item | Status |
| --- | --- |
| Terraform fmt | ✅ |
| Terraform init/validate | ✅ |
| Bootstrap validate | ✅ |
| TFLint | ✅ |
| terraform-docs generation check | ✅ |
| Checkov | ✅ |
| Trivy IaC scan | ✅ |
| Gitleaks | ✅ |
| Container build | ✅ |
| Container Trivy scan | ✅ |
| Compose validation | ✅ |
| Terraform Plan via optional OIDC job | ✅ |
| ECR image push | ❌ |
| ECS deployment | ❌ |
| Deployment rollback pipeline | ❌ |

## 4. Current application behavior

### Frontend

The frontend is a demonstration web page. It verifies that the backend is reachable by calling `/api/health` and updates a status line.

### Backend

The backend exposes the existing health endpoints, implements Google/Apple authentication with CloudStart sessions, and includes a protected technical Item CRUD. It does not yet implement authorization/RBAC, payments, financial calculations, or the final business domain.

### Database

RDS is present as infrastructure and the backend can validate connectivity. No business schema is created by the repository.

## 5. Current security boundaries

```text
Internet
   |
   v
ALB SG
   |
   +--> Frontend SG --> Frontend task
   |
   +--> Backend SG --> Backend task --> RDS SG --> RDS
```

The ECS tasks have no public IP addresses.

The RDS instance is not publicly accessible.

The backend password is delivered through ECS secret injection.

## 6. Current operational boundaries

### Exists

```text
Infrastructure declaration
Infrastructure validation
Container validation
Image vulnerability scanning
Secret scanning
Basic runtime observability
Deployment circuit breaker
RDS backups
Multi-AZ runtime architecture
```

### Does not exist

```text
Automatic development image publication
Automatic development application deployment
Formal incident-management system
Alarm notification routing
Restore drill automation
Chaos testing
Formal DR environment
Formal RTO/RPO implementation
```

## 7. Current documentation ambiguities resolved

### HTTP vs HTTPS

The current ALB listener is HTTP on port 80. Documentation must not represent it as HTTPS.

### ECS capacity

Terraform defines a resilient target of two tasks when deployment is enabled, but the default repository state sets `deploy_application = false`, reducing desired/minimum counts to zero.

### CI vs CD

The repository contains CI plus a guarded development CD path that publishes immutable application images to ECR and updates only the application ECS resources.

### Local vs AWS PostgreSQL

Local Compose uses PostgreSQL 17; AWS RDS defaults to PostgreSQL 16.

### “RDS password in Secrets Manager”

The password is managed by RDS and exposed through the managed secret. It is not stored in Terraform source.

## 8. Current non-components

The following have no current implementation and must not be described as part of the MVP runtime:

```text
WAF
ACM
HTTPS
Route 53
CloudFront
Lambda
EC2
Redis/ElastiCache
SQS
SNS
EventBridge
Mobile
Financial core
PSP/payment integration
Audit Fabric
FinOps/Cost Intelligence
Distributed tracing
Multi-account
Hybrid connectivity
On-premises infrastructure
Corporate AD/LDAP integration
```

## 9. File-to-capability traceability

| Capability | Primary files |
| --- | --- |
| Provider/version | `providers.tf` |
| Remote state | `backend.tf`, `bootstrap/*` |
| VPC/network | `vpc.tf`, `locals.tf`, `variables.tf` |
| Security groups | `security_groups.tf` |
| ECS/ALB | `ecs.tf`, `ecs_services.tf` |
| ECR | `ecr.tf` |
| RDS | `rds.tf` |
| IAM/secrets access | `iam.tf`, `ecs_services.tf` |
| Zabbix/Grafana | `monitoring.tf`, `docker-compose.monitoring.yml` |
| App frontend | `apps/frontend/*` |
| App backend | `apps/backend/*` |
| Local development | `docker-compose.yml`, `apps/frontend/nginx.conf` |
| Terraform CI | `.github/workflows/terraform-lint.yml` |
| Container CI | `.github/workflows/container-ci.yml` |
| Dependency automation | `.github/dependabot.yml` |
| PR governance | `.github/pull_request_template.md`, `.github/CODEOWNERS` |

## 10. Final current-state statement

The repository currently implements a **Terraform-defined AWS foundation plus a minimal two-service web application baseline**.

It is not yet a complete production business application.

It is not a production-grade continuous-delivery system; production deployment remains intentionally gated.

It is not yet the P2 financial/mobile/security platform.

It is not yet the P3 hybrid enterprise platform.

That distinction is intentional and is now reflected across the documentation.
