module "frontend" {
  source = "../../modules/frontend"

  name        = var.project_name
  environment = var.environment
  aws_region  = var.aws_region

  vpc_id             = var.vpc_id
  private_subnet_ids  = var.private_subnet_ids
  ecs_cluster_arn     = var.ecs_cluster_arn
  frontend_security_group_id = var.frontend_security_group_id
  alb_security_group_id       = var.alb_security_group_id

  alb_listener_arn = var.alb_listener_arn

  container_image = var.container_image

  tags = var.tags
}
