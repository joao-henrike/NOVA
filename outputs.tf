output "aws_account_id" {
  description = "AWS account ID used for the deployment."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region used for the deployment."
  value       = data.aws_region.current.region
}

output "vpc_id" {
  description = "ID of the CloudStart VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs by Availability Zone."
  value       = { for az, subnet in aws_subnet.public : az => subnet.id }
}

output "private_app_subnet_ids" {
  description = "Private application subnet IDs by Availability Zone."
  value       = { for az, subnet in aws_subnet.private_app : az => subnet.id }
}

output "private_db_subnet_ids" {
  description = "Private database subnet IDs by Availability Zone."
  value       = { for az, subnet in aws_subnet.private_db : az => subnet.id }
}

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer."
  value       = aws_lb.this.dns_name
}

output "frontend_ecr_repository_url" {
  description = "ECR repository URL for frontend images."
  value       = aws_ecr_repository.frontend.repository_url
}

output "backend_ecr_repository_url" {
  description = "ECR repository URL for backend images."
  value       = aws_ecr_repository.backend.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "frontend_ecs_service_name" {
  description = "ECS frontend service name."
  value       = aws_ecs_service.frontend.name
}

output "backend_ecs_service_name" {
  description = "ECS backend service name."
  value       = aws_ecs_service.backend.name
}

output "frontend_task_definition_arn" {
  description = "Current frontend ECS task definition ARN."
  value       = aws_ecs_task_definition.frontend.arn
}

output "backend_task_definition_arn" {
  description = "Current backend ECS task definition ARN."
  value       = aws_ecs_task_definition.backend.arn
}

output "rds_endpoint" {
  description = "RDS connection endpoint hostname and port."
  value       = aws_db_instance.this.endpoint
}

output "rds_port" {
  description = "RDS PostgreSQL listener port."
  value       = aws_db_instance.this.port
}

output "rds_master_username" {
  description = "RDS master username."
  value       = aws_db_instance.this.username
}

output "rds_master_user_secret_arn" {
  description = "Secrets Manager ARN containing the RDS-managed master password."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
  sensitive   = true
}



output "grafana_url" {
  description = "Grafana URL exposed through the current public ALB listener."
  value       = "http://${aws_lb.this.dns_name}/grafana/"
}

output "monitoring_ecs_service_name" {
  description = "ECS monitoring service name hosting Zabbix server, Zabbix web, and Grafana."
  value       = aws_ecs_service.monitoring.name
}

output "monitoring_rds_endpoint" {
  description = "Private RDS endpoint used by the Zabbix monitoring database."
  value       = aws_db_instance.monitoring.endpoint
}
