# CloudStart Commerce — frontend Danilo

The HTML/CSS and required JavaScript from the Danilo branch are integrated within `apps/frontend/`. No Terraform, FastAPI, ECS or RDS source was changed.

## Real backend integration
The homepage calls `GET /api/health` and `GET /api/health/db` via the existing ALB path rules; the status banner reflects actual FastAPI and PostgreSQL connectivity.

## Demonstration-only functionality
Catalog, cart, filters, product comparison, quote and checkout simulation use client-side reference data. There are **no backend product, order, or payment APIs**; no real orders or payments occur. Checkout does not request card numbers or customer personal information and saves only cart items, estimated total and simulated method. Registration and login inputs are disabled: FastAPI supports configured OAuth Google/Apple (HTTPS required), not username/password. The AWS development ALB is presently HTTP-only.

Static pages live under `public/`. Product SVG fallbacks are in `public/assets/images/`. The Nginx image serves this UI; the ALB forwards `/api/*` to FastAPI. Git changes do not deploy themselves to AWS.

## Publish ONLY the frontend to an existing NOVA AWS environment

From a **clean** CloudShell checkout of `main` with `config/dev.env` configured for the current AWS account:

```bash
bash apps/frontend/deploy-aws-only.sh
```

This script checks AWS account and remote Terraform State, builds and pushes only the frontend image, validates that a targeted Terraform plan changes only the frontend ECS task definition, then rolls only the ECS frontend service. Existing backend, monitoring, RDS and network infrastructure are not part of this operation. A rolling frontend deployment can still briefly affect frontend availability. Do **not** use `make deploy` merely to publish a visual frontend change.
