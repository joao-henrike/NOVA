output "ecr_repository_name" {
  description = "Nome do ECR do frontend."
  value       = aws_ecr_repository.frontend.name
}

output "ecr_repository_url" {
  description = "URL do ECR do frontend."
  value       = aws_ecr_repository.frontend.repository_url
}

output "ecr_repository_arn" {
  description = "ARN do ECR do frontend."
  value       = aws_ecr_repository.frontend.arn
}

output "target_group_arn" {
  description = "ARN do Target Group do frontend."
  value       = aws_lb_target_group.frontend.arn
}

output "target_group_name" {
  description = "Nome do Target Group do frontend."
  value       = aws_lb_target_group.frontend.name
}

output "ecs_service_name" {
  description = "Nome do ECS Service do frontend."
  value       = aws_ecs_service.frontend.name
}

output "ecs_task_definition_arn" {
  description = "ARN da Task Definition do frontend."
  value       = aws_ecs_task_definition.frontend.arn
}

output "execution_role_arn" {
  description = "ARN da Execution Role."
  value       = aws_iam_role.execution.arn
}

output "task_role_arn" {
  description = "ARN da Task Role."
  value       = aws_iam_role.task.arn
}

output "log_group_name" {
  description = "Nome do CloudWatch Log Group."
  value       = aws_cloudwatch_log_group.frontend.name
}
