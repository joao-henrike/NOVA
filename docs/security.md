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
cloudstart-<env>-rds-sg
```

### Allowed ingress

```text
Internet -> ALB :80
ALB     -> Frontend :80
ALB     -> Backend  :8000
Backend -> RDS      :5432
```

### Current egress

```text
Frontend -> Internet :443
Backend  -> Internet :443
Backend  -> RDS     :5432
RDS      -> Internet :all
```

These egress rules are the actual current configuration; no stronger future restriction should be documented as already implemented.

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
- Multi-AZ;
- storage encryption;
- automated backups;
- storage autoscaling;
- automatic minor version upgrades.

The RDS security group accepts PostgreSQL 5432 only from the backend security group.

The current code does not define a customer-managed KMS key for RDS.

## 8. Secret management

The RDS resource sets:

```hcl
manage_master_user_password = true
```

The backend receives the password through ECS secret injection.

No application password is hardcoded in the backend source.

The repository's local Compose file does contain a development-only password literal. It is explicitly labeled as local development and is not wired into the AWS stack.

## 9. IAM model

The monitoring workload has a separate ECS execution role from the application workloads. The application role can read only the application RDS-managed secret, while the monitoring execution role reads the monitoring database secret and the Grafana administrator secret.


The ECS execution role has only the permissions needed for the current task startup/runtime integration:

```text
ECR image pull
Zabbix/Grafana log write
Secrets Manager secret read
```

Frontend and backend task roles are separate but empty of application permissions.

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

The current OIDC deployment path is restricted to the development environment. There is intentionally no automated production-deployment OIDC path.

## 12. Current public security limitations

Because the current ALB has an HTTP listener on port 80, the current MVP does not provide HTTPS/TLS termination.

There is also no current:

```text
WAF
ACM certificate
CloudFront
Route 53
API Gateway
```

These must not be described as current protections.

## 13. Application security limitations

The current backend implements:

```text
Google authentication
Apple authentication
OAuth state validation
OIDC nonce validation
CloudStart access tokens
Refresh-token rotation
Session revocation
```

The current backend still does not implement:

```text
Authorization/RBAC
MFA
Rate limiting
Payment security controls
Financial transaction controls
Business-level audit logging
Interactive account-linking workflow
```

The current endpoints are infrastructure/application health and information endpoints rather than a complete user-facing business API.

## 14. Monitoring and logging security

The monitoring plane is now Zabbix + Grafana, both containerized. Grafana is the only monitoring UI exposed through the public ALB. Zabbix Server and Zabbix Web are kept private within the monitoring ECS task.

The Zabbix database has a dedicated security group and private RDS placement. Application RDS access is not granted to the monitoring task as part of the current MVP; end-to-end database health is observed through the backend `/api/health/db` path.

The former `awslogs`/CloudWatch logging path is removed. Zabbix/Grafana are the monitoring and visualization plane, not a centralized immutable application-log archive. This MVP therefore makes no claim of durable centralized application-log retention.

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
