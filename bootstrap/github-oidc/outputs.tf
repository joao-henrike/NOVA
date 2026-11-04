output "github_actions_cd_role_arn" {
  description = "Set this value as the GitHub repository variable AWS_CD_ROLE_ARN."
  value       = aws_iam_role.github_actions_cd.arn
}

output "github_actions_oidc_provider_arn" {
  description = "AWS IAM OIDC identity provider trusted by GitHub Actions."
  value       = local.github_oidc_provider_arn
}

output "github_actions_oidc_subject" {
  description = "Exact immutable GitHub OIDC subject trusted by the development role."
  value       = local.github_oidc_subject
}

output "github_actions_cd_role_name" {
  description = "Name of the narrowly scoped development deployment IAM role."
  value       = aws_iam_role.github_actions_cd.name
}
