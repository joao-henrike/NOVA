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

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds-sg"
  description = "Security group for the private RDS database."
  vpc_id      = aws_vpc.this.id

  tags = merge(local.global_tags, {
    Name = "${local.name}-rds-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Public HTTP ingress"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_frontend" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.frontend.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "ALB to frontend targets"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_backend" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = var.backend_container_port
  to_port                      = var.backend_container_port
  ip_protocol                  = "tcp"
  description                  = "ALB to backend targets"
}

resource "aws_vpc_security_group_ingress_rule" "frontend_from_alb" {
  security_group_id            = aws_security_group.frontend.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "Frontend traffic from ALB only"
}

#trivy:ignore:AWS-0104
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "frontend_https" {
  security_group_id = aws_security_group.frontend.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Frontend outbound HTTPS"
}

resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.backend_container_port
  to_port                      = var.backend_container_port
  ip_protocol                  = "tcp"
  description                  = "Backend traffic from ALB only"
}

#trivy:ignore:AWS-0104
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

resource "aws_vpc_security_group_ingress_rule" "rds_from_backend" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from backend only"
}

#trivy:ignore:AWS-0104
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "rds_all" {
  security_group_id = aws_security_group.rds.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Default outbound traffic"
}
