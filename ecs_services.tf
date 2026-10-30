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

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.frontend.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

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
  execution_role_arn = (
    var.deploy_application
    ? aws_iam_role.ecs_backend_execution.arn
    : aws_iam_role.ecs_execution.arn
  )
  task_role_arn = aws_iam_role.ecs_backend_task.arn

  lifecycle {
    precondition {
      condition = (
        !var.deploy_application ||
        (
          trimspace(var.backend_auth_secret_arn) != "" &&
          trimspace(var.db_runtime_secret_arn) != "" &&
          trimspace(var.db_migrator_secret_arn) != "" &&
          var.db_runtime_username != var.db_migrator_username &&
          var.db_runtime_username != var.db_username &&
          var.db_migrator_username != var.db_username &&
          var.db_runtime_secret_arn != var.db_migrator_secret_arn &&
          var.db_runtime_secret_arn != aws_db_instance.this.master_user_secret[0].secret_arn &&
          var.db_migrator_secret_arn != aws_db_instance.this.master_user_secret[0].secret_arn
        )
      )
      error_message = "Application deployment requires three distinct PostgreSQL usernames, three distinct database password secrets, and backend_auth_secret_arn."
    }
  }

  container_definitions = jsonencode([
    {
      name      = var.backend_container_name
      image     = "${aws_ecr_repository.backend.repository_url}:${var.backend_image_tag}"
      essential = true
      cpu       = var.backend_task_cpu
      memory    = var.backend_task_memory

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.backend.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

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
          value = var.deploy_application ? var.db_runtime_username : var.db_username
        }
      ]

      secrets = concat(
        var.deploy_application ? [
          {
            name      = "DB_PASSWORD"
            valueFrom = "${var.db_runtime_secret_arn}:password::"
          }
          ] : [
          {
            name      = "DB_PASSWORD"
            valueFrom = "${aws_db_instance.this.master_user_secret[0].secret_arn}:password::"
          }
        ],
        var.backend_auth_secret_arn == "" ? [] : [
          for key in local.backend_auth_secret_keys : {
            name      = key
            valueFrom = "${var.backend_auth_secret_arn}:${key}::"
          }
        ]
      )

      # Authentication configuration is supplied out-of-band through Secrets Manager.
      # Do not put OAuth credentials or JWT signing material in Terraform variables.

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

  depends_on = [
    aws_iam_role_policy.ecs_backend_execution,
  ]

  tags = merge(local.global_tags, {
    Name      = "${local.name}-backend-task"
    Component = "backend"
  })
}

resource "aws_ecs_task_definition" "db_bootstrap" {
  family                   = "${local.name}-db-bootstrap"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_db_bootstrap_execution.arn

  # Intentionally omit task_role_arn: the process receives no AWS task credentials.
  # ECR pulls, logs, and startup secret injection are handled by the execution role.

  lifecycle {
    precondition {
      condition = (
        !var.deploy_application ||
        (
          trimspace(var.db_runtime_secret_arn) != "" &&
          trimspace(var.db_migrator_secret_arn) != "" &&
          var.db_runtime_username != var.db_migrator_username &&
          var.db_runtime_username != var.db_username &&
          var.db_migrator_username != var.db_username &&
          var.db_runtime_secret_arn != var.db_migrator_secret_arn &&
          var.db_runtime_secret_arn != aws_db_instance.this.master_user_secret[0].secret_arn &&
          var.db_migrator_secret_arn != aws_db_instance.this.master_user_secret[0].secret_arn
        )
      )
      error_message = "Database bootstrap requires distinct master/runtime/migrator usernames and distinct Secrets Manager password ARNs before application deployment."
    }
  }

  container_definitions = jsonencode([
    {
      name      = "db-bootstrap"
      image     = "${aws_ecr_repository.backend.repository_url}:${var.backend_image_tag}"
      essential = true
      command   = ["python", "-m", "app.db.bootstrap_roles"]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.db_bootstrap.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      environment = [
        { name = "DB_HOST", value = aws_db_instance.this.address },
        { name = "DB_PORT", value = tostring(aws_db_instance.this.port) },
        { name = "DB_NAME", value = var.db_name },
        { name = "DB_ADMIN_USER", value = var.db_username },
        { name = "DB_RUNTIME_USER", value = var.db_runtime_username },
        { name = "DB_MIGRATOR_USER", value = var.db_migrator_username },
      ]

      secrets = concat(
        [
          {
            name      = "DB_ADMIN_PASSWORD"
            valueFrom = "${aws_db_instance.this.master_user_secret[0].secret_arn}:password::"
          }
        ],
        var.db_runtime_secret_arn == "" ? [] : [
          {
            name      = "DB_RUNTIME_PASSWORD"
            valueFrom = "${var.db_runtime_secret_arn}:password::"
          }
        ],
        var.db_migrator_secret_arn == "" ? [] : [
          {
            name      = "DB_MIGRATOR_PASSWORD"
            valueFrom = "${var.db_migrator_secret_arn}:password::"
          }
        ]
      )
    }
  ])

  depends_on = [
    aws_iam_role_policy.ecs_db_bootstrap_execution,
  ]

  tags = merge(local.global_tags, {
    Name      = "${local.name}-db-bootstrap-task"
    Component = "database-bootstrap"
  })
}

resource "aws_ecs_task_definition" "db_migration" {
  family                   = "${local.name}-db-migration"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_migration_execution.arn

  # Intentionally omit task_role_arn: Alembic needs database access, not AWS API credentials.

  lifecycle {
    precondition {
      condition     = !var.deploy_application || trimspace(var.db_migrator_secret_arn) != ""
      error_message = "The database migration task requires db_migrator_secret_arn before application deployment."
    }
  }

  container_definitions = jsonencode([
    {
      name      = "db-migration"
      image     = "${aws_ecr_repository.backend.repository_url}:${var.backend_image_tag}"
      essential = true
      command   = ["alembic", "upgrade", "head"]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.db_migration.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      environment = [
        { name = "APP_ENV", value = var.environment },
        { name = "DB_HOST", value = aws_db_instance.this.address },
        { name = "DB_PORT", value = tostring(aws_db_instance.this.port) },
        { name = "DB_NAME", value = var.db_name },
        { name = "DB_USER", value = var.db_migrator_username },
      ]

      secrets = var.db_migrator_secret_arn == "" ? [] : [
        {
          name      = "DB_PASSWORD"
          valueFrom = "${var.db_migrator_secret_arn}:password::"
        }
      ]
    }
  ])

  depends_on = [
    aws_iam_role_policy.ecs_migration_execution,
  ]

  tags = merge(local.global_tags, {
    Name      = "${local.name}-db-migration-task"
    Component = "database-migration"
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


  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_lb_listener_rule.backend,
    aws_iam_role_policy.ecs_backend_execution,
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
