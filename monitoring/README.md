# CloudStart Monitoring — Zabbix + Grafana

The current MVP uses a containerized Zabbix + Grafana monitoring plane.

## Components

```text
Zabbix Server
      |
Zabbix Web
      |
    Grafana
```

In AWS these three components run inside one ECS/Fargate task. The task uses a dedicated private PostgreSQL RDS instance for Zabbix state/history. Grafana is exposed through the existing Application Load Balancer at `/grafana/`.

For local development, `docker-compose.monitoring.yml` provides the same logical stack with PostgreSQL, Zabbix Server, Zabbix Web and Grafana containers.

## Monitoring scope in the current MVP

The implementation is intentionally focused on end-to-end availability and behavior:

- ALB reachability;
- frontend `/health`;
- backend `/api/health`;
- backend `/api/health/db`;
- Zabbix server/web;
- Grafana;
- monitoring PostgreSQL.

Kubernetes is not part of this MVP and is not provisioned. It can be added as a monitored runtime later if the project actually adopts Kubernetes.

## Grafana integration

The Grafana container installs the Zabbix application plugin:

```text
alexanderzobnin-zabbix-app@6.8.0
```

The plugin connects Grafana to the Zabbix API. In AWS the Zabbix Web API is internal to the monitoring ECS task.

## CloudWatch container logs

Zabbix/Grafana remain the metrics and availability monitoring plane. ECS stdout/stderr is shipped separately through the `awslogs` driver to Terraform-managed CloudWatch log groups. The monitoring task's Zabbix Server, Zabbix Web, and Grafana containers share the monitoring log group but use distinct stream prefixes.

The other four groups are for frontend, backend, database bootstrap, and database migration tasks. Retention is 7 days in development and 30 days in production. The groups use the AWS-owned CloudWatch Logs encryption key; no customer-managed CMK or long-term S3 archive is configured.

## Important boundary

CloudWatch Logs provides centralized short-retention container logs, not a long-term audit archive. Zabbix + Grafana provide availability/metrics views and are not a replacement for the log pipeline.

> Monitoring image choices were aligned with the current Zabbix 8.0 container documentation and Grafana documentation available at the time of this update.
