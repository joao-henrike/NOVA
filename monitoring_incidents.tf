# Independent incident evidence: the monitoring UI may itself be unavailable.
resource "aws_cloudwatch_metric_alarm" "grafana_no_healthy_target" {
  count               = var.enable_public_alb ? 1 : 0
  alarm_name          = "${local.name}-grafana-no-healthy-target"
  alarm_description   = "Grafana has no healthy ALB target; expected during intentional shutdown."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  dimensions = {
    LoadBalancer = aws_lb.this[0].arn_suffix
    TargetGroup  = aws_lb_target_group.grafana[0].arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "monitoring_alb_503" {
  count               = var.enable_public_alb ? 1 : 0
  alarm_name          = "${local.name}-alb-503"
  alarm_description   = "ALB-generated HTTP 503 across all routes; correlate with target health."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_503_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = aws_lb.this[0].arn_suffix
  }
}

resource "aws_cloudwatch_log_group" "monitoring_task_events" {
  name              = "/aws/events/${local.name}/monitoring-task-stops"
  retention_in_days = 14
}

resource "aws_cloudwatch_event_rule" "monitoring_task_stopped" {
  name        = "${local.name}-monitoring-task-stopped"
  description = "Preserve ECS stop reason and container exit codes beyond ECS short-lived task history."
  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.this.arn]
      group      = ["service:${aws_ecs_service.monitoring.name}"]
      lastStatus = ["STOPPED"]
    }
  })
}

resource "aws_cloudwatch_log_resource_policy" "monitoring_task_events" {
  policy_name = "${local.name}-monitoring-task-event-delivery"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "delivery.logs.amazonaws.com"] }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.monitoring_task_events.arn}:*"
    }]
  })
}

resource "aws_cloudwatch_event_target" "monitoring_task_stopped" {
  rule       = aws_cloudwatch_event_rule.monitoring_task_stopped.name
  target_id  = "MonitoringTaskStopLogs"
  arn        = aws_cloudwatch_log_group.monitoring_task_events.arn
  depends_on = [aws_cloudwatch_log_resource_policy.monitoring_task_events]
}
