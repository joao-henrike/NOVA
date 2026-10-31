# NOVA Operational Scripts

> Repository-wide documentation: [NOVA documentation index](../docs/README.md) · [Deployment guide](../docs/deployment.md) · [Local development](../docs/local-development.md) · [Security model](../docs/security.md).

This folder contains local setup, validation, deployment, state-bootstrap, secret-provisioning, and CI helper scripts. Read the side-effect classification before running a script.

## Script inventory

| Script | Purpose | Side effects |
| --- | --- | --- |
| `bootstrap-local.sh` | Installs the repository-pinned local toolchain and Python virtual environment. | Local files under `.tools/` and `.venv/`; no AWS resources. |
| `doctor.sh` | Checks local branch/tool availability. | Read-only local checks. |
| `terraform-validate.sh` | Runs root/bootstrap Terraform validation in an isolated temporary workspace. | Temporary files only; no Terraform apply. |
| `wait-for-postgres.sh` | Waits for the local Compose PostgreSQL service. | Reads Compose health/logs; does not create AWS resources. |
| `ensure-terraform-state.sh` | Verifies the AWS identity, expected bucket owner, and remote-state region. Default mode can bootstrap a confirmed-missing bucket; `--verify-only` is read-only and fails if the bucket is missing. | Default mode may create S3/DynamoDB bootstrap resources; `--verify-only` performs AWS reads only. |
| `provision-db-credentials.sh` | Creates or reuses the runtime and migrator Secrets Manager credentials. | Creates/updates secret versions in the configured AWS account; values are not printed. |
| `provision-backend-auth-secret.sh` | Creates or reuses the backend JWT/OAuth JSON secret, preserving the existing signing key. | Creates/updates the configured Secrets Manager secret; values are not printed. |
| `bootstrap-github-oidc-role.sh` | Explicitly provisions the GitHub OIDC provider and least-privilege NOVA development deployment role through the isolated `bootstrap/github-oidc/` Terraform stack. | **Creates/updates IAM identity infrastructure.** Requires an already-authorized AWS identity, exact account confirmation, and the explicit `CREATE_GITHUB_OIDC_ROLE` argument. |
| `test-github-oidc-subject.sh` | Verifies the immutable GitHub owner/repository IDs and OIDC subject format against the repository contract. | Read-only checks. |
| `deploy.sh` | End-to-end development deployment: validates account, prepares state/secrets, plans/applies infrastructure, builds/pushes immutable images, migrates, activates ECS, and smoke-tests. | **State-changing and potentially billable AWS operations.** |
| `activate-application-services.sh` | Switches frontend/backend ECS services to the registered task revisions after migrations and runtime grants succeed, preserves current running capacity (or uses the configured initial count), restores autoscaling bounds, waits for stability, and verifies the active task-definition ARNs. | **Changes ECS task revisions and capacity.** Requires initialized Terraform state and AWS credentials. |
| `destroy-all.sh` | Destroys resources tracked in the configured current/legacy states, stops local Compose stacks, then inventories remaining project resources. | **Destructive.** Requires exact account/region confirmation. Does not directly delete arbitrary untracked leftovers. |
| `run-gitleaks.sh` | Downloads a pinned Gitleaks binary with checksum verification and scans the Git repository. | Local/CI temporary files; no AWS operations. |
| `extreme-checks.sh` | Shared GitHub Actions helper for recording independent validation results and skipped checks. | CI evidence files only; it does not provision AWS. |
| `test-extreme-checks.sh` | Tests that complete, failed, and skipped validation results produce the correct blocking verdict. | Temporary test files only. |
| `nova-ops.sh` | Interactive/read-only AWS status, cost, inventory, and log inspection plus explicitly requested ECS/RDS controls. | Read-only by default; explicit ECS/RDS changes only. Never deletes resources or runs Terraform apply/destroy. |
| `test-nova-ops.sh` | Mock AWS contract tests for account guarding, scaling bounds, monitoring singleton, log validation, and RDS confirmation. | Temporary test files only; no AWS account access. |

The root-level `audit-nova.sh` and `audit-frontend.sh` are separate read-only diagnostic tools and are documented in the [root README](../README.md).

GitHub CD invokes `ensure-terraform-state.sh --verify-only`; the OIDC deployment role cannot create or replace the Terraform state bucket. Prepare the protected state bucket separately before enabling CD. Local `make deploy` retains the default bootstrap mode.

The supported deployment paths intentionally keep new frontend/backend task revisions inactive during Terraform apply. They call `activate-application-services.sh` only after database bootstrap, Alembic upgrade, and post-migration runtime grants have succeeded. Do not run this helper manually before those steps.

## Safe local validation

From the repository root:

```bash
make setup
make doctor
make validate
make tf-validate
make tflint
make test
make smoke
```

These prepare/check local tooling and the Compose application. They do not imply that the live AWS account or remote Terraform state has been verified.

## AWS preflight

Before any AWS state-changing operation:

```bash
git branch --show-current
git status --short --branch
set -a
source config/dev.env
set +a
aws sts get-caller-identity
```

Confirm the account is `760396521507` and the region is the intended development region. Never copy access keys or secret values into this folder or tracked files.

## Destructive teardown

The `destroy-all.sh` script requires the exact phrase:

```text
DESTROY cloudstart <actual-account-id> <aws-region>
```

It inventories before teardown, destroys Terraform-managed resources across configured state keys, stops local Compose stacks, and inventories afterward. It preserves the remote state bucket and its versioned history. Any project resource outside the known Terraform states is reported rather than deleted through an arbitrary AWS API call.

Do not use `destroy-all.sh` as a routine validation command. Read [Deployment and Operations](../docs/deployment.md) and inspect its implementation before approving a teardown.

## Operating boundary

- Never run `deploy.sh`, `ensure-terraform-state.sh`, secret provisioners, or `destroy-all.sh` merely to test documentation.
- Never treat a successful local validation as proof of AWS runtime health.
- Keep generated state, plans, secret material, and `.deploy/` artifacts out of Git.
- Review and approve Terraform plans before applying infrastructure changes.


## Cloud operations orchestrator

The operator interface is maintained in [Cloud operations](../docs/operations.md). It is independent from the deployment script and does not require the branch-specific local doctor check.

Quick entry points:

~~~bash
make ops-help
make ops
make ops ACTION=overview
make ops ACTION=costs
make ops ACTION=costs ARGS='project'
make ops ACTION=costs ARGS='resources rds'
make ops ACTION=logs ARGS='backend --since 2h'
make ops ACTION=stop ARGS='all'
make ops ACTION=start ARGS='all'
make ops ACTION=stop ARGS='application'
make ops ACTION=start ARGS='application'
make ops ACTION=db ARGS='status'
~~~

Before any AWS call, nova-ops.sh verifies the current AWS account against config/dev.env. Do not use it from an unintended AWS profile/account. Service scaling is bounded by the max task counts in config/dev.tfvars. Monitoring is a singleton task and accepts only zero or one replica.

The costs command shows the account-wide monthly view; costs project filters by the Project and Environment cost-allocation tags (which must be activated in Billing first). The resource-level Cost Explorer command depends on AWS opt-in/settings for the selected service. See the operations guide for data limitations, IAM permissions, remaining fixed costs, and RDS stop/start behavior.

The orchestrator does not turn off or delete NAT Gateways, the ALB, the VPC, ECR, the S3 Terraform state bucket, snapshots, or CloudWatch log storage. stop all brings all three ECS workloads to zero but leaves the databases running. start all checks/starts both databases and, once both are available, brings the application and monitoring services up. RDS stop requires dependent ECS services at zero (including zero running tasks) and an exact interactive confirmation. Run mocked tests with:

~~~bash
make ops-test
~~~
