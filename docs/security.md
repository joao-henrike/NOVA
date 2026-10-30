# CloudStart — Current MVP Security Model

> This document records security controls that are actually implemented in the current repository. It does not treat planned hardening as deployed security.

## 1. Security boundary

```text
Internet
    |
    | TCP :80
    v
+-----------+
| Public ALB |
+-----------+
    |      |
    |      |
 :80|      |:8000
    v      v
Frontend  Backend
 private  private
    |       |
    |       +------ :5432 ------> RDS
    |
   no public IP
```

The database is in private database subnets and is not publicly accessible.

## 2. Network segmentation

Current tiers:

```text
Public
Private App
Private DB
```

The public tier contains the ALB and NAT gateways.

The private application tier contains the ECS tasks.

The private database tier contains the RDS subnet group.

## 3. Security groups

Current groups:

```text
cloudstart-<env>-alb-sg
cloudstart-<env>-frontend-sg
cloudstart-<env>-backend-sg
cloudstart-<env>-monitoring-sg
cloudstart-<env>-rds-sg
cloudstart-<env>-monitoring-db-sg
```

### Allowed ingress

```text
Internet -> ALB :80
ALB     -> Frontend :80
ALB     -> Backend  :8000
ALB     -> Grafana  :3000
Backend -> RDS      :5432
Monitoring -> Monitoring RDS :5432
```

### Current egress

```text
ALB             -> Frontend :80
ALB             -> Backend  :8000
ALB             -> Grafana  :3000
Backend         -> Internet :443
Backend         -> App RDS  :5432
Database tasks  -> Internet :443
Database tasks  -> App RDS  :5432
Monitoring      -> Monitoring RDS :5432
Monitoring      -> Internet :443
```

The frontend and both RDS security groups have no declared egress rules. Security groups are stateful, so return traffic for allowed inbound/initiated connections is automatically permitted; RDS does not need unrestricted outbound access to reply to PostgreSQL clients. The frontend serves static assets and has no runtime external HTTPS dependency.

## 4. ECS public exposure

Both application services use:

```text
assign_public_ip = false
```

They run in private application subnets.

The ALB is the public ingress point.

## 5. Container security

### Backend

The backend Dockerfile:

- uses `python:3.12-slim`;
- creates a dedicated non-root user;
- runs the application as that user;
- installs pinned application dependencies;
- defines a health check.

### Frontend

The frontend uses the Alpine-based Nginx image and defines a container health check.

The repository does not currently configure advanced container runtime controls such as read-only root filesystems, capability dropping, or image signing in the ECS task definitions.

## 6. ECR security controls

Both ECR repositories use:

```text
IMMUTABLE image tags
scan_on_push = true
```

Lifecycle policy:

```text
keep 10 most recent images
```

## 7. Database security

RDS is configured with:

- private subnets;
- `publicly_accessible = false`;
- Single-AZ in the current low-cost environment (`multi_az = false`);
- storage encryption;
- automated backups;
- storage autoscaling;
- automatic minor version upgrades.

The application RDS security group accepts PostgreSQL 5432 from the backend HTTP security group and the dedicated database-task security group. The monitoring RDS accepts 5432 only from the monitoring security group. Both RDS instances are Single-AZ in the current low-cost configuration.

The current code does not define a customer-managed KMS key for RDS.

## 8. Secret management

The RDS resource sets:

```hcl
manage_master_user_password = true
```

The RDS master password is injected only into the one-off database role-bootstrap task. It is not present in the normal backend HTTP task definition.

The normal backend task uses the dedicated `cloudstart_runtime` PostgreSQL login. Its password comes from the external Secrets Manager secret referenced by `db_runtime_secret_arn`. The Alembic task uses `cloudstart_migrator`, with a different secret referenced by `db_migrator_secret_arn`. Terraform stores only these ARNs, never the secret values.

Bootstrap and migration tasks run with a dedicated security group that has no ingress rules. Its egress is restricted to TCP 5432 toward the application RDS security group and HTTPS toward AWS image/secret services through the private-subnet NAT route. It does not reuse the backend HTTP security group and cannot receive ALB traffic.

The bootstrap task has a separate ECS execution role and is the only application task permitted to read the RDS-managed master secret. It revokes database-level `CONNECT` and `TEMPORARY` from `PUBLIC`, clears all direct database ACLs on the runtime and migrator logins, then grants `CONNECT` explicitly to those two logins. Neither application login receives database-level `TEMPORARY`. It creates/updates the restricted PostgreSQL roles, removes inherited role memberships from both application logins, transfers application tables/sequences/views and non-extension routines to the migrator, and reconciles both direct and `PUBLIC` ACLs before granting runtime DML/sequence access. Existing `SECURITY DEFINER` routines are owned by the migrator and do not retain `PUBLIC EXECUTE`; the migrator's default privileges also revoke `EXECUTE` from `PUBLIC` for future functions. The runtime login cannot create temporary tables, access migration metadata, or inherit unrelated role privileges. The deployment process runs bootstrap, Alembic, then bootstrap again to grant runtime DML privileges on newly-created tables and sequences.

JWT and Google/Apple OAuth settings remain injected from a separate Secrets Manager JSON secret when `backend_auth_secret_arn` is configured. The backend deployment guard requires all three application secret ARNs when `deploy_application = true`.

No application password or OAuth credential is hardcoded in the backend source.

The repository's local Compose file does contain a development-only password literal. It is explicitly labeled as local development and is not wired into the AWS stack.

## 9. IAM model

The frontend ECS execution role is ECR-pull-only. The normal backend execution role reads only its runtime database secret and backend authentication secret. The migration execution role reads only the migrator secret. The one-off database bootstrap execution role reads the RDS master secret plus the runtime/migrator password secrets. The monitoring execution role reads only the monitoring database and Grafana administrator secrets.


The frontend and backend HTTP services use separate task roles with no application AWS permissions. The one-off database bootstrap and migration task definitions intentionally omit `task_role_arn` entirely, so their containers receive no ECS task-role credentials. ECR image pulls, CloudWatch log delivery, and startup-time Secrets Manager injection are handled by their narrowly scoped task execution roles; those execution-role credentials are not exposed to the application process.

All ECS containers use the `awslogs` driver. Frontend, backend, database bootstrap, database migration, and monitoring workloads write to separate Terraform-managed CloudWatch log groups. Each execution role receives only `logs:CreateLogStream` and `logs:PutLogEvents` for its own group; no container receives CloudWatch Logs read permissions. Retention is 7 days in development and 30 days in production. The ECS task execution roles do not need `logs:CreateLogGroup` because the groups are created by Terraform.

This means the current MVP does not grant the application arbitrary AWS APIs.

## 10. Terraform-state security

The bootstrap state bucket uses:

```text
public-access-block
versioning
encryption
bucket-owner-enforced ownership
secure-transport deny policy
```

The root backend also enables encryption and S3 lockfile support.

The bootstrap stack itself remains local-state and must be protected operationally.

## 11. CI security controls

The current CI provides:

```text
Terraform validation
TFLint
Checkov
Trivy IaC scan
Trivy container scan
Gitleaks
```

The optional Terraform Plan path uses GitHub OIDC instead of long-lived AWS credentials stored in the workflow.

The extreme full-system validation workflow is deliberately limited to pushes on `Joao` and manual runs on that branch. It does not run on pull requests: its live AWS step requires `id-token: write` to assume the development role, so excluding untrusted PR contexts prevents PR code from inheriting AWS OIDC capability. Ordinary pull requests continue to receive the non-AWS CI validation. The AWS step consumes the real `steps.aws_oidc.outcome` value and stops before any AWS API call if role assumption fails.

The current OIDC deployment path is restricted to the development environment. There is intentionally no automated production-deployment OIDC path.

## 12. Current public security limitations

The committed development baseline has both `acm_certificate_arn` and `alb_domain_name` empty, so that baseline is HTTP-only and does not provide TLS termination.

Terraform supports an optional HTTPS mode when an operator supplies an already-issued ACM certificate in the ALB's AWS region and the hostname covered by that certificate. In that mode, the ALB listens on 443 and redirects HTTP 80 to HTTPS. The repository does not issue certificates, complete domain validation, or create DNS records. Until the operator configures and applies those prerequisites, HTTPS must not be described as an active protection.

There is also no current:

```text
WAF
CloudFront
Route 53 resources managed by this stack
API Gateway
```

These must not be described as current protections.

## 13. Application security limitations

The current backend implements:

```text
PostgreSQL-backed authentication rate limits shared across ECS tasks
Google authentication
Apple authentication
OAuth state validation
OIDC nonce validation
Provider subject IDs as canonical account identity
Verified provider claims as the only email source
Apple browser profile data accepted for display name only
CloudStart access tokens bound to refresh-token families
Refresh-token rotation and reuse detection
Session-family revocation
Immediate rejection of access tokens after family revocation
```

Apple's browser-posted `user` object is not a signed identity assertion. The backend reads only its optional display name and never uses its email field; account email is accepted only from the provider's verified ID-token claim. Unverified addresses do not reserve the unique account email. All `/api/*` responses use `Cache-Control: no-store`, `Pragma: no-cache`, `X-Content-Type-Options: nosniff`, and `Referrer-Policy: no-referrer`, including user-scoped item data and health responses. This prevents private API responses from being cached by browsers or intermediaries.

The current backend still does not implement:

```text
RBAC/role permissions beyond owner-scoped Item access
MFA
Payment security controls
Financial transaction controls
Business-level audit logging
Interactive account-linking workflow
```

The current endpoints are infrastructure/application health and information endpoints rather than a complete user-facing business API.

## 14. Monitoring and logging security

The monitoring plane is now Zabbix + Grafana, both containerized. Grafana is the only monitoring UI exposed through the public ALB. Zabbix Server and Zabbix Web are kept private within the monitoring ECS task.

The Zabbix database has a dedicated security group and private RDS placement. Application RDS access is not granted to the monitoring task as part of the current MVP; end-to-end database health is observed through the backend `/api/health/db` path.

Zabbix/Grafana provide monitoring and visualization. ECS container stdout/stderr is separately centralized in five Terraform-managed CloudWatch log groups using the `awslogs` driver. The monitoring task's three containers share one group with distinct stream prefixes. Retention is 7 days in development and 30 days in production; CloudWatch Logs uses its AWS-owned encryption key. This is short-retention operational logging, not a long-term immutable audit archive.

## 15. Security controls that are intentionally not claimed

The current repository must not be described as already implementing:

```text
Zero Trust platform
Enterprise IAM
MFA
Immutable audit fabric
SIEM/SOAR
Runtime threat detection
Customer-managed KMS governance
Cross-account security governance
Formal incident-response automation
Formal compliance controls
```

Those are not present in this MVP code.

## 16. Security change review rule

For every security change, the PR should identify:

```text
What is exposed?
What identity is used?
What resource is reachable?
Which ports/protocols are opened?
Why is the permission required?
What existing control changes?
What is the rollback path?
```

The repository's PR template provides the first level of this review discipline.


### Authentication rate limiting

The backend applies fixed-window quotas to authentication endpoints. Counters are stored in PostgreSQL with atomic upserts, so ECS replicas share the same limits rather than maintaining independent in-memory counters.

| Scope | Limit | Window |
|---|---:|---:|
| OAuth login start | 10 requests | 5 minutes |
| OAuth callbacks | 20 requests | 5 minutes |
| Refresh | 30 requests | 5 minutes |
| Logout | 60 requests | 5 minutes |

Blocked requests return HTTP 429 with a Retry-After header and a generic response body. Bucket keys are HMACs derived from the application signing secret and the endpoint scope/client address; raw client IP addresses are not stored. Buckets older than one day are pruned during authentication requests.

In non-local environments, client address extraction uses the final address in X-Forwarded-For. The ALB explicitly sets `xff_header_processing_mode = "append"` and `enable_xff_client_port = false`, so it appends the peer address as a plain IP. Backend tasks accept traffic only from the ALB security group. Do not change the ALB to `preserve` or `remove`, expose the backend directly, or trust arbitrary forwarding headers from another ingress path.

These limits are a baseline abuse-control measure, not a substitute for AWS WAF, bot management, account-level risk controls, or alerting. The quotas are fixed defaults in application code and should be tuned using real traffic before a public launch.
