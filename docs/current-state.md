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
| Backend HTTP SG | ✅ |
| One-off database-tasks SG (no ingress) | ✅ |
| Monitoring SG | ✅ |
| Application RDS SG | ✅ |
| Monitoring RDS SG | ✅ |
| Internet → ALB TCP 80 (443 only when ACM is enabled) | ✅ |
| ALB → Frontend TCP 80 | ✅ |
| ALB → Backend TCP 8000 | ✅ |
| ALB → Grafana TCP 3000 | ✅ |
| Backend → Application RDS TCP 5432 | ✅ |
| Database tasks → Application RDS TCP 5432 | ✅ |
| Monitoring → Monitoring RDS TCP 5432 | ✅ |
| Backend / monitoring / database-task outbound TCP 443 | ✅ |
| Frontend egress | ❌ (no declared egress) |
| Application and monitoring RDS egress | ❌ (no declared egress) |
| Database-task ingress from ALB or Internet | ❌ |
| IP-based internal workload allowlist | ❌ |
| Private task public IPs | ❌ |

### 3.3 Load balancing

| Item | Status | Boundary |
| --- | --- | --- |
| Application Load Balancer | ✅ | Public ALB |
| HTTP listener :80 | ✅ | Default development entry point |
| Default frontend route | ✅ | |
| /api and /api/* backend rules | ✅ | |
| HTTPS listener | 🟡 Optional | Created only when an existing ACM certificate ARN and matching hostname are supplied |
| ACM certificate issuance/validation | ❌ | Not managed by this stack |
| DNS / Route 53 records | ❌ | Operator-managed outside the stack |
| WAF | ❌ | Not implemented |
| CloudFront | ❌ | Not implemented |

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
| Guarded development application deployment | ✅ (`Joao` → `development`, subject to GitHub OIDC/environment variables) |
| EC2 capacity provider | ❌ |
| Spot capacity | ❌ |

### 3.5 Containers

| Item | Status | Evidence / boundary |
| --- | --- | --- |
| Frontend Dockerfile | ✅ | apps/frontend |
| Backend Dockerfile | ✅ | apps/backend |
| Nginx frontend | ✅ | Separate AWS and local configurations |
| FastAPI backend | ✅ | |
| Backend non-root user | ✅ | |
| Container health checks | ✅ | Docker/ECS health checks |
| Fixed application dependencies | ✅ | Requirements files |
| Local Compose | ✅ | PostgreSQL 17.11, backend, frontend |
| SBOM generation | ❌ | Not implemented |
| Image signing | ❌ | Not implemented |
| Development image build and ECR publication | ✅ | Guarded deploy-dev.yml workflow |

### 3.6 ECR

| Item | Status | Evidence / boundary |
| --- | --- | --- |
| Frontend repository | ✅ | |
| Backend repository | ✅ | |
| Immutable tags | ✅ | Full Git SHA tags in development CD |
| Scan on push | ✅ | |
| Lifecycle policy | ✅ | Keeps 10 recent images |
| Automatic development image publication | ✅ | deploy-dev.yml after CI succeeds |
| Automatic production publication | ❌ | No production workflow |

### 3.7 Database

| Item | Status |
| --- | --- |
| RDS | ✅ |
| PostgreSQL | ✅ |
| PostgreSQL 16 default | ✅ |
| Multi-AZ | ❌ (intentionally Single-AZ for current cost profile) |
| Private subnets | ✅ |
| Public accessibility disabled | ✅ |
| Storage encryption | ✅ |
| Automated backups | ✅ |
| 1-day retention default | ✅ |
| Storage autoscaling | ✅ |
| gp3 | ✅ |
| 20 GiB default | ✅ |
| 100 GiB max default | ✅ |
| DB schema/migrations | ✅ |
| Application domain tables | 🟡 Technical `items` table; final domain not defined |
| Read replica | ❌ |
| Cross-region database | ❌ |

### 3.8 Secrets/IAM

| Item | Status | Evidence / boundary |
| --- | --- | --- |
| Purpose-specific ECS execution roles | ✅ | Frontend, backend, bootstrap, migration, monitoring |
| Frontend/backend/monitoring task roles | ✅ | No additional application AWS permissions |
| Bootstrap/migration ECS task role | ❌ | task_role_arn is intentionally omitted |
| Runtime PostgreSQL identity | ✅ | cloudstart_runtime; DML-only |
| Migration PostgreSQL identity | ✅ | cloudstart_migrator; migration task only |
| RDS master identity | ✅ | One-off bootstrap task only |
| RDS-managed master secret | ✅ | Managed by RDS |
| Runtime and migrator secret provisioning | ✅ | scripts/provision-db-credentials.sh |
| Backend authentication secret provisioning | ✅ | scripts/provision-backend-auth-secret.sh |
| JWT signing key | ✅ | Randomly generated on first auth-secret creation; preserved afterwards |
| Google/Apple OAuth values | 🟡 | Optional operator-supplied values; each provider requires a complete set |
| Grafana administrator secret | ✅ | Terraform-managed Secrets Manager secret |
| Application password in source | ❌ | No production credential is committed |
| Human identity system | ✅ | Google + Apple provider identity and local session model |
| MFA | ❌ | Not implemented |
| OIDC development deployment | ✅ | Guarded development workflow; AWS trust/policy configured outside repo |
| OIDC production deployment | ❌ | Not implemented |

### 3.9 Observability / monitoring

| Capability | Status | Evidence / boundary |
|---|---|---|
| Zabbix server container | ✅ | `monitoring.tf` / Docker Compose |
| Zabbix web container | ✅ | `monitoring.tf` / Docker Compose |
| Grafana container | ✅ | `monitoring.tf` / Docker Compose |
| Grafana Zabbix plugin | ✅ | `alexanderzobnin-zabbix-app@6.8.0` |
| Monitoring RDS | ✅ | Dedicated PostgreSQL instance, encrypted, Single-AZ |
| Grafana through ALB | ✅ | `/grafana/*` listener rule |
| Zabbix/Grafana monitoring plane | ✅ | Health/availability and monitoring database |
| CloudWatch alarms / project dashboards | ❌ | No project-managed alarm/dashboard resources |
| CloudWatch log groups | ✅ | Five Terraform-managed groups for frontend, backend, bootstrap, migration, monitoring |
| ECS container stdout/stderr | ✅ | `awslogs` driver; monitoring containers use separate stream prefixes |
| Log retention | ✅ | 7 days dev / 30 days prod; AWS-owned key encryption |
| Long-term centralized log archive | ❌ | Retention is intentionally short; no separate archive/S3 export |
| ECS Container Insights | ✅ | `ecs.tf`; enabled at cluster level |
| Kubernetes monitoring | ❌ | Kubernetes is not in the current MVP |

### 3.10 Terraform

| Item | Status | Evidence / boundary |
| --- | --- | --- |
| Root Terraform configuration | ✅ | |
| Bootstrap Terraform configuration | ✅ | |
| Required Terraform version | ✅ | >=1.16.4, <1.17.0 |
| AWS provider constraint | ✅ | ~>6.62; exact selected version in .terraform.lock.hcl |
| Dynamic AZ data source | ✅ | |
| Variable validations | ✅ | |
| Cross-variable checks | ✅ | |
| Global tags | ✅ | |
| Sensitive secret output | ✅ | RDS master secret ARN |
| S3 remote backend | ✅ | Canonical development state key |
| S3 lockfile | ✅ | Active root backend locking |
| Bootstrap DynamoDB table | ✅ | Compatibility resource only; not used by root backend locking |
| Root .terraform.lock.hcl committed | ✅ | |
| Guarded development terraform apply | ✅ | Saved-plan allowlist in deploy/rebuild workflows |
| General-purpose automatic infrastructure apply | ❌ | Infrastructure changes outside the CD allowlist need explicit operator review |

### 3.11 CI/CD

| Item | Status | Evidence / boundary |
| --- | --- | --- |
| Standard CI | ✅ | Backend tests, images/runtime smoke, Compose, Terraform and security checks |
| Extreme validation | ✅ | Joao push/manual; optional read-only AWS checks with OIDC |
| Terraform fmt/init/validate | ✅ | ci.yml |
| TFLint | ✅ | ci.yml |
| Checkov / Trivy / Gitleaks / ShellCheck / CodeQL | ✅ | CI security gate |
| Compose validation | ✅ | ci.yml |
| Development ECR image publication | ✅ | deploy-dev.yml; full Git SHA tags |
| Guarded development ECS deployment | ✅ | Saved Terraform plan and resource allowlist |
| Database migration deployment | ✅ | Bootstrap -> Alembic -> grants bootstrap |
| Post-deployment smoke checks | ✅ | ALB, API, database, Grafana |
| Destructive dev rebuild | ✅ | Manual-only; exact REBUILD confirmation |
| Production deployment | ❌ | No production workflow |
| Separate workflow-level rollback pipeline | 🟡 | ECS deployment circuit breaker/rollback is enabled; no separate release rollback orchestrator |

## 4. Current application behavior

### Frontend

The frontend is a demonstration web page. It verifies that the backend is reachable by calling `/api/health` and updates a status line.

### Backend

The backend exposes the existing health endpoints, implements Google/Apple authentication with CloudStart sessions, and includes an owner-scoped technical Item CRUD. It does not yet implement role-based permissions, payments, financial calculations, or the final business domain. Runtime OAuth availability depends on the target environment's Secrets Manager values and HTTPS callback configuration.

### Database

RDS is present as infrastructure and the backend can validate connectivity. The repository creates authentication/session tables, the technical `items` table, and supporting rate-limit/OAuth-state tables; the final business domain is not defined.

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

Both application and monitoring RDS instances are Single-AZ and not publicly accessible. The database-task security group has no ingress rules and permits only HTTPS egress plus PostgreSQL toward the application RDS security group.

The normal backend task uses `cloudstart_runtime` and receives only the runtime Secrets Manager password. The Alembic task uses `cloudstart_migrator`; the one-off bootstrap task alone receives the RDS-managed master secret. JWT/OAuth settings use a separate optional Secrets Manager JSON secret; values are populated out-of-band.

## 6. Current operational boundaries

### Exists

```text
Infrastructure declaration
Infrastructure validation
Container validation
Image vulnerability scanning
Secret scanning
Zabbix/Grafana availability monitoring
CloudWatch ECS container logs (7-day dev / 30-day prod retention)
Deployment circuit breaker
Single-AZ RDS backups
```

### Does not exist

```text
Automatic production deployment
Production deployment approval gate
Formal incident-management system
Alarm notification routing
Restore drill automation
Chaos testing
Formal DR environment
Formal RTO/RPO implementation
```

## 7. Current documentation ambiguities resolved

### HTTP vs HTTPS

The committed development configuration leaves acm_certificate_arn and alb_domain_name empty, so HTTP on port 80 is active by default. Terraform supports an optional HTTPS listener and HTTP-to-HTTPS redirect when an already-issued ACM certificate in the target region and a matching hostname are supplied. Certificate issuance, domain validation, and DNS records are not managed by this stack.

### ECS capacity

Terraform defines a resilient target of two tasks when deployment is enabled, but the default repository state sets `deploy_application = false`, reducing desired/minimum counts to zero.

### CI vs CD

The repository contains standard CI, an extreme full-system validation workflow, and a guarded development CD path. Development CD publishes immutable application images and allows only the explicitly enumerated frontend/backend/monitoring task/service, scoped IAM, database-task network, and CloudWatch log-group changes. It waits for all three services and checks Grafana health. Production CD remains absent.

### Local vs AWS PostgreSQL

Local Compose uses PostgreSQL 17; AWS RDS defaults to PostgreSQL 16.

### “RDS password in Secrets Manager”

The RDS master password is managed by RDS and exposed through its managed secret. It is injected only into the one-off role-bootstrap task. The normal backend receives a separate DML-only runtime password; the migration task receives a separate migrator password. The backend JWT/OAuth JSON secret is created/reused by the deployment provisioner. Terraform receives secret ARNs, not plaintext password or OAuth values.

## 8. Current non-components

The following have no managed resource or application implementation in the current MVP:

```text
ACM certificate issuance and DNS validation
Route 53 records / managed DNS
WAF
CloudFront
API Gateway
Lambda
EC2 / Auto Scaling Groups
ElastiCache / Redis
SQS / SNS / EventBridge
Mobile application
Financial core / payment processing
Audit Fabric
FinOps / Cost Intelligence
Distributed tracing
Multi-account organization
Hybrid / on-premises connectivity
Corporate AD/LDAP integration
```

The ALB's optional HTTPS listener is implemented in Terraform; the ACM certificate itself and DNS mapping remain external prerequisites. This distinction is intentional.

## 9. File-to-capability traceability

| Capability | Primary files |
| --- | --- |
| Provider/version | providers.tf, .terraform.lock.hcl |
| Root inputs and validations | variables.tf, main.tf, locals.tf |
| Remote state | backend.tf, bootstrap/*, scripts/ensure-terraform-state.sh |
| VPC/network | vpc.tf, locals.tf, variables.tf |
| Security groups | security_groups.tf, monitoring.tf |
| ECS/ALB | ecs.tf, ecs_services.tf |
| ECR | ecr.tf |
| RDS | rds.tf, monitoring.tf |
| IAM/secrets access | iam.tf, ecs_services.tf |
| Backend authentication | apps/backend/app, scripts/provision-backend-auth-secret.sh |
| Database credentials | apps/backend/app/db, scripts/provision-db-credentials.sh |
| Zabbix/Grafana | monitoring.tf, docker-compose.monitoring.yml, monitoring/README.md |
| App frontend | apps/frontend/* |
| App backend | apps/backend/* |
| Local development | docker-compose.yml, docker-compose.monitoring.yml, Makefile |
| Deployment scripts | scripts/deploy.sh, scripts/ensure-terraform-state.sh, scripts/provision-*.sh |
| Standard CI | .github/workflows/ci.yml |
| Extreme validation | .github/workflows/extreme-validation.yml |
| Development CD | .github/workflows/deploy-dev.yml |
| Manual development rebuild | .github/workflows/rebuild-dev.yml |
| Configuration reference | docs/configuration-reference.md |
| Architecture / security / operations | docs/architecture.md, docs/security.md, docs/deployment.md |
| Dependency automation | .github/dependabot.yml |
| PR governance | .github/pull_request_template.md, .github/CODEOWNERS |

## 10. Final current-state statement

The repository implements a Terraform-defined AWS foundation, a minimal two-service web application, a Zabbix/Grafana monitoring plane, and guarded continuous delivery for the development environment.

It is not yet a complete production business application or a production-grade delivery platform. Production CD, high-availability database configuration, formal disaster recovery, full business authorization, financial processing, and enterprise security services remain outside the current implementation.

The configuration reference in docs/configuration-reference.md records every root Terraform input, bootstrap input, secret name, GitHub variable, workflow entry point, and deployment boundary. It must be updated alongside the source whenever those interfaces change.
