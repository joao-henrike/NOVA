locals {
  frontend_desired_count = var.deploy_application ? var.frontend_desired_task_count : 0
  frontend_min_count     = var.deploy_application ? var.frontend_min_task_count : 0
  backend_desired_count  = var.deploy_application ? var.backend_desired_task_count : 0
  backend_min_count      = var.deploy_application ? var.backend_min_task_count : 0
}


resource "aws_ecs_task_definition" "frontend" {
  family                   = "${local.name}-frontend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.frontend_task_cpu
  memory                   = var.frontend_task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_frontend_task.arn

  container_definitions = jsonencode([
    {
      name      = var.frontend_container_name
      image     = "${aws_ecr_repository.frontend.repository_url}:${var.frontend_image_tag}"
      essential = true
      cpu       = var.frontend_task_cpu
      memory    = var.frontend_task_memory

      portMappings = [
        {
          name          = "http"
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]

      healthCheck = {
        command = [
          "CMD-SHELL",
          "wget -q -O - http://127.0.0.1:80${var.frontend_health_check_path} >/dev/null || exit 1"
        ]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }

    }
  ])

  tags = merge(local.global_tags, {
    Name      = "${local.name}-frontend-task"
    Component = "frontend"
  })
}

resource "aws_ecs_task_definition" "backend" {
  family                   = "${local.name}-backend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.backend_task_cpu
  memory                   = var.backend_task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_backend_task.arn

  container_definitions = jsonencode([
    {
      name      = var.backend_container_name
      image     = "${aws_ecr_repository.backend.repository_url}:${var.backend_image_tag}"
      essential = true
      cpu       = var.backend_task_cpu
      memory    = var.backend_task_memory

      portMappings = [
        {
          name          = "http"
          containerPort = var.backend_container_port
          hostPort      = var.backend_container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "APP_ENV"
          value = var.environment
        },
        {
          name  = "DB_HOST"
          value = aws_db_instance.this.address
        },
        {
          name  = "DB_PORT"
          value = tostring(aws_db_instance.this.port)
        },
        {
          name  = "DB_NAME"
          value = var.db_name
        },
        {
          name  = "DB_USER"
          value = var.db_username
        }
      ]

      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = "${aws_db_instance.this.master_user_secret[0].secret_arn}:password::"
        }
      ]

      healthCheck = {
        command = [
          "CMD-SHELL",
          "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:${var.backend_container_port}${var.backend_health_check_path}', timeout=3)\""
        ]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }

    }
  ])

  tags = merge(local.global_tags, {
    Name      = "${local.name}-backend-task"
    Component = "backend"
  })
}

resource "aws_ecs_service" "frontend" {
  name            = "${local.name}-frontend"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.frontend.arn
  desired_count   = local.frontend_desired_count
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = [for subnet in aws_subnet.private_app : subnet.id]
    security_groups  = [aws_security_group.frontend.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = var.frontend_container_name
    container_port   = 80
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy.ecs_execution,
  ]

  tags = merge(local.global_tags, {
    Name      = "${local.name}-frontend"
    Component = "frontend"
  })
}

resource "aws_ecs_service" "backend" {
  name            = "${local.name}-backend"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = local.backend_desired_count
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = [for subnet in aws_subnet.private_app : subnet.id]
    security_groups  = [aws_security_group.backend.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = var.backend_container_name
    container_port   = var.backend_container_port
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_lb_listener_rule.backend,
    aws_iam_role_policy.ecs_execution,
  ]

  tags = merge(local.global_tags, {
    Name      = "${local.name}-backend"
    Component = "backend"
  })
}

resource "aws_appautoscaling_target" "frontend" {
  max_capacity       = var.frontend_max_task_count
  min_capacity       = local.frontend_min_count
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.frontend.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.frontend]
}

resource "aws_appautoscaling_target" "backend" {
  max_capacity       = var.backend_max_task_count
  min_capacity       = local.backend_min_count
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.backend.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.backend]
}

resource "aws_appautoscaling_policy" "frontend_cpu" {
  name               = "${local.name}-frontend-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.frontend.resource_id
  scalable_dimension = aws_appautoscaling_target.frontend.scalable_dimension
  service_namespace  = aws_appautoscaling_target.frontend.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.frontend_cpu_target_utilization
    scale_in_cooldown  = 180
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "frontend_memory" {
  name               = "${local.name}-frontend-memory"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.frontend.resource_id
  scalable_dimension = aws_appautoscaling_target.frontend.scalable_dimension
  service_namespace  = aws_appautoscaling_target.frontend.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.frontend_memory_target_utilization
    scale_in_cooldown  = 180
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "backend_cpu" {
  name               = "${local.name}-backend-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.backend.resource_id
  scalable_dimension = aws_appautoscaling_target.backend.scalable_dimension
  service_namespace  = aws_appautoscaling_target.backend.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.backend_cpu_target_utilization
    scale_in_cooldown  = 180
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "backend_memory" {
  name               = "${local.name}-backend-memory"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.backend.resource_id
  scalable_dimension = aws_appautoscaling_target.backend.scalable_dimension
  service_namespace  = aws_appautoscaling_target.backend.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.backend_memory_target_utilization
    scale_in_cooldown  = 180
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}
