# Local Development and Environment Bootstrap

This document is the canonical procedure for preparing a new Linux/CloudShell checkout of NOVA.

The repository is designed so that project-specific CLI tools and Python dependencies are installed inside the repository workspace without requiring a global Terraform or Python package installation.

## 1. Supported workflow

The working branch for the current project cycle is:

```text
Joao
```

Start from a fresh clone:

```bash
git clone --branch Joao --single-branch https://github.com/joao-henrike/NOVA.git
cd NOVA
```

Verify:

```bash
git branch --show-current
git status --short --branch
```

Do not use `main` as the implementation branch for these changes.

## 2. One-command bootstrap

Run:

```bash
make setup
```

The bootstrap script:

- verifies Git, curl, unzip, Python 3.12+, and Docker;
- downloads the repository-pinned Terraform version (1.16.4) into `.tools/bin`;
- downloads the repository-pinned TFLint version (0.64.0) into `.tools/bin`;
- installs AWS CLI v2 locally when the host does not already provide it;
- creates `.venv`;
- installs backend runtime and development Python dependencies;
- runs provider-free Terraform formatting validation; full `terraform validate` is a separate infrastructure check because it downloads provider binaries;
- compiles the backend Python source and tests.

The bootstrap does **not** authenticate to AWS, authenticate to GitHub, create credentials, or create AWS resources.

## 3. Load the local tool environment

The bootstrap keeps downloaded tools out of the host-wide package manager:

```bash
export PATH="$PWD/.tools/bin:$PATH"
source .venv/bin/activate
```

Check everything:

```bash
make doctor
```

The doctor checks the branch, Terraform, TFLint, Python, pytest, Ruff, mypy, Bandit, Docker, Compose, AWS CLI, and curl. CI-only tools such as Checkov and pip-audit are not installed by the default local bootstrap.

## 4. Run the application locally

Start the development stack:

```bash
make up
```

The Compose topology is:

```text
Browser
  |
  v
Frontend / Nginx :8080
  |
  +--> /api/* --> Backend :8000
                    |
                    v
                PostgreSQL :5432
```

Endpoints:

```text
Frontend     http://localhost:8080/
Frontend     http://localhost:8080/health
Backend      http://localhost:8000/
Backend      http://localhost:8000/health
Backend API  http://localhost:8000/api/health
Backend info http://localhost:8000/api/info
Database     localhost:5432
```

Run:

```bash
make smoke
```

Stop the stack:

```bash
make down
```

View logs:

```bash
make logs
```

## 5. Run backend tests

Prepare PostgreSQL and run the complete local backend test suite:

```bash
make test
```

The target applies Alembic migrations against the local PostgreSQL container and then runs pytest.

To run migrations only:

```bash
make migrate
```

## 6. Validate the infrastructure code

Local application validation:

```bash
make validate
```

Full Terraform/provider validation (downloads the AWS provider):

```bash
make tf-validate
```

Terraform linting:

```bash
make tflint
```

Root Terraform commands intentionally use:

```text
Terraform 1.16.4
```

as defined by the repository and CI workflow.

## 7. AWS authentication

The repository does not store AWS credentials.

### Current CloudShell phase

AWS authentication is intentionally **not part of the bootstrap**.

CloudShell can already provide the AWS execution identity needed for commands executed from that environment. The bootstrap only installs/prepares the AWS CLI; it does not call `aws configure`, create access keys, write credential files, or fetch secrets.

### Future local-workstation phase

A future authentication helper should:

```text
.env
 |
 +--> AWS credential/configuration inputs
 |
 v
authentication helper
 |
 v
AWS CLI / Terraform session
```

The future implementation must:

- read credentials/configuration from a local `.env` or another explicitly approved secret source;
- never commit the `.env`;
- never print secret values;
- avoid embedding credentials in Terraform files;
- fail closed when required values are missing.

That helper is intentionally **not implemented yet**.

Confirm the current identity manually when AWS deployment is actually being performed:

```bash
aws sts get-caller-identity
```

## 8. Future GitHub authentication

The repository is already cloned from GitHub during normal setup, so no GitHub authentication step is required for the current CloudShell bootstrap.

A future authentication helper may provide a standardized GitHub CLI/Git workflow:

```text
.env / approved credential source
          |
          v
GitHub authentication helper
          |
          +--> gh auth
          +--> git credential / token flow
```

The future helper must never commit, echo, or persist plaintext credentials in tracked repository files.

This GitHub authentication layer is also intentionally **not implemented yet**.

## 9. Terraform remote state

The root Terraform configuration uses an S3 backend with S3-native lockfiles. The bucket is created by the separate bootstrap stack when it is missing.

For the current development environment, source the non-sensitive metadata and run the safe state helper:

```bash
set -a
source config/dev.env
set +a
scripts/ensure-terraform-state.sh
```

The helper verifies the AWS account, expected bucket owner, and region. It reuses a matching bucket, bootstraps missing resources only when the bucket is confirmed absent, and fails closed if ownership or access cannot be verified.

The bootstrap creates the versioned/encrypted S3 bucket, full public-access-block settings, ownership controls, secure-transport policy, lifecycle rules, and a DynamoDB compatibility table. The root backend uses S3 lockfiles; it does not use the DynamoDB table for locking. The bootstrap stack itself keeps local state, which must be protected and never committed.

For deliberate manual bootstrap in a new/custom environment only, first configure bootstrap/terraform.tfvars from its example and run terraform with backend disabled. Do not run a second bootstrap against an existing bucket merely to recreate its state. Prefer the shared helper for the current development bucket.

## 10. Initialize the root backend

After the state helper confirms that the bucket exists:

```bash
set -a
source config/dev.env
set +a
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="key=$TF_STATE_KEY" \
  -reconfigure -input=false
```

The Makefile target make tf-init can initialize an already-existing bucket, but it does not call the bootstrap helper. make deploy runs the helper automatically as part of its end-to-end deployment path.

Verify state access:

```bash
terraform state list
```

## 11. Build application images

The production ECS task definitions use immutable ECR tags.

For a manual deployment, use an immutable tag such as the current commit SHA:

```bash
export IMAGE_TAG="$(git rev-parse HEAD)"
```

Build:

```bash
docker build -t "cloudstart-dev-frontend:$IMAGE_TAG" apps/frontend
docker build -t "cloudstart-dev-backend:$IMAGE_TAG" apps/backend
```

Check the frontend Nginx configuration:

```bash
docker run --rm "cloudstart-dev-frontend:$IMAGE_TAG" nginx -t
```

The AWS frontend image must not depend on the Docker Compose hostname `backend`.

## 12. Repository boundaries

The bootstrap creates only local developer artifacts:

```text
.tools/
.venv/
```

Both are ignored by Git.

Secrets, AWS credentials, Terraform state, `.tfvars`, and certificates must never be committed.

## 13. CloudShell

AWS CloudShell is a supported execution environment for this repository.

Recommended sequence:

```bash
git clone --branch Joao --single-branch https://github.com/joao-henrike/NOVA.git
cd NOVA
make setup
make doctor
make validate
make up
make smoke
```

After local validation, the AWS deployment flow should be executed explicitly.

## 14. Deployment automation boundary

The local bootstrap is intentionally separate from AWS provisioning.

```text
make setup
    |
    +--> local tools
    +--> Python environment
    +--> static validation

AWS deployment
    |
    +--> AWS identity
    +--> Terraform backend
    +--> Terraform plan
    +--> Terraform apply
    +--> ECR image publication
    +--> ECS deployment
    +--> migrations
    +--> smoke tests

Future authentication
    |
    +--> local .env / approved secret source
    +--> AWS authentication helper
    +--> GitHub authentication helper
```

This separation makes failures attributable to a specific layer and prevents a local environment bootstrap from unexpectedly creating billable AWS resources.
