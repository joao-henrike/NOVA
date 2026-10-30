# CloudStart — Current MVP Architecture

> **Source of truth:** the Terraform configuration and application files in this repository snapshot. This document describes what the MVP actually declares. It does not incorporate future proposals.

## 1. Architectural boundary

The current repository implements a small web application platform on AWS:

```text
Client / Internet
      |
      v
Public Application Load Balancer
      |
      +----------------------------+
      |                            |
      v                            v
Frontend ECS/Fargate          Backend ECS/Fargate
      |                            |
      |                            v
      |                      PostgreSQL RDS
      |
      +----------------------------+
                   |
             Zabbix/Grafana
```

The supporting control plane is Terraform + GitHub Actions + ECR. It is documented separately so it does not visually obscure the runtime path.

## 2. AWS boundary and region

Default Terraform input:

```text
Region = us-east-1
```

The project does not hardcode AZ names. It discovers available AZs and selects the configured number, defaulting to two and allowing two or three.

## 3. VPC topology

Default VPC:

```text
10.20.0.0/16
```

For two selected AZs, the repository derives:

```text
AZ-A
├── Public      10.20.0.0/24
├── Private App 10.20.10.0/24
└── Private DB  10.20.20.0/24

AZ-B
├── Public      10.20.1.0/24
├── Private App 10.20.11.0/24
└── Private DB  10.20.21.0/24
```

The CIDRs are derived from `var.vpc_cidr`, so the formulas—not those literal default values—are the Terraform source of truth.

## 4. Routing

### Public

```text
Public subnet
   |
   +--> 0.0.0.0/0 -> Internet Gateway
```

### Private application

Each selected AZ has its own private-app route table:

```text
Private App AZ-A -> NAT Gateway AZ-A
Private App AZ-B -> NAT Gateway AZ-B
```

The NAT gateways live in public subnets and use EIPs.

### Private database

The database route tables contain no default route to the internet.

## 5. Runtime request path

The current ALB has an **HTTP** listener on port 80.

```text
Client
 |
 | HTTP :80
 v
ALB
 |
 +-- /api       --> Backend target group --> Backend :8000
 +-- /api/*     --> Backend target group --> Backend :8000
 +-- everything --> Frontend target group -> Frontend :80
```

The listener's default action is the frontend target group. The backend path rule has priority 10.

There is no HTTPS listener, ACM certificate, WAF, Route 53 record, or edge distribution in the current Terraform.

## 6. Frontend runtime

The frontend ECS task runs:

```text
nginx:1.29-alpine
```

Port mapping:

```text
container 80 -> target group 80
```

Nginx serves the static application from `/usr/share/nginx/html`.

The local Nginx configuration includes an `/api` reverse-proxy location for Compose. In AWS, the ALB performs the `/api` route directly, so the frontend container does not need to know the backend service hostname.

## 7. Backend runtime

The backend ECS task runs:

```text
python:3.12-slim
```

The process is Uvicorn/FastAPI on port 8000 and executes as a non-root user named `appuser` with UID 10001.

Current endpoints:

```text
/health
/api/health
/api/info
/api/health/db
```

The database health endpoint opens a short PostgreSQL connection and returns `503` when required connection variables are missing or PostgreSQL is unreachable.

## 8. ECS services

One ECS cluster contains two services:

```text
frontend
backend
```

Both use:

- Fargate;
- `awsvpc` networking;
- private application subnets;
- no public IP;
- their own security group;
- their own task role;
- the shared execution role;
- target groups attached to the ALB;
- AZ-spread placement;
- deployment circuit breaker with rollback;
- target-tracking autoscaling for CPU and memory.

The current defaults are:

```text
CPU per task:    256
Memory per task: 512 MiB

Desired: 2
Minimum: 2
Maximum: 6
```

Those desired/minimum counts are applied only when `deploy_application = true`. Otherwise the local Terraform expression reduces desired/minimum counts to zero.

## 9. Health checks

There are two health-check layers.

### Container health

Frontend:

```text
GET /health on localhost:80
```

Backend:

```text
GET /health on localhost:8000
```

### ALB target health

Both target groups use HTTP health checks every 30 seconds, with a 5-second timeout, two healthy successes, three unhealthy failures, and a `200-399` matcher.

Paths:

```text
Frontend -> /health
Backend  -> /health
```

## 10. Database topology

RDS is PostgreSQL and is placed only in private database subnets.

Current default:

```text
PostgreSQL 16
Multi-AZ: false (Single-AZ for current cost profile)
Publicly accessible: false
Storage: encrypted gp3
20 GiB -> autoscaling up to 100 GiB
Backup retention: 1 day by default
```

The application RDS security group accepts TCP 5432 from the backend HTTP security group and from the dedicated no-ingress database-tasks security group. The separate monitoring RDS accepts TCP 5432 only from the monitoring security group. Both RDS groups have no declared egress rules; security groups are stateful.

## 11. Security-group model

The network boundary is explicit:

```text
Internet -> ALB SG :80 (443 only when ACM is configured)
ALB SG   -> Frontend SG :80
ALB SG   -> Backend SG :8000
ALB SG   -> Monitoring SG :3000
Backend HTTP SG -> Application RDS SG :5432
Database-tasks SG -> Application RDS SG :5432
Monitoring SG -> Monitoring DB SG :5432
```

Only the backend, monitoring, and one-off database-task security groups have declared HTTPS egress. The database-task SG has no ingress and only two egress paths: HTTPS and TCP 5432 to application RDS. Frontend and both RDS security groups have no declared egress rules. Return traffic is allowed by stateful security-group behavior.

No component is assigned a public IP at the ECS task level.

## 12. Identity and secrets

### ECS execution identities

Each ECS task purpose has its own execution policy:

| Task | ECR scope | Secret access | CloudWatch Logs |
|---|---|---|---|
| Frontend | Frontend repository | None | Frontend log group only |
| Backend HTTP | Backend repository | Runtime DB + backend auth JSON | Backend log group only |
| DB bootstrap | Backend repository | RDS master + runtime + migrator secrets | Bootstrap log group only |
| DB migration | Backend repository | Migrator secret only | Migration log group only |
| Monitoring | Public monitoring images | Monitoring DB + Grafana admin | Monitoring log group only |

Execution roles receive only `logs:CreateLogStream` and `logs:PutLogEvents` for their own log group; containers do not receive CloudWatch Logs read access. Task roles remain separate and empty of application AWS permissions.

### Task identities

Separate frontend, backend, and monitoring task roles exist with no additional permissions in the current implementation. One-off bootstrap and migration tasks use the backend task role, which has no extra AWS permissions; their narrowly scoped startup secret access is on their separate execution roles.

### PostgreSQL identities

Three database identities are used in AWS:

| Identity | Use | Privilege boundary |
|---|---|---|
| `cloudstart_runtime` | Normal backend HTTP requests | DML and sequence usage only; cannot create/alter schema or read `alembic_version` |
| `cloudstart_migrator` | One-off Alembic task | Owns application schema objects and performs schema changes |
| RDS master (`cloudstart_admin`) | One-off bootstrap task only | Creates/updates the two restricted identities and reapplies runtime grants |

Deployment order is bootstrap → Alembic migration → bootstrap again, so new tables/sequences receive runtime DML grants. The normal backend never receives the RDS master or migration credentials.

### Database password

The RDS resource uses AWS-managed password management:

```text
RDS
 |
 | manage_master_user_password = true
 v
Secrets Manager
 |
 v
ECS backend secret injection -> DB_PASSWORD
```

The application image does not contain the database password.

## 13. ECR and image lifecycle

There are two ECR repositories:

```text
Frontend image repository
Backend image repository
```

Both use:

```text
IMMUTABLE image tags
scan_on_push = true
lifecycle = keep 10 most recent images
```

The current ECS task definitions reference the repository URL plus the configured tag.

Development CD publishes immutable SHA-tagged application images to ECR.

## 14. Monitoring and observability

The current MVP separates operational telemetry from container logs: Zabbix + Grafana provide availability/monitoring views, while CloudWatch Logs centrally retains stdout/stderr from all ECS containers. Project-managed CloudWatch alarms and dashboards are not provisioned; ECS Container Insights is enabled at cluster level.

### Monitoring service

Terraform creates one ECS/Fargate monitoring task containing three containers:

```text
Monitoring ECS task
├── Zabbix Server :10051
├── Zabbix Web :8080
└── Grafana :3000
```

The three containers share the task network namespace. Zabbix Web reaches Zabbix Server on `127.0.0.1:10051`, and Grafana reaches Zabbix Web on `127.0.0.1:8080`.

Grafana is the only monitoring UI exposed by the public ALB, through `/grafana/*`. Zabbix Server and Zabbix Web remain private.

### Monitoring database

Zabbix configuration/history is stored in a dedicated private PostgreSQL RDS instance. It is deliberately separate from the application RDS to preserve fault and access boundaries between the monitoring plane and the application data plane.

The monitoring RDS instance is Single-AZ, encrypted, backed up with the current one-day default retention, and protected by a dedicated security group.

### What Zabbix can observe in the MVP

The current monitoring design is centered on availability and end-to-end behavior:

- public ALB reachability;
- frontend `/health`;
- backend `/api/health`;
- backend `/api/health/db`;
- Grafana health;
- monitoring database availability;
- Zabbix server/web health.

The monitoring design intentionally does not claim ECS host-level or Kubernetes metrics that are not directly collected by the current implementation.

### Grafana

Grafana uses the Zabbix plugin as its monitoring data source. The current container installs `alexanderzobnin-zabbix-app@6.8.0`.

Grafana is configured to serve from the `/grafana/` subpath so it can sit behind the existing ALB without adding another public load balancer.

### Logging boundary

All seven ECS containers use the `awslogs` driver and write to five Terraform-managed CloudWatch log groups: frontend, backend, bootstrap, migration, and monitoring. The three monitoring containers share the monitoring group with distinct stream prefixes. Retention is 7 days in development and 30 days in production. CloudWatch Logs uses its AWS-owned encryption key by default; no customer-managed KMS key or long-term S3 archive is configured. Zabbix/Grafana remain a separate metrics/availability plane, not the central log store.

### Kubernetes boundary

Kubernetes is not part of the current MVP. No EKS cluster, Kubernetes workloads, or Kubernetes-specific resources are provisioned. The monitoring platform is container-native and can be extended later once such a runtime exists.

## 15. Terraform control plane

Terraform is split by responsibility and has two stacks:

```text
bootstrap/
    creates the remote-state infrastructure

root stack/
    creates the application infrastructure
```

### Root stack resources

The current root resources are:

```text
VPC / networking:
  aws_vpc
  aws_internet_gateway
  aws_subnet
  aws_eip
  aws_nat_gateway
  aws_route_table
  aws_route_table_association

Security:
  aws_security_group
  aws_vpc_security_group_ingress_rule
  aws_vpc_security_group_egress_rule

ECR:
  aws_ecr_repository
  aws_ecr_lifecycle_policy

ECS / ALB:
  aws_ecs_cluster
  aws_lb
  aws_lb_target_group
  aws_lb_listener
  aws_lb_listener_rule
  aws_ecs_task_definition
  aws_ecs_service
  aws_appautoscaling_target
  aws_appautoscaling_policy

Database:
  aws_db_subnet_group
  aws_db_instance

IAM:
  aws_iam_role
  aws_iam_role_policy

Monitoring:
  aws_db_subnet_group (monitoring)
  aws_db_instance (monitoring)
  aws_ecs_task_definition (monitoring)
  aws_ecs_service (monitoring)
  aws_lb_target_group (Grafana)
  aws_lb_listener_rule (Grafana)
```

### Bootstrap resources

```text
aws_s3_bucket
aws_s3_bucket_public_access_block
aws_s3_bucket_versioning
aws_s3_bucket_server_side_encryption_configuration
aws_s3_bucket_ownership_controls
aws_s3_bucket_policy
aws_dynamodb_table
```

## 16. Terraform state architecture

```text
Bootstrap stack
      |
      +--> S3 versioned/encrypted state bucket
      |
      +--> DynamoDB lock table
      |
      v
Root Terraform backend
      |
      +--> key = cloudstart/dev/terraform.tfstate
      +--> use_lockfile = true
```

The bootstrap stack intentionally has no remote backend of its own.

## 17. CI architecture

```text
Pull Request / main push
           |
           v
 Standard CI (tests, Terraform, scanners, Compose, containers)
           |
           +--> PR validation (no AWS OIDC)

Push to Joao / manual dispatch
           |
           v
 Extreme validation (full local system + read-only AWS plan when OIDC is available)

Push to Joao with runtime-artifact changes
           |
           v
 Guarded Development CD (OIDC, saved-plan allowlist, migrations, 3-service wait, smoke tests)

Manual rebuild (exact REBUILD confirmation)
           |
           v
 Destructive dev teardown + rebuild

The extreme workflow deliberately does not trigger on pull requests because its job needs `id-token: write` for live AWS validation. Standard CI remains the PR gate. There is no production deployment pipeline.

## 18. Local Compose topology

```text
localhost:8080
      |
      v
frontend/nginx
      |
      | /api
      v
backend:8000
      |
      v
postgres:5432
```

Compose uses PostgreSQL 17 while the default AWS RDS uses PostgreSQL 16. This mismatch is part of the current repository state.

## 19. Availability and failure behavior actually encoded

The current Terraform provides several resilience mechanisms:

```text
Multiple AZs
   + public/private subnet separation
   + NAT per AZ
   + ECS placement spread by AZ
   + configurable >=2 task deployment
   + ALB health checks
   + ECS container health checks
   + ECS service deployment circuit breaker
   + rollback on failed ECS deployment
   + RDS Multi-AZ
   + automated RDS backups
```

These are infrastructure/runtime controls. The repository does not yet contain tested RTO/RPO procedures, restore drills, chaos testing, or a separate DR environment.

## 20. What is deliberately not part of the current architecture

The following resources/services do not exist in the current Terraform/application source and therefore are excluded from the current architecture:

```text
ACM
WAF
Route 53
CloudFront
API Gateway
Lambda
EC2/Auto Scaling Groups
EKS/Kubernetes
ElastiCache/Redis
SQS
SNS
EventBridge
Step Functions
OpenSearch
Secrets beyond the RDS-managed secret
Customer-managed KMS keys
VPC endpoints
Multi-account organization
Cross-region DR
On-premises connectivity
Corporate AD integration
Mobile application
Financial core
Payment provider integration
Audit Fabric
Cost Intelligence / FinOps engine
Distributed tracing
```

## 21. Architectural truth table

| Concern | Current implementation |
| --- | --- |
| Public entry | ALB HTTP :80 |
| Compute | ECS/Fargate |
| Application services | Frontend + Backend |
| App networking | Private subnets |
| Public network resources | ALB + NAT |
| Database | RDS PostgreSQL Single-AZ (dev cost profile) |
| Database network | Private DB subnets |
| Container registry | ECR |
| Monitoring | Zabbix + Grafana containers |
| ECS logs | Five CloudWatch log groups; 7d dev / 30d prod |
| Container metrics | ECS Container Insights + Zabbix/Grafana |
| Alarms | Zabbix/Grafana; no project-managed CloudWatch alarms |
| Database identities | Runtime DML role + migrator role + RDS master bootstrap |
| Secrets | RDS-managed master + separate runtime/migrator/backend-auth/Grafana secrets |
| IAM | Purpose-specific ECS execution roles + empty task roles |
| IaC | Terraform |
| Remote state | S3 + S3 lockfile + bootstrap DynamoDB |
| CI | GitHub Actions |
| Automatic development image publish | Yes |
| Automatic development ECS deployment | Yes |
| HTTPS | No |
| Application auth | Google + Apple |
| Business database schema | No |
| Financial engine | No |
| Audit Fabric | No |
| FinOps engine | No |
| Hybrid/on-prem | No |

> Monitoring image choices were aligned with the current Zabbix 8.0 container documentation and Grafana documentation available at the time of this update.
