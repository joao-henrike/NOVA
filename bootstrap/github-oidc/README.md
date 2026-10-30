# GitHub Actions → AWS OIDC bootstrap

This stack creates the IAM OIDC provider and a **development application-deployment role** for NOVA. It is deliberately separate from the S3 state bootstrap and the root application stack, so creating the GitHub role does not require or overwrite the root Terraform state.

## Fixed trust boundary

The role trusts only:

- GitHub repository: `joao-henrike/NOVA`
- Immutable GitHub owner ID: `133373332`
- Immutable GitHub repository ID: `1393500090`
- GitHub Environment: `development`
- OIDC audience: `sts.amazonaws.com`
- AWS account: `760396521507`

The trusted subject is:

```text
repo:joao-henrique@133373332/NOVA@1393500090:environment:development
```

The repository was created after July 15, 2026, so its default OIDC subject contains immutable owner/repository IDs. The role must not be configured with the older name-only subject. The GitHub `development` Environment should also restrict deployment branches to `Joao`.

## Permission scope

The inline policy is designed for the existing `deploy-dev.yml` workflow and the read-only AWS validation in `extreme-validation.yml`. It grants:

- Read-only metadata access required for Terraform refresh/plan across the existing NOVA stack.
- Read/write access only to the canonical state object and its S3 lock file.
- Image push access only to `cloudstart-dev-frontend` and `cloudstart-dev-backend`.
- Create/read/update access only to the three application Secrets Manager secrets.
- ECS task-definition registration and service updates only in the `cloudstart-dev` cluster.
- RunTask only for the database-bootstrap and database-migration task definitions, limited to 256 CPU units and 512 MiB.
- PassRole only for the NOVA ECS task roles and only to `ecs-tasks.amazonaws.com`.
- IAM role/policy changes only for the named NOVA ECS execution roles.
- CloudWatch log-group changes only under `/ecs/cloudstart-dev/`.
- Security-group changes only for Project=cloudstart, Environment=dev resources.
- Application Auto Scaling changes only for NOVA ECS service desired-count targets.

It does **not** grant general administrator access, broad RDS/VPC/ALB mutation, IAM user/key management, account/billing administration, or infrastructure destruction. The state-bucket bootstrap remains a separate one-time administrative operation.

## One-time apply

Use an AWS CLI identity already authorized to create IAM OIDC providers and IAM roles in account `760396521507`. Do not paste AWS access keys or session tokens into GitHub or this repository.

From the repository root, run:

```bash
aws sts get-caller-identity
bash scripts/bootstrap-github-oidc-role.sh CREATE_GITHUB_OIDC_ROLE
```

The script verifies the AWS account, initializes and validates this stack, and looks for an existing GitHub OIDC provider. If one exists, it reads the provider and reuses its ARN as a Terraform data source; it does not import, update, or retag a shared provider. It creates the provider only if absent. It then displays the exact role plan and requires the explicit confirmation phrase before applying.

After the apply, set the repository Actions variable using the output ARN:

```bash
gh variable set AWS_CD_ROLE_ARN \
  --repo joao-henrike/NOVA \
  --body "$(terraform -chdir=bootstrap/github-oidc output -raw github_actions_cd_role_arn)"
```

The GitHub CLI identity needs repository Variables write permission. This value is a repository variable, not a secret. Do not put it in a tracked file.

Also verify that the GitHub Environment `development` allows deployment from branch `Joao` only and contains the `GRAFANA_ADMIN_PASSWORD` environment secret.

## Important limitations

- This stack does not create or configure a destructive rebuild role. The manual rebuild workflow uses a separate `AWS_REBUILD_ROLE_ARN` variable and the `development-rebuild` Environment. Keep that role separate and protected by required reviewers.
- The role policy is scoped to the current development resource names and state key. If the infrastructure naming convention, service list, or task sizes change, update and revalidate this policy in the same pull request.
- Terraform validation cannot prove that an AWS account's existing service-linked roles, permissions boundaries, SCPs, or organization policies permit the deployment. The first live deployment is the final permission check.
- Keep this stack's local Terraform state private. It contains IAM policy and trust configuration and must never be committed.
