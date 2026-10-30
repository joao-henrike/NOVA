data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"
      identifiers = [
        "ecs-tasks.amazonaws.com"
      ]
    }
  }
}

data "aws_iam_policy_document" "ecs_execution_permissions" {
  statement {
    sid    = "EcrPull"
    effect = "Allow"

    actions = [
      "ecr:GetAuthorizationToken"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "EcrRepositoryPull"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ]

    resources = [
      aws_ecr_repository.frontend.arn,
      aws_ecr_repository.backend.arn
    ]
  }

  # Compatibility only while deploy_application=false: the disabled baseline
  # keeps the legacy backend task definition valid if an existing service is
  # still running. The deployed backend switches to its dedicated execution role.
  dynamic "statement" {
    for_each = var.deploy_application ? [] : [aws_db_instance.this.master_user_secret[0].secret_arn]

    content {
      sid       = "LegacyBackendDatabaseSecretWhileDisabled"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [statement.value]
    }
  }

  dynamic "statement" {
    for_each = var.deploy_application || var.backend_auth_secret_arn == "" ? [] : [var.backend_auth_secret_arn]

    content {
      sid       = "LegacyBackendAuthSecretWhileDisabled"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = merge(local.global_tags, {
    Name = "${local.name}-ecs-execution"
  })
}

resource "aws_iam_role_policy" "ecs_execution" {
  name   = "${local.name}-ecs-execution"
  role   = aws_iam_role.ecs_execution.id
  policy = data.aws_iam_policy_document.ecs_execution_permissions.json
}

data "aws_iam_policy_document" "ecs_backend_execution_permissions" {
  source_policy_documents = [data.aws_iam_policy_document.ecs_execution_permissions.json]

  dynamic "statement" {
    for_each = var.db_runtime_secret_arn == "" ? [] : [var.db_runtime_secret_arn]

    content {
      sid       = "ReadRuntimeDatabaseSecret"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [statement.value]
    }
  }

  dynamic "statement" {
    for_each = var.backend_auth_secret_arn == "" ? [] : [var.backend_auth_secret_arn]

    content {
      sid       = "ReadBackendAuthenticationSecret"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role" "ecs_backend_execution" {
  name               = "${local.name}-ecs-backend-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = merge(local.global_tags, {
    Name      = "${local.name}-ecs-backend-execution"
    Component = "backend"
  })
}

resource "aws_iam_role_policy" "ecs_backend_execution" {
  name   = "${local.name}-ecs-backend-execution"
  role   = aws_iam_role.ecs_backend_execution.id
  policy = data.aws_iam_policy_document.ecs_backend_execution_permissions.json
}

data "aws_iam_policy_document" "ecs_migration_execution_permissions" {
  source_policy_documents = [data.aws_iam_policy_document.ecs_execution_permissions.json]

  dynamic "statement" {
    for_each = var.db_migrator_secret_arn == "" ? [] : [var.db_migrator_secret_arn]

    content {
      sid       = "ReadMigrationDatabaseSecret"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role" "ecs_migration_execution" {
  name               = "${local.name}-ecs-migration-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = merge(local.global_tags, {
    Name      = "${local.name}-ecs-migration-execution"
    Component = "database-migration"
  })
}

resource "aws_iam_role_policy" "ecs_migration_execution" {
  name   = "${local.name}-ecs-migration-execution"
  role   = aws_iam_role.ecs_migration_execution.id
  policy = data.aws_iam_policy_document.ecs_migration_execution_permissions.json
}

data "aws_iam_policy_document" "ecs_db_bootstrap_execution_permissions" {
  source_policy_documents = [data.aws_iam_policy_document.ecs_execution_permissions.json]

  statement {
    sid       = "ReadRdsMasterSecretForRoleBootstrap"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.this.master_user_secret[0].secret_arn]
  }

  dynamic "statement" {
    for_each = compact([
      var.db_runtime_secret_arn,
      var.db_migrator_secret_arn,
    ])

    content {
      sid       = "ReadApplicationDatabaseRoleSecrets"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role" "ecs_db_bootstrap_execution" {
  name               = "${local.name}-ecs-db-bootstrap-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = merge(local.global_tags, {
    Name      = "${local.name}-ecs-db-bootstrap-execution"
    Component = "database-bootstrap"
  })
}

resource "aws_iam_role_policy" "ecs_db_bootstrap_execution" {
  name   = "${local.name}-ecs-db-bootstrap-execution"
  role   = aws_iam_role.ecs_db_bootstrap_execution.id
  policy = data.aws_iam_policy_document.ecs_db_bootstrap_execution_permissions.json
}


data "aws_iam_policy_document" "ecs_monitoring_execution_permissions" {
  statement {
    sid    = "ReadMonitoringSecrets"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue"
    ]

    resources = [
      aws_db_instance.monitoring.master_user_secret[0].secret_arn,
      aws_secretsmanager_secret.grafana_admin.arn
    ]
  }
}

resource "aws_iam_role" "ecs_monitoring_execution" {
  name               = "${local.name}-ecs-monitoring-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = merge(local.global_tags, {
    Name      = "${local.name}-ecs-monitoring-execution"
    Component = "monitoring"
  })
}

resource "aws_iam_role_policy" "ecs_monitoring_execution" {
  name   = "${local.name}-ecs-monitoring-execution"
  role   = aws_iam_role.ecs_monitoring_execution.id
  policy = data.aws_iam_policy_document.ecs_monitoring_execution_permissions.json
}

resource "aws_iam_role" "ecs_frontend_task" {
  name               = "${local.name}-ecs-frontend-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = merge(local.global_tags, {
    Name      = "${local.name}-ecs-frontend-task"
    Component = "frontend"
  })
}

resource "aws_iam_role" "ecs_backend_task" {
  name               = "${local.name}-ecs-backend-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = merge(local.global_tags, {
    Name      = "${local.name}-ecs-backend-task"
    Component = "backend"
  })
}
