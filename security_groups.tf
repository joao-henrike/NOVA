resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Security group for the public Application Load Balancer."
  vpc_id      = aws_vpc.this.id

  tags = merge(local.global_tags, {
    Name = "${local.name}-alb-sg"
  })
}

resource "aws_security_group" "frontend" {
  name        = "${local.name}-frontend-sg"
  description = "Security group for the frontend ECS service."
  vpc_id      = aws_vpc.this.id

  tags = merge(local.global_tags, {
    Name      = "${local.name}-frontend-sg"
    Component = "frontend"
  })
}

resource "aws_security_group" "backend" {
  name        = "${local.name}-backend-sg"
  description = "Security group for the backend ECS service."
  vpc_id      = aws_vpc.this.id

  tags = merge(local.global_tags, {
    Name      = "${local.name}-backend-sg"
    Component = "backend"
  })
}

resource "aws_security_group" "database_tasks" {
  #checkov:skip=CKV2_AWS_5:Attached dynamically to one-off Fargate tasks via the database_tasks_security_group_id output in deployment scripts/workflows.
  name        = "${local.name}-database-tasks-sg"
  description = "No-ingress security group for one-off database bootstrap and migration tasks."
  vpc_id      = aws_vpc.this.id

  tags = merge(local.global_tags, {
    Name      = "${local.name}-database-tasks-sg"
    Component = "database"
  })
}

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds-sg"
  description = "Security group for the private RDS database."
  vpc_id      = aws_vpc.this.id

  tags = merge(local.global_tags, {
    Name = "${local.name}-rds-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  count = var.enable_public_alb ? 1 : 0

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Public HTTP ingress and HTTPS redirect"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count = var.enable_public_alb && var.acm_certificate_arn != "" ? 1 : 0

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Public HTTPS ingress when ACM TLS is configured"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_frontend" {
  count = var.enable_public_alb ? 1 : 0

  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.frontend.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "ALB to frontend targets"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_backend" {
  count = var.enable_public_alb ? 1 : 0

  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = var.backend_container_port
  to_port                      = var.backend_container_port
  ip_protocol                  = "tcp"
  description                  = "ALB to backend targets"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_grafana" {
  count = var.enable_public_alb ? 1 : 0

  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.monitoring.id
  from_port                    = var.grafana_container_port
  to_port                      = var.grafana_container_port
  ip_protocol                  = "tcp"
  description                  = "ALB to Grafana target only"
}

resource "aws_vpc_security_group_ingress_rule" "frontend_from_alb" {
  count = var.enable_public_alb ? 1 : 0

  security_group_id            = aws_security_group.frontend.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "Frontend traffic from ALB only"
}

resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  count = var.enable_public_alb ? 1 : 0

  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.backend_container_port
  to_port                      = var.backend_container_port
  ip_protocol                  = "tcp"
  description                  = "Backend traffic from ALB only"
}

#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "backend_https" {
  security_group_id = aws_security_group.backend.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Backend outbound HTTPS"
}

resource "aws_vpc_security_group_egress_rule" "backend_to_rds" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Backend to PostgreSQL"
}

# One-off database tasks need HTTPS for ECR/S3 image pulls and Secrets Manager
# injection, plus PostgreSQL. They deliberately have no inbound rules.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "database_tasks_https" {
  security_group_id = aws_security_group.database_tasks.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Database task outbound HTTPS for ECR and Secrets Manager"
}

resource "aws_vpc_security_group_egress_rule" "database_tasks_to_rds" {
  security_group_id            = aws_security_group.database_tasks.id
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "One-off database tasks to application PostgreSQL"
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_backend" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from backend only"
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_database_tasks" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.database_tasks.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from one-off database tasks only"
}

