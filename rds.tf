resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-db-subnets"
  subnet_ids = [for subnet in aws_subnet.private_db : subnet.id]

  tags = merge(local.global_tags, {
    Name = "${local.name}-db-subnets"
  })
}

resource "aws_db_instance" "this" {
  identifier = "${local.name}-db"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username

  manage_master_user_password = true

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  multi_az               = false
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period    = var.db_backup_retention_period
  backup_window              = "03:00-04:00"
  maintenance_window         = "sun:04:00-sun:05:00"
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  deletion_protection = var.rds_deletion_protection
  skip_final_snapshot = var.environment != "prod"

  final_snapshot_identifier = var.environment == "prod" ? "${local.name}-final" : null

  tags = merge(local.global_tags, {
    Name = "${local.name}-db"
  })
}
