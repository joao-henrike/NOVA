# CloudStart — CI/CD

This document describes the CI and CD workflows currently committed in `.github/workflows/`.

## Workflow inventory

```text
.github/workflows/ci.yml
.github/workflows/extreme-validation.yml
.github/workflows/deploy-dev.yml
.github/workflows/rebuild-dev.yml
```

The standard CI is the fast blocking gate. `extreme-validation.yml` is the full-system evidence gate. `deploy-dev.yml` performs non-destructive application delivery, while `rebuild-dev.yml` is an explicitly confirmed destructive infrastructure rebuild.

Legacy `container-ci.yml` and `terraform-lint.yml` workflows were removed so there is a single standard CI source of truth.

## CI

`ci.yml` runs on pushes to `main` and `Joao`, pull requests targeting either branch, and manual dispatch.

All third-party GitHub Actions used by the pipeline are pinned to full commit SHAs.

### Backend quality gate

The backend job starts PostgreSQL 16 as an isolated GitHub Actions service and executes:

```text
pip check
python -m compileall
Ruff
Mypy
Bandit
pip-audit
Alembic upgrade head
alembic check
Alembic downgrade base/upgrade head
alembic check
Pytest
```

The migration gate applies the full chain, checks model/migration drift, rolls the database to `base`, reapplies `head`, and checks drift again.

### Container gate

The pipeline builds both application images without publishing them.

It validates:

```text
frontend nginx configuration
backend /health runtime
Trivy HIGH/CRITICAL image vulnerabilities
```

### Compose gate

Both Compose files are parsed with Docker Compose.

### Terraform gate

The root and bootstrap stacks are checked with:

```text
terraform fmt -check
terraform init -backend=false
terraform validate
TFLint
```

### Security gate

The repository is scanned with:

```text
Checkov
Trivy Terraform misconfiguration scan
Trivy container image scan
Gitleaks
ShellCheck
CodeQL
```

HIGH/CRITICAL infrastructure and image findings are blocking. The CI Terraform Trivy scan uses a runner-generated trusted configuration and a temporary empty ignore file; repository-level Trivy policy is not trusted by this blocking gate.

## Extreme Validation

`extreme-validation.yml` is intentionally broader than the normal CI. It runs a single resilient validation runner so that an early failure does not suppress later diagnostics.

Each check is executed independently and recorded as:

```text
CHECK_NAME    EXIT_CODE
```

The runner continues after failures across these domains:

```text
Backend quality
Frontend image/runtime
Application Compose integration
Monitoring Compose integration
Terraform root + bootstrap
TFLint
Terraform dependency graph and plan-input contract
Repository contract
Secret-pattern checks
GitHub Actions workflow contracts
Shell script syntax
Deployment automation dry-run
Gitleaks
CodeQL
AWS OIDC readiness
Remote Terraform backend access
Live AWS Terraform plan
```

Every check writes its own log under the runner temporary directory. The workflow uploads the collected logs and result table as a GitHub Actions artifact even when the final verdict is failure.

The final verdict is blocking: a single failed check makes the extreme validation workflow fail, but the workflow still attempts the remaining independent checks first.

The extreme validation workflow runs on pushes to `Joao` and manual dispatch only; it does not run on pull requests because its job has `id-token: write` for an optional live, read-only AWS plan. Standard CI remains the PR gate. Extreme validation does not destroy or apply AWS infrastructure. Destructive end-to-end reconstruction remains isolated to `rebuild-dev.yml` and requires explicit `REBUILD` confirmation.

## CD — Development

deploy-dev.yml is restricted to branch Joao and the GitHub development Environment. The job is guarded by the presence of the AWS_CD_ROLE_ARN repository variable. TF_STATE_BUCKET is optional because the workflow has a committed development default.

The push trigger is intentionally narrow. It includes application runtime assets, backend source/migrations and Docker build inputs, frontend public assets/Nginx configuration and Docker build inputs, and docker-compose.yml. A change to documentation, Terraform, deployment scripts, or workflow definitions alone does not trigger a push deployment. workflow_dispatch can be used for an explicit manual development deployment.

The sequence is:

```text
Joao app/runtime-artifact push or manual dispatch
      |
      v
Wait for successful standard CI
      |
      v
GitHub OIDC authentication
      |
      v
Provision/reuse runtime and migrator DB secrets
      |
      v
Provision/reuse backend JWT and optional OAuth secret
      |
      v
Build frontend/backend images
      |
      v
Trivy scan + local container smoke
      |
      v
Push immutable full Git-SHA image tags to ECR
      |
      v
Ensure remote S3 state and terraform init
      |
      v
terraform plan + resource allowlist guard
      |
      v
Apply exact plan (register task revisions; hold app services)
      |
      v
Wait for current/zero-count services
      |
      v
DB bootstrap -> Alembic migration -> runtime grants bootstrap
      |
      v
Activate frontend/backend revisions + restore autoscaling capacity
      |
      v
Wait for application/monitoring ECS stability
      |
      v
ALB / API / DB / Grafana smoke tests
```

### AWS authentication and GitHub configuration

The workflow uses GitHub OIDC with id-token: write instead of long-lived AWS access keys. It rejects any AWS account other than 760396521507.

Required repository variable:

```text
AWS_CD_ROLE_ARN
```

Optional repository variables:

```text
TF_STATE_BUCKET       (default: cloudstart-nova-terraform-state-760396521507)
TERRAFORM_AWS_REGION  (default: us-east-1; deploy-dev.yml only)
```

Required GitHub Environment secret for normal CD:

```text
GRAFANA_ADMIN_PASSWORD
```

Optional Google/Apple OAuth secrets are listed in docs/configuration-reference.md. Supply every field for a provider or leave that provider unused. The deployment creates/reuses the backend authentication JSON secret and keeps its JWT signing key stable.

The AWS OIDC role is configured outside this repository. It must be able to verify the account and state bucket, bootstrap missing remote-state resources, provision the three application Secrets Manager entries, and perform the scoped Terraform/ECR/ECS operations. Secret provisioning requires DescribeSecret, GetSecretValue, CreateSecret, and PutSecretValue on the runtime DB, migrator DB, and backend authentication secrets. Do not grant account-wide administrator permissions merely to satisfy the workflow.

## Application deployment safety

The development CD pipeline does not blindly apply every Terraform difference.

It creates a saved plan and allows only the known application/monitoring task definitions and services, frontend/backend autoscaling targets, purpose-specific ECS execution roles/policies, the dedicated no-ingress database-task security group/rules, and the five CloudWatch log groups. It rejects every unlisted resource change and every delete action. The local deploy script and manual rebuild workflow enforce the same explicit allowlist.

During an application release, Terraform registers the new frontend/backend task definitions but does not switch the live service revisions. The deployment paths then perform database bootstrap, Alembic migration, and post-migration runtime grants before calling `scripts/activate-application-services.sh`. The helper updates both ECS services, restores configured desired capacity/autoscaling bounds, waits for all application/monitoring services to stabilize, and verifies that ECS retained the requested task-definition ARNs. During first deployment the frontend/backend services are created at zero tasks and start only after migrations.

Terraform intentionally ignores subsequent ECS service `task_definition` and `desired_count` drift because the release helper is the authority for application activation. Standalone Terraform apply is not the supported method for rolling out new application images.

Migrations must remain backward-compatible with the currently running version while they execute (expand/contract). Add replacement schema first, switch application code only after migration, and remove obsolete schema in a later release.

Infrastructure drift or unrelated infrastructure changes must be resolved through the infrastructure workflow rather than hidden inside an application release.

The root Terraform backend uses S3 state with the S3 lockfile mechanism. The CD workflow therefore does not pass a legacy DynamoDB backend-lock argument.

## Application image identity

Images are tagged with the complete Git commit SHA.

```text
cloudstart-dev-frontend:<commit-sha>
cloudstart-dev-backend:<commit-sha>
```

The ECR repositories are configured with immutable tags.

## Database migrations

Migrations run as one-off private Fargate tasks using separate task definitions and identities:

1. Database bootstrap: uses the RDS master secret only to create/update `cloudstart_runtime` and `cloudstart_migrator`.
2. Alembic: uses only the migrator secret and runs `alembic upgrade head`.
3. Post-migration bootstrap: reapplies DML/sequence grants to new objects.

These tasks use the dedicated `database_tasks` security group, which has no ingress and only HTTPS plus TCP 5432 egress to application RDS. The normal backend task uses only the runtime credential and cannot read `alembic_version` or perform DDL.

## Post-deployment acceptance

The development CD pipeline checks:

```text
/
/api/health
/api/info
/api/health/db
/grafana/api/health
```

It also verifies that `GET /api/items` returns `401 Unauthorized`.

## Production

There is intentionally no automatic production deployment in this implementation.

A future production pipeline should add:

```text
production GitHub Environment
required reviewers
separate AWS role
separate state/account boundary
approval before apply
production smoke tests
rollback procedure
```

The development pipeline must not be reused as an implicit production authorization mechanism.

## Dependency maintenance

Dependabot is configured for:

```text
GitHub Actions
Terraform
bootstrap Terraform
Python / pip
Docker (backend)
Docker (frontend)
```

## Security baseline policy

Checkov is configured by `.checkov.yaml` with explicit, reviewable exceptions for known MVP constraints. These are not a blanket disablement: any check not listed there remains subject to the configured gate.

The current exceptions cover controls tied to:

```text
HTTP-only MVP ALB while ACM/HTTPS is pending
WAF, ALB access logging and deletion protection not yet enabled
RDS Multi-AZ/IAM auth/performance/enhanced monitoring/deletion protection pending
RDS/Secrets Manager KMS CMK and secret rotation pending
S3 logging/replication/KMS/notification controls for the Terraform state MVP
ECR customer-managed KMS encryption pending
CloudWatch log groups use AWS-owned encryption and cost-bounded 7-day dev / 30-day prod retention
VPC Flow Logs pending
development-only public ALB HTTP ingress
```

These exceptions are technical debt and must be removed as the corresponding controls are implemented.

## Latest recorded validation evidence

The following is a timestamped repository-run observation, not a claim about the current live AWS runtime:

| Workflow | Commit | Result | Interpretation |
| --- | --- | --- | --- |
| [NOVA CI](https://github.com/joao-henrike/NOVA/actions/runs/41123601138) | `cdb9a431826bb3440df367381242a9838b4729a5` | Success | All seven CI jobs completed successfully. |
| [NOVA — Extreme Validation](https://github.com/joao-henrike/NOVA/actions/runs/41123600983) | `cdb9a431826bb3440df367381242a9838b4729a5` | Job success; coverage partial | Local checks completed with zero recorded failures, but nine live AWS checks were marked `SKIP`. |

The extreme-validation logs for that run showed `AWS_CD_ROLE_ARN` empty. The OIDC step was therefore skipped, and the workflow did not verify AWS identity, state-bucket access, remote Terraform initialization, or a live AWS plan. The bucket name is present in the tracked `config/dev.env`; the missing role variable was the observed blocker.

**Interpretation rule:** a green workflow conclusion is not proof of complete AWS validation when the workflow summary says `Coverage: PARTIAL` or lists skipped AWS checks. Re-run the workflow after the external OIDC role and GitHub repository variable are configured. Do not infer live infrastructure health from these CI results.
