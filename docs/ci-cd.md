# CloudStart — CI/CD

This document describes the CI and CD workflows currently committed in `.github/workflows/`.

## Workflow inventory

```text
.github/workflows/ci.yml
.github/workflows/deploy-dev.yml
```

Legacy `container-ci.yml` and `terraform-lint.yml` workflows were removed so there is a single source of truth for validation.

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

## CD — Development

`deploy-dev.yml` is restricted to the `Joao` branch and the GitHub `development` environment. The job is additionally guarded by the presence of `AWS_CD_ROLE_ARN` and `TF_STATE_BUCKET`; when those repository variables are absent, the CD job is skipped.

The sequence is:

```text
Git push to Joao
      |
      v
AWS OIDC authentication
      |
      v
Build frontend/backend images
      |
      v
Trivy scan
      |
      v
Container runtime smoke test
      |
      v
Push immutable SHA-tagged images to ECR
      |
      v
terraform init against remote S3 state
      |
      v
terraform plan
      |
      v
Terraform plan scope guard
      |
      v
terraform apply exact saved plan
      |
      v
wait for ECS services
      |
      v
run Alembic migration task
      |
      v
ALB smoke tests
```

### AWS authentication

The workflow uses GitHub OIDC with `id-token: write` instead of long-lived AWS access keys.

The workflow also requires the AWS account to be exactly:

```text
760396521507
```

Required repository variables:

```text
AWS_CD_ROLE_ARN
TF_STATE_BUCKET
```

Optional repository variable:

```text
TERRAFORM_AWS_REGION
```

Required GitHub Environment secret:

```text
GRAFANA_ADMIN_PASSWORD
```

## Application deployment safety

The development CD pipeline does not blindly apply every Terraform difference.

It creates a saved plan and allows only these resources:

```text
aws_ecs_task_definition.frontend
aws_ecs_task_definition.backend
aws_ecs_service.frontend
aws_ecs_service.backend
aws_appautoscaling_target.frontend
aws_appautoscaling_target.backend
```

Any other resource change or any delete action stops the deployment. This preserves a hard boundary between application release changes and unrelated infrastructure changes.

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

Migrations are executed as a one-off Fargate task using the newly deployed backend task definition:

```bash
alembic upgrade head
```

The migration task uses the private application subnets and backend security group.

## Post-deployment acceptance

The development CD pipeline checks:

```text
/
/api/health
/api/info
/api/health/db
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
VPC Flow Logs pending
development-only public ALB HTTP ingress
```

These exceptions are technical debt and must be removed as the corresponding controls are implemented.