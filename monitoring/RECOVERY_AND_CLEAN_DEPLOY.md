# NOVA monitoring — recovery and clean deployment

This branch changes Grafana from disposable SQLite to a dedicated PostgreSQL database
(`nova_grafana`) and role on the existing private monitoring RDS. It does not
migrate an existing SQLite database automatically. Export current custom dashboards,
folders, alert rules and datasource settings before replacing any existing task.
Do not destroy RDS or Terraform state to perform an upgrade.

## Fresh deployment

1. Merge only after CI and Terraform validation pass. Use the repository's guarded
   `main` deployment workflow. Confirm `aws sts get-caller-identity`, region,
   the expected account in `config/dev.env`, and the intended state bucket/key.
   Do not reuse a state bucket belonging to another account or bypass the guard.
2. In a clean checkout of the merged branch, run:
   `make setup`, `make doctor`, `make tf-validate`,
   `python3 -m unittest discover -s monitoring/tests -v`,
   `python3 monitoring/grafana/validate.py`, then `make deploy`.
   The deploy script reuses the existing admin secret on a clean checkout if it
   exists; use a high-entropy stable administrator credential. Do not print secrets.
3. Check ECS task health, Grafana `/grafana/api/health` (database must be ok),
   CloudWatch log streams `grafana-db-init`, `grafana`, and
   `monitoring-bootstrap`. Require the messages:
   `NOVA Grafana PostgreSQL initialized`,
   `NOVA monitoring bootstrap complete`,
   `NOVA original dashboards verified: 30`, and
   `NOVA Zabbix collector ready`.
4. Verify the 30 original dashboards, 30 Zabbix Live dashboards and
   `nova-monitoring` by UID; inspect actual datasource queries, not just HTTP health.
   Templates requiring unavailable instrumentation are not expected to show data.
5. In a disposable test environment only, create a uniquely named test dashboard,
   restart/replace the task, then verify the same UID, datasource health and retained
   Zabbix history. Compare before/after counts; delete the test dashboard only after
   validation. Check for new `history_pkey`, OOM, 503 and authentication errors.
6. Verify alarms and ECS stop-event logging. Alarm states are visible in CloudWatch;
   notification subscriptions/actions are not configured by this branch.

## Operational boundaries

- The initial database/encryption keys are domain-separated derivatives of the
  initial admin credential, frozen in Terraform state and injected through Secrets
  Manager. Protect the state; do not replace the `terraform_data` key resource or
  regenerate credentials without a documented rotation/recovery plan. Existing
  Grafana and Zabbix admin passwords must remain synchronized with the bootstrap.
- PostgreSQL requires TLS encryption, but this configuration does not pin/verify
  the RDS server certificate. Add verified TLS and independent random secret
  generation before production. RDS remains single-AZ and shared for cost.
- The task is still a singleton with Zabbix and Grafana in one task. The collector
  is nonessential; Zabbix and Grafana remain essential. The deployment policy
  intentionally prevents two simultaneous Zabbix writers; this means a planned
  outage during deployment. Do not scale the combined service to two.
- Grafana originals are fetched from a private S3 object with SHA-256 verification.
  Dashboard provisioning is create-if-missing; intentional template upgrades
  require a controlled migration, not overwriting live edits.
- Zabbix watermarks are recovered from persistent item history via `lastclock`;
  this reduces replay after replacement, but sender ACK is not a transactional
  database commit. Test partial batches and late-arriving samples. Existing
  historical duplicate errors are not repaired by deleting history.
- Future work: split Grafana, Zabbix and collector into separate ECS services with
  private service discovery; two Grafana replicas with shared database, verified
  session/live/alerting HA, and independent health checks; per-container OOM alarm
  and notification routing; backup restore test and audit of missing CloudWatch
  series. A healthy ALB alone does not prove the dashboards/collector are complete.
