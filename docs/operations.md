# NOVA Cloud Operations Orchestrator

NOVA Ops is the repository-owned command-line control plane for inspecting, scaling, shutting down, and restoring the existing CloudStart development environment in AWS. It uses the AWS identity already configured in the operator's shell. Full infrastructure shutdown/resume is Terraform-managed, plan-reviewed, confirmation-gated, and available only from branch TESTE1.

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

# Full AWS infrastructure shutdown and restoration
make ops ACTION=shutdown
make ops ACTION=resume
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
| stop all | Sets frontend, backend, and monitoring ECS desired counts to zero; leaves RDS, NAT, and ALB running |
| start all | Runs the full resume workflow: restores NAT/ALB, starts RDS, then restores ECS workloads |
| stop monitoring / start monitoring | Sets the stateful monitoring ECS service to zero or one task |
| scale frontend N / scale backend N | Changes ECS desired count within the respective max task count in config/dev.tfvars |
| restart SERVICE | Requests a new ECS deployment for an already-running service |

When frontend/backend desired count is set to zero, the script also sets the Application Auto Scaling minimum to zero and suspends dynamic and scheduled scaling for that target. Starting or scaling above zero restores the minimum to the requested count and resumes scaling. The maximum is always written from the committed development configuration. Terraform ignores the ECS desired count for both application services; the frontend scaling target ignores both min/max changes, while the backend target ignores only the minimum and keeps its maximum Terraform-managed.

Monitoring is intentionally a single stateful Fargate task in this MVP. It accepts only zero or one task. Terraform now ignores its operator-managed desired count so a future plan does not automatically undo a deliberate stop.

### Full infrastructure shutdown and resume

For meaningful savings, use the full infrastructure workflow rather than only setting ECS desired counts to zero.

~~~bash
make ops ACTION=shutdown
# Confirm exactly: SHUTDOWN cloudstart-dev

make ops ACTION=resume
# Confirm exactly: RESUME cloudstart-dev
~~~

Equivalent Make targets are `make ops-shutdown` and `make ops-resume`. The interactive menu also exposes both operations.

The full shutdown workflow:

1. Requires branch `TESTE1`, the expected AWS account, AWS CLI, Terraform, the protected remote-state bucket, and the local secret/ARN metadata generated by the existing deployment scripts.
2. Initializes the existing S3 Terraform backend and creates a refreshed plan.
3. Displays the plan and rejects any managed-resource change outside the explicit NOVA Ops allowlist.
4. Requires the exact shutdown confirmation.
5. Suspends frontend/backend autoscaling, sets all three ECS services to zero, waits for zero running tasks, and verifies that dependent workloads are drained.
6. Stops both RDS instances without deleting them or their data, and waits until both report `stopped`.
7. Refreshes and validates the Terraform plan again, then applies only the approved changes.

Terraform disables `enable_nat_gateways` and `enable_public_alb`. It removes the two per-AZ NAT Gateways and their allocated public IPv4 addresses, private-app default routes to NAT, the public ALB, its listeners and target groups, ALB security rules, and ECS service target-group attachments. ECS services remain registered at desired count zero.

The full resume workflow reverses that process. It recreates NAT Gateways and public IPv4 allocations, the ALB/listeners/target groups and ECS target attachments; starts both RDS instances; waits for them to become `available`; restores frontend/backend autoscaling bounds and configured task counts; starts the monitoring task; and waits for ECS stability.

Both workflows build a Terraform plan and reject out-of-scope changes. Shutdown rejects unexpected resource creation; resume rejects unexpected resource deletion. They never delete the VPC, RDS instances, database contents, ECR repositories/images, Secrets Manager secrets, CloudWatch log groups, snapshots, or S3 remote-state bucket. They do not run `terraform destroy`.

The infrastructure helper needs the local ignored files created by the deployment workflow:

~~~text
.deploy/grafana-admin-password
.deploy/db-secret-arns.env
.deploy/backend-auth-secret-arn.env
~~~

Those files are intentionally not committed. If they are missing, the helper fails closed rather than rotating the Grafana password or guessing database/authentication secret ARNs. Run full infrastructure commands from the same local deployment workspace after checking out `TESTE1`.

A stopped RDS DB instance is automatically restarted after seven consecutive days. Therefore this is a cost-reduction mode for temporary shutdown, not an indefinite zero-cost state. For a longer shutdown, the databases need a separate snapshot/retention and deletion/recovery procedure; that destructive workflow is intentionally not included here.

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

## What remains billable after full shutdown

The full shutdown removes the recurring compute/network charges associated with the ECS tasks, ALB, and NAT Gateways, but it does not make the account or project cost-free.

Preserved resources that can continue to incur charges include:

- RDS provisioned database storage, automated backup storage, manual snapshots, and transaction logs retained for recovery; stopped RDS instances also restart automatically after seven days.
- ECR repository image storage.
- S3 Terraform state, object versions, and requests.
- CloudWatch log ingestion and retained log storage.
- Secrets Manager secrets.
- Other account-level services or resources not created by this Terraform state.

The VPC, subnets, route tables, security groups, and Internet Gateway are kept so the database subnet configuration and the remote-state-managed environment remain recoverable. They do not carry the same hourly compute charges as NAT Gateways or an ALB, although data transfer and other account activity may still incur charges.

Use `make ops ACTION=costs` for account-wide month-to-date costs and `make ops ACTION=costs ARGS='project'` for usage filtered by activated project cost-allocation tags. Cost Explorer data is delayed; it is not a real-time proof that every resource has stopped billing.

## Side effects and safety boundaries

- Read-only commands: overview, services, inventory, costs, and logs.
- ECS state-changing commands: scale, stop, start, and restart.
- RDS state-changing commands: db stop and db start, each protected by dependency checks and exact interactive confirmation.
- Read-only commands never mutate AWS. ECS/RDS controls issue their documented AWS API updates. Full shutdown/resume invokes Terraform plan/apply only after exact confirmation and strict resource allowlisting; it removes only the network ingress/egress resources described above, not the databases or remote state.
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
ec2:DescribeAddresses
ec2:DescribeRouteTables
ec2:CreateRoute
ec2:ReplaceRoute
ec2:DeleteRoute
ec2:CreateTags
ec2:AllocateAddress
ec2:ReleaseAddress
ec2:DeleteNatGateway
elasticloadbalancing:DescribeLoadBalancers
elasticloadbalancing:CreateLoadBalancer
elasticloadbalancing:DeleteLoadBalancer
elasticloadbalancing:CreateTargetGroup
elasticloadbalancing:DeleteTargetGroup
elasticloadbalancing:CreateListener
elasticloadbalancing:DeleteListener
elasticloadbalancing:CreateRule
elasticloadbalancing:DeleteRule
ce:GetCostAndUsage
ce:GetCostAndUsageWithResources
~~~

Full Terraform apply also requires the narrowly scoped EC2/VPC, ELBv2, ECS, Application Auto Scaling, RDS, and S3 state permissions used by the root Terraform configuration. The list above is illustrative, not a complete Terraform provider policy. Do not add these operator permissions to the GitHub deployment OIDC role (AWS_CD_ROLE_ARN). Use a dedicated human operator role or the AWS identity intentionally configured in CloudShell. Grant only the permissions needed for the operations you plan to run.

## Tests

Run the mock-based safety tests without contacting AWS:

~~~bash
make ops-test
~~~

The tests verify valid scaling, Terraform-configured capacity limits, account mismatch rejection, monitoring singleton constraints, unknown log-group rejection, and that an RDS stop request is not sent without interactive confirmation.

These local tests do not prove the live AWS identity has permissions or that the currently deployed resources match the configuration. Verify current state using make ops ACTION=overview before making any change.
