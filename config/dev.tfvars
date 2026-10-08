# CloudStart Development environment configuration.
# This file intentionally contains non-sensitive values only.
# Secrets are generated/loaded by scripts/deploy.sh and never committed.

project_name                         = "cloudstart"
environment                          = "dev"
aws_region                           = "us-east-1"
availability_zone_count              = 2
vpc_cidr                             = "10.20.0.0/16"

deploy_application                   = false
frontend_image_tag                   = "v0.1.1"
backend_image_tag                    = "v0.1.0"
frontend_container_name              = "frontend"
backend_container_name               = "backend"
backend_container_port               = 8000
frontend_health_check_path            = "/health"
backend_health_check_path             = "/health"

frontend_task_cpu                     = 256
frontend_task_memory                  = 512
backend_task_cpu                     = 256
backend_task_memory                   = 512

frontend_desired_task_count           = 2
frontend_min_task_count               = 2
frontend_max_task_count               = 6
backend_desired_task_count            = 2
backend_min_task_count                = 2
backend_max_task_count                = 6

frontend_cpu_target_utilization       = 60
frontend_memory_target_utilization    = 70
backend_cpu_target_utilization        = 60
backend_memory_target_utilization     = 70

db_name                               = "cloudstart"
db_username                           = "cloudstart_admin"
db_instance_class                     = "db.t4g.micro"
db_engine_version                     = "16"
db_allocated_storage                  = 20
db_max_allocated_storage              = 100
db_backup_retention_period            = 1

owner                                 = "cloudstart"
cost_center                           = "cloudstart-mvp"
repository_name                       = "NOVA"

alb_deletion_protection               = false
rds_deletion_protection               = false

monitoring_desired_count              = 1
monitoring_task_cpu                   = 1024
monitoring_task_memory                = 2048
zabbix_server_image                   = "zabbix/zabbix-server-pgsql:alpine-7.4.15"
zabbix_web_image                      = "zabbix/zabbix-web-nginx-pgsql:alpine-7.4.15"
grafana_image                         = "grafana/grafana:13.2.3"
grafana_zabbix_plugin                 = "alexanderzobnin-zabbix-app@6.8.0"
grafana_container_port                = 3000
monitoring_timezone                   = "America/Sao_Paulo"
monitoring_db_name                    = "zabbix"
monitoring_db_username                = "zabbix"
monitoring_db_engine_version          = "16"
monitoring_db_instance_class          = "db.t4g.micro"
monitoring_db_allocated_storage       = 20
monitoring_db_max_allocated_storage   = 100
monitoring_db_backup_retention_period = 1
