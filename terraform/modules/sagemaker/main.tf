###############################################################################
# SageMaker
#
# SageMaker is used here for two things and deliberately not for a third:
#
#   used      managed training jobs. A training job is a batch workload that wants
#             a GPU for twenty minutes and then wants nothing. SageMaker bills it
#             per second, provisions the instance, and tears it down, which is a
#             better fit than keeping a GPU node group warm.
#   used      batch transform, for scoring a large file on a schedule.
#   not used  the model registry. MLflow owns the registry in this platform, and
#             the champion alias there is the single source of truth about what is
#             serving. A SageMaker model package group is available behind a flag
#             for organisations whose approval workflow is built on SageMaker's
#             ApprovalStatus, but running both as sources of truth is worse than
#             running either one: the day they disagree, nobody can say which is
#             right.
#
# Online inference runs on EKS, not on a SageMaker endpoint. The reason is
# observability: Prometheus scrapes a pod, and it cannot scrape a managed
# endpoint. Serving on EKS means the model layer metrics in monitoring/ come from
# the same scrape as the infrastructure layer, and a single Grafana query can put
# prediction distribution next to pod CPU. The serving image still implements the
# /ping and /invocations contract, so moving to a SageMaker endpoint later is a
# deployment change and not a rewrite.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

###############################################################################
# Training job execution role
###############################################################################

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }

    # Confused-deputy protection. Without the SourceAccount condition the
    # SageMaker service principal can be induced to assume this role on behalf of
    # a different account's job.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid    = "ReadTrainingData"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
    ]
    resources = [
      var.artifact_bucket_arn,
      "${var.artifact_bucket_arn}/${var.prefixes.datasets}*",
      "${var.artifact_bucket_arn}/${var.prefixes.models}*",
    ]
  }

  statement {
    sid    = "WriteModelArtifacts"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:AbortMultipartUpload",
    ]
    # Write access to exactly one prefix. A training role with PutObject on the
    # whole bucket can overwrite the champion model it was supposed to be
    # competing with.
    resources = ["${var.artifact_bucket_arn}/${var.prefixes.models}*"]
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
    sid    = "PullTrainingImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = var.ecr_repository_arns
  }

  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # This action does not support resource-level permissions.
  }

  statement {
    sid    = "WriteTrainingLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/sagemaker/*",
    ]
  }

  statement {
    sid       = "PublishTrainingMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData has no resource ARN.

    condition {
      # Scoped by namespace instead. Without this the role can write to any
      # namespace, including the ones your alarms read.
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["/aws/sagemaker/TrainingJobs", var.metric_namespace]
    }
  }

  dynamic "statement" {
    # Only present when the job runs inside the VPC, which is the configuration
    # this module recommends: a training job with no VPC configuration runs on the
    # SageMaker service network and reaches the internet.
    for_each = var.enable_vpc_access ? [1] : []
    content {
      sid    = "AttachToVpc"
      effect = "Allow"
      actions = [
        "ec2:CreateNetworkInterface",
        "ec2:CreateNetworkInterfacePermission",
        "ec2:DeleteNetworkInterface",
        "ec2:DeleteNetworkInterfacePermission",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeVpcs",
        "ec2:DescribeDhcpOptions",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
      ]
      resources = ["*"] # These describe and ENI actions are not resource scoped.
    }
  }
}

resource "aws_iam_role" "execution" {
  name        = "${var.name}-sagemaker-execution"
  description = "Assumed by SageMaker training and batch transform jobs for ${var.name}"
  path        = "/mlops/"

  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn
  max_session_duration = 3600

  tags = var.tags
}

resource "aws_iam_policy" "execution" {
  name        = "${var.name}-sagemaker-execution"
  description = "Least-privilege permissions for ${var.name} SageMaker jobs"
  path        = "/mlops/"
  policy      = data.aws_iam_policy_document.execution.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = aws_iam_policy.execution.arn
}

###############################################################################
# Job network isolation
###############################################################################

resource "aws_security_group" "jobs" {
  count = var.enable_vpc_access ? 1 : 0

  name_prefix = "${var.name}-sagemaker-"
  description = "SageMaker training jobs. Egress only; nothing connects inbound to a training job."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-sagemaker-jobs" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "jobs_https" {
  count = var.enable_vpc_access ? 1 : 0

  security_group_id = aws_security_group.jobs[0].id
  description       = "HTTPS to S3, ECR, CloudWatch and the SageMaker control plane"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "jobs_mlflow" {
  count = var.enable_vpc_access ? 1 : 0

  security_group_id = aws_security_group.jobs[0].id
  description       = "MLflow tracking server inside the VPC"
  cidr_ipv4         = var.vpc_cidr
  from_port         = var.mlflow_port
  to_port           = var.mlflow_port
  ip_protocol       = "tcp"

  tags = var.tags
}

###############################################################################
# Optional SageMaker model package group
###############################################################################

resource "aws_sagemaker_model_package_group" "this" {
  count = var.enable_model_package_group ? 1 : 0

  model_package_group_name = "${var.name}-${var.model_name}"
  model_package_group_description = join(" ", [
    "Mirror of the MLflow registry for ${var.model_name}.",
    "MLflow remains the source of truth: the champion alias there decides what serves.",
    "This group exists only for an approval workflow built on SageMaker ApprovalStatus.",
  ])

  tags = var.tags
}

###############################################################################
# CloudWatch log group for training jobs
#
# Created here with a retention period rather than letting SageMaker create it on
# first use. A log group SageMaker creates has retention set to never expire, and
# training logs at GPU volumes are one of the quieter ways a CloudWatch bill grows.
###############################################################################

resource "aws_cloudwatch_log_group" "training" {
  name              = "/aws/sagemaker/TrainingJobs"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.tags

  lifecycle {
    # SageMaker may already have created this group in an existing account. A
    # plan that wants to delete and recreate it would drop historical logs.
    prevent_destroy = true
  }
}
