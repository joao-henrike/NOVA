resource "aws_cloudwatch_log_group" "frontend" {
  name              = "/cloudstart/${var.environment}/frontend"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name        = "${var.name}-frontend-logs"
    Component   = "frontend"
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}
