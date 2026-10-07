# CloudStart — AWS Application Infrastructure

[![Terraform](https://img.shields.io/badge/Terraform-1.16.4-7B42BC?logo=terraform)](https://developer.hashicorp.com/terraform)
[![AWS](https://img.shields.io/badge/AWS-ECS%20%7C%20RDS%20%7C%20VPC-FF9900?logo=amazonaws)](https://aws.amazon.com/)
[![Terraform CI](https://github.com/joao-henrike/NOVA/actions/workflows/terraform-lint.yml/badge.svg)](https://github.com/joao-henrike/NOVA/actions/workflows/terraform-lint.yml)
[![Container CI](https://github.com/joao-henrike/NOVA/actions/workflows/container-ci.yml/badge.svg)](https://github.com/joao-henrike/NOVA/actions/workflows/container-ci.yml)

> **Current-state documentation:** this README describes the implementation contained in the `NOVA` repository and the current intended deployment behavior of the `Joao` branch. Planned P2/P3 capabilities are intentionally not presented as implemented architecture.
>
> **Important:** repository/IaC state and live AWS runtime state are different concepts. This README explicitly separates them whenever the distinction matters.

## 1. What this repository is

CloudStart is the AWS application-infrastructure baseline inside the `NOVA` repository.

The current implementation combines a small two-service web application with an AWS foundation built as Terraform and a dedicated monitoring runtime based on Zabbix and Grafana.

The current MVP contains:

* one custom VPC;
* dynamically discovered Availability Zones, two by default;
* public, private application, and private database subnets;
* one NAT Gateway per selected Availability Zone;
* one public Application Load Balancer;
* one ECS cluster using Fargate services;
* one frontend service, one backend service, and one monitoring service;
* two private ECR repositories;
* one private PostgreSQL RDS instance for the application;
* one separate private PostgreSQL RDS instance for Zabbix monitoring state/history;
* Zabbix Server, Zabbix Web, and Grafana running as containers in the monitoring ECS task;
* Grafana exposed through the ALB;
* IAM roles for ECS execution and application tasks;
* RDS-managed master passwords through Secrets Manager;
* a Terraform remote-state bootstrap using S3 and a bootstrap locking resource;
* root Terraform backend locking using the S3 lockfile mechanism;
* GitHub Actions for Terraform, IaC, secret, and container validation;
* local Docker Compose development for frontend, backend, and PostgreSQL.

The current MVP does **not** implement:

* financial core;
* double-entry ledger;
* payment orchestration;
* reconciliation engine;
* mobile application;
* Audit Fabric;
* Cost Intelligence / FinOps engine;
* enterprise hybrid integration;
* multi-account landing zone;
* multi-region deployment;
* Kubernetes/EKS;
* service mesh;
* WAF;
* ACM/TLS termination;
* enterprise Zero Trust;
* automated disaster-recovery environment.

Future capabilities remain outside the current implementation boundary.

---

## 2. Repository source of truth

The repository follows this model:

```text
GitHub
   |
   | branch: Joao
   v
Terraform / Application Code / Workflows
   |
   v
AWS
```

The primary working branch for this cycle is:

```text
Joao
```

Never use `main` as the direct implementation branch for these changes.

Before modifying anything:

```bash
git branch --show-current
git status --short --branch
```

Expected:

```text
Joao
```

---

## 3. Current implementation state

There are three states that must remain distinct.

| State               | Meaning                                                                           |
| ------------------- | --------------------------------------------------------------------------------- |
| Terraform/IaC       | What the repository declares Terraform should create/configure.                   |
| Container artifacts | What application images have been built and published to ECR.                     |
| AWS runtime         | What is actually running and healthy in the target AWS account at a given moment. |

A successful:

```bash
terraform apply
```

does **not** by itself prove that the application is healthy.

Likewise, a successful Docker build does not prove that the image is available in ECR or that ECS is running it.

The operational acceptance model is:

```text
IaC valid
+
Infrastructure provisioned
+
Images available
+
ECS tasks running
+
ALB targets healthy
+
Application endpoints healthy
+
RDS healthy
+
Monitoring healthy
+
Security reviewed
```

---

## 4. Current `Joao` branch deployment defaults

The `Joao` branch was updated so the application is enabled by default once its images have been published.

Current intended values:

```hcl
deploy_application = true
frontend_image_tag = "v0.1.1"
backend_image_tag  = "v0.1.0"
```

Initial desired task counts:

```text
Frontend = 2
Backend  = 2
```

Default autoscaling range:

```text
Frontend: min 2 / desired 2 / max 6
Backend:  min 2 / desired 2 / max 6
```

Target tracking defaults:

```text
CPU:
  60%

Memory:
  70%
```

The previous invalid memory defaults of `10` were removed. The Terraform variable validation allows:

```text
20 <= target <= 90
```

Temporary `TF_VAR_*` overrides used during recovery must not be treated as permanent repository configuration.

---

## 5. Application image versions

The current application image versions are intentionally different because the frontend required an AWS-specific Nginx correction.

```text
Frontend:
v0.1.1

Backend:
v0.1.0
```

The frontend `v0.1.1` image contains the corrected AWS-facing Nginx configuration and no longer depends on the Docker Compose service name:

```text
backend:8000
```

inside the production image.

The backend remains on:

```text
v0.1.0
```

until a new backend release is intentionally created.

---

## 6. Architecture at a glance

```text
                           INTERNET
                              |
                              | HTTP :80
                              v
                    +----------------------+
                    | Application Load     |
                    | Balancer             |
                    +----------+-----------+
                               |
                +--------------+--------------+
                |                             |
              /api*                           /
                |                             |
                v                             v
       +------------------+          +------------------+
       | Backend ECS      |          | Frontend ECS     |
       | Fargate          |          | Fargate          |
       | :8000            |          | :80              |
       +--------+---------+          +------------------+
                |
                | TCP :5432
                v
       +----------------------+
       | Application RDS      |
       | PostgreSQL 16       |
       +----------------------+


                MONITORING PLANE

                    ALB /grafana/*
                         |
                         v
              +----------------------+
              | Monitoring ECS Task  |
              | Fargate              |
              |                      |
              | Zabbix Server        |
              | Zabbix Web           |
              | Grafana              |
              +----------+-----------+
                         |
                         | TCP :5432
                         v
              +----------------------+
              | Monitoring RDS       |
              | PostgreSQL 16       |
              +----------------------+
```

Frontend, backend, and monitoring workloads run in private application subnets.

The Application Load Balancer and NAT Gateways are placed in public subnets.

RDS instances are placed in private database subnets.

---

## 7. Request flow

The current public HTTP entry point is the ALB.

```text
Client
  |
  | HTTP :80
  v
Application Load Balancer
  |
  +---- /api
  |       |
  |       v
  |   Backend Target Group
  |       |
  |       v
  |   Backend :8000
  |
  +---- /api/*
  |       |
  |       v
  |   Backend Target Group
  |
  +---- all other paths
  |       |
  |       v
  |   Frontend Target Group
  |       |
  |       v
  |   Frontend :80
  |
  +---- /grafana/*
          |
          v
      Grafana Target Group
          |
          v
       Grafana :3000
```

The ALB has a default action for the frontend.

A dedicated listener rule forwards:

```text
/api
/api/*
```

to the backend target group.

Grafana is exposed through:

```text
/grafana/
```

and:

```text
/grafana/*
```

---

## 8. Frontend AWS architecture

The frontend is an independent ECS/Fargate service.

Current production image:

```text
cloudstart-dev-frontend:v0.1.1
```

Current base image:

```text
nginx:1.29-alpine
```

The AWS production Nginx configuration is responsible for:

* serving the static application;
* SPA fallback;
* `/health` endpoint;
* no dependency on Docker Compose DNS names.

The production image must **not** use:

```nginx
proxy_pass http://backend:8000;
```

because frontend and backend are separate ECS services.

The frontend browser calls:

```text
/api/health
```

and the ALB routes that request directly to the backend service.

### Frontend health

ECS has an explicit container health check against:

```text
/health
```

The ALB target group also checks:

```text
/health
```

---

## 9. Frontend local-development topology

Local Docker Compose uses a separate configuration:

```text
apps/frontend/nginx.local.conf
```

This configuration can resolve:

```text
backend
```

through Docker Compose service discovery.

Therefore:

```text
AWS:
Frontend -> browser -> ALB -> Backend

Local Compose:
Frontend container -> backend:8000
```

The two topologies are intentionally different.

This separation prevents AWS ECS from depending on a DNS name that only exists inside Docker Compose.

---

## 10. Backend architecture

The backend is an independent ECS/Fargate service.

Current production image:

```text
cloudstart-dev-backend:v0.1.0
```

Current base image:

```text
python:3.12-slim
```

The backend uses FastAPI and Uvicorn.

The current application exposes health/information endpoints including:

```text
GET /health
GET /api/health
GET /api/info
GET /api/health/db
```

The backend listens on:

```text
8000/TCP
```

### Backend container

The Dockerfile creates a dedicated non-root application user:

```text
appuser
UID 10001
```

The application code is owned by that user.

The ECS task definition contains an explicit container health check.

The ALB target group checks:

```text
/health
```

---

## 11. Backend database flow

The backend receives:

```text
APP_ENV
DB_HOST
DB_PORT
DB_NAME
DB_USER
```

through ECS environment variables.

The database password is injected from Secrets Manager:

```text
DB_PASSWORD
```

The application does not contain the database password in source code.

Database flow:

```text
Backend ECS
    |
    | TCP :5432
    v
Application RDS
```

The frontend never connects directly to RDS.

---

## 12. Network architecture

### 12.1 VPC

Default:

```text
Region:
us-east-1

VPC:
10.20.0.0/16
```

The VPC is dedicated to the CloudStart environment.

Availability Zones are discovered dynamically.

Default:

```text
2 AZs
```

The implementation requires sufficient AZ availability and derives subnets from the VPC CIDR.

---

## 13. Subnet model

The current network is divided into three tiers.

| Tier        | Purpose            | Internet routing          |
| ----------- | ------------------ | ------------------------- |
| Public      | ALB + NAT Gateways | Internet Gateway          |
| Private App | ECS workloads      | NAT Gateway               |
| Private DB  | RDS                | No default internet route |

Default CIDRs for two AZs:

```text
Public:
10.20.0.0/24
10.20.1.0/24

Private App:
10.20.10.0/24
10.20.11.0/24

Private DB:
10.20.20.0/24
10.20.21.0/24
```

---

## 14. Internet Gateway and NAT

The VPC has one Internet Gateway.

Public subnet routing:

```text
0.0.0.0/0
    |
    v
Internet Gateway
```

One NAT Gateway is created per selected AZ.

Private application routing follows:

```text
Private App AZ-A
       |
       v
NAT Gateway AZ-A
       |
       v
Internet Gateway

Private App AZ-B
       |
       v
NAT Gateway AZ-B
       |
       v
Internet Gateway
```

The database subnets intentionally do not receive a default route to the Internet.

This means the audit finding that claimed no NAT default routes existed was a false positive caused by the auditor's route parsing.

---

## 15. Security groups

The current network isolation uses dedicated security groups for:

```text
ALB
Frontend
Backend
Application RDS
Monitoring
Monitoring RDS
```

The important data path is:

```text
Internet
   |
   v
ALB
   |
   +----> Frontend
   |
   +----> Backend
             |
             v
        Application RDS
```

Monitoring follows:

```text
ALB
 |
 +----> Grafana
           |
Monitoring stack
           |
           v
      Monitoring RDS
```

RDS is not intended to be publicly accessible.

The audit correctly confirmed the current RDS instances as:

```text
PubliclyAccessible = false
```

---

## 16. Public ingress

The ALB is intentionally:

```text
internet-facing
```

and therefore a public ingress rule on the ALB security group is expected.

This is not itself a security defect.

The security requirement is that the public exposure terminate at the ALB rather than exposing:

```text
5432
8000
3000
10051
```

directly to the Internet.

---

## 17. HTTPS status

The current ALB exposes:

```text
HTTP :80
```

There is currently no:

```text
HTTPS :443
ACM certificate
TLS listener
```

Therefore the current public path is:

```text
HTTP only
```

This is a known hardening gap and a planned next security step.

The application should not be considered production-hardened until TLS termination has been implemented and validated.

---

## 18. ECS architecture

The cluster is:

```text
cloudstart-dev-cluster
```

Services:

```text
cloudstart-dev-frontend
cloudstart-dev-backend
cloudstart-dev-monitoring
```

Frontend and backend:

```text
Launch:
Fargate

Network:
awsvpc

Public IP:
disabled
```

The services use deployment protection:

```text
minimum healthy percent = 100
maximum percent = 200
health check grace = 60 seconds
circuit breaker = enabled
rollback = enabled
```

---

## 19. ECS task counts and autoscaling

Frontend defaults:

```text
Desired = 2
Minimum = 2
Maximum = 6
```

Backend defaults:

```text
Desired = 2
Minimum = 2
Maximum = 6
```

Autoscaling uses target tracking for:

```text
CPU
Memory
```

Targets:

```text
CPU = 60%
Memory = 70%
```

Terraform deliberately ignores ECS `desired_count` changes after the service has been created so Application Auto Scaling can control the runtime count.

---

## 20. Monitoring architecture

The monitoring service runs as one stateful ECS service.

The monitoring task contains:

```text
Zabbix Server
Zabbix Web
Grafana
```

The monitoring service has:

```text
Desired = 1
```

because the current MVP keeps the Zabbix Server stateful inside the monitoring task.

### Monitoring images

Current Zabbix images:

```text
zabbix/zabbix-server-pgsql:alpine-7.4-latest
zabbix/zabbix-web-nginx-pgsql:alpine-7.4-latest
```

Grafana:

```text
grafana/grafana:13.2.3
```

The previous `8.0` image references were invalid and caused:

```text
CannotPullContainerError
manifest unknown
```

They were replaced with the working `7.4` image family.

---

## 21. Grafana

Grafana listens on:

```text
3000/TCP
```

Grafana is reached externally through:

```text
/grafana/
```

The monitoring stack uses the Zabbix Grafana plugin.

Current pinned plugin reference:

```text
alexanderzobnin-zabbix-app@6.8.0
```

Grafana is not intended to become a public standalone service.

Its public access path is:

```text
Internet
   |
   v
ALB
   |
   | /grafana/*
   v
Grafana Target Group
   |
   v
Monitoring Task
```

---

## 22. Monitoring runtime health status

The monitoring infrastructure is provisioned, but runtime health must be verified independently.

A previous audit observed:

```text
Grafana target:
unhealthy

Reason:
Target.Timeout
```

ECS also replaced monitoring tasks after unhealthy status.

Therefore monitoring must be considered:

```text
Provisioned
```

but not automatically:

```text
Healthy
```

until the following are confirmed:

```text
[ ] monitoring task running
[ ] Grafana process healthy
[ ] port 3000 reachable from ALB
[ ] Grafana target healthy
[ ] /grafana/ responds correctly
[ ] Zabbix Server stable
[ ] Zabbix Web stable
[ ] Monitoring RDS reachable
```

---

## 23. RDS architecture

Two independent PostgreSQL RDS instances exist.

### Application

```text
cloudstart-dev-db
```

### Monitoring

```text
cloudstart-dev-monitoring-db
```

Both are intended to remain private.

Current observed configuration:

```text
Engine:
PostgreSQL 16

PubliclyAccessible:
false

StorageEncrypted:
true

BackupRetention:
1 day

MultiAZ:
false
```

### Why Multi-AZ is false

The previous design used Multi-AZ, but the actual AWS account applied Free Tier restrictions that prevented the selected RDS configuration.

The environment is currently optimized for the observed Free Tier constraints rather than maximum production resilience.

This must not be documented as a fully resilient production RDS architecture.

---

## 24. RDS backup retention

Current repository defaults:

```text
Application RDS:
1 day

Monitoring RDS:
1 day
```

The previous value:

```text
7 days
```

caused:

```text
FreeTierRestrictionError
```

during instance creation.

The Terraform validation still permits the general RDS range:

```text
1–35 days
```

but the current environment uses:

```text
1 day
```

to remain compatible with the observed account restrictions.

---

## 25. RDS storage and access controls

The current database resources use:

```text
encrypted storage
private subnets
security-group isolation
RDS-managed master password
storage autoscaling
```

The application database is reachable from the backend security boundary.

The monitoring database is reachable from the monitoring security boundary.

RDS is not directly exposed through the public ALB.

---

## 26. Secrets Manager

The current monitoring secret is:

```text
cloudstart-dev/monitoring/grafana-admin
```

RDS master credentials are also managed through AWS/RDS Secrets Manager integration.

The repository must never contain production secret values.

Do not commit:

```text
terraform.tfvars
credentials
tokens
private keys
real passwords
```

Examples such as:

```text
terraform.tfvars.example
```

are documentation artifacts and are not themselves secrets.

---

## 27. ECR architecture

Repositories:

```text
cloudstart-dev-frontend
cloudstart-dev-backend
```

Both are private.

The current repositories use:

```text
image scanning on push
AES256 repository encryption
versioned image tags
lifecycle control
```

Current application artifacts:

```text
Frontend:
v0.1.1

Backend:
v0.1.0
```

---

## 28. ECR release process

Login:

```bash
aws ecr get-login-password --region us-east-1 | \
docker login \
  --username AWS \
  --password-stdin \
  760396521507.dkr.ecr.us-east-1.amazonaws.com
```

Build backend:

```bash
docker build \
  -t cloudstart-dev-backend:v0.1.0 \
  ./apps/backend
```

Build frontend:

```bash
docker build \
  -t cloudstart-dev-frontend:v0.1.1 \
  ./apps/frontend
```

Frontend validation:

```bash
docker run --rm \
  cloudstart-dev-frontend:v0.1.1 \
  nginx -t
```

Tag:

```bash
docker tag \
  cloudstart-dev-backend:v0.1.0 \
  760396521507.dkr.ecr.us-east-1.amazonaws.com/cloudstart-dev-backend:v0.1.0
```

```bash
docker tag \
  cloudstart-dev-frontend:v0.1.1 \
  760396521507.dkr.ecr.us-east-1.amazonaws.com/cloudstart-dev-frontend:v0.1.1
```

Push:

```bash
docker push \
  760396521507.dkr.ecr.us-east-1.amazonaws.com/cloudstart-dev-backend:v0.1.0
```

```bash
docker push \
  760396521507.dkr.ecr.us-east-1.amazonaws.com/cloudstart-dev-frontend:v0.1.1
```

Verify:

```bash
aws ecr describe-images \
  --repository-name cloudstart-dev-frontend \
  --region us-east-1 \
  --output table
```

```bash
aws ecr describe-images \
  --repository-name cloudstart-dev-backend \
  --region us-east-1 \
  --output table
```

---

## 29. Terraform structure

The root Terraform stack is intentionally split by responsibility.

```text
backend.tf
providers.tf
main.tf
locals.tf
variables.tf

vpc.tf
security_groups.tf

ecs.tf
ecs_services.tf

ecr.tf

rds.tf
monitoring.tf

iam.tf
outputs.tf
```

Bootstrap:

```text
bootstrap/
├── backend.tf
├── main.tf
├── outputs.tf
├── providers.tf
├── terraform.tfvars.example
└── variables.tf
```

---

## 30. Terraform remote state

The root backend uses:

```hcl
terraform {
  backend "s3" {
    key          = "cloudstart/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
```

The current state bucket is:

```text
cloudstart-nova-terraform-state-760396521507
```

The bucket is created by the bootstrap architecture.

The root Terraform backend does not use normal Terraform input variables for the bucket because backend configuration is initialized before variable evaluation.

Initialize with:

```bash
terraform init \
  -backend-config="bucket=cloudstart-nova-terraform-state-760396521507" \
  -backend-config="region=us-east-1"
```

Do not type shell commands into an interactive bucket prompt.

If Terraform asks:

```text
bucket
  The name of the S3 bucket
```

stop with:

```text
Ctrl+C
```

and rerun initialization with `-backend-config`.

---

## 31. Remote-state security

The state bucket is expected to use:

```text
versioning
encryption
public access blocking
secure transport enforcement
```

The latest audit confirmed:

```text
Versioning: enabled
Encryption: enabled
SecureTransport policy: present
```

However, the audit also detected that the S3 Public Access Block was not fully configured.

This remains a security task and must be explicitly verified before the environment is considered hardened.

---

## 32. Bootstrap locking compatibility

The bootstrap still provisions the project's locking compatibility resource.

The root backend, however, currently uses:

```text
S3 lockfile
```

The repository's GitHub workflow still contains legacy references to:

```text
TF_STATE_DYNAMODB_TABLE
dynamodb_table=...
```

This creates a configuration-consistency task.

The final design should have one clearly documented locking mechanism.

Until this is reconciled, do not describe the project as having a completely unified remote-state locking design.

---

## 33. IAM architecture

The current ECS identity model separates:

```text
ECS execution role
Frontend task role
Backend task role
Monitoring execution role
Monitoring task role
```

The execution roles are responsible for actions such as:

```text
ECR image retrieval
Secrets Manager secret retrieval
```

Frontend and backend workloads receive separate task identities.

The intended principle is:

```text
Execution permissions
!=
Application permissions
```

and:

```text
Frontend task
!=
Backend task
```

The current audit identified IAM policies that require a deeper least-privilege review.

The auditor's automated rule was too broad to prove that the policies were actually overprivileged, so the policies must be reviewed by `Action`, `Resource`, and `Condition` before changing them.

---

## 34. GitHub Actions

The repository currently contains:

```text
.github/workflows/terraform-lint.yml
.github/workflows/container-ci.yml
```

### Terraform workflow

The workflow validates items such as:

```text
Terraform formatting
Terraform validation
Terraform bootstrap validation
TFLint
Terraform documentation
Checkov
Trivy configuration scanning
Gitleaks
```

The workflow also has an optional credentialed Terraform Plan path.

### Container workflow

The container workflow builds and scans application images and validates Compose configuration.

It currently does not provide a complete:

```text
build
→ push ECR
→ update ECS
→ deploy
```

continuous-delivery pipeline.

---

## 35. CI versus CD

The current repository has strong validation-oriented CI, but the application publication/deployment process is still partly operational.

Current:

```text
GitHub
   |
   v
GitHub Actions
   |
   +--> Terraform validation
   +--> security scanning
   +--> container build
   +--> container scanning
```

Not yet fully automated:

```text
container build
   |
   v
ECR publish
   |
   v
ECS rollout
```

This distinction must remain explicit in architecture and operational documentation.

---

## 36. Local development

The main local application stack uses:

```text
docker-compose.yml
```

Application topology:

```text
Browser
   |
   | :8080
   v
Frontend / Nginx
   |
   | Docker service DNS
   v
Backend / FastAPI
   |
   | :5432
   v
PostgreSQL
```

The application Compose configuration uses a local-specific Nginx configuration:

```text
apps/frontend/nginx.local.conf
```

The AWS image uses:

```text
apps/frontend/nginx.conf
```

The two configurations must remain intentionally different.

---

## 37. Local monitoring

The monitoring stack is maintained separately from the application Compose stack.

Typical local monitoring services are:

```text
Grafana
Zabbix Server
Zabbix Web
Zabbix PostgreSQL
```

The local monitoring plane should not be confused with the AWS production-like monitoring ECS task.

---

## 38. Environment variables and secrets

For AWS Terraform operations, sensitive values may be supplied through environment variables.

Example:

```bash
export TF_VAR_grafana_admin_password='...'
```

Do not print the secret:

```bash
echo "$TF_VAR_grafana_admin_password"
```

Do not put real values into:

```text
terraform.tfvars.example
README.md
GitHub repository
Dockerfile
Docker image layers
audit reports
```

---

## 39. First-time operator setup

The operator needs:

```text
Git
GitHub CLI
AWS CLI
Terraform
Docker
```

Authenticate GitHub as required by the environment.

Then:

```bash
git clone https://github.com/joao-henrike/NOVA.git
cd NOVA
```

Fetch branches:

```bash
git fetch origin
```

Switch:

```bash
git switch --track origin/Joao
```

Verify:

```bash
git branch --show-current
```

Expected:

```text
Joao
```

---

## 40. Terraform initialization from a new environment

After the bootstrap state exists:

```bash
terraform init \
  -backend-config="bucket=cloudstart-nova-terraform-state-760396521507" \
  -backend-config="region=us-east-1"
```

Then:

```bash
terraform fmt -check
```

Then:

```bash
terraform validate
```

Then:

```bash
terraform plan -out=nova-start.tfplan
```

Inspect:

```bash
terraform show -no-color nova-start.tfplan
```

Only after review:

```bash
terraform apply nova-start.tfplan
```

---

## 41. Safe Terraform operating procedure

The normal operating cycle is:

```text
Change
  |
  v
git diff
  |
  v
terraform fmt
  |
  v
terraform validate
  |
  v
terraform plan
  |
  v
Review
  |
  v
terraform apply
  |
  v
AWS validation
  |
  v
Extreme audit
```

Never use:

```bash
terraform apply -auto-approve
```

as the standard review workflow for consequential infrastructure changes.

Never apply an unexpected destructive plan without understanding the cause.

---

## 42. Application deployment procedure

### Step 1 — Verify branch

```bash
git branch --show-current
```

### Step 2 — Verify ECR

```bash
aws ecr describe-images \
  --repository-name cloudstart-dev-frontend \
  --region us-east-1
```

```bash
aws ecr describe-images \
  --repository-name cloudstart-dev-backend \
  --region us-east-1
```

### Step 3 — Validate Terraform

```bash
terraform fmt -check
terraform validate
```

### Step 4 — Generate plan

```bash
terraform plan -out=nova-start.tfplan
```

### Step 5 — Review

Check:

```text
resource additions
resource changes
resource destroys
ECS task definition image versions
desired counts
autoscaling
```

### Step 6 — Apply

```bash
terraform apply nova-start.tfplan
```

### Step 7 — Validate ECS

```bash
aws ecs describe-services \
  --cluster cloudstart-dev-cluster \
  --services \
    cloudstart-dev-frontend \
    cloudstart-dev-backend \
    cloudstart-dev-monitoring \
  --region us-east-1 \
  --output table
```

### Step 8 — Validate target groups

```bash
aws elbv2 describe-target-health \
  --target-group-arn TARGET_GROUP_ARN \
  --region us-east-1
```

### Step 9 — Validate endpoints

```bash
ALB_DNS="$(terraform output -raw alb_dns_name)"
```

```bash
curl -i --max-time 15 \
  "http://$ALB_DNS/"
```

```bash
curl -i --max-time 15 \
  "http://$ALB_DNS/api/health"
```

```bash
curl -i --max-time 15 \
  "http://$ALB_DNS/api/info"
```

```bash
curl -i --max-time 15 \
  "http://$ALB_DNS/api/health/db"
```

```bash
curl -I --max-time 15 \
  "http://$ALB_DNS/grafana/"
```

---

## 43. ECS troubleshooting

If:

```text
Desired = 0
Running = 0
```

do not immediately investigate ALB.

First verify:

```text
deploy_application
```

and the effective Terraform variables.

If:

```text
Desired > 0
Running = 0
```

inspect task failures.

```bash
aws ecs list-tasks \
  --cluster cloudstart-dev-cluster \
  --service-name cloudstart-dev-frontend \
  --desired-status STOPPED \
  --region us-east-1
```

Then:

```bash
aws ecs describe-tasks \
  --cluster cloudstart-dev-cluster \
  --tasks TASK_ARN \
  --region us-east-1
```

Investigate:

```text
CannotPullContainerError
EssentialContainerExited
ResourceInitializationError
OutOfMemoryError
CannotStartContainerError
```

---

## 44. ECR troubleshooting

If ECS cannot pull an image:

```bash
aws ecr describe-images \
  --repository-name cloudstart-dev-frontend \
  --region us-east-1
```

and:

```bash
aws ecr describe-images \
  --repository-name cloudstart-dev-backend \
  --region us-east-1
```

Verify:

```text
repository exists
image tag exists
ECS task definition uses the same tag
ECS execution role can retrieve ECR image
```

Do not use a mutable `latest` tag as the default release mechanism.

---

## 45. ALB troubleshooting

### HTTP 503

Typical flow:

```text
ALB
 |
 v
Target Group
 |
 +--> no healthy target
```

Check:

```bash
aws elbv2 describe-target-health \
  --target-group-arn TARGET_GROUP_ARN \
  --region us-east-1
```

Then inspect ECS.

Do not modify the ALB routing rules before proving that the targets themselves are available.

### HTTP 504

Typical interpretation:

```text
ALB connected to target
but target did not answer in time
```

For Grafana this currently requires:

```text
Grafana process
port 3000
security group
target health check
task network
```

---

## 46. RDS troubleshooting

Verify status:

```bash
aws rds describe-db-instances \
  --region us-east-1 \
  --query 'DBInstances[?starts_with(DBInstanceIdentifier, `cloudstart-dev`)].{
    Identifier:DBInstanceIdentifier,
    Status:DBInstanceStatus,
    Engine:Engine,
    Version:EngineVersion,
    MultiAZ:MultiAZ,
    Public:PubliclyAccessible,
    Encrypted:StorageEncrypted,
    BackupRetention:BackupRetentionPeriod
  }' \
  --output table
```

Expected current constraints:

```text
available
private
encrypted
backup retention 1
```

For application database health, use:

```text
/api/health/db
```

rather than attempting direct Internet connectivity to PostgreSQL.

---

## 47. Monitoring troubleshooting

Start with ECS:

```bash
aws ecs describe-services \
  --cluster cloudstart-dev-cluster \
  --services cloudstart-dev-monitoring \
  --region us-east-1 \
  --output json
```

Then inspect the monitoring task:

```bash
aws ecs list-tasks \
  --cluster cloudstart-dev-cluster \
  --service-name cloudstart-dev-monitoring \
  --region us-east-1
```

Then:

```bash
aws ecs describe-tasks \
  --cluster cloudstart-dev-cluster \
  --tasks TASK_ARN \
  --region us-east-1
```

Check:

```text
Zabbix Server
Zabbix Web
Grafana
container exit codes
container reasons
ports
network
```

For Grafana target failures:

```text
ALB
  |
  v
Target Group
  |
  v
port 3000
  |
  v
Grafana
```

The historical error observed was:

```text
Target.Timeout
```

which requires runtime diagnosis rather than an arbitrary ALB configuration change.

---

## 48. Git operating procedure

Always begin:

```bash
git status --short --branch
git branch --show-current
```

Review:

```bash
git diff
```

Stage only intentional files:

```bash
git add variables.tf terraform.tfvars.example
```

Review staged changes:

```bash
git diff --cached
```

Commit:

```bash
git commit -m "fix: align NOVA deployment defaults"
```

Update branch:

```bash
git fetch origin
git rebase origin/Joao
```

Push:

```bash
git push origin Joao
```

Never use:

```bash
git add .
```

without reviewing generated files first.

---

## 49. Files that must not be committed

Do not commit:

```text
terraform.tfvars
*.tfstate
*.tfstate.*
*.tfplan
.terraform/
*.backup*
audit-nova-*/
```

The following are allowed and expected:

```text
terraform.tfvars.example
```

---

## 50. Repository quality gates

Before declaring an IaC change ready:

```bash
terraform fmt -check
```

must succeed.

Then:

```bash
terraform validate
```

must succeed.

The branch must be:

```text
Joao
```

The working tree must contain only intentional changes.

The plan must be reviewed for:

```text
unexpected destroy
unexpected replacement
wrong image tag
wrong desired count
wrong region
wrong account
wrong network
wrong security group
```

---

## 51. Extreme audit

The repository contains:

```text
audit-nova-extreme.sh
```

Normal:

```bash
./audit-nova-extreme.sh
```

Deep:

```bash
AUDIT_DEEP=1 ./audit-nova-extreme.sh
```

The audit performs read-only checks against:

```text
Git
Terraform
Docker
ECR
ECS
ALB
Target Groups
VPC
Subnets
Routes
NAT
Security Groups
RDS
Secrets Manager
IAM
Autoscaling
remote state
CI/CD
CloudTrail
GuardDuty
repository patterns
```

The output is written into a timestamped:

```text
audit-nova-extreme-YYYYMMDD-HHMMSS/
```

---

## 52. Audit interpretation rules

Audit findings must not be fixed mechanically.

The process is:

```text
Finding
   |
   v
Evidence
   |
   v
Root cause
   |
   v
Classification
   |
   +--> Real issue
   |
   +--> False positive
   |
   +--> Expected architecture
   |
   +--> Hardening opportunity
   |
   v
Correction
   |
   v
Validation
   |
   v
Re-audit
```

Examples of findings already proven to be false positives:

```text
Frontend ECS health check missing
Backend ECS health check missing
NAT default routes missing
terraform.tfvars.example treated as secret
placeholder password treated as secret
ALB public ingress treated as inherently unsafe
```

The audit script itself therefore requires maintenance.

---

## 53. Current audit findings — status

### Already resolved

```text
[RESOLVED] Frontend ECR repository had no image
[RESOLVED] Backend ECR repository had no image
[RESOLVED] Frontend image v0.1.1 published
[RESOLVED] Backend image v0.1.0 published
[RESOLVED] RDS backup retention reduced to 1 day
[RESOLVED] RDS Multi-AZ disabled for current Free Tier constraints
[RESOLVED] Zabbix 8.0 image references replaced with 7.4
[RESOLVED] Terraform formatting validation passes
[RESOLVED] Terraform configuration validates
```

### Configured in the `Joao` IaC

```text
[CONFIGURED] deploy_application = true
[CONFIGURED] frontend_image_tag = v0.1.1
[CONFIGURED] backend_image_tag = v0.1.0
[CONFIGURED] frontend/backend memory targets = 70
[CONFIGURED] frontend/backend desired counts = 2
[CONFIGURED] frontend/backend minimum counts = 2
```

### Still pending runtime validation/correction

```text
[PENDING] frontend ECS actually running
[PENDING] backend ECS actually running
[PENDING] frontend target healthy
[PENDING] backend target healthy
[PENDING] Grafana target healthy
[PENDING] Grafana timeout investigation
[PENDING] HTTPS/ACM
[PENDING] state bucket full Public Access Block
[PENDING] IAM least-privilege review
[PENDING] VPC Flow Logs
[PENDING] ALB access logs
[PENDING] CloudTrail
[PENDING] secret rotation strategy
[PENDING] CI lockfile/DynamoDB consistency
[PENDING] container hardening
```

---

## 54. Known live AWS snapshot

The most recent audited environment observed:

```text
Account:
760396521507

Region:
us-east-1

VPC:
vpc-060907935831aae05

VPC CIDR:
10.20.0.0/16

ALB:
cloudstart-dev-alb-1378251204.us-east-1.elb.amazonaws.com

ECS cluster:
cloudstart-dev-cluster

Application RDS:
cloudstart-dev-db

Monitoring RDS:
cloudstart-dev-monitoring-db
```

At that audit moment:

```text
Frontend:
Desired 0
Running 0

Backend:
Desired 0
Running 0

Monitoring:
Desired 1
Running 1
```

This snapshot predates the intended ECS activation change in the current `Joao` IaC and therefore must not be confused with the desired repository state.

The ECR images were subsequently published:

```text
Frontend:
v0.1.1

Backend:
v0.1.0
```

---

## 55. Current known security posture

Implemented:

```text
[OK] RDS private
[OK] RDS encrypted
[OK] ECS tasks without public IP
[OK] Security-group segmentation
[OK] ECR image scanning on push
[OK] Versioned image tags
[OK] Backend non-root container user
[OK] RDS-managed secrets
[OK] Terraform state encryption
[OK] Terraform state versioning
[OK] Secure-transport state policy
[OK] GitHub security validation workflows
```

Not yet hardened:

```text
[TODO] HTTPS
[TODO] ACM
[TODO] full S3 Public Access Block verification
[TODO] IAM least privilege review
[TODO] VPC Flow Logs
[TODO] ALB access logs
[TODO] CloudTrail
[TODO] secret rotation
[TODO] frontend non-root hardening
[TODO] monitoring container hardening
```

---

## 56. AWS root identity rule

The audit session observed:

```text
arn:aws:iam::760396521507:root
```

Using the root principal for routine infrastructure administration is not the desired operational model.

Future AWS operations should use an appropriate administrative identity or role and keep root reserved for tasks that genuinely require the root account.

This is an operational security requirement, not an application component.

---

## 57. Container hardening roadmap

The current backend container already creates an unprivileged user.

The frontend currently still requires review because Nginx is built from an Alpine base image and the audit identified the absence of an explicit non-root runtime declaration.

Future hardening should evaluate:

```text
non-root execution
read-only root filesystem
capability reduction
minimal writable paths
image vulnerability scanning
pinned image digests
```

Changes must be tested against actual runtime behavior.

Do not enable `readonlyRootFilesystem` blindly for stateful workloads.

---

## 58. Observability roadmap

The current runtime provides:

```text
Zabbix
Grafana
```

The next observability/security improvements are:

```text
VPC Flow Logs
ALB access logs
CloudTrail
GuardDuty
```

These services are not automatically implied by the existence of Grafana/Zabbix.

Application metrics and security/audit telemetry are separate concerns.

---

## 59. Cost considerations

The MVP uses:

```text
2 NAT Gateways
2 RDS instances
ECS/Fargate
ALB
ECR
S3
```

The two NAT Gateways and two RDS instances are meaningful cost drivers.

Because the environment is considered ephemeral, operators should explicitly destroy resources that are no longer needed.

However, destruction must be performed through Terraform and only after reviewing the plan.

Never manually delete Terraform-managed infrastructure unless a recovery procedure explicitly requires it.

---

## 60. Destroying an ephemeral environment

Before destruction:

```bash
terraform plan -destroy
```

Review the plan.

Then:

```bash
terraform destroy
```

Confirm that the intended account and region are correct.

After destruction, verify:

```text
ECS services gone
ALB gone
target groups gone
RDS gone
NAT gateways gone
EIPs released
subnets gone
VPC gone
```

Remote state and bootstrap resources may be intentionally retained for future environment recreation.

Do not destroy the remote-state infrastructure accidentally while attempting to destroy an application environment.

---

## 61. Recreating an ephemeral environment

The intended recreation workflow is:

```text
GitHub / Joao
      |
      v
Bootstrap / Remote State
      |
      v
terraform init
      |
      v
terraform validate
      |
      v
ECR repositories
      |
      v
Build + push images
      |
      v
terraform plan
      |
      v
terraform apply
      |
      v
ECS
      |
      v
ALB
      |
      v
RDS
      |
      v
Monitoring
      |
      v
Acceptance tests
      |
      v
Extreme audit
```

The goal of the project is that infrastructure can be reproduced from code rather than relying on manual AWS console configuration.

---

## 62. Release checklist

### Git

```text
[ ] branch = Joao
[ ] working tree reviewed
[ ] no secrets
[ ] no state files
[ ] no plan files
[ ] intended diff only
```

### Terraform

```text
[ ] terraform fmt -check
[ ] terraform validate
[ ] terraform plan
[ ] plan reviewed
[ ] no unexpected destroy
```

### Images

```text
[ ] frontend build succeeds
[ ] backend build succeeds
[ ] frontend health/config test succeeds
[ ] Trivy scan reviewed
[ ] image versioned
[ ] image pushed to ECR
```

### AWS

```text
[ ] correct account
[ ] correct region
[ ] ECS cluster active
[ ] frontend running
[ ] backend running
[ ] monitoring running
[ ] frontend target healthy
[ ] backend target healthy
[ ] Grafana target healthy
[ ] RDS available
```

### Application

```text
[ ] /
[ ] /api/health
[ ] /api/info
[ ] /api/health/db
[ ] /grafana/
```

### Security

```text
[ ] no public RDS
[ ] no public backend
[ ] no public database port
[ ] state bucket protected
[ ] secrets externalized
[ ] IAM reviewed
```

---

## 63. Definition of done

The NOVA MVP must not be considered operationally complete merely because Terraform returns:

```text
Apply complete!
```

The environment is accepted only when:

```text
Terraform
   +
AWS Infrastructure
   +
ECR
   +
ECS
   +
ALB
   +
RDS
   +
Monitoring
   +
Security
   +
Audit
```

have all been independently validated.

Minimum application acceptance:

```text
Frontend:
HTTP 200

Backend:
HTTP 200 /api/health

Database:
HTTP 200 /api/health/db

Monitoring:
Grafana reachable and target healthy

ECS:
running >= desired for stable deployment

ALB:
all required target groups healthy
```

---

## 64. What is intentionally not claimed

This README does **not** claim that the current MVP provides:

```text
High-end production DR
Multi-region failover
Multi-account governance
Enterprise WAF
HTTPS/TLS
Complete SIEM
Complete audit fabric
Full application authentication
Full authorization model
Financial transaction processing
Mobile application
Kubernetes
Enterprise service mesh
Automated CD to production
```

These capabilities require additional design, implementation, testing, and acceptance.

---

## 65. Project operating principle

The project should be operated using the following rule:

```text
Code
  ↓
Validate
  ↓
Plan
  ↓
Review
  ↓
Apply
  ↓
Observe
  ↓
Audit
  ↓
Correct
  ↓
Re-audit
```

Never:

```text
Observe warning
   ↓
blindly change code
```

Always determine:

```text
evidence
→ root cause
→ impact
→ correction
→ validation
```

---

## 66. One-command operational starting point

For an operator returning to the project:

```bash
cd ~/NOVA

git fetch origin
git switch Joao
git pull --ff-only origin Joao

git status --short --branch
terraform validate

terraform plan -out=nova-start.tfplan
```

Then review the plan before:

```bash
terraform apply nova-start.tfplan
```

After deployment:

```bash
terraform output
```

and perform the ECS/ALB/RDS/Monitoring checks documented above.

---

## 67. Architecture summary

The current CloudStart MVP follows this separation:

```text
PUBLIC EDGE
    |
    v
ALB
    |
    +----> Frontend
    |
    +----> Backend
    |
    +----> Grafana

PRIVATE APPLICATION
    |
    +----> Frontend ECS
    +----> Backend ECS
    +----> Monitoring ECS

PRIVATE DATA
    |
    +----> Application RDS
    +----> Monitoring RDS

SUPPORT
    |
    +----> ECR
    +----> IAM
    +----> Secrets Manager
    +----> S3 Remote State

DELIVERY
    |
    +----> GitHub
    +----> GitHub Actions
    +----> Terraform
```

The architectural principle is:

> **Public entry, private workloads, isolated data, separated monitoring, versioned container artifacts, and infrastructure managed as code.**

---

## 68. Current implementation matrix

| Component           | Repository      | Intended AWS state      | Current verification requirement |
| ------------------- | --------------- | ----------------------- | -------------------------------- |
| VPC                 | Implemented     | Provisioned             | Verify                           |
| Public subnets      | Implemented     | Provisioned             | Verify                           |
| Private App subnets | Implemented     | Provisioned             | Verify                           |
| Private DB subnets  | Implemented     | Provisioned             | Verify                           |
| IGW                 | Implemented     | Provisioned             | Verify                           |
| NAT Gateways        | Implemented     | 2                       | Verify                           |
| ALB                 | Implemented     | Public HTTP :80         | Verify                           |
| HTTPS               | Not implemented | N/A                     | Future hardening                 |
| Frontend ECS        | Implemented     | 2 tasks                 | Runtime validation               |
| Backend ECS         | Implemented     | 2 tasks                 | Runtime validation               |
| Monitoring ECS      | Implemented     | 1 task                  | Runtime validation               |
| Application RDS     | Implemented     | Private PostgreSQL 16   | Verify                           |
| Monitoring RDS      | Implemented     | Private PostgreSQL 16   | Verify                           |
| Frontend ECR        | Implemented     | `v0.1.1`                | Verify                           |
| Backend ECR         | Implemented     | `v0.1.0`                | Verify                           |
| Grafana             | Implemented     | Port 3000               | Runtime validation               |
| Zabbix Server       | Implemented     | Private                 | Runtime validation               |
| Zabbix Web          | Implemented     | Private                 | Runtime validation               |
| Secrets Manager     | Implemented     | External secret storage | Verify                           |
| IAM                 | Implemented     | Dedicated roles         | Security review                  |
| S3 remote state     | Implemented     | Enabled                 | Security review                  |
| GitHub Actions      | Implemented     | CI                      | Verify                           |
| Full automatic CD   | Not implemented | N/A                     | Future                           |
| VPC Flow Logs       | Not implemented | N/A                     | Hardening                        |
| ALB access logs     | Not implemented | N/A                     | Hardening                        |
| CloudTrail          | Not implemented | N/A                     | Hardening                        |
| GuardDuty           | Not implemented | N/A                     | Hardening                        |
| WAF                 | Not implemented | N/A                     | Future                           |
| ACM/HTTPS           | Not implemented | N/A                     | Future                           |

---

## 69. Final operational rule

Before touching AWS:

```text
1. Confirm account
2. Confirm region
3. Confirm branch
4. Confirm Git diff
5. Validate Terraform
6. Review plan
7. Apply
8. Validate runtime
9. Audit
10. Commit/push source changes
```

The AWS environment is ephemeral.

The code is not.

Therefore:

> **Every important infrastructure correction must end up documented and versioned in `Joao`, so that the next environment can be recreated from source rather than from memory or manual console changes.**

