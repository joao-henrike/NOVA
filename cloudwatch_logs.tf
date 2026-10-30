resource "aws_cloudwatch_log_group" "frontend" {
  name              = "/ecs/${local.name}/frontend"
  retention_in_days = local.log_retention_days

  tags = merge(local.global_tags, {
    Name      = "/ecs/${local.name}/frontend"
    Component = "frontend"
  })
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${local.name}/backend"
  retention_in_days = local.log_retention_days

  tags = merge(local.global_tags, {
    Name      = "/ecs/${local.name}/backend"
    Component = "backend"
  })
}

resource "aws_cloudwatch_log_group" "db_bootstrap" {
  name              = "/ecs/${local.name}/db-bootstrap"
  retention_in_days = local.log_retention_days

  tags = merge(local.global_tags, {
    Name      = "/ecs/${local.name}/db-bootstrap"
    Component = "database-bootstrap"
  })
}

resource "aws_cloudwatch_log_group" "db_migration" {
  name              = "/ecs/${local.name}/db-migration"
  retention_in_days = local.log_retention_days

  tags = merge(local.global_tags, {
    Name      = "/ecs/${local.name}/db-migration"
    Component = "database-migration"
  })
}

resource "aws_cloudwatch_log_group" "monitoring" {
  name              = "/ecs/${local.name}/monitoring"
  retention_in_days = local.log_retention_days

  tags = merge(local.global_tags, {
    Name      = "/ecs/${local.name}/monitoring"
    Component = "monitoring"
  })
}
