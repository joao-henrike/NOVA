resource "aws_cloudwatch_log_group" "frontend" {
  #checkov:skip=CKV_AWS_158:CloudWatch Logs encrypts stored log data by default with an AWS-owned key; a customer-managed KMS key adds cost and is not required by this low-cost MVP.
  #checkov:skip=CKV_AWS_338:Retention is deliberately 7 days in development and 30 days in production to cap log-storage cost; longer retention requires an explicit budget and compliance requirement.
  name              = "/ecs/${local.name}/frontend"
  retention_in_days = local.log_retention_days

  tags = merge(local.global_tags, {
    Name      = "/ecs/${local.name}/frontend"
    Component = "frontend"
  })
}

resource "aws_cloudwatch_log_group" "backend" {
  #checkov:skip=CKV_AWS_158:CloudWatch Logs encrypts stored log data by default with an AWS-owned key; a customer-managed KMS key adds cost and is not required by this low-cost MVP.
  #checkov:skip=CKV_AWS_338:Retention is deliberately 7 days in development and 30 days in production to cap log-storage cost; longer retention requires an explicit budget and compliance requirement.
  name              = "/ecs/${local.name}/backend"
  retention_in_days = local.log_retention_days

  tags = merge(local.global_tags, {
    Name      = "/ecs/${local.name}/backend"
    Component = "backend"
  })
}

resource "aws_cloudwatch_log_group" "db_bootstrap" {
  #checkov:skip=CKV_AWS_158:CloudWatch Logs encrypts stored log data by default with an AWS-owned key; a customer-managed KMS key adds cost and is not required by this low-cost MVP.
  #checkov:skip=CKV_AWS_338:Retention is deliberately 7 days in development and 30 days in production to cap log-storage cost; longer retention requires an explicit budget and compliance requirement.
  name              = "/ecs/${local.name}/db-bootstrap"
  retention_in_days = local.log_retention_days

  tags = merge(local.global_tags, {
    Name      = "/ecs/${local.name}/db-bootstrap"
    Component = "database-bootstrap"
  })
}

resource "aws_cloudwatch_log_group" "db_migration" {
  #checkov:skip=CKV_AWS_158:CloudWatch Logs encrypts stored log data by default with an AWS-owned key; a customer-managed KMS key adds cost and is not required by this low-cost MVP.
  #checkov:skip=CKV_AWS_338:Retention is deliberately 7 days in development and 30 days in production to cap log-storage cost; longer retention requires an explicit budget and compliance requirement.
  name              = "/ecs/${local.name}/db-migration"
  retention_in_days = local.log_retention_days

  tags = merge(local.global_tags, {
    Name      = "/ecs/${local.name}/db-migration"
    Component = "database-migration"
  })
}

resource "aws_cloudwatch_log_group" "monitoring" {
  #checkov:skip=CKV_AWS_158:CloudWatch Logs encrypts stored log data by default with an AWS-owned key; a customer-managed KMS key adds cost and is not required by this low-cost MVP.
  #checkov:skip=CKV_AWS_338:Retention is deliberately 7 days in development and 30 days in production to cap log-storage cost; longer retention requires an explicit budget and compliance requirement.
  name              = "/ecs/${local.name}/monitoring"
  retention_in_days = local.log_retention_days

  tags = merge(local.global_tags, {
    Name      = "/ecs/${local.name}/monitoring"
    Component = "monitoring"
  })
}
