terraform {
  backend "s3" {
    key          = "cloudstart/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
    # bucket and region are supplied during `terraform init` because Terraform
    # backend blocks cannot reference input variables.
  }
}
