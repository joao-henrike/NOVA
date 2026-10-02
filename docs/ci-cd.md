# CloudStart — CI/CD Current State

> This document describes the workflows that actually exist in `.github/workflows/`. The repository has automated **continuous integration** and an optional credentialed Terraform Plan, but it does not currently implement continuous deployment.

## 1. Workflow inventory

```text
.github/workflows/terraform-lint.yml
.github/workflows/container-ci.yml
```

## 2. Terraform CI workflow

### Trigger

The workflow runs on:

```text
pull_request
push to main
```

The path filters cover Terraform/configuration, GitHub workflow/configuration, and documentation changes.

### Global environment

```text
Terraform      1.16.4
TFLint         0.64.0
terraform-docs 0.24.0
```

## 3. Terraform Static Validation job

### Step 1 — Checkout

The repository is checked out with persisted Git credentials disabled.

### Step 2 — Terraform setup

The workflow installs Terraform 1.16.4.

### Step 3 — Format check

```bash
terraform fmt -check -recursive -diff
```

This does not modify the repository.

### Step 4 — Root initialization

```bash
terraform init -backend=false -input=false -no-color
```

The remote backend is intentionally not contacted for this validation step.

### Step 5 — Root validation

```bash
terraform validate -no-color
```

### Step 6 — Bootstrap initialization

The bootstrap stack is initialized independently with its backend disabled.

### Step 7 — Bootstrap validation

```bash
terraform validate -no-color
```

### Step 8 — TFLint

The repository installs a pinned TFLint release and the AWS ruleset, then runs:

```bash
tflint --config .tflint.hcl --recursive --format compact
```

### Step 9 — terraform-docs

The workflow generates Terraform input/output documentation into a temporary file and checks that the generated content contains the expected inputs, outputs, and markers.

It does not replace the committed README as part of the CI run.

## 4. IaC Security and Policy job

### Checkov

The workflow runs Checkov against the root Terraform code.

Configured behavior:

```text
HIGH/CRITICAL -> hard fail
LOW/MEDIUM    -> soft fail
```

### Trivy

The workflow runs Trivy in configuration/misconfiguration mode using `trivy.yaml`.

The configured scan focuses on HIGH and CRITICAL findings and fails on them.

## 5. Secret-scanning job

Gitleaks checks the repository history.

This is intended to detect accidentally committed secrets and does not provide application authentication or runtime secret management.

## 6. Optional Terraform Plan job

A fourth job exists but is conditional.

The job only runs when:

```text
Pull request
AND not a fork
AND AWS_TERRAFORM_PLAN_ROLE_ARN is set
AND TF_STATE_BUCKET is set
AND TF_STATE_DYNAMODB_TABLE is set
```

### AWS authentication

It uses GitHub OIDC to assume the configured AWS IAM role.

### Terraform initialization

It configures the remote state using repository variables.

### Plan

```bash
terraform plan -refresh=true -lock=true -input=false -out=tfplan
```

### Sanitized PR summary

The workflow does not post raw plan contents to the PR. It computes a summary of changed resource actions.

### Destructive-change guard

Any resource action containing a delete causes the job to fail unless the PR has the label:

```text
infra-allow-destroy
```

That label is therefore an explicit human-review gate for destructive changes in this optional path.

## 7. Container CI workflow

### Trigger

Runs for changes under:

```text
apps/**
docker-compose.yml
.github/workflows/container-ci.yml
```

on PRs and pushes to `main`.

### Frontend build

The workflow builds the frontend image from:

```text
apps/frontend
```

with a CI tag based on the Git commit SHA.

### Backend build

The workflow builds the backend image from:

```text
apps/backend
```

with a CI tag based on the Git commit SHA.

### Push behavior

The workflow explicitly sets:

```text
push: false
```

Therefore CI does not publish these images to ECR.

### Image scans

Each built image is scanned with Trivy for:

```text
HIGH
CRITICAL
```

Unfixed vulnerabilities are ignored by the configured action invocation.

### Compose validation

The workflow runs:

```bash
docker compose config --quiet
```

This validates the Compose configuration syntax.

## 8. What the workflows accomplish today

```text
Source change
   |
   +--> IaC syntax/format validation
   +--> Terraform validation
   +--> Terraform lint
   +--> IaC security scans
   +--> secret scan
   +--> container build
   +--> container vulnerability scan
   +--> Compose validation
   +--> optional AWS-backed Terraform plan
```

This provides a strong validation pipeline for the current MVP repository.

## 9. What the workflows do not accomplish today

```text
ECR push
ECS deployment
Production approval gate for deployment
Automatic rollback driven by deployment pipeline
Database migration execution
Post-deployment smoke test
Automatic alarm notification
```

ECS itself has deployment circuit-breaker/rollback behavior, but the GitHub workflows do not orchestrate the deployment.

## 10. CI/CD terminology for this repository

The repository should be described as:

> **CI + optional credentialed Terraform Plan**

not as a fully automated CD platform.

The current architecture intentionally separates validation from AWS write operations.
