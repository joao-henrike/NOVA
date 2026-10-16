# Configure o backend remoto somente depois de criar o bucket de estado
# e o mecanismo de locking adotado pela infraestrutura principal.
#
# Exemplo:
#
# terraform {
#   backend "s3" {
#     bucket       = "cloudstart-terraform-state"
#     key          = "frontend/dev/terraform.tfstate"
#     region       = "us-east-1"
#     encrypt      = true
#     use_lockfile = true
#   }
# }
#
# Nunca versionar credenciais AWS no repositório.
