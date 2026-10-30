data "aws_caller_identity" "current" {}

locals {
  name                  = "${var.project_name}-${var.environment}"
  github_oidc_subject   = "repo:joao-henrike@${var.github_owner_id}/NOVA@${var.github_repository_id}:environment:${var.github_environment}"
  state_bucket_arn      = "arn:aws:s3:::${var.state_bucket_name}"
  state_object_arn      = "${local.state_bucket_arn}/${var.state_key}"
  state_lock_object_arn = "${local.state_bucket_arn}/${var.state_key}.tflock"
  ecr_repository_arns = [
    "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${local.name}-frontend",
    "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${local.name}-backend",
  ]
  secret_names = [
    "${local.name}/database/runtime",
    "${local.name}/database/migrator",
    "${local.name}/backend/authentication",
  ]
  secret_arns = [
    for secret_name in local.secret_names :
    "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${secret_name}-*"
  ]
  ecs_cluster_arn         = "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${local.name}-cluster"
  ecs_task_definition_arn = "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.name}-*:*"
  ecs_one_off_task_definition_arns = [
    "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.name}-db-bootstrap:*",
    "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.name}-db-migration:*",
  ]
  ecs_service_arns = [
    "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${local.name}-cluster/${local.name}-frontend",
    "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${local.name}-cluster/${local.name}-backend",
    "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${local.name}-cluster/${local.name}-monitoring",
  ]
  ecs_execution_role_arns = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-ecs-execution",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-ecs-backend-execution",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-ecs-migration-execution",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-ecs-db-bootstrap-execution",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-ecs-monitoring-execution",
  ]
  ecs_mutable_role_arns = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-ecs-backend-execution",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-ecs-migration-execution",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-ecs-db-bootstrap-execution",
  ]
  ecs_pass_role_arns = concat(local.ecs_execution_role_arns, [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-ecs-frontend-task",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-ecs-backend-task",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-ecs-monitoring-task",
  ])
  log_group_arn           = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${local.name}/*:*"
  security_group_arn      = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/*"
  security_group_rule_arn = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group-rule/*"
  vpc_arn                 = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:vpc/*"
  scalable_target_arn     = "arn:aws:application-autoscaling:${var.aws_region}:${data.aws_caller_identity.current.account_id}:scalable-target/service/${local.name}-cluster/${local.name}-*"
}

locals {
  github_oidc_provider_arn = (
    var.existing_github_oidc_provider_arn != ""
    ? data.aws_iam_openid_connect_provider.existing_github[0].arn
    : aws_iam_openid_connect_provider.github[0].arn
  )
  github_oidc_provider_has_sts_audience = (
    var.existing_github_oidc_provider_arn == ""
    ? true
    : contains(
      data.aws_iam_openid_connect_provider.existing_github[0].client_id_list,
      "sts.amazonaws.com",
    )
  )
}

data "aws_iam_openid_connect_provider" "existing_github" {
  count = var.existing_github_oidc_provider_arn == "" ? 0 : 1
  arn   = var.existing_github_oidc_provider_arn
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    sid     = "TrustOnlyNOVADevelopmentEnvironment"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_oidc_subject]
    }
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.existing_github_oidc_provider_arn == "" ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Name = "github-actions-oidc"
  }
}

resource "aws_iam_role" "github_actions_cd" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600

  tags = {
    Name       = var.role_name
    Purpose    = "NOVA development application deployment"
    Repository = var.github_repository
  }

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.expected_account_id
      error_message = "Refusing to create the GitHub Actions role outside the expected CloudStart AWS account."
    }

    precondition {
      condition     = local.github_oidc_provider_has_sts_audience
      error_message = "The existing GitHub OIDC provider must already trust the sts.amazonaws.com audience; this stack will not modify a shared provider."
    }
  }
}

data "aws_iam_policy_document" "github_cd_permissions" {
  statement {
    sid    = "ReadOnlyInfrastructureMetadata"
    effect = "Allow"
    actions = [
      "application-autoscaling:Describe*",
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "ec2:Describe*",
      "ecr:Describe*",
      "ecr:List*",
      "ecs:Describe*",
      "ecs:List*",
      "elasticloadbalancing:Describe*",
      "iam:Get*",
      "iam:List*",
      "logs:Describe*",
      "logs:List*",
      "rds:Describe*",
      "secretsmanager:DescribeSecret",
      "sts:GetCallerIdentity",
      "tag:GetResources",
      "tag:GetTagKeys",
      "tag:GetTagValues",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadTerraformStateBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid       = "ListOnlyCanonicalTerraformStatePrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["cloudstart/dev/*"]
    }
  }

  statement {
    sid       = "ReadWriteOnlyCanonicalTerraformState"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = [local.state_object_arn]
  }

  statement {
    sid       = "ManageOnlyCanonicalTerraformLockFile"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.state_lock_object_arn]
  }

  statement {
    sid       = "AuthenticateToECR"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PushOnlyCloudStartDevelopmentImages"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = local.ecr_repository_arns
  }

  statement {
    sid    = "ManageOnlyApplicationSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
    ]
    resources = local.secret_arns
  }

  statement {
    sid       = "CreateOnlyNamedApplicationSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:CreateSecret"]
    resources = local.secret_arns

    condition {
      test     = "StringEquals"
      variable = "secretsmanager:Name"
      values   = local.secret_names
    }
  }

  statement {
    sid    = "CreateAndTrustOnlyNamedNOVAExecutionRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = local.ecs_mutable_role_arns
  }

  statement {
    sid    = "UpdateOnlyNOVAExecutionRoleInlinePolicies"
    effect = "Allow"
    actions = [
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
    ]
    resources = local.ecs_execution_role_arns
  }

  statement {
    sid       = "PassOnlyNOVAECSTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.ecs_pass_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid    = "CreateOnlyRequiredECSServiceLinkedRoles"
    effect = "Allow"
    actions = [
      "iam:CreateServiceLinkedRole",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/ecs.amazonaws.com/AWSServiceRoleForECS",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/ecs.application-autoscaling.amazonaws.com/AWSServiceRoleForApplicationAutoScaling_ECSService",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com",
        "ecs.application-autoscaling.amazonaws.com",
      ]
    }
  }

  statement {
    sid    = "RegisterNOVAApplicationTaskDefinitions"
    effect = "Allow"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:TagResource",
      "ecs:UntagResource",
    ]
    resources = [local.ecs_task_definition_arn]
  }

  statement {
    sid    = "CreateAndUpdateNOVAApplicationServices"
    effect = "Allow"
    actions = [
      "ecs:CreateService",
      "ecs:UpdateService",
      "ecs:TagResource",
      "ecs:UntagResource",
    ]
    resources = concat(local.ecs_service_arns, [local.ecs_cluster_arn, local.ecs_task_definition_arn])

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.ecs_cluster_arn]
    }
  }

  statement {
    sid       = "RunOnlyDatabaseBootstrapAndMigrationTasks"
    effect    = "Allow"
    actions   = ["ecs:RunTask", "ecs:TagResource"]
    resources = local.ecs_one_off_task_definition_arns

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.ecs_cluster_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "ecs:task-cpu"
      values   = ["256"]
    }

    condition {
      test     = "StringEquals"
      variable = "ecs:task-memory"
      values   = ["512"]
    }
  }

  statement {
    sid    = "ManageOnlyNOVAApplicationLogGroups"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
    ]
    resources = [local.log_group_arn]
  }

  statement {
    sid       = "CreateOnlyTaggedNOVADevelopmentSecurityGroups"
    effect    = "Allow"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = [local.security_group_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [var.project_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = [var.environment]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values = [
        "Name",
        "Project",
        "Environment",
        "ManagedBy",
        "Repository",
        "Owner",
        "CostCenter",
        "Component",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:Region"
      values   = [var.aws_region]
    }
  }

  statement {
    sid       = "CreateOnlyInTaggedNOVADevelopmentVPCs"
    effect    = "Allow"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = [local.vpc_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [var.environment]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:Region"
      values   = [var.aws_region]
    }
  }

  statement {
    sid       = "TagOnlyNOVADevelopmentResourcesDuringCreation"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = [local.security_group_arn, local.security_group_rule_arn]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values = [
        "CreateSecurityGroup",
        "AuthorizeSecurityGroupIngress",
        "AuthorizeSecurityGroupEgress",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [var.project_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = [var.environment]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values = [
        "Name",
        "Project",
        "Environment",
        "ManagedBy",
        "Repository",
        "Owner",
        "CostCenter",
        "Component",
      ]
    }
  }

  statement {
    sid       = "ManageNonOwnershipTagsOnlyOnOwnedNOVAResources"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = [local.security_group_arn, local.security_group_rule_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [var.environment]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values = [
        "Name",
        "ManagedBy",
        "Repository",
        "Owner",
        "CostCenter",
        "Component",
      ]
    }
  }

  statement {
    sid    = "AuthorizeOnlyTaggedNOVADevelopmentSecurityGroups"
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
    ]
    resources = [local.security_group_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [var.environment]
    }
  }

  statement {
    sid    = "AuthorizeOnlyTaggedNOVADevelopmentSecurityGroupRules"
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
    ]
    resources = [local.security_group_rule_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [var.project_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = [var.environment]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values = [
        "Project",
        "Environment",
        "ManagedBy",
        "Repository",
        "Owner",
        "CostCenter",
      ]
    }
  }

  statement {
    sid    = "RevokeRulesOnlyOnTaggedNOVADevelopmentGroups"
    effect = "Allow"
    actions = [
      "ec2:RevokeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
    ]
    resources = [local.security_group_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [var.environment]
    }
  }

  statement {
    sid    = "ActivateOnlyNOVADevelopmentECSAutoscalingTargets"
    effect = "Allow"
    actions = [
      "application-autoscaling:RegisterScalableTarget",
      "application-autoscaling:TagResource",
      "application-autoscaling:UntagResource",
    ]
    resources = [local.scalable_target_arn]

    condition {
      test     = "StringEquals"
      variable = "application-autoscaling:service-namespace"
      values   = ["ecs"]
    }

    condition {
      test     = "StringEquals"
      variable = "application-autoscaling:scalable-dimension"
      values   = ["ecs:service:DesiredCount"]
    }
  }
}

resource "aws_iam_role_policy" "github_actions_cd" {
  name   = "nova-development-deployment"
  role   = aws_iam_role.github_actions_cd.id
  policy = data.aws_iam_policy_document.github_cd_permissions.json
}
