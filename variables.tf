variable "project_name" {
  description = "Short project identifier used in resource names and tags."
  type        = string
  default     = "cloudstart"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,24}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-26 characters, lowercase, and contain only letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region where the MVP infrastructure will be deployed."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(?:-gov)?-[a-z]+-\\d$", var.aws_region))
    error_message = "aws_region must look like a valid AWS region identifier, for example us-east-1."
  }
}

variable "availability_zone_count" {
  description = "Number of Availability Zones to use for the workload."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "availability_zone_count must be between 2 and 3."
  }
}

variable "vpc_cidr" {
  description = "Primary IPv4 CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "deploy_application" {
  description = "Whether ECS services should run application tasks. Set true after the frontend/backend images have been pushed to ECR."
  type        = bool
  default     = false
}

variable "frontend_image_tag" {
  description = "Immutable tag of the frontend image in the CloudStart ECR repository."
  type        = string
  default     = "v0.1.0"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", var.frontend_image_tag))
    error_message = "frontend_image_tag must be a valid ECR image tag."
  }
}

variable "backend_image_tag" {
  description = "Immutable tag of the backend image in the CloudStart ECR repository."
  type        = string
  default     = "v0.1.0"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", var.backend_image_tag))
    error_message = "backend_image_tag must be a valid ECR image tag."
  }
}

variable "frontend_container_name" {
  description = "ECS frontend container name."
  type        = string
  default     = "frontend"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$", var.frontend_container_name))
    error_message = "frontend_container_name must be 1-63 characters and use letters, numbers, underscores, or hyphens."
  }
}

variable "backend_container_name" {
  description = "ECS backend container name."
  type        = string
  default     = "backend"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$", var.backend_container_name))
    error_message = "backend_container_name must be 1-63 characters and use letters, numbers, underscores, or hyphens."
  }
}

variable "backend_container_port" {
  description = "TCP port exposed by the backend container."
  type        = number
  default     = 8000

  validation {
    condition     = var.backend_container_port >= 1 && var.backend_container_port <= 65535
    error_message = "backend_container_port must be between 1 and 65535."
  }
}

variable "frontend_health_check_path" {
  description = "ALB/ECS health check path for the frontend."
  type        = string
  default     = "/health"

  validation {
    condition     = startswith(var.frontend_health_check_path, "/")
    error_message = "frontend_health_check_path must start with '/'."
  }
}

variable "backend_health_check_path" {
  description = "ALB/ECS health check path for the backend."
  type        = string
  default     = "/health"

  validation {
    condition     = startswith(var.backend_health_check_path, "/")
    error_message = "backend_health_check_path must start with '/'."
  }
}

variable "frontend_task_cpu" {
  description = "Fargate CPU units for frontend tasks."
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.frontend_task_cpu)
    error_message = "frontend_task_cpu must be one of the supported Fargate values: 256, 512, 1024, 2048, 4096."
  }
}

variable "frontend_task_memory" {
  description = "Fargate memory in MiB for frontend tasks."
  type        = number
  default     = 512

  validation {
    condition     = var.frontend_task_memory >= 512 && var.frontend_task_memory <= 30720
    error_message = "frontend_task_memory must be between 512 and 30720 MiB and compatible with the selected CPU."
  }
}

variable "backend_task_cpu" {
  description = "Fargate CPU units for backend tasks."
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.backend_task_cpu)
    error_message = "backend_task_cpu must be one of the supported Fargate values: 256, 512, 1024, 2048, 4096."
  }
}

variable "backend_task_memory" {
  description = "Fargate memory in MiB for backend tasks."
  type        = number
  default     = 512

  validation {
    condition     = var.backend_task_memory >= 512 && var.backend_task_memory <= 30720
    error_message = "backend_task_memory must be between 512 and 30720 MiB and compatible with the selected CPU."
  }
}

variable "frontend_desired_task_count" {
  description = "Initial desired number of frontend ECS tasks when deployment is enabled."
  type        = number
  default     = 2

  validation {
    condition     = var.frontend_desired_task_count >= 0 && var.frontend_desired_task_count <= 20
    error_message = "frontend_desired_task_count must be between 0 and 20."
  }
}

variable "frontend_min_task_count" {
  description = "Minimum number of frontend ECS tasks."
  type        = number
  default     = 2

  validation {
    condition     = var.frontend_min_task_count >= 0 && var.frontend_min_task_count <= 20
    error_message = "frontend_min_task_count must be between 0 and 20."
  }
}

variable "frontend_max_task_count" {
  description = "Maximum number of frontend ECS tasks."
  type        = number
  default     = 6

  validation {
    condition     = var.frontend_max_task_count >= 1 && var.frontend_max_task_count <= 50
    error_message = "frontend_max_task_count must be between 1 and 50."
  }
}

variable "backend_desired_task_count" {
  description = "Initial desired number of backend ECS tasks when deployment is enabled."
  type        = number
  default     = 2

  validation {
    condition     = var.backend_desired_task_count >= 0 && var.backend_desired_task_count <= 20
    error_message = "backend_desired_task_count must be between 0 and 20."
  }
}

variable "backend_min_task_count" {
  description = "Minimum number of backend ECS tasks."
  type        = number
  default     = 2

  validation {
    condition     = var.backend_min_task_count >= 0 && var.backend_min_task_count <= 20
    error_message = "backend_min_task_count must be between 0 and 20."
  }
}

variable "backend_max_task_count" {
  description = "Maximum number of backend ECS tasks."
  type        = number
  default     = 6

  validation {
    condition     = var.backend_max_task_count >= 1 && var.backend_max_task_count <= 50
    error_message = "backend_max_task_count must be between 1 and 50."
  }
}

variable "frontend_cpu_target_utilization" {
  description = "Target CPU utilization for frontend service scaling."
  type        = number
  default     = 60

  validation {
    condition     = var.frontend_cpu_target_utilization >= 20 && var.frontend_cpu_target_utilization <= 90
    error_message = "frontend_cpu_target_utilization must be between 20 and 90."
  }
}

variable "frontend_memory_target_utilization" {
  description = "Target memory utilization for frontend service scaling."
  type        = number
  default     = 70

  validation {
    condition     = var.frontend_memory_target_utilization >= 20 && var.frontend_memory_target_utilization <= 90
    error_message = "frontend_memory_target_utilization must be between 20 and 90."
  }
}

variable "backend_cpu_target_utilization" {
  description = "Target CPU utilization for backend service scaling."
  type        = number
  default     = 60

  validation {
    condition     = var.backend_cpu_target_utilization >= 20 && var.backend_cpu_target_utilization <= 90
    error_message = "backend_cpu_target_utilization must be between 20 and 90."
  }
}

variable "backend_memory_target_utilization" {
  description = "Target memory utilization for backend service scaling."
  type        = number
  default     = 70

  validation {
    condition     = var.backend_memory_target_utilization >= 20 && var.backend_memory_target_utilization <= 90
    error_message = "backend_memory_target_utilization must be between 20 and 90."
  }
}

variable "db_name" {
  description = "Initial RDS database name."
  type        = string
  default     = "cloudstart"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.db_name))
    error_message = "db_name must start with a lowercase letter and contain only lowercase letters, numbers, or underscores."
  }
}

variable "db_username" {
  description = "RDS master username. The password is managed by RDS/Secrets Manager."
  type        = string
  default     = "cloudstart_admin"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,15}$", var.db_username))
    error_message = "db_username must be 1-16 characters, start with a letter, and contain only letters, numbers, or underscores."
  }
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"

  validation {
    condition     = can(regex("^db\\.[a-z0-9.-]+$", var.db_instance_class))
    error_message = "db_instance_class must be a valid-looking RDS instance class such as db.t4g.micro."
  }
}

variable "db_engine_version" {
  description = "Major PostgreSQL version."
  type        = string
  default     = "16"

  validation {
    condition     = can(regex("^\\d{2}$", var.db_engine_version))
    error_message = "db_engine_version must be a two-digit PostgreSQL major version such as 16."
  }
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GiB."
  type        = number
  default     = 20

  validation {
    condition     = var.db_allocated_storage >= 20 && var.db_allocated_storage <= 16384
    error_message = "db_allocated_storage must be between 20 and 16384 GiB."
  }
}

variable "db_max_allocated_storage" {
  description = "Maximum RDS storage autoscaling cap in GiB."
  type        = number
  default     = 100

  validation {
    condition     = var.db_max_allocated_storage >= 20 && var.db_max_allocated_storage <= 16384
    error_message = "db_max_allocated_storage must be between 20 and 16384 GiB."
  }
}

variable "db_backup_retention_period" {
  description = "Number of days to retain automated RDS backups."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_period >= 1 && var.db_backup_retention_period <= 35
    error_message = "db_backup_retention_period must be between 1 and 35 days."
  }
}


variable "owner" {
  description = "Owner tag value."
  type        = string
  default     = "cloudstart"

  validation {
    condition     = length(trimspace(var.owner)) >= 2 && length(trimspace(var.owner)) <= 64
    error_message = "owner must contain between 2 and 64 non-space characters."
  }
}

variable "cost_center" {
  description = "Cost center tag value."
  type        = string
  default     = "cloudstart-mvp"

  validation {
    condition     = length(trimspace(var.cost_center)) >= 2 && length(trimspace(var.cost_center)) <= 64
    error_message = "cost_center must contain between 2 and 64 non-space characters."
  }
}

variable "repository_name" {
  description = "Repository name used for tagging."
  type        = string
  default     = "NOVA"

  validation {
    condition     = length(trimspace(var.repository_name)) >= 2 && length(trimspace(var.repository_name)) <= 100
    error_message = "repository_name must contain between 2 and 100 non-space characters."
  }
}

variable "alb_deletion_protection" {
  description = "Enable ALB deletion protection. Recommended for production."
  type        = bool
  default     = false
}

variable "rds_deletion_protection" {
  description = "Enable RDS deletion protection. Recommended for production."
  type        = bool
  default     = false
}


variable "monitoring_desired_count" {
  description = "Number of ECS monitoring tasks. The stack contains a stateful Zabbix server, so the MVP keeps one task by default."
  type        = number
  default     = 1

  validation {
    condition     = var.monitoring_desired_count == 1
    error_message = "monitoring_desired_count must be 1 in the current MVP because the Zabbix server is stateful and runs inside the monitoring task."
  }
}

variable "monitoring_task_cpu" {
  description = "Fargate CPU units for the combined Zabbix/Grafana monitoring task."
  type        = number
  default     = 1024

  validation {
    condition     = contains([512, 1024, 2048, 4096], var.monitoring_task_cpu)
    error_message = "monitoring_task_cpu must be one of the supported Fargate values: 512, 1024, 2048, 4096."
  }
}

variable "monitoring_task_memory" {
  description = "Fargate memory in MiB for the combined Zabbix/Grafana monitoring task."
  type        = number
  default     = 2048

  validation {
    condition     = var.monitoring_task_memory >= 1024 && var.monitoring_task_memory <= 8192
    error_message = "monitoring_task_memory must be between 1024 and 8192 MiB."
  }
}

variable "zabbix_server_image" {
  description = "Zabbix server PostgreSQL container image."
  type        = string
  default     = "zabbix/zabbix-server-pgsql:alpine-8.0-latest"
}

variable "zabbix_web_image" {
  description = "Zabbix web interface PostgreSQL/Nginx container image."
  type        = string
  default     = "zabbix/zabbix-web-nginx-pgsql:alpine-8.0-latest"
}

variable "grafana_image" {
  description = "Grafana OSS container image."
  type        = string
  default     = "grafana/grafana:13.2.3"
}

variable "grafana_zabbix_plugin" {
  description = "Grafana Zabbix plugin package and pinned plugin version."
  type        = string
  default     = "alexanderzobnin-zabbix-app@6.8.0"
}

variable "grafana_container_port" {
  description = "Grafana HTTP port inside the ECS monitoring task."
  type        = number
  default     = 3000

  validation {
    condition     = var.grafana_container_port >= 1 && var.grafana_container_port <= 65535
    error_message = "grafana_container_port must be between 1 and 65535."
  }
}

variable "grafana_admin_password" {
  description = "Initial Grafana administrator password. Required for monitoring deployment and stored in AWS Secrets Manager."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.grafana_admin_password == null || length(var.grafana_admin_password) >= 12
    error_message = "grafana_admin_password must contain at least 12 characters when provided."
  }
}

variable "monitoring_timezone" {
  description = "PHP timezone used by the Zabbix web interface."
  type        = string
  default     = "America/Sao_Paulo"
}

variable "monitoring_db_name" {
  description = "PostgreSQL database name used by Zabbix."
  type        = string
  default     = "zabbix"
}

variable "monitoring_db_username" {
  description = "PostgreSQL username used by Zabbix."
  type        = string
  default     = "zabbix"
}

variable "monitoring_db_engine_version" {
  description = "Major PostgreSQL version for the Zabbix database."
  type        = string
  default     = "16"

  validation {
    condition     = can(regex("^\\d{2}$", var.monitoring_db_engine_version))
    error_message = "monitoring_db_engine_version must be a two-digit PostgreSQL major version such as 16."
  }
}

variable "monitoring_db_instance_class" {
  description = "RDS instance class for the Zabbix database."
  type        = string
  default     = "db.t4g.micro"

  validation {
    condition     = can(regex("^db\\.[a-z0-9.-]+$", var.monitoring_db_instance_class))
    error_message = "monitoring_db_instance_class must be a valid-looking RDS instance class."
  }
}

variable "monitoring_db_allocated_storage" {
  description = "Initial monitoring RDS storage in GiB."
  type        = number
  default     = 20

  validation {
    condition     = var.monitoring_db_allocated_storage >= 20 && var.monitoring_db_allocated_storage <= 16384
    error_message = "monitoring_db_allocated_storage must be between 20 and 16384 GiB."
  }
}

variable "monitoring_db_max_allocated_storage" {
  description = "Maximum monitoring RDS storage autoscaling cap in GiB."
  type        = number
  default     = 100

  validation {
    condition     = var.monitoring_db_max_allocated_storage >= 20 && var.monitoring_db_max_allocated_storage <= 16384
    error_message = "monitoring_db_max_allocated_storage must be between 20 and 16384 GiB."
  }
}

variable "monitoring_db_backup_retention_period" {
  description = "Number of days to retain automated backups for the monitoring database."
  type        = number
  default     = 7

  validation {
    condition     = var.monitoring_db_backup_retention_period >= 1 && var.monitoring_db_backup_retention_period <= 35
    error_message = "monitoring_db_backup_retention_period must be between 1 and 35 days."
  }
}
