variable "aws_region" {
  description = "AWS region for the Terraform state infrastructure."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(?:-gov)?-[a-z]+-\\d$", var.aws_region))
    error_message = "aws_region must look like a valid AWS region identifier, for example us-east-1."
  }
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name)) && !strcontains(var.state_bucket_name, "..") && !strcontains(var.state_bucket_name, ".-") && !strcontains(var.state_bucket_name, "-.")
    error_message = "state_bucket_name must be a valid globally unique S3 bucket name."
  }
}

variable "lock_table_name" {
  description = "DynamoDB table used for Terraform state locking compatibility."
  type        = string
  default     = "cloudstart-terraform-lock"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{3,255}$", var.lock_table_name))
    error_message = "lock_table_name must be 3-255 characters using letters, numbers, underscores, dots, or hyphens."
  }
}
