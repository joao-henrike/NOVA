resource "aws_security_group" "monitoring" {
  name        = "${local.name}-monitoring-sg"
  description = "Security group for the Zabbix and Grafana monitoring task."
  vpc_id      = aws_vpc.this.id

  tags = merge(local.global_tags, {
    Name      = "${local.name}-monitoring-sg"
    Component = "monitoring"
  })
}

resource "aws_security_group" "monitoring_db" {
  name        = "${local.name}-monitoring-db-sg"
  description = "Security group for the private PostgreSQL database used by Zabbix."
  vpc_id      = aws_vpc.this.id

  tags = merge(local.global_tags, {
    Name      = "${local.name}-monitoring-db-sg"
    Component = "monitoring"
  })
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_from_alb" {
  security_group_id            = aws_security_group.monitoring.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.grafana_container_port
  to_port                      = var.grafana_container_port
  ip_protocol                  = "tcp"
  description                  = "Grafana traffic from the public ALB only"
}

resource "aws_vpc_security_group_egress_rule" "monitoring_to_db" {
  security_group_id            = aws_security_group.monitoring.id
  referenced_security_group_id = aws_security_group.monitoring_db.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Zabbix server to monitoring PostgreSQL"
}

resource "aws_vpc_security_group_egress_rule" "monitoring_https" {
  security_group_id = aws_security_group.monitoring.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Monitoring outbound HTTPS for external checks and image/runtime dependencies"
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_db_from_monitoring" {
  security_group_id            = aws_security_group.monitoring_db.id
  referenced_security_group_id = aws_security_group.monitoring.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL access from the monitoring task only"
}

resource "aws_vpc_security_group_egress_rule" "monitoring_db_all" {
  security_group_id = aws_security_group.monitoring_db.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Default outbound traffic"
}

resource "aws_db_subnet_group" "monitoring" {
  name       = "${local.name}-monitoring-db-subnets"
  subnet_ids = [for subnet in aws_subnet.private_db : subnet.id]

  tags = merge(local.global_tags, {
    Name      = "${local.name}-monitoring-db-subnets"
    Component = "monitoring"
  })
}

resource "aws_db_instance" "monitoring" {
  identifier = "${local.name}-monitoring-db"

  engine         = "postgres"
  engine_version = var.monitoring_db_engine_version
  instance_class = var.monitoring_db_instance_class

  db_name  = var.monitoring_db_name
  username = var.monitoring_db_username

  manage_master_user_password = true

  allocated_storage     = var.monitoring_db_allocated_storage
  max_allocated_storage = var.monitoring_db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  multi_az               = false
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.monitoring.name
  vpc_security_group_ids = [aws_security_group.monitoring_db.id]

  backup_retention_period    = var.monitoring_db_backup_retention_period
  backup_window              = "04:00-05:00"
  maintenance_window         = "sun:05:00-sun:06:00"
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  deletion_protection = var.rds_deletion_protection
  skip_final_snapshot = var.environment != "prod"

  final_snapshot_identifier = var.environment == "prod" ? "${local.name}-monitoring-final" : null

  tags = merge(local.global_tags, {
    Name      = "${local.name}-monitoring-db"
    Component = "monitoring"
  })
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  name = "${local.name}/monitoring/grafana-admin"

  tags = merge(local.global_tags, {
    Name      = "${local.name}/monitoring/grafana-admin"
    Component = "monitoring"
  })
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id     = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({ password = var.grafana_admin_password })
}

resource "aws_lb_target_group" "grafana" {
  name        = substr("${local.name}-grafana-tg", 0, 32)
  port        = var.grafana_container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/api/health"
    protocol            = "HTTP"
    matcher             = "200-299"
  }

  tags = merge(local.global_tags, {
    Name      = "${local.name}-grafana-tg"
    Component = "monitoring"
  })
}

resource "aws_lb_listener_rule" "grafana" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }

  condition {
    path_pattern {
      values = ["/grafana", "/grafana/*"]
    }
  }

  tags = merge(local.global_tags, {
    Name      = "${local.name}-grafana-route"
    Component = "monitoring"
  })
}

resource "aws_iam_role" "ecs_monitoring_task" {
  name               = "${local.name}-ecs-monitoring-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = merge(local.global_tags, {
    Name      = "${local.name}-ecs-monitoring-task"
    Component = "monitoring"
  })
}

resource "aws_ecs_task_definition" "monitoring" {
  family                   = "${local.name}-monitoring"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.monitoring_task_cpu
  memory                   = var.monitoring_task_memory
  execution_role_arn       = aws_iam_role.ecs_monitoring_execution.arn
  task_role_arn            = aws_iam_role.ecs_monitoring_task.arn

  container_definitions = jsonencode([
    {
      name      = "zabbix-server"
      image     = var.zabbix_server_image
      essential = true
      cpu       = 512
      memory    = 1024

      portMappings = [
        {
          name          = "zabbix-server"
          containerPort = 10051
          hostPort      = 10051
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "DB_SERVER_HOST"
          value = aws_db_instance.monitoring.address
        },
        {
          name  = "DB_SERVER_PORT"
          value = tostring(aws_db_instance.monitoring.port)
        },
        {
          name  = "POSTGRES_DB"
          value = var.monitoring_db_name
        },
        {
          name  = "POSTGRES_USER"
          value = var.monitoring_db_username
        },
        {
          name  = "ZBX_SERVER_NAME"
          value = "${local.name}-zabbix"
        }
      ]

      secrets = [
        {
          name      = "POSTGRES_PASSWORD"
          valueFrom = "${aws_db_instance.monitoring.master_user_secret[0].secret_arn}:password::"
        }
      ]
    },
    {
      name      = "zabbix-web"
      image     = var.zabbix_web_image
      essential = true
      cpu       = 256
      memory    = 512

      portMappings = [
        {
          name          = "zabbix-web"
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "ZBX_SERVER_HOST"
          value = "127.0.0.1"
        },
        {
          name  = "DB_SERVER_HOST"
          value = aws_db_instance.monitoring.address
        },
        {
          name  = "DB_SERVER_PORT"
          value = tostring(aws_db_instance.monitoring.port)
        },
        {
          name  = "POSTGRES_DB"
          value = var.monitoring_db_name
        },
        {
          name  = "POSTGRES_USER"
          value = var.monitoring_db_username
        },
        {
          name  = "PHP_TZ"
          value = var.monitoring_timezone
        },
        {
          name  = "ZBX_SERVER_NAME"
          value = "${local.name}-zabbix"
        }
      ]

      secrets = [
        {
          name      = "POSTGRES_PASSWORD"
          valueFrom = "${aws_db_instance.monitoring.master_user_secret[0].secret_arn}:password::"
        }
      ]

      healthCheck = {
        command = [
          "CMD-SHELL",
          "wget -q -O - http://127.0.0.1:8080/ >/dev/null || exit 1"
        ]
        interval    = 30
        timeout     = 5
        retries     = 5
        startPeriod = 30
      }
    },
    {
      name      = "grafana"
      image     = var.grafana_image
      essential = true
      cpu       = 256
      memory    = 512

      portMappings = [
        {
          name          = "grafana"
          containerPort = var.grafana_container_port
          hostPort      = var.grafana_container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "GF_SERVER_ROOT_URL"
          value = "%(protocol)s://%(domain)s/grafana/"
        },
        {
          name  = "GF_SERVER_SERVE_FROM_SUB_PATH"
          value = "true"
        },
        {
          name  = "GF_PLUGINS_PREINSTALL"
          value = var.grafana_zabbix_plugin
        },
        {
          name  = "GF_USERS_ALLOW_SIGN_UP"
          value = "false"
        }
      ]

      secrets = [
        {
          name      = "GF_SECURITY_ADMIN_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.grafana_admin.arn}:password::"
        }
      ]

      dependsOn = [
        {
          containerName = "zabbix-web"
          condition     = "HEALTHY"
        }
      ]

      healthCheck = {
        command = [
          "CMD-SHELL",
          "wget -q -O - http://127.0.0.1:${var.grafana_container_port}/api/health >/dev/null || exit 1"
        ]
        interval    = 30
        timeout     = 5
        retries     = 5
        startPeriod = 30
      }
    }
  ])

  tags = merge(local.global_tags, {
    Name      = "${local.name}-monitoring-task"
    Component = "monitoring"
  })
}

resource "aws_ecs_service" "monitoring" {
  name            = "${local.name}-monitoring"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.monitoring.arn
  desired_count   = var.monitoring_desired_count
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 90

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = [for subnet in aws_subnet.private_app : subnet.id]
    security_groups  = [aws_security_group.monitoring.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.grafana.arn
    container_name   = "grafana"
    container_port   = var.grafana_container_port
  }


  depends_on = [
    aws_lb_listener_rule.grafana,
    aws_iam_role_policy.ecs_monitoring_execution,
  ]

  tags = merge(local.global_tags, {
    Name      = "${local.name}-monitoring"
    Component = "monitoring"
  })
}
