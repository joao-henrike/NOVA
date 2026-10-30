# Terraform State Bootstrap

> Repository-wide documentation: [NOVA documentation index](../docs/README.md) · [Configuration reference](../docs/configuration-reference.md) · [Deployment guide](../docs/deployment.md).

## Purpose

The `bootstrap/` stack creates the protected S3 bucket used by the root Terraform S3 backend and retains a DynamoDB compatibility table for older tooling.

The root backend uses S3-native lock files (`use_lockfile = true`). The DynamoDB table is **not** the active root state-lock mechanism.

## Resources declared

| Resource | Configuration |
| --- | --- |
| S3 state bucket | Globally unique bucket name supplied through `state_bucket_name`. |
| Public access block | Blocks public ACLs and bucket policies. |
| Versioning | Enabled so prior state versions can be recovered. |
| Server-side encryption | SSE-S3 (`AES256`) by default; no customer-managed KMS key is provisioned. |
| Ownership controls | `BucketOwnerEnforced`. |
| Bucket policy | Denies requests that do not use secure transport. |
| Lifecycle | Expires non-current object versions after 30 days and aborts incomplete multipart uploads after 7 days. |
| DynamoDB compatibility table | On-demand `LockID` table with point-in-time recovery; not used by the current root backend. |

## Inputs and outputs

Inputs in `variables.tf`:

- `aws_region` — defaults to `us-east-1`.
- `state_bucket_name` — required and globally unique.
- `lock_table_name` — defaults to `cloudstart-terraform-lock`.

Outputs in `outputs.tf` include bucket name/ARN, compatibility table name, and region.

## State and safety

The bootstrap stack intentionally uses **local Terraform state**. That state is security-sensitive because it describes the remote-state infrastructure. Keep it private, back it up securely, and never commit it.

For the current development environment, prefer the shared helper:

```bash
set -a
source config/dev.env
set +a
scripts/ensure-terraform-state.sh
```

The helper verifies the caller account, expected bucket owner, and bucket region. It reuses an existing bucket when ownership/access can be verified and creates the bootstrap resources only when the bucket is confirmed missing. It fails closed when ownership or access is uncertain.

Do not run a second manual bootstrap against an existing bucket to recreate or overwrite bootstrap state.

## Manual bootstrap for a genuinely new environment

Only for a new/custom environment after verifying the AWS account and region:

```bash
cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars
# Edit state_bucket_name to a globally unique, approved bucket name.
terraform -chdir=bootstrap init -backend=false -input=false
terraform -chdir=bootstrap validate
terraform -chdir=bootstrap plan -out=bootstrap.tfplan
terraform -chdir=bootstrap apply bootstrap.tfplan
```

This creates billable or persistent AWS control-plane resources. Review the plan before applying it. Keep the generated state and plan out of Git.

## Root backend

After the bucket exists, initialize the root stack with the canonical development key:

```bash
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="key=cloudstart/dev/terraform.tfstate" \
  -reconfigure -input=false
```

The root backend uses `encrypt = true` and `use_lockfile = true`. Do not add a DynamoDB backend-lock argument unless the state-lock architecture is deliberately redesigned.

For the full deployment sequence and recovery rules, see [Deployment and Operations](../docs/deployment.md).
