output "state_bucket_name" {
  description = "S3 bucket name for Terraform remote state."
  value       = aws_s3_bucket.terraform_state.bucket
}

output "state_bucket_arn" {
  description = "S3 bucket ARN for Terraform remote state."
  value       = aws_s3_bucket.terraform_state.arn
}

output "lock_table_name" {
  description = "DynamoDB table name used for Terraform state locking compatibility."
  value       = aws_dynamodb_table.terraform_lock.name
}

output "region" {
  description = "AWS region used for the backend resources."
  value       = var.aws_region
}
