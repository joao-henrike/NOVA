# Compact dashboard query inventory for the existing monitoring sidecar.
# Compression avoids embedding the full >1 MB dashboard templates in ECS.
locals {
  nova_zabbix_dashboards = [
    for p in sort(tolist(fileset("${path.module}/monitoring/grafana/dashboards", "**/*.json"))) :
    jsondecode(file("${path.module}/monitoring/grafana/dashboards/${p}"))
  ]
  nova_zabbix_catalog = [
    for d in local.nova_zabbix_dashboards : {
      uid   = d.uid
      title = d.title
      panels = [
        for p in d.panels : {
          title  = p.title
          unit   = try(p.fieldConfig.defaults.unit, "short")
          source = try(p.datasource.uid, "")
          target = p.targets[0]
        } if contains(["nova-cloudwatch", "nova-zabbix"], try(p.datasource.uid, ""))
      ]
    }
  ]
  nova_zabbix_resource_vars = {
    region            = var.aws_region
    project           = local.name
    cluster           = aws_ecs_cluster.this.name
    appdb             = aws_db_instance.this.identifier
    mondb             = aws_db_instance.monitoring.identifier
    vpc               = aws_vpc.this.id
    alb               = try(aws_lb.this[0].arn_suffix, "")
    tg_frontend       = try(aws_lb_target_group.frontend[0].arn_suffix, "")
    tg_backend        = try(aws_lb_target_group.backend[0].arn_suffix, "")
    tg_grafana        = try(aws_lb_target_group.grafana[0].arn_suffix, "")
    nat_a             = try(aws_nat_gateway.this[local.azs[0]].id, "")
    nat_b             = try(aws_nat_gateway.this[local.azs[1]].id, "")
    nat_c             = try(aws_nat_gateway.this[local.azs[2]].id, "")
    logs_frontend     = aws_cloudwatch_log_group.frontend.name
    logs_backend      = aws_cloudwatch_log_group.backend.name
    logs_db_bootstrap = aws_cloudwatch_log_group.db_bootstrap.name
    logs_db_migration = aws_cloudwatch_log_group.db_migration.name
    logs_monitoring   = aws_cloudwatch_log_group.monitoring.name
    target_arns       = concat(aws_lb_target_group.frontend[*].arn, aws_lb_target_group.backend[*].arn, aws_lb_target_group.grafana[*].arn)
    ecr_repositories  = [aws_ecr_repository.frontend.name, aws_ecr_repository.backend.name]
    https_url         = var.enable_public_alb && var.acm_certificate_arn != "" && var.alb_domain_name != "" ? "https://${var.alb_domain_name}" : ""
  }
}
