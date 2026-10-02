data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type        = "Service"
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


  statement {
    sid    = "ReadDatabaseSecret"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue"
    ]

    resources = [
      aws_db_instance.this.master_user_secret[0].secret_arn
    ]
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
