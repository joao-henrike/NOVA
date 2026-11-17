# NOVA — Grafana dashboard templates

30 dashboards, 506 requirements. Importable Grafana dashboard JSON, organized in six categories. Existing bootstrap dashboard `nova-monitoring` is unchanged.

## Importação
In Grafana, Dashboards > New > Import, upload one JSON at a time (or use your approved dashboard provisioning process). Existing datasource UIDs: `nova-cloudwatch` and `nova-zabbix`. The CloudWatch datasource uses the ECS task role; no credentials are stored here. Textbox variables default to development resource names; replace ALB, target group and NAT placeholders with your actual AWS dimension identifiers (ARN suffix for ALB/TG, NAT ID for NAT). Verify log group names and dimensions in the actual deployed environment.

- CloudWatch panels use native metrics, including basic Container Insights. Service-level fallback is explicitly used in Fargate views; container-level collectors still need to be implemented.
- Existing internal Zabbix health charts use exact item names from `monitoring/bootstrap.py`.
- **PENDENTE** charts target planned numeric items defined in `collector-contract.json`. No hosts, items, triggers, or collectors are created by importing the dashboard. Missing data remains missing. Review units, aggregation semantics, scope, and data source permissions against your deployment before enabling collectors.
- `requirements.md` and catalog panels preserve all original requirements. A composite requirement can need multiple metrics, instrumentation, inventory queries or logs; it is not automatically fulfilled by a template panel.
- FinOps billing is delayed; operational metrics are not billed costs. Business checkout is not evidence of real revenue.
- The templates are separate from the current automatic AWS bootstrap. They are not auto-imported on deploy. No infrastructure or IAM changes.

## Validation
Run `python3 monitoring/grafana/validate.py` from the repository root. Structural validation does not verify Grafana runtime/plugin compatibility or CloudWatch data; conduct a real import and verify query inspector. Keep templates free of secrets and test-data datasources.

## Index

- [nova-01-global-overview](dashboards/01-infrastructure/01-global-overview.json)
- [nova-02-ecs-cluster](dashboards/01-infrastructure/02-ecs-cluster.json)
- [nova-03-ecs-services](dashboards/01-infrastructure/03-ecs-services.json)
- [nova-04-fargate-containers](dashboards/01-infrastructure/04-fargate-containers.json)
- [nova-05-auto-scaling](dashboards/01-infrastructure/05-auto-scaling.json)
- [nova-06-alb](dashboards/01-infrastructure/06-alb.json)
- [nova-07-target-groups](dashboards/01-infrastructure/07-target-groups.json)
- [nova-08-vpc-network](dashboards/01-infrastructure/08-vpc-network.json)
- [nova-09-nat-gateways](dashboards/01-infrastructure/09-nat-gateways.json)
- [nova-10-frontend-nginx](dashboards/02-applications/10-frontend-nginx.json)
- [nova-11-backend-fastapi](dashboards/02-applications/11-backend-fastapi.json)
- [nova-12-api-endpoints](dashboards/02-applications/12-api-endpoints.json)
- [nova-13-rds-application](dashboards/02-applications/13-rds-application.json)
- [nova-14-rds-monitoring](dashboards/02-applications/14-rds-monitoring.json)
- [nova-15-postgresql](dashboards/02-applications/15-postgresql.json)
- [nova-16-business-intelligence](dashboards/02-applications/16-business-intelligence.json)
- [nova-17-zabbix](dashboards/03-sre/17-zabbix.json)
- [nova-18-grafana](dashboards/03-sre/18-grafana.json)
- [nova-19-availability-slo](dashboards/03-sre/19-availability-slo.json)
- [nova-20-disaster-recovery](dashboards/03-sre/20-disaster-recovery.json)
- [nova-21-backup-restore](dashboards/03-sre/21-backup-restore.json)
- [nova-22-soc](dashboards/04-security/22-soc.json)
- [nova-23-authentication](dashboards/04-security/23-authentication.json)
- [nova-24-vulnerability-compliance](dashboards/04-security/24-vulnerability-compliance.json)
- [nova-25-github-actions](dashboards/05-devops/25-github-actions.json)
- [nova-26-ecr](dashboards/05-devops/26-ecr.json)
- [nova-27-terraform-governance](dashboards/05-devops/27-terraform-governance.json)
- [nova-28-finops-global](dashboards/06-finops/28-finops-global.json)
- [nova-29-finops-resources](dashboards/06-finops/29-finops-resources.json)
- [nova-30-finops-optimization](dashboards/06-finops/30-finops-optimization.json)
