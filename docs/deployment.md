# CloudStart — Deployment and Operations Guide

> This procedure describes only the deployment paths that the current repository actually supports. The repository now has automated development CD from `Joao` through GitHub Actions. Production deployment remains intentionally manual/gated.

## 1. Prerequisites

For local validation and deployment, use:

| Tool | Requirement |
| --- | --- |
| Git | Required; deployment is restricted to branch Joao. |
| Python | 3.12 or newer. |
| Terraform | 1.16.4 (repository constraint >=1.16.4 and <1.17.0). |
| AWS CLI | v2 recommended; authenticated to account 760396521507 for this development configuration. |
| Docker | Working daemon, Buildx, and Compose plugin. |
| jq | Required by deployment plan guards and scripts. |
| curl | Required for endpoint smoke tests. |
| unzip | Required by the local setup bootstrap. |

Run make setup and make doctor to prepare/check the local toolchain. The bootstrap does not install jq, and make doctor checks it explicitly. Checkov and pip-audit are CI-only tools and are not part of the default local setup.

An AWS identity with permissions to inspect the account, manage the remote-state bootstrap, provision the required Secrets Manager entries, and create/update the Terraform-managed development resources is required for make deploy. GitHub deployment uses the external OIDC role described in docs/ci-cd.md. Neither path stores AWS access keys in the repository.

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

The deployment automation verifies branch `Joao` and the expected AWS account, creates the protected remote-state bucket when it is missing, provisions the restricted database secrets and backend authentication secret, initializes the canonical state key, creates the infrastructure baseline, builds and pushes immutable frontend/backend images, registers new ECS task definitions without switching live frontend/backend services, bootstraps database roles, runs Alembic as the migrator role, reapplies runtime grants, activates the new application task revisions, preserves current running capacity (or uses the configured initial count), restores autoscaling bounds, and waits for ECS stability, and performs ALB/API/database/Grafana smoke tests. The local Makefile deployment and both GitHub workflows use the same provisioning scripts.

The Grafana administrator password is generated locally by `scripts/deploy.sh` on first use and stored under `.deploy/`. This directory is ignored by Git. The database provisioner stores generated runtime/migrator password values only in AWS Secrets Manager; its local `.deploy/db-secret-arns.env` file contains ARNs only. The RDS master password remains managed by RDS and is injected only into the one-off role-bootstrap task.

The backend authentication secret is created once in AWS Secrets Manager. A strong JWT signing key is generated automatically; existing JWT material is preserved on later deploys. Google and Apple OAuth values are optional and can be supplied through matching environment variables locally or as secrets in the GitHub `development` Environment. Configure every field for a provider or leave that provider unused. The provisioner never prints secret values or writes them to the repository.

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

The effective ECS desired/minimum count follows the configured desired/minimum values while `deploy_application = true`; when it is false, frontend/backend desired and minimum counts are zero. The monitoring service remains at one task.

The development release path sets `start_application_services = false` during Terraform apply. That registers new frontend/backend task definitions while leaving existing service revisions untouched; on first deployment, application services remain at zero tasks. After database bootstrap, Alembic migrations, and post-migration runtime grants succeed, `scripts/activate-application-services.sh` switches the two services to the new task revisions and restores configured desired/minimum/maximum capacity.

Terraform intentionally ignores subsequent ECS service `task_definition` and `desired_count` changes because application rollout is coordinated by the deployment helper. Use `make deploy` or the supported GitHub deployment workflow rather than expecting a standalone `terraform apply` to roll out a new application image.

Migrations must remain backward-compatible with the currently running backend during the migration phase (expand/contract: add schema first, switch application code, remove obsolete schema only in a later release). Do not drop or rename a database object still used by the currently active service in the same release that introduces its replacement.

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

The normal deployment path runs `scripts/ensure-terraform-state.sh` automatically. It verifies the AWS account and bucket owner, reuses an existing bucket in the expected region, and creates the protected bootstrap resources only when the bucket is genuinely missing. It refuses to create resources when bucket ownership or access cannot be verified.

For manual recovery, copy the example variable file:

```bash
cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars
```

Set a globally unique bucket name matching `TF_STATE_BUCKET` in `config/dev.env`, then run:

```bash
terraform -chdir=bootstrap init -backend=false
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

After the bucket exists (the deployment script also performs this initialization automatically):

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

Use an immutable tag for a manual recovery build. A full Git commit SHA avoids collisions with immutable ECR tags and follows the same image-identity convention as automated development releases:

```bash
IMAGE_TAG="$(git rev-parse HEAD)"
docker build --pull -t "cloudstart-dev-frontend:$IMAGE_TAG" apps/frontend
docker build --pull -t "cloudstart-dev-backend:$IMAGE_TAG" apps/backend
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

Tag the local images with the immutable ECR repository URLs. Use the exact tag that was used to build each image:

```bash
docker tag "cloudstart-dev-frontend:$IMAGE_TAG" "$(terraform output -raw frontend_ecr_repository_url):$IMAGE_TAG"
docker tag "cloudstart-dev-backend:$IMAGE_TAG" "$(terraform output -raw backend_ecr_repository_url):$IMAGE_TAG"
```

Push:

```bash
docker push "$(terraform output -raw frontend_ecr_repository_url):$IMAGE_TAG"
docker push "$(terraform output -raw backend_ecr_repository_url):$IMAGE_TAG"
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

The committed development baseline uses HTTP. Its base URL is:

```bash
terraform output -raw alb_application_url
```

For an HTTPS deployment, configure both Terraform variables in a protected environment-specific tfvars file before planning:

```hcl
acm_certificate_arn = "arn:aws:acm:<region>:<account-id>:certificate/<certificate-id>"
alb_domain_name     = "app.example.com"
```

The ACM certificate must already be issued in the same region as the ALB and cover `alb_domain_name`. Configure the DNS provider to point that hostname to the ALB DNS name returned by `terraform output -raw alb_dns_name`; DNS records and certificate issuance are intentionally outside this stack.

With both values configured, port 443 serves the frontend, backend API, and Grafana, while port 80 redirects to HTTPS. With both empty, the HTTP-only development listener is retained and port 443 remains closed. The backend sets `AUTH_COOKIE_SECURE=true` when HTTPS is enabled (and always for `prod`); it uses `false` for the HTTP development listener so browser session cookies work in that non-production environment. Hosted OAuth requires registered callback URLs; Apple web sign-in requires HTTPS.

Validate the configured public path:

```bash
APP_URL="$(terraform output -raw alb_application_url)"
curl -i "${APP_URL}"
curl -i "${APP_URL}api/health"
curl -i "${APP_URL}api/health/db"
curl -i "${APP_URL}grafana/"
```

When TLS is enabled, also confirm the port-80 response is HTTP 301 and that the certificate hostname matches `alb_domain_name`.

Expected routing:

```text
/                 -> frontend
/api/health       -> backend
/api/health/db    -> backend -> PostgreSQL connectivity check
/grafana/         -> Grafana
```

This is optional Terraform support only. It does not mean a certificate, DNS record, or HTTPS endpoint has already been provisioned.

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
dev baseline: Single-AZ (multi_az=false)
backup retention (1 day by default)
storage and autoscaling
```

Multi-AZ is a production hardening target, not enabled in the current low-cost dev configuration.

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

The committed development configuration is HTTP-only because its ACM inputs are empty. Terraform can enable HTTPS and redirect HTTP when an already-issued certificate ARN and matching hostname are supplied; certificate issuance, DNS, and domain validation remain operator-managed.

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
  cloudstart/terraform.tfstate
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
GRAFANA_ADMIN_PASSWORD secret (for normal application CD)
```

Optional provider secrets in the same GitHub Environment are `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REDIRECT_URI`, `APPLE_CLIENT_ID`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`, and `APPLE_REDIRECT_URI`. Configure all fields for a provider or leave that provider unused. `TF_STATE_BUCKET` may be set as a repository variable; otherwise the workflow uses the development bucket name in the repository. The OIDC role must be allowed to create the state bucket/bootstrap resources when missing and to create/read/update the three database and backend-auth Secrets Manager secrets.

The workflow generates a temporary Grafana administrator password during the rebuild and passes it to Terraform as a sensitive variable. The generated value is stored by the application stack in AWS Secrets Manager and is not printed into the workflow logs.

## 21. Automated development CD

Pushes to the `Joao` branch that change application code trigger `.github/workflows/deploy-dev.yml`.

Before enabling the deployment job, configure `AWS_CD_ROLE_ARN` as a repository variable and `GRAFANA_ADMIN_PASSWORD` as a secret in the `development` GitHub Environment. `TF_STATE_BUCKET` is optional because the workflow has a committed development default. Optional Google/Apple provider secrets are listed in the rebuild section above. The CD workflow passes `config/dev.tfvars` and explicit activation overrides to Terraform.

AWS authentication uses GitHub OIDC. The CD workflow rejects an AWS account other than `760396521507`.

The extreme validation workflow that performs live AWS checks is not triggered by pull requests; it runs only on the `Joao` branch (push or manual dispatch). This keeps the job-level OIDC permission away from untrusted PR execution contexts. CI remains the mandatory PR validation path.

The workflow applies only a previously generated Terraform plan whose non-no-op resources are within the explicit application delivery allowlist: frontend/backend/monitoring task definitions and services, frontend/backend autoscaling targets, dedicated ECS execution roles and policies, the no-ingress database-task security group and its rules, and the five workload CloudWatch log groups. Any unlisted resource change or destructive action stops the release.

The workflow provisions/reuses the runtime, migrator, and backend JWT/OAuth Secrets Manager values before planning. The AWS CD role therefore needs `secretsmanager:DescribeSecret`, `GetSecretValue`, `CreateSecret`, and `PutSecretValue` scoped to those three development secrets. Existing JWT signing material is preserved; supplied non-empty OAuth fields are merged without deleting saved values.

All ECS task stdout/stderr is sent to CloudWatch Logs through Terraform-managed groups. Retention is 7 days in development and 30 days in production; each ECS execution role can create streams and write events only to its workload's group.

After ECS activation it runs three private Fargate tasks in order: database role bootstrap (master login), Alembic migrations (migrator login), then database role bootstrap again (to grant runtime DML access on all post-migration objects). Those one-off tasks use a dedicated no-ingress security group, have no ECS task role (and therefore receive no task-role AWS credentials), and allow only PostgreSQL and HTTPS egress. Their execution roles are limited to image pulls, their own logs, and the exact startup secrets required by each task. The normal HTTP backend task receives only the runtime login. The CD plan guard allows only the application/database/monitoring task definitions and services, their dedicated execution policies, the database-task network rules, and the CloudWatch log groups; unrelated changes and all deletes still fail the guard.

Development deploy and rebuild workflows share one non-cancelling concurrency group so Terraform destroy/apply and secret provisioning cannot overlap.

No production deployment is implied by this development workflow.
