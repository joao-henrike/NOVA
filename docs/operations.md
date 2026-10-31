# NOVA Cloud Operations Orchestrator

NOVA Ops is the repository-owned command-line control plane for inspecting and operating the existing CloudStart development environment in AWS. It uses the AWS identity already configured in the operator's shell; it does not provision infrastructure or alter Terraform state.

## Quick start

From the repository root, in AWS CloudShell or an environment with AWS CLI v2 and jq:

~~~bash
make ops-help
make ops
~~~

Direct commands:

~~~bash
make ops ACTION=overview
make ops ACTION=services
make ops ACTION=inventory
make ops ACTION=costs
make ops ACTION=costs ARGS='project'
make ops ACTION=costs ARGS='resources ecs'
make ops ACTION=logs ARGS='backend --since 2h'
make ops ACTION=logs ARGS='backend --since 30m --follow'
make ops ACTION=scale ARGS='frontend 1'
make ops ACTION=stop ARGS='application'
make ops ACTION=start ARGS='application'
make ops ACTION=db ARGS='status'
~~~

NOVA_AWS_REGION and NOVA_EXPECTED_ACCOUNT_ID can override the non-secret values in config/dev.env for a deliberate alternate development target. Do not use them to bypass the account guard accidentally.

## Account and region guard

Before every AWS operation, the script calls aws sts get-caller-identity and compares the returned account ID with EXPECTED_AWS_ACCOUNT_ID from config/dev.env (default 760396521507). A mismatch terminates the command before the requested action runs. The configured region is read from config/dev.env.

The script never reads, sources, prints, or writes AWS credentials or application secrets. It uses only the current AWS CLI credentials/profile/role.

## What can be inspected

| Command | Information |
| --- | --- |
| overview | ECS desired/running/pending tasks, autoscaling targets, both RDS instances, tagged NAT Gateways, ALB state/DNS, tagged-resource count |
| services | ECS desired/running/pending counts and frontend/backend autoscaling bounds |
| inventory | Resources returned by Resource Groups Tagging API with Project=cloudstart and Environment=dev |
| costs | Cost Explorer month-to-date total grouped by AWS service, with billing currency reported by Cost Explorer |
| costs project | Month-to-date charges filtered by Project and Environment cost-allocation tags |
| costs project | Month-to-date charges filtered by Project and Environment cost-allocation tags |

| costs resources ecs/rds/elb/vpc/s3 | Optional daily resource-ID breakdown for the last 14 days, if AWS resource-level data is enabled for that service |
| logs GROUP | CloudWatch Logs for a selected ECS task log group; accepts --since 30m, 2h, 1d and --follow |

Known log groups:

~~~text
/ecs/cloudstart-dev/frontend
/ecs/cloudstart-dev/backend
/ecs/cloudstart-dev/monitoring
/ecs/cloudstart-dev/db-bootstrap
/ecs/cloudstart-dev/db-migration
~~~

Cost Explorer's default month-to-date output covers the AWS billing account, not just resources belonging to NOVA. Use costs project to filter by both Project and Environment cost-allocation tags; the inventory is not itself a bill. AWS user-defined cost-allocation tags must first be activated in Billing/Cost Management for the account. Only eligible usage after tag activation is included; do not expect retroactive attribution. See [activating cost allocation tags](https://docs.aws.amazon.com/cost-management/latest/userguide/activating-tags.html).

Resource-level Cost Explorer data is not universally available. It must be enabled for the relevant service in Cost Explorer settings, daily resource history is limited to the most recent 14 days, and new opt-in data can take up to 48 hours to appear. Unsupported or unconfigured resources may appear as No resource ID. See the [AWS resource-level cost data guide](https://docs.aws.amazon.com/cost-management/latest/userguide/ce-per-resource.html) and [GetCostAndUsageWithResources API](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsageWithResources.html). Cost Explorer API usage can incur a per-request fee; see [Cost Explorer pricing](https://aws.amazon.com/aws-cost-management/aws-cost-explorer/pricing/).

## Safe workload controls

NOVA Ops changes runtime capacity; it does not delete resources.

| Command | Effect |
| --- | --- |
| stop frontend / start frontend | Sets frontend ECS desired count to zero or back to the configured default |
| stop backend / start backend | Sets backend ECS desired count to zero or back to the configured default; starting requires application RDS to be available |
| stop application / start application | Stops or restores both frontend and backend services; startup orders backend before frontend |
| stop all / start all | Stops all three ECS workloads, or starts both RDS instances (with confirmation if stopped) and then starts all ECS workloads once both databases are available |
| stop monitoring / start monitoring | Sets the stateful monitoring ECS service to zero or one task |
| scale frontend N / scale backend N | Changes ECS desired count within the respective max task count in config/dev.tfvars |
| restart SERVICE | Requests a new ECS deployment for an already-running service |

When frontend/backend desired count is set to zero, the script also sets the Application Auto Scaling minimum to zero and suspends dynamic and scheduled scaling for that target. Starting or scaling above zero restores the minimum to the requested count and resumes scaling. The maximum remains bounded by the committed development configuration. Terraform ignores the operator-managed desired count and scaling minimum/maximum for these application services.

Monitoring is intentionally a single stateful Fargate task in this MVP. It accepts only zero or one task. Terraform now ignores its operator-managed desired count so a future plan does not automatically undo a deliberate stop.

### Temporarily stopping an RDS instance

Only the two existing database instances are supported:

- application → cloudstart-dev-db
- monitoring → cloudstart-dev-monitoring-db

Before stopping the application database, both frontend and backend ECS desired counts must be zero. Before stopping the monitoring database, the monitoring ECS service must be zero. The command also requires an interactive exact confirmation:

~~~bash
make ops ACTION=stop ARGS='all'          # frontend, backend and monitoring ECS tasks
make ops ACTION=stop ARGS='application'
make ops ACTION=stop ARGS='monitoring'
make ops ACTION=db ARGS='stop application'
# Type exactly: STOP cloudstart-dev-db
~~~

To start an RDS instance:

~~~bash
make ops ACTION=start ARGS='all'
# If an RDS instance is stopped, confirm START cloudstart-dev-db and/or START cloudstart-dev-monitoring-db.
# Once both RDS instances report available, run start all again.
make ops ACTION=db ARGS='status'
~~~

RDS start is asynchronous. Wait until the instance reports available before starting its dependent ECS workload. An RDS stop can reduce instance-hour charges, but provisioned storage and backup storage continue to incur charges. A stopped RDS instance is automatically restarted after seven consecutive days, so this is not a permanent shutdown. See [Stopping an Amazon RDS DB instance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StopInstance.html) and [Starting an Amazon RDS DB instance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StartInstance.html).

## What remains billable when workloads are stopped

Setting ECS desired count to zero and stopping RDS does not turn off the whole environment. The tool intentionally does not stop/delete the following resources:

- NAT Gateways and their associated public IPv4 addresses/EIPs;
- the public Application Load Balancer and its listeners/target groups;
- VPC, subnets, route tables, Internet Gateway, security groups, and ECR repositories/images;
- the remote Terraform state bucket and its retained versions;
- CloudWatch log storage and retained log events;
- RDS provisioned storage, snapshots, and backups while the database is stopped.

The ALB and NAT Gateways do not have a safe generic pause operation in this interface. Removing them requires an explicit Terraform architecture change and a reviewed plan, because the ALB is the public application entry point and NAT is the egress path for private ECS workloads. Do not manually delete Terraform-managed resources to save cost.

## Side effects and safety boundaries

- Read-only commands: overview, services, inventory, costs, and logs.
- ECS state-changing commands: scale, stop, start, and restart.
- RDS state-changing commands: db stop and db start, each protected by dependency checks and exact interactive confirmation.
- No command invokes Terraform apply, destroy, or state; no command deletes AWS resources.
- No automatic scheduling is configured. Run the command when you choose to operate the environment.
- The script performs no live query until the operator executes it with AWS credentials.

## IAM permissions

The active human/operator role needs read and narrowly scoped state-change permissions for the actions the operator intends to use. Typical actions include:

~~~text
sts:GetCallerIdentity
ecs:DescribeClusters
ecs:DescribeServices
ecs:UpdateService
application-autoscaling:DescribeScalableTargets
application-autoscaling:RegisterScalableTarget
rds:DescribeDBInstances
rds:StopDBInstance
rds:StartDBInstance
logs:DescribeLogGroups
logs:DescribeLogStreams
logs:GetLogEvents
logs:FilterLogEvents
tag:GetResources
ec2:DescribeNatGateways
elasticloadbalancing:DescribeLoadBalancers
ce:GetCostAndUsage
ce:GetCostAndUsageWithResources
~~~

Do not add these operator permissions to the GitHub deployment OIDC role (AWS_CD_ROLE_ARN). Use a dedicated human operator role or the AWS identity intentionally configured in CloudShell. Grant only the permissions needed for the operations you plan to run.

## Tests

Run the mock-based safety tests without contacting AWS:

~~~bash
make ops-test
~~~

The tests verify valid scaling, Terraform-configured capacity limits, account mismatch rejection, monitoring singleton constraints, unknown log-group rejection, and that an RDS stop request is not sent without interactive confirmation.

These local tests do not prove the live AWS identity has permissions or that the currently deployed resources match the configuration. Verify current state using make ops ACTION=overview before making any change.
