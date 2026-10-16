data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type = "Service"

      identifiers = [
        "ecs-tasks.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-${var.environment}-frontend-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = merge(var.tags, {
    Name        = "${var.name}-frontend-execution"
    Component   = "frontend"
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# Permissões necessárias para o ECS Agent:
# - baixar imagem do ECR
# - enviar logs para o CloudWatch
resource "aws_iam_role_policy" "execution" {
  name = "${var.name}-${var.environment}-frontend-execution"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EcrPull"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.frontend.arn}:*"
      },
    ]
  })
}

# Task Role separado do Execution Role.
# Fica sem permissões por padrão e pode receber apenas as permissões
# que a aplicação realmente precisar futuramente.
resource "aws_iam_role" "task" {
  name               = "${var.name}-${var.environment}-frontend-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = merge(var.tags, {
    Name        = "${var.name}-frontend-task"
    Component   = "frontend"
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}
