###############################################################################
# CI/CD identity: GitHub Actions OIDC
#
# No access keys. A long-lived AWS access key in a GitHub secret is the single
# most common way an AWS account is compromised through a CI system: it does not
# expire, it is readable by every workflow in the repository, and it is
# exfiltrated by one malicious dependency in a build step.
#
# Instead GitHub mints a short-lived OIDC token per job and AWS exchanges it for a
# session. The security of the arrangement rests entirely on the sub condition in
# the trust policy, so that condition is built carefully here:
#
#   repo:owner/name:ref:refs/heads/main       a push to main and nothing else
#   repo:owner/name:environment:production    a job running in the production
#                                             environment, which GitHub will not
#                                             start until its reviewers approve
#   repo:owner/name:pull_request              a pull request build
#
# The common mistake is repo:owner/name:* which accepts a token from any branch,
# any tag and any pull request in the repository. That means anyone who can open a
# pull request can run a workflow that assumes your deploy role, and on a public
# repository that is anyone at all.
#
# Two roles, not one, for the same reason:
#
#   plan role     read-only. Trusted by pull requests. It can run terraform plan
#                 and describe things, and it cannot change anything.
#   apply role    write. Trusted only by main and by the protected environment. A
#                 pull request cannot assume it.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  issuer     = "token.actions.githubusercontent.com"
  repo       = "${var.github_owner}/${var.github_repository}"

  # Subjects allowed to assume the read-only plan role.
  plan_subjects = concat(
    ["repo:${local.repo}:pull_request"],
    [for branch in var.trusted_branches : "repo:${local.repo}:ref:refs/heads/${branch}"],
    [for environment in var.trusted_environments : "repo:${local.repo}:environment:${environment}"],
  )

  # Subjects allowed to assume the apply role. Pull requests are absent, on purpose.
  apply_subjects = concat(
    [for branch in var.trusted_branches : "repo:${local.repo}:ref:refs/heads/${branch}"],
    [for environment in var.trusted_environments : "repo:${local.repo}:environment:${environment}"],
  )

  provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn
}

###############################################################################
# OIDC provider
#
# An account can only hold one provider per issuer URL, so this is optional: in an
# account that already federates GitHub, pass the existing ARN instead and this
# module creates nothing.
#
# No thumbprint_list. The provider documentation states that for GitHub, AWS
# relies on its own library of trusted root certificate authorities and any
# configured thumbprint is retained but not used for verification. The old advice
# to paste in a fingerprint produced a value that had to be rotated by hand and
# was never actually checked.
###############################################################################

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://${local.issuer}"
  client_id_list = ["sts.amazonaws.com"]

  tags = merge(var.tags, { Name = "github-actions" })
}

###############################################################################
# Trust policies
###############################################################################

data "aws_iam_policy_document" "assume_plan" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      # StringEquals against an explicit list, never StringLike with a wildcard.
      # Every value is a fully qualified subject, so the list itself is the
      # allow-list and there is no pattern for a new branch name to satisfy
      # accidentally.
      test     = "StringEquals"
      variable = "${local.issuer}:sub"
      values   = local.plan_subjects
    }
  }
}

data "aws_iam_policy_document" "assume_apply" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:sub"
      values   = local.apply_subjects
    }
  }
}

###############################################################################
# Plan role: read only
###############################################################################

resource "aws_iam_role" "plan" {
  name        = "${var.name}-ci-plan"
  description = "Read-only role for terraform plan and image scanning from pull requests"
  path        = "/mlops/"

  assume_role_policy   = data.aws_iam_policy_document.assume_plan.json
  permissions_boundary = var.permissions_boundary_arn
  max_session_duration = 3600

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role = aws_iam_role.plan.name
  # ViewOnlyAccess rather than ReadOnlyAccess. ReadOnlyAccess includes
  # s3:GetObject and secretsmanager list operations across the account, which for
  # a role any pull request can assume is more than a plan needs.
  policy_arn = "arn:${local.partition}:iam::aws:policy/job-function/ViewOnlyAccess"
}

data "aws_iam_policy_document" "plan_extra" {
  statement {
    sid    = "ReadTerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      var.state_bucket_arn,
      "${var.state_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "ReadStateLockTable"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:DescribeTable",
    ]
    resources = [var.state_lock_table_arn]
  }

  statement {
    sid    = "DescribeCluster"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
      "eks:DescribeAddon",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadStateEncryptionKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = compact([var.state_kms_key_arn, var.kms_key_arn])
  }
}

resource "aws_iam_policy" "plan_extra" {
  name        = "${var.name}-ci-plan-extra"
  description = "State access and cluster describe for the plan role"
  path        = "/mlops/"
  policy      = data.aws_iam_policy_document.plan_extra.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "plan_extra" {
  role       = aws_iam_role.plan.name
  policy_arn = aws_iam_policy.plan_extra.arn
}

###############################################################################
# Apply role: write, and still scoped
###############################################################################

resource "aws_iam_role" "apply" {
  name        = "${var.name}-ci-apply"
  description = "Deploy role for ${local.repo}: pushes images, applies terraform, deploys to the cluster"
  path        = "/mlops/"

  assume_role_policy   = data.aws_iam_policy_document.assume_apply.json
  permissions_boundary = var.permissions_boundary_arn
  max_session_duration = 3600

  tags = var.tags
}

data "aws_iam_policy_document" "apply" {
  statement {
    sid    = "TerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      var.state_bucket_arn,
      "${var.state_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "TerraformStateLock"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = [var.state_lock_table_arn]
  }

  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # No resource-level permissions for this action.
  }

  statement {
    sid    = "PushImages"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    # Named repositories only. A CI role with ecr:PutImage on every repository in
    # the account can overwrite an unrelated team's production image.
    resources = var.ecr_repository_arns
  }

  statement {
    sid    = "DescribeClusterForKubeconfig"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadArtifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
    ]
    resources = [
      var.artifact_bucket_arn,
      "${var.artifact_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "WriteDatasetsAndModels"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:AbortMultipartUpload",
    ]
    resources = [
      "${var.artifact_bucket_arn}/${var.prefixes.datasets}*",
      "${var.artifact_bucket_arn}/${var.prefixes.models}*",
    ]
  }

  statement {
    sid    = "UseArtifactKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }

  statement {
    sid    = "RunTrainingJobs"
    effect = "Allow"
    actions = [
      "sagemaker:CreateTrainingJob",
      "sagemaker:DescribeTrainingJob",
      "sagemaker:StopTrainingJob",
      "sagemaker:ListTrainingJobs",
      "sagemaker:CreateTransformJob",
      "sagemaker:DescribeTransformJob",
      "sagemaker:AddTags",
      "sagemaker:ListTags",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassOnlyTheExecutionRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [var.sagemaker_execution_role_arn]

    condition {
      # Without this condition, iam:PassRole on the execution role lets the CI
      # role hand that role to any service that accepts a role, not only to
      # SageMaker. PassRole is the most commonly over-granted action in an ML
      # account and this is the condition that contains it.
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["sagemaker.amazonaws.com"]
    }
  }

  statement {
    sid    = "ReadLogsForDebugging"
    effect = "Allow"
    actions = [
      "logs:GetLogEvents",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups",
      "logs:FilterLogEvents",
    ]
    resources = [
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/sagemaker/*",
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/eks/*",
    ]
  }
}

resource "aws_iam_policy" "apply" {
  name        = "${var.name}-ci-apply"
  description = "Deploy permissions for ${local.repo}"
  path        = "/mlops/"
  policy      = data.aws_iam_policy_document.apply.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "apply" {
  role       = aws_iam_role.apply.name
  policy_arn = aws_iam_policy.apply.arn
}

# Infrastructure changes need more than the policy above. Rather than granting the
# apply role administrator access, attach the policies your organisation uses for
# infrastructure change and list them here, so the grant is visible in code review.
resource "aws_iam_role_policy_attachment" "apply_additional" {
  for_each = toset(var.apply_additional_policy_arns)

  role       = aws_iam_role.apply.name
  policy_arn = each.value
}
