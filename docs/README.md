# NOVA documentation index

This folder contains the project-wide operational and implementation documentation for the CloudStart MVP.

## Start here

| Need | Document |
| --- | --- |
| Understand the project and current boundaries | [Root README](../README.md) |
| Understand the AWS topology and request flow | [Architecture](architecture.md) |
| Verify what is implemented versus planned | [Current-state inventory](current-state.md) |
| Prepare a local checkout or CloudShell | [Local development](local-development.md) |
| Deploy, operate, inspect, or tear down development | [Deployment and operations](deployment.md) |
| Operate live AWS services and inspect costs, inventory, and logs | [Cloud operations orchestrator](operations.md) |
| Understand CI, CD, OIDC, release guards, and workflow evidence | [CI/CD](ci-cd.md) |
| Review implemented security controls | [Security model](security.md) |
| Understand accepted Checkov/Trivy exceptions | [Security exceptions](security-exceptions.md) |
| Configure Terraform, GitHub, and secrets | [Configuration reference](configuration-reference.md) |

## Folder-level guides

- [Backend](../apps/backend/README.md): FastAPI routes, authentication, PostgreSQL roles, migrations, secret delivery, and tests.
- [Frontend](../apps/frontend/README.md): static UI, Nginx behavior, security headers, local proxy, and AWS routing.
- [Monitoring](../monitoring/README.md): Zabbix, Grafana, the monitoring database, plugin, and CloudWatch logs.
- [Terraform state bootstrap](../bootstrap/README.md): S3 state bucket, compatibility DynamoDB table, and local bootstrap state.
- [Operational scripts](../scripts/README.md): what each helper does, which commands change AWS resources, and which are local/read-only.

## Source-of-truth order

When two sources disagree, use this order:

1. Terraform and provider lock files for infrastructure declarations and provider selection.
2. Application source, Dockerfiles, Nginx configuration, migrations, and Compose files for runtime behavior.
3. GitHub workflow YAML and scripts for automation, guardrails, and side effects.
4. `config/dev.tfvars` and `config/dev.env` for committed non-secret development defaults.
5. The documents in this folder and the folder-level READMEs for explanation and operating procedures.
6. Screenshots and architecture images as visual aids only.

The preserved `CloudStart_MVP_Arquitetura_Atual.drawio.png` in the repository root is intentionally retained. If its visual representation differs from current Terraform or application code, follow the source files and the detailed [architecture document](architecture.md).

## Documentation maintenance rules

- Update the relevant folder README and the matching document in this folder whenever implementation behavior changes.
- Keep default values aligned with `variables.tf`, `config/dev.tfvars`, `config/dev.env`, and workflow inputs.
- Distinguish repository configuration, CI validation, and live AWS runtime observations. A Terraform resource or green local CI run does not prove a live AWS resource is healthy.
- Label deferred features and accepted security exceptions; do not present roadmap items as implemented.
- Record CI evidence with its commit SHA and run link. State whether coverage was complete or partial and identify skipped checks.
- Never place credentials, secret values, private keys, or sensitive local state in documentation.
- Do not claim that `terraform-docs` is generated or checked by CI unless a corresponding workflow step is added.

## Recommended review sequence

For infrastructure or release changes, read [Architecture](architecture.md), [Security](security.md), [Configuration](configuration-reference.md), and [CI/CD](ci-cd.md) together. For an actual deployment or teardown, follow [Deployment and Operations](deployment.md) and verify the AWS account, region, branch, plan, and confirmation gates before any state-changing operation.
