data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

check "frontend_capacity_consistency" {
  assert {
    condition     = var.frontend_min_task_count <= var.frontend_desired_task_count && var.frontend_desired_task_count <= var.frontend_max_task_count
    error_message = "Frontend task counts must satisfy min <= desired <= max."
  }
}

check "backend_capacity_consistency" {
  assert {
    condition     = var.backend_min_task_count <= var.backend_desired_task_count && var.backend_desired_task_count <= var.backend_max_task_count
    error_message = "Backend task counts must satisfy min <= desired <= max."
  }
}

check "rds_storage_consistency" {
  assert {
    condition     = var.db_max_allocated_storage >= var.db_allocated_storage
    error_message = "db_max_allocated_storage must be greater than or equal to db_allocated_storage."
  }
}


check "grafana_password_when_monitoring_enabled" {
  assert {
    condition     = var.grafana_admin_password != null && length(var.grafana_admin_password) >= 12
    error_message = "grafana_admin_password must be provided with at least 12 characters for the current Zabbix/Grafana monitoring stack."
  }
}
