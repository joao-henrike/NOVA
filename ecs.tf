resource "aws_lb_target_group" "frontend" {
  name        = substr("${var.name}-${var.environment}-fe", 0, 32)
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, {
    Name        = "${var.name}-frontend-tg"
    Component   = "frontend"
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# Regra opcional. O ALB/listener continua pertencendo à infraestrutura principal.
resource "aws_lb_listener_rule" "frontend" {
  count = var.alb_listener_arn != null ? 1 : 0

  listener_arn = var.alb_listener_arn
  priority     = var.listener_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }

  dynamic "condition" {
    for_each = var.host_header != null ? [var.host_header] : []

    content {
      host_header {
        values = [condition.value]
      }
    }
  }

  dynamic "condition" {
    for_each = var.host_header == null ? [1] : []

    content {
      path_pattern {
        values = var.path_patterns
      }
    }
  }
}

locals {
  # O módulo aceita uma imagem externa para permitir CI/CD.
  # Quando null, usa um placeholder somente para permitir o primeiro
  # provisionamento da infraestrutura. O pipeline deve substituir pela
  # imagem aprovada antes de colocar o serviço em produção.
  effective_image = coalesce(
    var.container_image,
    "public.ecr.aws/nginx/nginx:stable"
  )
}

resource "aws_ecs_task_definition" "frontend" {
  family                   = "${var.name}-${var.environment}-frontend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = tostring(var.cpu)
  memory = tostring(var.memory)

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "frontend"
      image     = local.effective_image
      essential = true

      portMappings = [
        {
          name          = "http"
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      readonlyRootFilesystem = false

      healthCheck = {
        command = [
          "CMD-SHELL",
          "wget -q -O /dev/null http://127.0.0.1${var.health_check_path} || exit 1",
        ]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.frontend.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "frontend"
        }
      }

      stopTimeout = 30
    }
  ])

  tags = merge(var.tags, {
    Name        = "${var.name}-frontend-task"
    Component   = "frontend"
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

resource "aws_ecs_service" "frontend" {
  name            = "${var.name}-${var.environment}-frontend"
  cluster         = var.ecs_cluster_arn
  task_definition = aws_ecs_task_definition.frontend.arn

  desired_count = var.desired_count
  launch_type   = "FARGATE"

  platform_version = "LATEST"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = 60

  network_configuration {
    subnets = var.private_subnet_ids

    security_groups = [
      var.frontend_security_group_id,
    ]

    # Segurança: as tasks não recebem IPv4 público.
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = "frontend"
    container_port   = var.container_port
  }

  lifecycle {
    # A versão da Task Definition é atualizada pelo Terraform/CI.
    # Ignorar desired_count permite que autoscaling futuro altere
    # temporariamente a capacidade sem drift constante.
    ignore_changes = [
      desired_count,
    ]
  }

  depends_on = [
    aws_lb_target_group.frontend,
  ]

  tags = merge(var.tags, {
    Name        = "${var.name}-frontend-service"
    Component   = "frontend"
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}
