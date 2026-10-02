locals {
  name = lower(join("-", compact([
    var.project_name,
    var.environment,
  ])))

  global_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Repository  = var.repository_name
    Owner       = var.owner
    CostCenter  = var.cost_center
  }

  azs = slice(
    data.aws_availability_zones.available.names,
    0,
    var.availability_zone_count,
  )

  public_subnet_cidrs = [
    for index in range(var.availability_zone_count) :
    cidrsubnet(var.vpc_cidr, 8, index)
  ]

  private_app_subnet_cidrs = [
    for index in range(var.availability_zone_count) :
    cidrsubnet(var.vpc_cidr, 8, index + 10)
  ]

  private_db_subnet_cidrs = [
    for index in range(var.availability_zone_count) :
    cidrsubnet(var.vpc_cidr, 8, index + 20)
  ]

  subnets_by_az = {
    for index, az in local.azs : az => {
      public_cidr      = local.public_subnet_cidrs[index]
      private_app_cidr = local.private_app_subnet_cidrs[index]
      private_db_cidr  = local.private_db_subnet_cidrs[index]
    }
  }
}
