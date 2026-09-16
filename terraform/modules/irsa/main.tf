###############################################################################
# IAM Roles for Service Accounts
#
# One generic module, instantiated once per workload identity. The alternative,
# a bespoke role resource per workload, is how a platform ends up with four roles
# whose trust policies differ in small ways that nobody intended.
#
# The trust policy is the security boundary and it has three conditions, not one:
#
#   aud  must be sts.amazonaws.com. Without this condition any token the cluster's
#        OIDC provider issues for any audience is accepted, which widens the role
#        to tokens that were never meant to assume it.
#   sub  must be exactly system:serviceaccount:<namespace>:<name>. A wildcard here,
#        which is common in copied examples, means every service account in the
#        cluster can assume the role. That single character turns a scoped
#        identity into a cluster-wide one.
#   The condition test is StringEquals, not StringLike, for the same reason.
#
# Multiple service accounts can share one role by passing more than one entry in
# service_accounts, which produces an explicit list of exact subjects rather than
# a pattern.
###############################################################################

locals {
  # The OIDC provider ARN ends in the issuer host and path. The trust policy
  # conditions key off that same string, so it is derived rather than passed
  # separately, which removes the chance of the two disagreeing.
  oidc_issuer = replace(var.oidc_provider_arn, "/^arn:.*oidc-provider\\//", "")

  subjects = [
    for account in var.service_accounts :
    "system:serviceaccount:${account.namespace}:${account.name}"
  ]
}

data "aws_iam_policy_document" "assume" {
  statement {
    sid     = "AllowServiceAccountTokenExchange"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      # StringEquals with an explicit list. Never StringLike with a wildcard.
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = local.subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name        = var.role_name
  description = var.description
  path        = var.path

  assume_role_policy = data.aws_iam_policy_document.assume.json

  # A boundary, when supplied, caps what this role can ever be granted regardless
  # of what a future policy attachment says. It is the one control that survives
  # someone attaching AdministratorAccess by mistake.
  permissions_boundary = var.permissions_boundary_arn

  # An hour. Long enough that a training job does not have to refresh mid-step,
  # short enough that a leaked token has a bounded life. Raise it only for a job
  # that genuinely runs longer than one hour without refreshing, which is rare:
  # the AWS SDKs refresh automatically.
  max_session_duration = var.max_session_duration

  tags = merge(var.tags, { Name = var.role_name })
}

# A managed policy rather than an inline one. aws_iam_role's inline_policy
# argument is deprecated in provider 6.x, and a separate policy resource is also
# readable on its own in the console and attachable to a second role later
# without being copied.
resource "aws_iam_policy" "this" {
  count = var.policy_json == null ? 0 : 1

  name        = "${var.role_name}-policy"
  description = "Permissions for ${var.role_name}"
  path        = var.path
  policy      = var.policy_json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "own" {
  count = var.policy_json == null ? 0 : 1

  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this[0].arn
}

resource "aws_iam_role_policy_attachment" "additional" {
  for_each = toset(var.additional_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}
