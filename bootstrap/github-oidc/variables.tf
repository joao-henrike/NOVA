variable "aws_region" {
  description = "AWS region used for the CloudStart development stack."
  type        = string
  default     = "us-east-1"
}

variable "expected_account_id" {
  description = "AWS account ID that owns the CloudStart development stack."
  type        = string
  default     = "760396521507"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "expected_account_id must be a 12-digit AWS account ID."
  }
}

variable "project_name" {
  description = "Project name used in AWS resource names and tags."
  type        = string
  default     = "cloudstart"
}

variable "environment" {
  description = "Environment name used in AWS resource names and tags."
  type        = string
  default     = "dev"
}

variable "state_bucket_name" {
  description = "Existing protected S3 bucket used by the root Terraform state."
  type        = string
  default     = "cloudstart-nova-terraform-state-760396521507"
}

variable "state_key" {
  description = "Canonical root Terraform state key."
  type        = string
  default     = "cloudstart/dev/terraform.tfstate"

  validation {
    condition     = var.state_key == "cloudstart/dev/terraform.tfstate"
    error_message = "The deployment role is intentionally scoped to the canonical CloudStart development state key."
  }
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the development deployment role."
  type        = string
  default     = "joao-henrike/NOVA"

  validation {
    condition     = var.github_repository == "joao-henrike/NOVA"
    error_message = "This bootstrap role is intentionally scoped to joao-henrike/NOVA."
  }
}

variable "github_owner_id" {
  description = "Immutable numeric GitHub owner ID. Repositories created after July 15, 2026 use immutable OIDC subject claims."
  type        = string
  default     = "133373332"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be a numeric GitHub owner ID."
  }
}

variable "github_repository_id" {
  description = "Immutable numeric GitHub repository ID."
  type        = string
  default     = "1393500090"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be a numeric GitHub repository ID."
  }
}

variable "github_environment" {
  description = "GitHub Environment whose jobs may assume this role."
  type        = string
  default     = "development"

  validation {
    condition     = var.github_environment == "development"
    error_message = "The normal deployment role trusts only the development GitHub Environment."
  }
}

variable "role_name" {
  description = "IAM role name used as the AWS_CD_ROLE_ARN repository variable."
  type        = string
  default     = "cloudstart-nova-github-actions-cd"

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.role_name))
    error_message = "role_name must be a valid IAM role name (1-64 characters)."
  }
}
