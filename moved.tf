# The ALB and target-group resources were originally singleton resources.
# Move their addresses into index zero before making them optional with count.
moved {
  from = aws_lb.this
  to   = aws_lb.this[0]
}

moved {
  from = aws_lb_target_group.frontend
  to   = aws_lb_target_group.frontend[0]
}

moved {
  from = aws_lb_target_group.backend
  to   = aws_lb_target_group.backend[0]
}

moved {
  from = aws_lb_target_group.grafana
  to   = aws_lb_target_group.grafana[0]
}

moved {
  from = aws_lb_listener_rule.backend
  to   = aws_lb_listener_rule.backend[0]
}

moved {
  from = aws_lb_listener_rule.grafana
  to   = aws_lb_listener_rule.grafana[0]
}

moved {
  from = aws_vpc_security_group_ingress_rule.alb_http
  to   = aws_vpc_security_group_ingress_rule.alb_http[0]
}

moved {
  from = aws_vpc_security_group_egress_rule.alb_to_frontend
  to   = aws_vpc_security_group_egress_rule.alb_to_frontend[0]
}

moved {
  from = aws_vpc_security_group_egress_rule.alb_to_backend
  to   = aws_vpc_security_group_egress_rule.alb_to_backend[0]
}

moved {
  from = aws_vpc_security_group_egress_rule.alb_to_grafana
  to   = aws_vpc_security_group_egress_rule.alb_to_grafana[0]
}

moved {
  from = aws_vpc_security_group_ingress_rule.frontend_from_alb
  to   = aws_vpc_security_group_ingress_rule.frontend_from_alb[0]
}

moved {
  from = aws_vpc_security_group_ingress_rule.backend_from_alb
  to   = aws_vpc_security_group_ingress_rule.backend_from_alb[0]
}

moved {
  from = aws_vpc_security_group_ingress_rule.monitoring_from_alb
  to   = aws_vpc_security_group_ingress_rule.monitoring_from_alb[0]
}
