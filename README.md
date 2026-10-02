# CloudStart — AWS Application Infrastructure

[![Terraform](https://img.shields.io/badge/Terraform-1.16.4-7B42BC?logo=terraform)](https://developer.hashicorp.com/terraform)
[![AWS](https://img.shields.io/badge/AWS-ECS%20%7C%20RDS%20%7C%20VPC-FF9900?logo=amazonaws)](https://aws.amazon.com/)
[![Terraform CI](https://github.com/joao-henrike/NOVA/actions/workflows/terraform-lint.yml/badge.svg)](https://github.com/joao-henrike/NOVA/actions/workflows/terraform-lint.yml)
[![Container CI](https://github.com/joao-henrike/NOVA/actions/workflows/container-ci.yml/badge.svg)](https://github.com/joao-henrike/NOVA/actions/workflows/container-ci.yml)

> **Current-state documentation:** this README describes the implementation contained in this repository snapshot. Planned P2/P3 capabilities are intentionally not presented as implemented architecture.

## 1. What this repository is

CloudStart is the AWS application-infrastructure baseline inside the `NOVA` repository. The current implementation combines a small two-service web application with an AWS foundation built as Terraform.

The current MVP contains:

- one custom VPC;
- dynamically discovered Availability Zones, two by default;
- public, private application, and private database subnets;
- one NAT Gateway per selected Availability Zone;
- one public Application Load Balancer;
- one ECS cluster using Fargate services;
- one frontend service, one backend service, and one monitoring service;
- two private ECR repositories;
- one private PostgreSQL RDS instance for the application, configured for Multi-AZ;
- one separate private PostgreSQL RDS instance for Zabbix monitoring state/history, configured for Multi-AZ;
- Zabbix + Grafana monitoring delivered as Docker containers, with Grafana exposed through the ALB;
- IAM roles for ECS execution and application tasks;
- RDS-managed master password stored through Secrets Manager;
- Terraform remote-state bootstrap using S3 plus a DynamoDB lock table for compatibility;
- GitHub Actions for Terraform/static/security validation and container build/scan validation;
- local Docker Compose development for frontend, backend, and PostgreSQL.

The current MVP **does not** implement the future financial core, mobile application, Audit Fabric, Cost Intelligence/FinOps engine, enterprise hybrid integration, or other planned P2/P3 capabilities.

## 2. Current implementation state

There are two important states to distinguish:

| State | Meaning in this repository |
| --- | --- |
| Infrastructure code | Terraform declares the AWS resources described in this README. |
| Application runtime | ECS task definitions and services exist in Terraform, but `deploy_application` defaults to `false`. |
| Application images | Dockerfiles and application source exist in the repository. Container CI builds and scans them, but does not push them to ECR. |
| Continuous integration | GitHub Actions validate Terraform, scan IaC/secrets, and build/scan containers. |
| Continuous delivery | No automatic ECR publish + ECS deployment workflow is implemented. |
| Credentialed Terraform Plan | Implemented as an optional PR job and only runs when its required repository variables are configured. |
| AWS live deployment | Not established by this repository snapshot alone; actual AWS state must be checked separately. |

### 2.1 Default application behavior

The Terraform default is:

```hcl
deploy_application = false
```

The ECS services are therefore configured with zero desired/minimum tasks until application deployment is explicitly enabled. The task definitions and autoscaling configuration still exist in Terraform.

When `deploy_application = true`, the defaults become:

```text
Frontend desired/min/max: 2 / 2 / 6
Backend  desired/min/max: 2 / 2 / 6
```

The ECS services use AZ-spread placement, so the intended running state distributes tasks across the selected Availability Zones.

## 3. Architecture at a glance

![CloudStart MVP Architecture](./CloudStart_MVP_Arquitetura_Atual.png)

The production-side application path is **HTTP on port 80**. There is no ACM certificate or HTTPS listener in the current Terraform implementation.

## 4. Request flow

The public entry point is the Application Load Balancer in the public subnets.

```text
Client
  |
  | TCP/HTTP :80
  v
Public ALB
  |
  +---- path /api or /api/* ----> Backend target group ----> Backend container :8000
  |
  +---- all other paths --------> Frontend target group --> Frontend container :80
```

The ALB listener has a default action to the frontend target group. A priority-10 listener rule forwards `/api` and `/api/*` to the backend target group.

The frontend browser application calls `/api/health`. In AWS that request returns to the ALB and is routed directly to the backend; it is **not** proxied from the frontend container to the backend.

The Nginx configuration contains `/api` proxying only for the local Docker Compose topology, where the frontend container can resolve the `backend` service name.

## 5. Network architecture

### 5.1 VPC

Default configuration:

```text
VPC CIDR: 10.20.0.0/16
Region:   us-east-1
AZs:      2
```

Availability Zones are discovered dynamically through the `aws_availability_zones` data source. The configuration requires at least two available AZs and accepts up to three.

### 5.2 Subnet tiers

For the default two-AZ configuration, Terraform derives three subnet tiers per AZ.

| Tier | Default purpose | Internet route |
| --- | --- | --- |
| Public | ALB and NAT Gateway | Internet Gateway |
| Private App | ECS/Fargate workloads | NAT Gateway for that AZ |
| Private DB | RDS | No default internet route |

The default derived CIDRs are:

```text
Public:
  AZ[0] -> 10.20.0.0/24
  AZ[1] -> 10.20.1.0/24

Private App:
  AZ[0] -> 10.20.10.0/24
  AZ[1] -> 10.20.11.0/24

Private DB:
  AZ[0] -> 10.20.20.0/24
  AZ[1] -> 10.20.21.0/24
```

These ranges are derived from the configured VPC CIDR; they are not hardcoded as independent resources.

### 5.3 Internet Gateway

The VPC has one Internet Gateway.

Public route table:

```text
0.0.0.0/0 -> Internet Gateway
```

### 5.4 NAT Gateways

One NAT Gateway and one EIP are created per selected Availability Zone.

The private application route table for each AZ points to its same-AZ NAT Gateway:

```text
Private App AZ-A -> NAT AZ-A -> IGW
Private App AZ-B -> NAT AZ-B -> IGW
```

The database route tables intentionally contain no default internet route.

## 6. Security groups and allowed network flows

The current Terraform creates four security groups:

```text
ALB SG
Frontend SG
Backend SG
RDS SG
```

### 6.1 Current ingress/egress relationships

```text
Internet
   |
   | TCP :80
   v
ALB SG
   |
   +---- TCP :80 ----> Frontend SG
   |
   +---- TCP :8000 --> Backend SG
                         |
                         +---- TCP :5432 --> RDS SG
```

### 6.2 Exact current rules

| Source / destination | Protocol | Port | Purpose |
| --- | --- | ---: | --- |
| `0.0.0.0/0` → ALB | TCP | 80 | Public HTTP ingress |
| ALB SG → Frontend SG | TCP | 80 | ALB to frontend |
| ALB SG → Backend SG | TCP | 8000 | ALB to backend |
| Backend SG → RDS SG | TCP | 5432 | PostgreSQL access |
| ALB SG → Monitoring SG | TCP | 3000 | Grafana through ALB |
| Monitoring SG → Monitoring DB SG | TCP | 5432 | Zabbix state/history |
| Frontend SG → `0.0.0.0/0` | TCP | 443 | Frontend outbound HTTPS |
| Backend SG → `0.0.0.0/0` | TCP | 443 | Backend outbound HTTPS |
| RDS SG → `0.0.0.0/0` | all | all | Current default outbound rule |

The backend-to-RDS flow uses a security-group reference rather than a workload IP address.

## 7. Application layer

### 7.1 Frontend

The frontend is a separate ECS/Fargate service backed by an Nginx container.

Current image base:

```text
nginx:1.29-alpine
```

The application contains a single static HTML page and calls:

```text
/api/health
```

to display backend availability.

The container listens on TCP 80.

The ECS task definition includes a container health check against:

```text
http://127.0.0.1:80/health
```

The ALB target group also health-checks `/health` over HTTP.

### 7.2 Backend

The backend is a separate ECS/Fargate service implemented with FastAPI.

Current image base:

```text
python:3.12-slim
```

Current application dependencies are:

```text
fastapi==0.118.0
uvicorn[standard]==0.37.0
psycopg[binary]==3.2.10
```

The application currently exposes:

```text
GET /health
GET /api/health
GET /api/info
GET /api/health/db
```

The backend listens on TCP 8000.

The container health check calls `/health` locally. The ALB target group also checks `/health`.

### 7.3 Current backend data access

The backend receives the following database configuration through ECS environment variables:

```text
APP_ENV
DB_HOST
DB_PORT
DB_NAME
DB_USER
```

The database password is injected through ECS Secrets Manager integration as:

```text
DB_PASSWORD
```

The current backend uses PostgreSQL only for the `/api/health/db` connectivity test. There is currently no implemented application schema, migration system, order system, payment system, financial ledger, or other business-domain persistence layer.

## 8. ECS architecture

### 8.1 Cluster

One ECS cluster is declared.

Container Insights is not enabled. Monitoring is provided by the Zabbix/Grafana ECS task.

### 8.2 Services

Two ECS services exist:

```text
cloudstart-<environment>-frontend
cloudstart-<environment>-backend
```

Both use:

```text
Launch type: FARGATE
Network mode: awsvpc
Public IP:   disabled
Placement:   spread by Availability Zone
```

### 8.3 Deployment behavior

Both services use:

```text
minimum healthy percent: 100
maximum percent:         200
health-check grace:     60 seconds
circuit breaker:        enabled
rollback:               enabled
```

This provides deployment-level protection against a failed ECS rollout, but it is not the same thing as a complete CI/CD system.

### 8.4 Autoscaling

Each service has target-tracking scaling for:

- CPU utilization;
- memory utilization.

Default targets:

```text
CPU    -> 60%
Memory -> 70%
```

Default task range when deployment is enabled:

```text
min = 2
max = 6
```

`desired_count` in the ECS service is ignored by Terraform after deployment so Application Auto Scaling can control the running count.

## 9. ECR

Two private ECR repositories exist:

```text
cloudstart-<environment>-frontend
cloudstart-<environment>-backend
```

Both repositories currently define:

- immutable image tags;
- scan-on-push;
- lifecycle policy retaining the 10 most recent images.

ECS task definitions refer to the configured image tags:

```hcl
frontend_image_tag = "v0.1.0"
backend_image_tag  = "v0.1.0"
```

These tags are references in task definitions; the repository snapshot does not contain the images themselves.

## 10. RDS architecture

The current database layer contains one `aws_db_instance` resource configured as PostgreSQL.

Default settings:

```text
Engine:            PostgreSQL
Major version:     16
Class:             db.t4g.micro
Storage:           20 GiB
Max storage:       100 GiB
Storage type:      gp3
Multi-AZ:          true
Publicly accessible: false
```

The instance is placed in an RDS subnet group containing the private database subnets.

### 10.1 Current database protections

Enabled in the Terraform resource:

- storage encryption;
- automated backup retention;
- storage autoscaling;
- automatic minor version upgrades;
- tag copying to snapshots;
- private accessibility;
- Multi-AZ deployment.

Default backup retention is 7 days.

### 10.2 Deletion behavior

The following are configuration variables and default to `false`:

```text
alb_deletion_protection
rds_deletion_protection
```

The RDS resource uses:

```text
prod      -> final snapshot is configured
non-prod  -> final snapshot is skipped
```

This means production-safe deletion protection is **not enabled by default** in the current variables.

## 11. Secrets Manager integration

RDS uses:

```hcl
manage_master_user_password = true
```

The generated master password is managed by RDS/Secrets Manager.

The ECS execution role has permission to read the RDS master secret required to inject `DB_PASSWORD` into the backend task.

The application repository does not contain the RDS password.

## 12. IAM

The current implementation declares three ECS-related roles:

```text
ECS execution role
Frontend task role
Backend task role
```

### 12.1 Execution role

The ECS execution policy permits:

```text
ECR:
  ecr:GetAuthorizationToken
  ecr:BatchCheckLayerAvailability
  ecr:BatchGetImage
  ecr:GetDownloadUrlForLayer

Secrets Manager:
  secretsmanager:GetSecretValue
```

The ECR repository access is scoped to the two project repositories, while the ECR authorization-token action uses `*` as required by the API model.

### 12.2 Task roles

Separate frontend and backend task roles exist, but the current project does not grant application permissions to either role.

They therefore provide identity separation without introducing unnecessary workload permissions.

## 13. Zabbix + Grafana observability

The current MVP monitoring layer is provided by a Dockerized Zabbix/Grafana stack; the former CloudWatch monitoring resources were removed.

### Monitoring topology

```text
Public ALB
    |
    | /grafana/*
    v
ECS monitoring task (private subnet)
    |
    +-- Zabbix Server :10051
    +-- Zabbix Web :8080
    +-- Grafana :3000
            |
            +-- Zabbix data source plugin

Zabbix / Grafana task
    |
    +-- TCP/HTTPS checks to application endpoints
    +-- PostgreSQL monitoring database
```

Zabbix is the monitoring and alerting engine. Grafana is the visualization layer and consumes Zabbix data through the Zabbix data-source plugin. The plugin is installed directly in the Grafana container.

The current MVP deliberately does not expose the Zabbix server port or Zabbix web interface through the public ALB. Grafana is the public monitoring UI; Zabbix server and web remain private inside the monitoring task.

The ALB remains part of the monitored path: Zabbix can observe the public application through `/health`, `/api/health`, and `/api/health/db` checks. This validates the load balancer, target availability, application path, and database health from the outside of the application containers.

The monitoring stack is separate from the request-serving path. A monitoring failure must not prevent frontend/backend traffic from reaching the application.

### Docker images

Current references are based on the Zabbix 8.0 container family and Grafana 13.2.3. Grafana preinstalls the Zabbix plugin version 6.8.0.

### Current boundary

Zabbix/Grafana replace the **project-managed CloudWatch observability layer**. They do not create a centralized log archive equivalent to CloudWatch Logs. ECS application containers therefore do not use the former `awslogs` configuration in this MVP.

Kubernetes is not part of the current architecture and is intentionally not provisioned or shown as a runtime component. Zabbix can be extended later with Kubernetes monitoring when a Kubernetes cluster actually exists.

## 14. Terraform architecture

The root Terraform stack is split by responsibility:

```text
providers.tf          Provider/version requirements
backend.tf            Remote state configuration
main.tf               Account/region data + consistency checks
locals.tf             Naming, tags, AZ/subnet derivations
variables.tf          Configurable inputs + validation
vpc.tf                VPC/subnets/routes/NAT/IGW
ecr.tf                ECR repositories/lifecycle
ecs.tf                ECS cluster + ALB + target groups + listener
ecs_services.tf      Task definitions + services + autoscaling
security_groups.tf    Network access rules
rds.tf                RDS subnet group + DB instance
iam.tf                ECS roles and execution policy
monitoring.tf          Zabbix/Grafana monitoring stack + ALB route
outputs.tf            Root outputs
```

### 14.1 Terraform validation controls

The current Terraform code includes:

- variable type declarations;
- variable validations;
- global tags;
- dynamic AZ discovery;
- precondition checking for minimum AZ availability;
- cross-variable consistency checks for task counts;
- storage consistency checks;
- sensitive marking for the secret ARN output.

## 15. Terraform remote state bootstrap

The `bootstrap/` stack creates the resources that the root stack needs for remote state.

### S3 state bucket

The bootstrap creates an S3 bucket with:

- public access blocking;
- versioning;
- server-side encryption using AES256;
- bucket-owner-enforced ownership;
- a policy denying insecure transport.

### DynamoDB lock table

The bootstrap creates:

```text
cloudstart-terraform-lock
```

with:

```text
PAY_PER_REQUEST
partition key: LockID (String)
Point-in-time recovery: enabled
```

The root backend enables S3 lockfile support:

```hcl
use_lockfile = true
```

The repository also passes the DynamoDB table through `terraform init` for compatibility with the bootstrap design.

### Root backend key

The state key is:

```text
cloudstart/terraform.tfstate
```

The bucket and region are supplied during `terraform init` because Terraform backend configuration cannot use normal input variables.

## 16. GitHub Actions — current delivery pipeline

The repository has two workflows.

### 16.1 Terraform CI

`.github/workflows/terraform-lint.yml` runs on PRs and pushes to `main` when Terraform/configuration/documentation paths change.

Current jobs:

```text
Terraform Static Validation
IaC Security and Policy
Secret Scanning
Terraform Plan (conditional)
```

#### Terraform Static Validation

Runs:

```text
terraform fmt -check -recursive -diff
terraform init -backend=false
terraform validate
bootstrap terraform init -backend=false
bootstrap terraform validate
tflint --recursive
terraform-docs generation check
```

#### IaC Security and Policy

Runs:

```text
Checkov
Trivy configuration/misconfiguration scan
```

The configured policy fails on HIGH and CRITICAL findings while lower severities are soft-failed for Checkov.

#### Secret Scanning

Runs Gitleaks against repository history.

#### Terraform Plan

The plan job is conditional. It requires all of the following to be true:

- the event is a pull request;
- the PR is not from a fork;
- `AWS_TERRAFORM_PLAN_ROLE_ARN` is configured;
- `TF_STATE_BUCKET` is configured;
- `TF_STATE_DYNAMODB_TABLE` is configured.

When enabled, it uses GitHub OIDC to assume an AWS role and posts a sanitized plan-action summary to the PR.

It also contains a destructive-change guard requiring the `infra-allow-destroy` label when a plan contains a delete action.

### 16.2 Container CI

`.github/workflows/container-ci.yml` runs on application/container changes.

Current actions:

```text
Build frontend image
Build backend image
Scan frontend with Trivy
Scan backend with Trivy
Validate Docker Compose configuration
```

The current workflow uses:

```text
push: false
```

Therefore it does **not** publish images to ECR and does **not** deploy to ECS.

## 17. Local development architecture

The application stack is defined in `docker-compose.yml`. The monitoring stack is defined separately in `docker-compose.monitoring.yml` so the application-only local workflow remains lightweight:

```text
Browser
   |
   | :8080
   v
Frontend / Nginx
   |
   | /api -> backend:8000
   v
Backend / FastAPI
   |
   | :5432
   v
PostgreSQL

Optional monitoring plane:
Zabbix DB -> Zabbix Server -> Zabbix Web -> Grafana
```

Services:

```text
frontend -> localhost:8080 -> container :80
backend  -> localhost:8000 -> container :8000
postgres -> localhost:5432 -> container :5432

monitoring compose:
Grafana       -> localhost:3000 -> container :3000
Zabbix Web    -> localhost:8081 -> container :8080
Zabbix Server -> localhost:10051 -> container :10051
Zabbix DB     -> internal only
```

Start monitoring locally with:

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
```

The local PostgreSQL image is:

```text
postgres:17-alpine
```

The AWS RDS default is PostgreSQL 16. The current project therefore does **not** use the same PostgreSQL major version locally and in AWS.

The Compose password is explicitly a local-development-only value and is not used by the AWS stack.

## 18. Repository and dependency governance

Current repository controls include:

```text
.github/CODEOWNERS
.github/pull_request_template.md
.github/dependabot.yml
.tflint.hcl
.terraform-docs.yml
trivy.yaml
```

Dependabot is configured to check weekly updates for:

- GitHub Actions;
- Terraform root configuration;
- Terraform bootstrap configuration.

## 19. Outputs exposed by the root stack

The root module exposes values for:

- AWS account ID;
- AWS region;
- VPC ID;
- public subnet IDs;
- private app subnet IDs;
- private DB subnet IDs;
- ALB DNS name;
- frontend/backend ECR URLs;
- ECS cluster name;
- frontend/backend ECS service names;
- frontend/backend task-definition ARNs;
- RDS endpoint and port;
- RDS master username;
- RDS master secret ARN (sensitive);
- Grafana URL;
- monitoring ECS service name;
- monitoring RDS endpoint.

These are infrastructure outputs, not a business API.

## 20. Security posture of the current MVP

Current implemented controls include:

- private RDS database;
- separate ALB/frontend/backend/RDS security groups;
- security-group references for internal workload access;
- no public IP assignment on ECS tasks;
- encrypted RDS storage;
- RDS-managed master password;
- ECS secret injection;
- immutable ECR image tags;
- ECR scan-on-push;
- non-root backend container user;
- Terraform state S3 public-access blocking;
- S3 state transport policy requiring secure transport;
- Terraform/IaC/security/secret scanning in CI.

The following are **not** current controls because they are not implemented in this MVP:

- HTTPS/ACM certificate;
- WAF;
- application authentication/authorization;
- MFA;
- Zero Trust implementation as a complete identity architecture;
- customer-managed KMS key architecture;
- VPC endpoints;
- centralized enterprise identity;
- advanced runtime security platform;
- automated security response;
- immutable audit-log store;
- full end-to-end Audit Fabric.

## 21. Current limitations and known consistency points

These are documentation-level facts about the current repository, not hidden assumptions:

### 21.1 HTTP only

The current public ALB exposes HTTP port 80. There is no TLS listener or ACM certificate in Terraform.

### 21.2 No automatic container publication

Container CI builds and scans images but uses `push: false`.

### 21.3 No automatic ECS deployment

There is no workflow step that publishes a production image and updates the ECS services automatically.

### 21.4 Application disabled by default

`deploy_application = false`, so the default Terraform apply creates the ECS service/task definitions without starting application tasks.

### 21.5 Production deletion protection defaults are off

Both ALB and RDS deletion-protection variables default to `false`.

### 21.6 No Zabbix notification destination configured

The repository provisions the Zabbix/Grafana monitoring runtime but does not provision notification channels, contact points, or external alert destinations.

### 21.7 Local/AWS PostgreSQL major-version mismatch

Compose uses PostgreSQL 17, while RDS defaults to PostgreSQL 16.

### 21.8 No application persistence model beyond connectivity

The backend verifies DB reachability, but it does not implement domain tables or migrations.

### 21.9 No live AWS state is encoded in the repository

The repository declares infrastructure. Whether a given resource currently exists in an AWS account is an external runtime fact and must not be inferred only from Terraform source.

### 21.10 `.terraform.lock.hcl`

The current project archive does not include `.terraform.lock.hcl`. Terraform generates it during `terraform init` based on the provider constraints and selected platform/provider packages.

## 22. Explicitly outside the current MVP

The following should **not** be interpreted as current architecture:

```text
Mobile application
Financial core
Payment orchestration / PSP integration
Double-entry ledger
Reconciliation engine
Audit Fabric
Cost Intelligence / FinOps engine
Distributed tracing
Business KPI telemetry
Chaos / Fault Injection
DR environment
Multi-account enterprise landing zone
AWS + on-premises integration
Corporate identity integration
Legacy-system integration
EC2/Spot capacity
Queues / event buses / caches
WAF / ACM / HTTPS
```

These capabilities may belong to later proposals, but they are not implemented in this repository snapshot.

## 23. Documentation map

The detailed current-state documentation is split by concern:

| Document | Purpose |
| --- | --- |
| `README.md` | Repository entry point and current implementation overview |
| `docs/architecture.md` | Detailed runtime and infrastructure architecture |
| `docs/current-state.md` | Auditable inventory of implemented vs non-implemented components |
| `docs/deployment.md` | Current bootstrap, image publication, deployment, and local-development procedures |
| `docs/ci-cd.md` | Exact behavior of the GitHub Actions workflows |
| `docs/security.md` | Current security controls, boundaries, and explicit non-controls |

The repository documentation follows the same rule throughout: implemented architecture is documented as current; future architecture is explicitly separated.

## 24. Quick command reference

### Local stack

```bash
docker compose up --build
```

### Terraform formatting and validation

```bash
terraform fmt -recursive
terraform init -backend=false
terraform validate
```

### Bootstrap

```bash
terraform -chdir=bootstrap init
terraform -chdir=bootstrap validate
terraform -chdir=bootstrap plan
terraform -chdir=bootstrap apply
```

### Root initialization after bootstrap

```bash
terraform init \
  -backend-config="bucket=$(terraform -chdir=bootstrap output -raw state_bucket_name)" \
  -backend-config="region=$(terraform -chdir=bootstrap output -raw region)" \
  -backend-config="dynamodb_table=$(terraform -chdir=bootstrap output -raw lock_table_name)" \
  -reconfigure
```

For the full procedure, see `docs/deployment.md`.

## 25. Source-of-truth rule

For any question about what the MVP currently contains, use the implementation itself as the source of truth:

```text
Terraform resources / configuration
        +
Application source / Dockerfiles
        +
GitHub workflow definitions
        +
Current repository documentation
        --------------------------------
                CURRENT MVP
```

The planning documents for later proposals do not override this repository state.

---

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | --- |
| `alb_deletion_protection` | Enable ALB deletion protection. Recommended for production. | `bool` | `false` | no |
| `availability_zone_count` | Number of Availability Zones to use for the workload. | `number` | `2` | no |
| `aws_region` | AWS region where the MVP infrastructure will be deployed. | `string` | `"us-east-1"` | no |
| `backend_container_name` | ECS backend container name. | `string` | `"backend"` | no |
| `backend_container_port` | TCP port exposed by the backend container. | `number` | `8000` | no |
| `backend_cpu_target_utilization` | Target CPU utilization for backend service scaling. | `number` | `60` | no |
| `backend_desired_task_count` | Initial desired number of backend ECS tasks when deployment is enabled. | `number` | `2` | no |
| `backend_health_check_path` | ALB/ECS health check path for the backend. | `string` | `"/health"` | no |
| `backend_image_tag` | Immutable tag of the backend image in the CloudStart ECR repository. | `string` | `"v0.1.0"` | no |
| `backend_max_task_count` | Maximum number of backend ECS tasks. | `number` | `6` | no |
| `backend_memory_target_utilization` | Target memory utilization for backend service scaling. | `number` | `70` | no |
| `backend_min_task_count` | Minimum number of backend ECS tasks. | `number` | `2` | no |
| `backend_task_cpu` | Fargate CPU units for backend tasks. | `number` | `256` | no |
| `backend_task_memory` | Fargate memory in MiB for backend tasks. | `number` | `512` | no |
| `cost_center` | Cost center tag value. | `string` | `"cloudstart-mvp"` | no |
| `db_allocated_storage` | Initial RDS storage in GiB. | `number` | `20` | no |
| `db_backup_retention_period` | Number of days to retain automated RDS backups. | `number` | `7` | no |
| `db_engine_version` | Major PostgreSQL version. | `string` | `"16"` | no |
| `db_instance_class` | RDS instance class. | `string` | `"db.t4g.micro"` | no |
| `db_max_allocated_storage` | Maximum RDS storage autoscaling cap in GiB. | `number` | `100` | no |
| `db_name` | Initial RDS database name. | `string` | `"cloudstart"` | no |
| `db_username` | RDS master username. The password is managed by RDS/Secrets Manager. | `string` | `"cloudstart_admin"` | no |
| `deploy_application` | Whether ECS services should run application tasks. Set true after the frontend/backend images have been pushed to ECR. | `bool` | `false` | no |
| `environment` | Deployment environment. | `string` | `"dev"` | no |
| `frontend_container_name` | ECS frontend container name. | `string` | `"frontend"` | no |
| `frontend_cpu_target_utilization` | Target CPU utilization for frontend service scaling. | `number` | `60` | no |
| `frontend_desired_task_count` | Initial desired number of frontend ECS tasks when deployment is enabled. | `number` | `2` | no |
| `frontend_health_check_path` | ALB/ECS health check path for the frontend. | `string` | `"/health"` | no |
| `frontend_image_tag` | Immutable tag of the frontend image in the CloudStart ECR repository. | `string` | `"v0.1.0"` | no |
| `frontend_max_task_count` | Maximum number of frontend ECS tasks. | `number` | `6` | no |
| `frontend_memory_target_utilization` | Target memory utilization for frontend service scaling. | `number` | `70` | no |
| `frontend_min_task_count` | Minimum number of frontend ECS tasks. | `number` | `2` | no |
| `frontend_task_cpu` | Fargate CPU units for frontend tasks. | `number` | `256` | no |
| `frontend_task_memory` | Fargate memory in MiB for frontend tasks. | `number` | `512` | no |
| `grafana_admin_password` | Initial Grafana administrator password. Required for monitoring deployment and stored in AWS Secrets Manager. | `string` | `null` | no |
| `grafana_container_port` | Grafana HTTP port inside the ECS monitoring task. | `number` | `3000` | no |
| `grafana_image` | Grafana OSS container image. | `string` | `"grafana/grafana:13.2.3"` | no |
| `grafana_zabbix_plugin` | Grafana Zabbix plugin package and pinned plugin version. | `string` | `"alexanderzobnin-zabbix-app@6.8.0"` | no |
| `monitoring_db_allocated_storage` | Initial monitoring RDS storage in GiB. | `number` | `20` | no |
| `monitoring_db_backup_retention_period` | Number of days to retain automated backups for the monitoring database. | `number` | `7` | no |
| `monitoring_db_engine_version` | Major PostgreSQL version for the Zabbix database. | `string` | `"16"` | no |
| `monitoring_db_instance_class` | RDS instance class for the Zabbix database. | `string` | `"db.t4g.micro"` | no |
| `monitoring_db_max_allocated_storage` | Maximum monitoring RDS storage autoscaling cap in GiB. | `number` | `100` | no |
| `monitoring_db_name` | PostgreSQL database name used by Zabbix. | `string` | `"zabbix"` | no |
| `monitoring_db_username` | PostgreSQL username used by Zabbix. | `string` | `"zabbix"` | no |
| `monitoring_desired_count` | Number of ECS monitoring tasks. The stack contains a stateful Zabbix server, so the MVP keeps one task by default. | `number` | `1` | no |
| `monitoring_task_cpu` | Fargate CPU units for the combined Zabbix/Grafana monitoring task. | `number` | `1024` | no |
| `monitoring_task_memory` | Fargate memory in MiB for the combined Zabbix/Grafana monitoring task. | `number` | `2048` | no |
| `monitoring_timezone` | PHP timezone used by the Zabbix web interface. | `string` | `"America/Sao_Paulo"` | no |
| `zabbix_server_image` | Zabbix server PostgreSQL container image. | `string` | `"zabbix/zabbix-server-pgsql:alpine-8.0-latest"` | no |
| `zabbix_web_image` | Zabbix web interface PostgreSQL/Nginx container image. | `string` | `"zabbix/zabbix-web-nginx-pgsql:alpine-8.0-latest"` | no |
| `owner` | Owner tag value. | `string` | `"cloudstart"` | no |
| `project_name` | Short project identifier used in resource names and tags. | `string` | `"cloudstart"` | no |
| `rds_deletion_protection` | Enable RDS deletion protection. Recommended for production. | `bool` | `false` | no |
| `repository_name` | Repository name used for tagging. | `string` | `"NOVA"` | no |
| `vpc_cidr` | Primary IPv4 CIDR block for the VPC. | `string` | `"10.20.0.0/16"` | no |

## Outputs

| Name | Description | Sensitive |
| --- | --- | :---: |
| `alb_dns_name` | Public DNS name of the Application Load Balancer. | no |
| `aws_account_id` | AWS account ID used for the deployment. | no |
| `aws_region` | AWS region used for the deployment. | no |
| `backend_ecs_service_name` | ECS backend service name. | no |
| `backend_ecr_repository_url` | ECR repository URL for backend images. | no |
| `backend_task_definition_arn` | Current backend ECS task definition ARN. | no |
| `frontend_ecs_service_name` | ECS frontend service name. | no |
| `frontend_ecr_repository_url` | ECR repository URL for frontend images. | no |
| `frontend_task_definition_arn` | Current frontend ECS task definition ARN. | no |
| `private_app_subnet_ids` | Private application subnet IDs by Availability Zone. | no |
| `private_db_subnet_ids` | Private database subnet IDs by Availability Zone. | no |
| `public_subnet_ids` | Public subnet IDs by Availability Zone. | no |
| `grafana_url` | Grafana URL exposed through the current public ALB listener. | no |
| `monitoring_ecs_service_name` | ECS monitoring service name hosting Zabbix server, Zabbix web, and Grafana. | no |
| `monitoring_rds_endpoint` | Private RDS endpoint used by the Zabbix monitoring database. | no |
| `rds_endpoint` | RDS connection endpoint hostname and port. | no |
| `rds_master_user_secret_arn` | Secrets Manager ARN containing the RDS-managed master password. | yes |
| `rds_master_username` | RDS master username. | no |
| `rds_port` | RDS PostgreSQL listener port. | no |
| `vpc_id` | ID of the CloudStart VPC. | no |

<!-- END_TF_DOCS -->
