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
- installs the CI-aligned Checkov and pip-audit versions;
- validates root and bootstrap Terraform configurations;
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

The doctor checks the branch, Terraform, TFLint, Python, pytest, Ruff, mypy, Bandit, Checkov, pip-audit, Docker, Compose, AWS CLI, and curl.

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

Static Terraform validation:

```bash
make validate
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

The root Terraform configuration uses an S3 backend with the S3 lockfile mechanism.

The repository also contains a separate bootstrap stack under:

```text
bootstrap/
```

The bootstrap stack creates the remote state infrastructure. It must be run only when the state bucket does not already exist or when intentionally rebuilding state infrastructure.

Example:

```bash
cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars
```

Set a unique bucket name, then:

```bash
terraform -chdir=bootstrap init
terraform -chdir=bootstrap validate
terraform -chdir=bootstrap plan
terraform -chdir=bootstrap apply
```

Do not commit `bootstrap/terraform.tfvars`.

## 10. Initialize the root backend

After the state bucket exists:

```bash
export TF_STATE_BUCKET="your-existing-state-bucket"

make tf-init
```

This configures:

```text
S3 remote state
S3 lockfile
encrypted state
```

Verify:

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
