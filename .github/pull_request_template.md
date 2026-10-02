# Summary

Describe what changed and why.

## Scope

- [ ] Network / VPC / routing / NAT
- [ ] Security groups / network access
- [ ] ECS / Fargate / ALB
- [ ] Frontend application / Nginx
- [ ] Backend application / FastAPI
- [ ] ECR / container image
- [ ] RDS / database
- [ ] IAM / Secrets Manager
- [ ] Observability / Zabbix + Grafana
- [ ] Bootstrap / Terraform state
- [ ] GitHub Actions / CI
- [ ] Dependency configuration
- [ ] Documentation

## Current-state fidelity

- [ ] I verified that documentation changes describe only functionality actually present in this repository.
- [ ] I did not document roadmap/future components as implemented.
- [ ] Any new AWS service is backed by a corresponding Terraform resource in this change.
- [ ] Any new application component is backed by source/Docker/runtime configuration in this change.

## Validation

- [ ] `terraform fmt -check -recursive`
- [ ] `terraform init -backend=false`
- [ ] `terraform validate`
- [ ] Bootstrap `terraform init -backend=false`
- [ ] Bootstrap `terraform validate`
- [ ] TFLint passes
- [ ] Checkov passes or findings are explicitly reviewed
- [ ] Trivy IaC scan passes
- [ ] Gitleaks reports no secrets
- [ ] `terraform-docs` generation check passes
- [ ] Container CI passes when application/container files changed
- [ ] `docker compose config --quiet` passes when Compose changes
- [ ] `terraform plan` reviewed when the credentialed plan gate is enabled

## Security

- [ ] No secrets, credentials, tokens, or private keys were committed.
- [ ] Security groups follow the current least-privilege intent.
- [ ] IAM permissions are scoped to required capabilities.
- [ ] Database remains private and is not publicly accessible.
- [ ] Container images do not embed runtime secrets.
- [ ] Any Checkov/Trivy exception is documented with a concrete reason.

## Reliability

- [ ] No unintended single-AZ dependency was introduced.
- [ ] ECS health-check and deployment behavior was reviewed.
- [ ] RDS backup/deletion behavior was reviewed.
- [ ] Destructive or replacement changes were explicitly reviewed.
- [ ] Any change affecting `deploy_application` behavior is documented.

## CI/CD impact

- [ ] This change does not assume automatic ECR publication unless such a workflow is included.
- [ ] This change does not claim automatic ECS deployment unless such a workflow is included.
- [ ] Any OIDC change identifies the exact AWS role/repository variables involved.

## Cost

Describe any new recurring AWS cost or confirm that no material cost change is expected.

Pay particular attention to:

- NAT Gateway changes;
- RDS changes;
- additional ECS capacity;
- additional observability/storage;
- new AWS managed services.

## Rollback

Describe how the change can be reverted safely.

## Reviewer notes

Call out anything that needs focused review.
