# NOVA — Configuration reference

This is the operator reference for Terraform inputs, bootstrap inputs, environment metadata, and GitHub Actions configuration. Values are read from the current Joao branch. When code changes, update this document in the same change.

> **Security rule:** never put passwords, access keys, OAuth credentials, private keys, or JWT signing material in tracked files or ordinary Terraform variables. Terraform receives secret ARNs where possible. Sensitive Terraform variables can still be stored in Terraform state; do not treat the sensitive flag as a replacement for Secrets Manager.

## 1. Terraform root inputs

The root stack declares 63 input variables in variables.tf.

| Name | Type | Default | Sensitive | Purpose |
| --- | --- | --- | --- | --- |
| project_name | string | "cloudstart" | No | Short project identifier used in resource names and tags. |
| environment | string | "dev" | No | Deployment environment. |
| aws_region | string | "us-east-1" | No | AWS region where the MVP infrastructure will be deployed. |
| availability_zone_count | number | 2 | No | Number of Availability Zones to use for the workload. |
| vpc_cidr | string | "10.20.0.0/16" | No | Primary IPv4 CIDR block for the VPC. |
| deploy_application | bool | false | No | Whether ECS services should run application tasks. Set true after the frontend/backend images have been pushed to ECR. |
| frontend_image_tag | string | "v0.1.1" | No | Immutable tag of the frontend image in the CloudStart ECR repository. |
| backend_image_tag | string | "v0.1.0" | No | Immutable tag of the backend image in the CloudStart ECR repository. |
| frontend_container_name | string | "frontend" | No | ECS frontend container name. |
| backend_container_name | string | "backend" | No | ECS backend container name. |
| backend_container_port | number | 8000 | No | TCP port exposed by the backend container. |
| frontend_health_check_path | string | "/health" | No | ALB/ECS health check path for the frontend. |
| backend_health_check_path | string | "/health" | No | ALB/ECS health check path for the backend. |
| frontend_task_cpu | number | 256 | No | Fargate CPU units for frontend tasks. |
| frontend_task_memory | number | 512 | No | Fargate memory in MiB for frontend tasks. |
| backend_task_cpu | number | 256 | No | Fargate CPU units for backend tasks. |
| backend_task_memory | number | 512 | No | Fargate memory in MiB for backend tasks. |
| frontend_desired_task_count | number | 2 | No | Initial desired number of frontend ECS tasks when deployment is enabled. |
| frontend_min_task_count | number | 2 | No | Minimum number of frontend ECS tasks. |
| frontend_max_task_count | number | 6 | No | Maximum number of frontend ECS tasks. |
| backend_desired_task_count | number | 2 | No | Initial desired number of backend ECS tasks when deployment is enabled. |
| backend_min_task_count | number | 2 | No | Minimum number of backend ECS tasks. |
| backend_max_task_count | number | 6 | No | Maximum number of backend ECS tasks. |
| frontend_cpu_target_utilization | number | 60 | No | Target CPU utilization for frontend service scaling. |
| frontend_memory_target_utilization | number | 70 | No | Target memory utilization for frontend service scaling. |
| backend_cpu_target_utilization | number | 60 | No | Target CPU utilization for backend service scaling. |
| backend_memory_target_utilization | number | 70 | No | Target memory utilization for backend service scaling. |
| db_name | string | "cloudstart" | No | Initial RDS database name. |
| db_username | string | "cloudstart_admin" | No | RDS master username. Used only by the one-off database role bootstrap task; its password is managed by RDS/Secrets Manager. |
| db_runtime_username | string | "cloudstart_runtime" | No | PostgreSQL login used by the normal backend service. It receives DML privileges only. |
| db_migrator_username | string | "cloudstart_migrator" | No | PostgreSQL login used only by the one-off Alembic migration task. |
| db_runtime_secret_arn | string | "" | No | ARN of an externally provisioned Secrets Manager JSON secret with a password field for db_runtime_username. The password value must never enter Terraform. |
| db_migrator_secret_arn | string | "" | No | ARN of an externally provisioned Secrets Manager JSON secret with a password field for db_migrator_username. The password value must never enter Terraform. |
| db_instance_class | string | "db.t4g.micro" | No | RDS instance class. |
| db_engine_version | string | "16" | No | Major PostgreSQL version. |
| db_allocated_storage | number | 20 | No | Initial RDS storage in GiB. |
| db_max_allocated_storage | number | 100 | No | Maximum RDS storage autoscaling cap in GiB. |
| db_backup_retention_period | number | 1 | No | Number of days to retain automated RDS backups. |
| owner | string | "cloudstart" | No | Owner tag value. |
| cost_center | string | "cloudstart-mvp" | No | Cost center tag value. |
| repository_name | string | "NOVA" | No | Repository name used for tagging. |
| alb_deletion_protection | bool | false | No | Enable ALB deletion protection. Recommended for production. |
| rds_deletion_protection | bool | false | No | Enable RDS deletion protection. Recommended for production. |
| acm_certificate_arn | string | "" | No | Optional ARN of an already-issued ACM certificate in aws_region. When set, the ALB enables HTTPS and redirects HTTP to HTTPS. |
| alb_domain_name | string | "" | No | DNS hostname covered by acm_certificate_arn. Required when HTTPS is enabled; DNS must be pointed to the ALB outside this stack. |
| monitoring_desired_count | number | 1 | No | Number of ECS monitoring tasks. The stack contains a stateful Zabbix server, so the MVP keeps one task by default. |
| monitoring_task_cpu | number | 1024 | No | Fargate CPU units for the combined Zabbix/Grafana monitoring task. |
| monitoring_task_memory | number | 2048 | No | Fargate memory in MiB for the combined Zabbix/Grafana monitoring task. |
| zabbix_server_image | string | "zabbix/zabbix-server-pgsql:alpine-7.4.15" | No | Zabbix server PostgreSQL container image. |
| zabbix_web_image | string | "zabbix/zabbix-web-nginx-pgsql:alpine-7.4.15" | No | Zabbix web interface PostgreSQL/Nginx container image. |
| grafana_image | string | "grafana/grafana:13.2.3" | No | Grafana OSS container image. |
| grafana_zabbix_plugin | string | "alexanderzobnin-zabbix-app@6.8.0" | No | Grafana Zabbix plugin package and pinned plugin version. |
| grafana_container_port | number | 3000 | No | Grafana HTTP port inside the ECS monitoring task. |
| grafana_admin_password | string | null | Yes | Initial Grafana administrator password. Required for monitoring deployment and stored in AWS Secrets Manager. |
| monitoring_timezone | string | "America/Sao_Paulo" | No | PHP timezone used by the Zabbix web interface. |
| monitoring_db_name | string | "zabbix" | No | PostgreSQL database name used by Zabbix. |
| monitoring_db_username | string | "zabbix" | No | PostgreSQL username used by Zabbix. |
| monitoring_db_engine_version | string | "16" | No | Major PostgreSQL version for the Zabbix database. |
| monitoring_db_instance_class | string | "db.t4g.micro" | No | RDS instance class for the Zabbix database. |
| monitoring_db_allocated_storage | number | 20 | No | Initial monitoring RDS storage in GiB. |
| monitoring_db_max_allocated_storage | number | 100 | No | Maximum monitoring RDS storage autoscaling cap in GiB. |
| monitoring_db_backup_retention_period | number | 1 | No | Number of days to retain automated backups for the monitoring database. |
| backend_auth_secret_arn | string | "" | No | Optional ARN of a Secrets Manager JSON secret containing backend JWT and OAuth settings. Required when deploy_application is true. |

### Cross-variable requirements

- The committed development baseline has deploy_application = false. In this mode frontend/backend desired and minimum ECS counts are reduced to zero.
- When deploy_application = true, the runtime, migrator, and RDS master PostgreSQL usernames and password secret ARNs must be distinct.
- Application activation also requires backend_auth_secret_arn. It must identify a JSON secret containing every key listed in section 5.
- grafana_admin_password must be supplied with at least 12 characters for the monitoring stack.
- Frontend/backend task counts must satisfy minimum <= desired <= maximum; autoscaling utilization values must pass the validations in variables.tf.
- The ACM variables must be configured together. The certificate must already be issued in aws_region, and alb_domain_name must be covered by it. DNS is managed outside this Terraform stack.
- The current monitoring design supports exactly one monitoring task because Zabbix Server state is held inside that task.

## 2. Terraform bootstrap inputs

The separate bootstrap stack declares three variables:

| Name | Type | Default | Purpose |
| --- | --- | --- | --- |
| aws_region | string | us-east-1 | Region for the remote-state resources. |
| state_bucket_name | string | Required | Globally unique S3 bucket name for Terraform state. |
| lock_table_name | string | cloudstart-terraform-lock | Compatibility DynamoDB table created by bootstrap. The root backend currently locks with S3 lockfiles, not DynamoDB. |

The bootstrap stack uses local state. Keep its state file private and backed up; do not commit it.

## 3. Non-sensitive development environment metadata

Tracked file: config/dev.env.

| Variable | Current development value | Purpose |
| --- | --- | --- |
| AWS_REGION | us-east-1 | AWS region used by local deployment scripts. |
| EXPECTED_AWS_ACCOUNT_ID | 760396521507 | Account allow-list checked before AWS operations. |
| TF_STATE_BUCKET | cloudstart-nova-terraform-state-760396521507 | S3 remote-state bucket. |
| TF_STATE_KEY | cloudstart/dev/terraform.tfstate | Canonical root Terraform state object. |
| LEGACY_TF_STATE_KEYS | cloudstart/redeploy-2026-10-08/terraform.tfstate, cloudstart/terraform.tfstate | Older state keys considered by destroy/rebuild tooling. |

These values are deployment metadata, not credentials.

## 4. GitHub Actions configuration

The deploy and rebuild workflows use the development Environment.

### Repository variables

| Variable | Required? | Purpose |
| --- | --- | --- |
| AWS_CD_ROLE_ARN | Yes | IAM role assumed through GitHub OIDC. Restrict the trust policy to this repository and the approved branch/environment. |
| TF_STATE_BUCKET | No | Overrides the committed development S3 bucket name. If omitted, workflows use cloudstart-nova-terraform-state-760396521507. |
| TERRAFORM_AWS_REGION | No | Region override used by deploy-dev.yml; default is us-east-1. The manual rebuild workflow is currently fixed to us-east-1. |

### GitHub Environment secrets

| Secret | Required? | Purpose |
| --- | --- | --- |
| GRAFANA_ADMIN_PASSWORD | Yes for normal CD | Grafana administrator password passed as a sensitive Terraform input. The rebuild workflow generates a fresh value instead. |
| GOOGLE_CLIENT_ID | Optional | Google OAuth client ID. |
| GOOGLE_CLIENT_SECRET | Optional | Google OAuth client secret. |
| GOOGLE_REDIRECT_URI | Optional | Exact registered Google callback URL. |
| APPLE_CLIENT_ID | Optional | Apple Service ID/client identifier. |
| APPLE_TEAM_ID | Optional | Apple developer team identifier. |
| APPLE_KEY_ID | Optional | Apple signing key identifier. |
| APPLE_PRIVATE_KEY | Optional | Apple private signing key, supplied only as an Environment secret. |
| APPLE_REDIRECT_URI | Optional | Exact registered Apple callback URL; Apple web sign-in requires HTTPS. |

For each identity provider, provide the complete set of its fields or leave the provider unconfigured. The auth-secret provisioner merges non-empty supplied OAuth fields into the existing secret and preserves the existing JWT signing key.

### AWS permissions for the OIDC role

The role needs permission to:
- inspect the target AWS account and verify the state bucket owner and region;
- create/configure the S3 state bucket and bootstrap compatibility resource when missing;
- manage only the three provisioned application Secrets Manager entries using DescribeSecret, GetSecretValue, CreateSecret, and PutSecretValue;
- run the Terraform plan/apply and deployment operations required by the explicitly scoped development stack.

The exact IAM policy is external to this repository. Review its Action, Resource, and Condition statements; do not grant broad administrator access merely to make the workflow pass.

## 5. Backend authentication secret

Provisioner: scripts/provision-backend-auth-secret.sh.

Default secret name: cloudstart-dev/backend/authentication.

Optional override: BACKEND_AUTH_SECRET_NAME.

The secret is a JSON object with all keys present. Values for an unused provider may be empty strings:

    AUTH_JWT_SECRET_KEY
    GOOGLE_CLIENT_ID
    GOOGLE_CLIENT_SECRET
    GOOGLE_REDIRECT_URI
    APPLE_CLIENT_ID
    APPLE_TEAM_ID
    APPLE_KEY_ID
    APPLE_PRIVATE_KEY
    APPLE_REDIRECT_URI

The provisioner generates a cryptographically random JWT signing key on first creation, preserves it on later runs, validates the JSON structure and string values, rejects partially configured providers, and never prints secret values. Supplied non-empty OAuth values are merged into the stored JSON. The ignored local file .deploy/backend-auth-secret-arn.env contains the ARN only.

## 6. PostgreSQL credential secrets

Provisioner: scripts/provision-db-credentials.sh.

| Secret name | JSON field | Injected into |
| --- | --- | --- |
| cloudstart-dev/database/runtime | password | Normal backend HTTP task; DML-only PostgreSQL role. |
| cloudstart-dev/database/migrator | password | One-off Alembic migration task only. |

Passwords are generated on first creation and kept in Secrets Manager. The ignored local file .deploy/db-secret-arns.env contains ARNs only. The RDS master secret is created and managed by RDS; only the one-off DB bootstrap task receives it.

## 7. Grafana administrator secret

Terraform manages cloudstart-dev/monitoring/grafana-admin.

The value is passed through the sensitive grafana_admin_password input. scripts/deploy.sh creates or reuses a local password file at .deploy/grafana-admin-password; normal GitHub CD uses the GRAFANA_ADMIN_PASSWORD Environment secret; the manual rebuild generates a temporary password. The secret value must never be committed.

## 8. Remote state and locking

Root backend (backend.tf):
- S3 bucket: TF_STATE_BUCKET;
- key: cloudstart/dev/terraform.tfstate;
- encryption enabled;
- use_lockfile = true (S3-native lock file).

Bootstrap (bootstrap/main.tf) also creates the DynamoDB table cloudstart-terraform-lock for compatibility with older tooling. The current root backend and GitHub workflows do not use DynamoDB locking. Do not add a dynamodb_table backend argument unless the locking architecture is deliberately redesigned.

scripts/ensure-terraform-state.sh validates the expected AWS account, bucket owner, and region; it reuses a matching existing bucket and refuses to create a bucket when access or ownership cannot be established safely.

## 9. Deployment entry points

| Entry point | What it does | AWS impact |
| --- | --- | --- |
| make setup | Installs the local toolchain and Python environment. | No AWS resources. |
| make up / make down | Starts/stops the local application Compose stack. | Local Docker only. |
| make tf-init | Initializes root Terraform against an already-existing bucket. | Reads/locks state; does not create infrastructure. |
| make deploy | Validates, provisions/reuses secrets and state bucket, plans/applies baseline, builds/pushes images, activates ECS, migrates database, and runs smoke tests. | Creates/changes billable AWS resources. |
| deploy-dev.yml | Pushes immutable Git-SHA images and applies an allowlisted development plan after CI. | Changes development AWS resources. |
| rebuild-dev.yml | Manual destructive teardown/rebuild; exact input REBUILD required. | Destroys and recreates CloudStart development resources; state bucket is retained. |

The deploy workflow is triggered by application/runtime artifact paths on branch Joao or by workflow_dispatch. Changes to documentation, Terraform, scripts, or workflow definitions alone do not trigger automatic application deployment. The CD job requires AWS_CD_ROLE_ARN; TF_STATE_BUCKET is optional because it has a default.

## 10. Validation ownership

- Standard CI runs backend tests, image build/runtime smoke, Compose validation, Terraform validation, security scans, and workflow contract checks.
- Extreme validation runs broader local/system checks and optional read-only AWS checks when OIDC is configured.
- Documentation is manually cross-checked against repository source as part of code changes. A README injection block for terraform-docs is not currently present; do not claim CI generates the Terraform input/output section until such a gate exists.

## 11. Source files

- Root inputs and validation: variables.tf, main.tf, locals.tf.
- Root outputs: outputs.tf.
- Bootstrap inputs/resources: bootstrap/variables.tf, bootstrap/main.tf.
- Development metadata: config/dev.env, config/dev.tfvars.
- Local deployment: scripts/deploy.sh, scripts/ensure-terraform-state.sh, scripts/provision-db-credentials.sh, scripts/provision-backend-auth-secret.sh.
- GitHub workflows: .github/workflows/ci.yml, .github/workflows/extreme-validation.yml, .github/workflows/deploy-dev.yml, .github/workflows/rebuild-dev.yml.
