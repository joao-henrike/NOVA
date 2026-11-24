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
  count = var.enable_public_alb ? 1 : 0

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

#trivy:ignore:AWS-0104
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
  name                           = "${local.name}/monitoring/grafana-admin"
  recovery_window_in_days        = 0
  force_overwrite_replica_secret = false

  tags = merge(local.global_tags, {
    Name      = "${local.name}/monitoring/grafana-admin"
    Component = "monitoring"
  })
}

# Keep DB and encryption credentials stable across administrator password changes.
resource "terraform_data" "grafana_storage_keys" {
  input = {
    database_password = sha256("NOVA-GRAFANA-DB:${var.grafana_admin_password == null ? "" : var.grafana_admin_password}")
    encryption_key    = sha256("NOVA-GRAFANA-KEY:${var.grafana_admin_password == null ? "" : var.grafana_admin_password}")
  }

  lifecycle {
    ignore_changes = [input]
    precondition {
      condition     = var.grafana_admin_password != null
      error_message = "Set a stable Grafana administrator password before creating monitoring storage."
    }
  }
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({
    password          = var.grafana_admin_password
    database_password = terraform_data.grafana_storage_keys.output.database_password
    encryption_key    = terraform_data.grafana_storage_keys.output.encryption_key
  })
}

resource "aws_lb_target_group" "grafana" {
  count = var.enable_public_alb ? 1 : 0

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
    # Grafana is configured with GF_SERVER_SERVE_FROM_SUB_PATH=true.
    path     = "/grafana/api/health"
    protocol = "HTTP"
    matcher  = "200-299"
  }

  tags = merge(local.global_tags, {
    Name      = "${local.name}-grafana-tg"
    Component = "monitoring"
  })
}

resource "aws_lb_listener_rule" "grafana" {
  count = var.enable_public_alb ? 1 : 0

  listener_arn = (
    var.acm_certificate_arn == ""
    ? aws_lb_listener.http[0].arn
    : aws_lb_listener.https[0].arn
  )
  priority = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana[0].arn
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

# Read-only metrics via task-role credentials; no long-lived AWS access keys.
resource "aws_iam_role_policy" "ecs_monitoring_metrics" {
  name = "${local.name}-ecs-monitoring-metrics"
  role = aws_iam_role.ecs_monitoring_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadCloudWatchMetricsAndInventory"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "rds:DescribeDBInstances",
          "rds:DescribeDBSnapshots",
          "ec2:DescribeRegions",
          "ec2:DescribeSubnets",
          "ec2:DescribeRouteTables",
          "ec2:DescribeNatGateways",
          "elasticloadbalancing:DescribeTargetHealth"
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.aws_region }
        }
      },
      {
        Sid      = "ReadProjectECRImageInventory"
        Effect   = "Allow"
        Action   = ["ecr:DescribeImages"]
        Resource = [aws_ecr_repository.frontend.arn, aws_ecr_repository.backend.arn]
      },
      {
        Sid      = "ReadMonitoringDashboardBundle"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.monitoring_assets.arn}/${aws_s3_object.monitoring_dashboards.key}"]
      },
      {
        Sid      = "DecryptMonitoringDashboardBundle"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.monitoring_assets.arn]
        Condition = {
          StringEquals = {
            "kms:ViaService"                   = "s3.${var.aws_region}.amazonaws.com"
            "kms:EncryptionContext:aws:s3:arn" = "${aws_s3_bucket.monitoring_assets.arn}/${aws_s3_object.monitoring_dashboards.key}"
          }
        }
      }
    ]
  })
}

# Keep the full dashboard catalog outside the ECS task-definition size limit.
locals {
  nova_original_dashboards_json = jsonencode([
    for dashboard in jsondecode(file("${path.module}/monitoring/grafana/manifest.json")).dashboards :
    jsondecode(file("${path.module}/monitoring/grafana/${dashboard.path}"))
  ])
}

resource "aws_s3_bucket" "monitoring_assets" {
  bucket_prefix = "${substr(local.name, 0, 22)}-mon-"
  # This bucket contains only reproducible Git-managed dashboard JSON.
  force_destroy = true
  tags          = merge(local.global_tags, { Component = "monitoring" })
}

resource "aws_s3_bucket_versioning" "monitoring_assets" {
  bucket = aws_s3_bucket.monitoring_assets.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "monitoring_assets" {
  bucket     = aws_s3_bucket.monitoring_assets.id
  depends_on = [aws_s3_bucket_versioning.monitoring_assets]

  rule {
    id     = "expire-obsolete-dashboard-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "monitoring_assets" {
  bucket                  = aws_s3_bucket.monitoring_assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_kms_key" "monitoring_assets" {
  description             = "Encrypt Git-managed NOVA dashboard catalog"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  # Enable account IAM delegation; the collector's identity policy grants only
  # Decrypt via S3 for the exact dashboard object, not unrestricted key access.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableAccountIAM"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
  tags = merge(local.global_tags, { Component = "monitoring" })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "monitoring_assets" {
  bucket = aws_s3_bucket.monitoring_assets.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.monitoring_assets.arn
    }
  }
}

resource "aws_s3_object" "monitoring_dashboards" {
  bucket       = aws_s3_bucket.monitoring_assets.id
  key          = "dashboards.json"
  content      = local.nova_original_dashboards_json
  content_type = "application/json"
  source_hash  = sha256(local.nova_original_dashboards_json)
  depends_on   = [aws_s3_bucket_public_access_block.monitoring_assets, aws_s3_bucket_server_side_encryption_configuration.monitoring_assets, aws_s3_bucket_versioning.monitoring_assets]
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

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.monitoring.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "zabbix-server"
        }
      }

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

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.monitoring.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "zabbix-web"
        }
      }

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
      name      = "grafana-db-init"
      image     = "postgres:16-alpine"
      essential = false
      cpu       = 0
      memory    = 128

      entryPoint = ["/bin/sh", "-ec"]
      command = [<<-SCRIPT
        export PGSSLMODE=require
        for i in $(seq 1 60); do
          if psql -X -Atqc 'SELECT 1' >/dev/null 2>&1; then break; fi
          sleep 5
        done
        psql -X -v ON_ERROR_STOP=1 <<'SQL'
        \getenv grafana_password GRAFANA_DB_PASSWORD
        SELECT 'CREATE ROLE nova_grafana LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nova_grafana') \gexec
        SELECT format('ALTER ROLE nova_grafana PASSWORD %L', :'grafana_password') \gexec
        GRANT nova_grafana TO CURRENT_USER WITH SET TRUE;
        SELECT 'CREATE DATABASE nova_grafana OWNER nova_grafana' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'nova_grafana') \gexec
        REVOKE CONNECT ON DATABASE nova_grafana FROM PUBLIC;
        SQL
        echo "NOVA Grafana PostgreSQL initialized"
      SCRIPT
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.monitoring.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "grafana-db-init"
        }
      }
      environment = [
        { name = "PGHOST", value = aws_db_instance.monitoring.address },
        { name = "PGPORT", value = tostring(aws_db_instance.monitoring.port) },
        { name = "PGDATABASE", value = var.monitoring_db_name },
        { name = "PGUSER", value = var.monitoring_db_username }
      ]
      secrets = [
        { name = "PGPASSWORD", valueFrom = "${aws_db_instance.monitoring.master_user_secret[0].secret_arn}:password::" },
        { name = "GRAFANA_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.grafana_admin.arn}:database_password::" }
      ]
    },
    {
      name      = "grafana"
      image     = var.grafana_image
      essential = true
      cpu       = 256
      memory    = 1024

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.monitoring.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "grafana"
        }
      }

      portMappings = [
        {
          name          = "grafana"
          containerPort = var.grafana_container_port
          hostPort      = var.grafana_container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "GF_DATABASE_TYPE", value = "postgres" },
        { name = "GF_DATABASE_HOST", value = "${aws_db_instance.monitoring.address}:5432" },
        { name = "GF_DATABASE_NAME", value = "nova_grafana" },
        { name = "GF_DATABASE_USER", value = "nova_grafana" },
        { name = "GF_DATABASE_SSL_MODE", value = "require" },
        { name = "GF_DATABASE_MAX_OPEN_CONN", value = "15" },
        { name = "GF_DATABASE_MAX_IDLE_CONN", value = "5" },
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
        },
        { name = "GF_DATABASE_PASSWORD", valueFrom = "${aws_secretsmanager_secret.grafana_admin.arn}:database_password::" },
        { name = "GF_SECURITY_SECRET_KEY", valueFrom = "${aws_secretsmanager_secret.grafana_admin.arn}:encryption_key::" }
      ]

      dependsOn = [
        {
          containerName = "grafana-db-init"
          condition     = "SUCCESS"
        }
      ]

      healthCheck = {
        command = [
          "CMD-SHELL",
          "wget -q -O - http://127.0.0.1:${var.grafana_container_port}/grafana/api/health >/dev/null || exit 1"
        ]
        interval    = 30
        timeout     = 5
        retries     = 5
        startPeriod = 30
      }
    },
    {
      # One idempotent sidecar handles both Zabbix configuration and Grafana
      # dashboards. A failed collector must not stop the Grafana interface.
      name      = "monitoring-bootstrap"
      image     = "python:3.12-alpine"
      essential = false
      cpu       = 0
      memory    = 512

      restartPolicy = {
        enabled              = true
        restartAttemptPeriod = 60
      }

      entryPoint = ["/bin/sh", "-ec"]
      command = [
        "printf '%s' \"$MONITOR_BOOTSTRAP_SCRIPT_B64\" | base64 -d > /tmp/bootstrap.py && (until python /tmp/bootstrap.py; do sleep 30; done) && rm -f /tmp/nova-monitoring-ready && printf '%s' \"$NOVA_COLLECTOR_SCRIPT_B64\" | base64 -d | gzip -dc > /tmp/nova_collector.py && exec python -u /tmp/nova_collector.py"
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.monitoring.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "monitoring-bootstrap"
        }
      }

      environment = [
        { name = "MONITOR_BOOTSTRAP_SCRIPT_B64", value = filebase64("${path.module}/monitoring/bootstrap.py") },
        { name = "NOVA_COLLECTOR_SCRIPT_B64", value = base64gzip(file("${path.module}/monitoring/collector.py")) },
        { name = "NOVA_ZABBIX_CATALOG_B64", value = base64gzip(jsonencode(local.nova_zabbix_catalog)) },
        { name = "NOVA_RESOURCE_VARS", value = jsonencode(local.nova_zabbix_resource_vars) },
        { name = "NOVA_DASHBOARD_BUCKET", value = aws_s3_bucket.monitoring_assets.id },
        { name = "NOVA_DASHBOARD_SHA256", value = aws_s3_object.monitoring_dashboards.source_hash },
        { name = "NOVA_COLLECTION_SECONDS", value = "900" },
        { name = "GRAFANA_URL", value = "http://127.0.0.1:${var.grafana_container_port}/grafana" },
        { name = "ZABBIX_URL", value = "http://127.0.0.1:8080/api_jsonrpc.php" },
        { name = "ZABBIX_WEB_CHECK_URL", value = "http://127.0.0.1:8080/" },
        { name = "GRAFANA_HEALTH_CHECK_URL", value = "http://127.0.0.1:${var.grafana_container_port}/grafana/api/health" },
        { name = "MONITOR_CLOUDWATCH", value = "true" },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "NOVA_CLUSTER", value = aws_ecs_cluster.this.name },
        { name = "NOVA_APPLICATION_DB", value = aws_db_instance.this.identifier },
        { name = "NOVA_MONITORING_DB", value = aws_db_instance.monitoring.identifier },
      ]

      secrets = [{
        name      = "GRAFANA_PASSWORD"
        valueFrom = "${aws_secretsmanager_secret.grafana_admin.arn}:password::"
      }]

      dependsOn = [
        { containerName = "zabbix-web", condition = "HEALTHY" },
        { containerName = "grafana", condition = "HEALTHY" }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "test -f /tmp/nova-monitoring-ready && test $(( $(date +%s) - $(cat /tmp/nova-monitoring-ready) )) -lt 1800"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 300
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

  # Zabbix is a singleton; do not run two collectors/servers during deployment.
  # ECS AZ rebalancing requires maximumPercent > 100, incompatible with this policy.
  availability_zone_rebalancing      = "DISABLED"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  health_check_grace_period_seconds  = 600

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = [for subnet in aws_subnet.private_app : subnet.id]
    security_groups  = [aws_security_group.monitoring.id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.enable_public_alb ? [1] : []

    content {
      target_group_arn = aws_lb_target_group.grafana[0].arn
      container_name   = "grafana"
      container_port   = var.grafana_container_port
    }
  }

  lifecycle {
    # Keep operator stop/start state across Terraform plans; service/task definitions remain Terraform-managed.
    ignore_changes = [desired_count]
  }


  depends_on = [
    aws_iam_role_policy.ecs_monitoring_execution,
    aws_iam_role_policy.ecs_monitoring_metrics,
    aws_secretsmanager_secret_version.grafana_admin,
  ]

  tags = merge(local.global_tags, {
    Name      = "${local.name}-monitoring"
    Component = "monitoring"
  })
}
