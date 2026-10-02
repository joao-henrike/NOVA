resource "aws_ecs_cluster" "this" {
  name = "${local.name}-cluster"


  tags = merge(local.global_tags, {
    Name = "${local.name}-cluster"
  })
}

resource "aws_lb" "this" {
  name                       = substr("${local.name}-alb", 0, 32)
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = [for subnet in aws_subnet.public : subnet.id]
  enable_deletion_protection = var.alb_deletion_protection

  tags = merge(local.global_tags, {
    Name = "${local.name}-alb"
  })
}

resource "aws_lb_target_group" "frontend" {
  name        = substr("${local.name}-frontend-tg", 0, 32)
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = var.frontend_health_check_path
    protocol            = "HTTP"
    matcher             = "200-399"
  }

  tags = merge(local.global_tags, {
    Name      = "${local.name}-frontend-tg"
    Component = "frontend"
  })
}

resource "aws_lb_target_group" "backend" {
  name        = substr("${local.name}-backend-tg", 0, 32)
  port        = var.backend_container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = var.backend_health_check_path
    protocol            = "HTTP"
    matcher             = "200-399"
  }

  tags = merge(local.global_tags, {
    Name      = "${local.name}-backend-tg"
    Component = "backend"
  })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }

  tags = merge(local.global_tags, {
    Name = "${local.name}-http-listener"
  })
}

resource "aws_lb_listener_rule" "backend" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = ["/api", "/api/*"]
    }
  }

  tags = merge(local.global_tags, {
    Name      = "${local.name}-backend-route"
    Component = "backend"
  })
}
