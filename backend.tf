terraform {
  backend "s3" {
    key          = "cloudstart/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
    # bucket and dynamodb_table are intentionally supplied during `terraform init`
    # because Terraform backend blocks cannot reference input variables.
  }
}
