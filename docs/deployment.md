# CloudStart — Deployment and Operations Guide

> This procedure describes only the deployment paths that the current repository actually supports. The repository now has automated development CD from `Joao` through GitHub Actions. Production deployment remains intentionally manual/gated.

## 1. Prerequisites

Required locally:

```text
Terraform 1.16.4
AWS CLI
Docker
Docker Compose
```

An AWS identity with permissions to create the Terraform-managed resources is required for local Terraform apply operations.

## 2. Repository defaults

The development environment now has repository-owned non-sensitive configuration:

```text
config/dev.tfvars
config/dev.env
```

For a fresh development deployment, the preferred command is:

```bash
make deploy
```

The deployment automation verifies branch `Joao` and the expected AWS account, initializes the dedicated state key, creates the full infrastructure baseline, builds and pushes immutable frontend/backend images, activates ECS, runs migrations, waits for all ECS services, and performs ALB/API/database/Grafana smoke tests.

The Grafana administrator password is generated locally by `scripts/deploy.sh` on first use and stored under `.deploy/`. This directory is ignored by Git. AWS RDS master passwords remain managed by RDS and Secrets Manager.

The automation does not authenticate GitHub or store GitHub credentials.


Unless overridden through Terraform variables or a `.tfvars` file, the current defaults include:

```text
project_name              = cloudstart
environment               = dev
aws_region                = us-east-1
availability_zone_count   = 2
vpc_cidr                  = 10.20.0.0/16
deploy_application        = false

The committed `config/dev.tfvars` keeps this safe Terraform baseline. `make deploy` temporarily overrides it only after ECR repositories exist and the new application images are available.
frontend_image_tag        = v0.1.1
backend_image_tag         = v0.1.0
frontend_desired_count    = 2
backend_desired_count     = 2
frontend_min_count        = 2
backend_min_count         = 2
frontend_max_count        = 6
backend_max_count         = 6
db_engine_version          = 16
db_instance_class          = db.t4g.micro
db_backup_retention         = 1 day
monitoring_db_backup_retention = 1 day
```

The effective ECS desired/minimum count follows the configured desired/minimum values while `deploy_application = true`.

## 3. Local application validation

Start the local stack:

```bash
docker compose up --build
```

Access:

```text
Frontend: http://localhost:8080
Backend docs: http://localhost:8000/docs
Backend health: http://localhost:8000/health
Database: localhost:5432
```

The local topology is:

```text
Frontend/Nginx :8080
       |
       +--> /api -> backend:8000
                     |
                     +--> postgres:5432
```

Stop it with:

```bash
docker compose down
```

Persistent local PostgreSQL data is stored in the Compose volume `postgres_data`.

## 4. Local teardown and resource audit

The project now provides a local CLI/Makefile path for teardown; it is not a GitHub Actions workflow.

For a read-only inventory of the current AWS identity, CloudStart development resources, and local Compose stacks:

```bash
make inventory-cloud
```

To run the destructive first-pass cleanup:

```bash
make destroy-all
```

The command checks the AWS account against `config/dev.env`, requires the exact confirmation phrase for the account and region, and then:

- Captures an inventory before cleanup.
- Runs `terraform destroy` independently for the canonical state and any legacy keys listed in `config/dev.env`, continuing to the next state if one fails.
- Stops the local application and monitoring Compose stacks, including their local named volumes.
- Removes local `cloudstart/frontend` and `cloudstart/backend` images created by this project.
- Captures an independent AWS inventory afterwards and writes per-step results.
- If (and only if) every step succeeded and the post-scan is clean, hides the current empty state objects with S3 delete markers. Previous S3 object versions remain available for recovery.

Reports are saved under `.deploy/destroy-all-<UTC timestamp>/` and include `inventory-before.txt`, `inventory-after.txt`, `results.tsv`, and the detailed command log. The script exits nonzero if a command failed or the final scan still finds project-scoped resources; do not treat a nonzero exit as a clean teardown.

**Important limitation of this first pass:** resources outside the known Terraform states are reported rather than deleted directly through arbitrary AWS service APIs. If the post-scan lists any resource, the teardown is incomplete and the report contains its identifier. The remote Terraform S3 bucket and bootstrap lock table are preserved so the project can continue to use its deployment backend. The current state-key pointers are only hidden after a confirmed clean inventory; historical versions are not purged.

## 5. Terraform formatting and validation

Root stack:

```bash
terraform fmt -recursive
terraform init -backend=false -input=false
terraform validate
```

Bootstrap stack:

```bash
terraform -chdir=bootstrap init -backend=false -input=false
terraform -chdir=bootstrap validate
```

The standard CI workflow performs these static validation steps automatically for matching changes. The separate `extreme-validation.yml` workflow performs a broader full-system validation with independent checks and preserved evidence.

## 6. Bootstrap the remote state

Create a local bootstrap variable file from the example:

```bash
cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars
```

Set a globally unique S3 bucket name in `bootstrap/terraform.tfvars`.

Then:

```bash
terraform -chdir=bootstrap init
terraform -chdir=bootstrap validate
terraform -chdir=bootstrap plan
terraform -chdir=bootstrap apply
```

The bootstrap creates:

```text
S3 bucket for root Terraform state
DynamoDB table for state-lock compatibility
```

The bootstrap stack uses local state by design.

## 7. Initialize the root backend

After the bootstrap succeeds:

```bash
terraform init \
  -backend-config="bucket=$(terraform -chdir=bootstrap output -raw state_bucket_name)" \
  -backend-config="region=$(terraform -chdir=bootstrap output -raw region)" \
  -reconfigure
```

The root backend uses the canonical development state key:

```text
cloudstart/dev/terraform.tfstate
```

It enables:

```hcl
use_lockfile = true
encrypt      = true
```

## 8. Plan the root infrastructure

Before application deployment:

```bash
terraform plan
```

The plan should declare the infrastructure and application control plane, while the ECS services remain configured for zero running tasks because `deploy_application` is false in the committed baseline. The one-command deployment overrides this only after the ECR/image phase.

## 9. Apply the infrastructure baseline

```bash
terraform apply
```

This creates the infrastructure declared by the root stack, including:

```text
VPC
Subnets
Routes
IGW
NAT gateways/EIPs
Security groups
ECR repositories
ECS cluster
ALB/target groups/listener/rule
RDS PostgreSQL
IAM roles/policy
Zabbix/Grafana monitoring task + monitoring RDS + Grafana ALB route
```

## 10. Build the application images

Build the same images used by the repository's Container CI:

### Frontend

```bash
docker build -t cloudstart/frontend:v0.1.0 apps/frontend
```

### Backend

```bash
docker build -t cloudstart/backend:v0.1.0 apps/backend
```

The development CD workflow builds, scans, and publishes application images automatically. The manual commands below remain useful for local/operator recovery.

## 11. Authenticate Docker to ECR

After obtaining the repository URLs from Terraform outputs, authenticate Docker to the target ECR registry using the AWS CLI.

Typical command pattern:

```bash
aws ecr get-login-password --region <region> \
  | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
```

This command pattern is an operational procedure; the repository does not hardcode a live AWS account ID.

## 12. Tag and push images

Tag the local images with the immutable ECR repository URLs:

```bash
docker tag cloudstart/frontend:v0.1.0 <frontend_ecr_repository_url>:v0.1.0
docker tag cloudstart/backend:v0.1.0 <backend_ecr_repository_url>:v0.1.0
```

Push:

```bash
docker push <frontend_ecr_repository_url>:v0.1.0
docker push <backend_ecr_repository_url>:v0.1.0
```

The current ECR repositories reject tag mutation because they are configured with immutable tags.

## 13. Enable the ECS application

Set:

```hcl
deploy_application = true
frontend_image_tag   = "v0.1.0"
backend_image_tag    = "v0.1.0"
```

This can be placed in a local environment-specific `terraform.tfvars` file.

Then run:

```bash
terraform plan
terraform apply
```

At this point the ECS desired/minimum counts become the configured non-zero values, defaulting to two tasks for each service.

## 14. Validate the ALB path

Get the ALB DNS output:

```bash
terraform output -raw alb_dns_name
```

The current public listener is HTTP (development MVP only):

```bash
ALB_DNS="$(terraform output -raw alb_dns_name)"
curl -i "http://${ALB_DNS}/"
curl -i "http://${ALB_DNS}/api/health"
curl -i "http://${ALB_DNS}/api/health/db"
```

Expected routing:

```text
/                 -> frontend
/api/health       -> backend
/api/health/db    -> backend -> PostgreSQL connectivity check
```

The current implementation does not expose HTTPS on the ALB.

## 15. Operational checks

### ECS

Verify:

```text
service desired count
service running count
task health
task placement across AZs
target-group health
```

### RDS

Verify:

```text
available state
Multi-AZ configuration
backup retention
storage
```

### Zabbix/Grafana

Review:

```text
ALB reachability
frontend /health
backend /api/health
backend /api/health/db
Grafana health
Zabbix server/web health
monitoring PostgreSQL availability
```

## 16. What the current repository does not automate

The following operations are not automatically performed:

```text
Production image publication
Production ECS deployment
Notify alarm recipients
Create a WAF configuration
Create TLS certificates
Perform a production approval workflow
Run a full DR test
Run a restore drill
```

## 17. Safe destroy considerations

The current defaults set:

```text
ALB deletion protection  = false
RDS deletion protection  = false
```

For non-production environments, the RDS resource is configured to skip the final snapshot.

For `prod`, the resource configures a final snapshot identifier.

Before destroying infrastructure, inspect:

```bash
terraform plan
```

For production, explicitly review backup and deletion-protection implications before applying destructive changes.

## 18. Bootstrap state care

The bootstrap stack's local state is security-sensitive because it describes the remote-state infrastructure.

Do not commit:

```text
bootstrap/terraform.tfvars
local state files
AWS credentials
secret material
```

The repository `.gitignore` is intended to keep Terraform runtime artifacts and local secret/config files out of Git.

## 19. Current deployment model summary

```text
Developer
   |
   +--> GitHub PR / push
   |       |
   |       +--> NOVA CI
   |
   +--> Development CD on Joao
           |
           +--> Build/scan
           +--> ECR
           +--> Terraform application plan/apply
           +--> ECS
           +--> migrations
           +--> smoke tests
```

This is the deployment model supported by the current repository. It is intentionally more conservative than a fully automated production CD pipeline.


## Zabbix + Grafana monitoring deployment

The current monitoring plane is deployed as a single ECS/Fargate monitoring task containing Zabbix Server, Zabbix Web, and Grafana, backed by a dedicated PostgreSQL RDS instance.

Required variable:

```hcl
grafana_admin_password = "at-least-12-characters"
```

The password is persisted in AWS Secrets Manager and injected into the Grafana container at runtime.

After applying Terraform, the `grafana_url` output points to the monitoring UI exposed by the existing ALB:

```text
http://<alb-dns>/grafana/
```

The public ALB listener remains HTTP-only in the current MVP. HTTPS/ACM is still outside the current implementation.

### Local Docker monitoring

The repository also includes a dedicated Docker Compose stack:

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
```

Local endpoints:

```text
Grafana  -> http://localhost:3000/
Zabbix   -> http://localhost:8081/
Zabbix server trapper -> tcp://localhost:10051
```

The local stack uses PostgreSQL as Zabbix's backend and persistent Docker volumes for Zabbix/Grafana state.

### Initial Grafana/Zabbix connection

Grafana includes the Zabbix plugin, but the current MVP does not create Zabbix hosts, items, triggers, or dashboards through Terraform. Those monitoring objects should be created through Zabbix's supported configuration/API workflow after the server is healthy.

Recommended initial host checks are the application endpoints exposed through the ALB:

```text
GET /health
GET /api/health
GET /api/health/db
```

This gives end-to-end coverage of the load balancer, frontend, backend and database path without requiring Kubernetes or host-level agent assumptions.


## 20. Rebuild development directly from GitHub

For a complete development rebuild, use the dedicated GitHub Actions workflow:

```text
Actions
  -> NOVA - Rebuild Development From Scratch
  -> Run workflow
  -> confirmation = REBUILD
```

The workflow runs only through `workflow_dispatch` and is intentionally destructive. A normal push to `Joao` cannot trigger it.

The workflow uses GitHub OIDC for AWS authentication and does not require AWS access keys in the repository.

The rebuild performs:

```text
Checkout Joao
     ↓
Verify AWS account
     ↓
Destroy canonical dev state
     ↓
Destroy legacy state:
  cloudstart/redeploy-2026-10-08/terraform.tfstate
  cloudstart/dev/terraform.tfstate
     ↓
Verify old CloudStart named resources are absent
     ↓
Initialize clean canonical state
     ↓
Terraform create-only plan
     ↓
Apply complete infrastructure baseline
     ↓
Build + push frontend/backend images
     ↓
Activate ECS application
     ↓
Wait for ECS stability
     ↓
Run Alembic migrations
     ↓
ALB/API/DB/Grafana smoke tests
```

The state bucket itself is intentionally retained because it is the Terraform state infrastructure, not part of the ephemeral CloudStart application environment.

Required GitHub configuration:

```text
development environment
AWS_CD_ROLE_ARN variable
```

The workflow generates a temporary Grafana administrator password during the rebuild and passes it to Terraform as a sensitive variable. The generated value is stored by the application stack in AWS Secrets Manager and is not printed into the workflow logs.

## 21. Automated development CD

Pushes to the `Joao` branch that change application code trigger `.github/workflows/deploy-dev.yml`.

Before enabling the deployment job, configure `AWS_CD_ROLE_ARN` and `TF_STATE_BUCKET` as repository variables and configure the `GRAFANA_ADMIN_PASSWORD` secret in the `development` GitHub Environment.

AWS authentication uses GitHub OIDC. The CD workflow rejects an AWS account other than `760396521507`.

The workflow applies only a previously generated Terraform plan whose non-no-op resources are limited to the frontend/backend ECS task definitions and services. Any unrelated resource change or destructive action stops the release.

The pipeline runs Alembic migrations as a one-off private Fargate task and performs ALB smoke tests after the ECS services stabilize.

No production deployment is implied by this development workflow.
