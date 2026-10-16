variable "name" {
  description = "Nome base dos recursos do frontend."
  type        = string
}

variable "environment" {
  description = "Ambiente de implantação."
  type        = string
}

variable "aws_region" {
  description = "Região AWS onde os recursos serão criados."
  type        = string
}

variable "vpc_id" {
  description = "ID da VPC onde o frontend será executado."
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets privadas de aplicação usadas pelo ECS."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "O frontend deve receber pelo menos duas subnets privadas."
  }
}

variable "ecs_cluster_arn" {
  description = "ARN do ECS Cluster existente."
  type        = string
}

variable "frontend_security_group_id" {
  description = "Security Group das tasks do frontend."
  type        = string
}

variable "alb_security_group_id" {
  description = "Security Group do ALB."
  type        = string
}

variable "alb_listener_arn" {
  description = "ARN do listener do ALB que receberá a regra do frontend."
  type        = string
  default     = null
}

variable "listener_priority" {
  description = "Prioridade da regra do listener, quando configurada."
  type        = number
  default     = 100
}

variable "host_header" {
  description = "Host opcional para direcionar tráfego ao frontend."
  type        = string
  default     = null
}

variable "path_patterns" {
  description = "Paths opcionais para direcionar ao frontend."
  type        = list(string)
  default     = ["/*"]
}

variable "container_image" {
  description = "Imagem inicial do frontend. Em produção, prefira repository@sha256:digest."
  type        = string
  default     = null
}

variable "container_port" {
  description = "Porta HTTP do container."
  type        = number
  default     = 80
}

variable "cpu" {
  description = "CPU da task Fargate."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Memória da task Fargate em MiB."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Quantidade desejada de tasks."
  type        = number
  default     = 2

  validation {
    condition     = var.desired_count >= 2
    error_message = "O frontend deve manter pelo menos duas tasks."
  }
}

variable "health_check_path" {
  description = "Endpoint usado pelo ALB para health check."
  type        = string
  default     = "/health"
}

variable "log_retention_days" {
  description = "Retenção dos logs do frontend no CloudWatch."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags adicionais."
  type        = map(string)
  default     = {}
}
