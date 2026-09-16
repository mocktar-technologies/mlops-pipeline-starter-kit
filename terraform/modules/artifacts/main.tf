###############################################################################
# Artifact storage: KMS, S3, ECR
#
# Three kinds of thing are stored, and they have different lifetimes, which is why
# they get different prefixes and different lifecycle rules rather than one bucket
# policy applied to everything:
#
#   models/       every registered model artifact. Kept, because a model you
#                 cannot retrieve is a model you cannot roll back to. Versioning
#                 is on and noncurrent versions are kept for a year.
#   datasets/     training snapshots and the drift reference sample. Transitioned
#                 to infrequent access after 30 days: read during a retrain and a
#                 postmortem, not daily.
#   inference/    captured request payloads, which is what the drift monitor
#                 compares against. High volume, short useful life, expired after
#                 90 days. This prefix is the one that grows without bound if you
#                 forget the rule.
#
# The bucket is encrypted with a customer managed key rather than SSE-S3. The
# reason is not encryption strength, it is that a customer managed key gives you a
# second, independent authorization check on every object read, one you can audit
# in CloudTrail and revoke without touching a bucket policy.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  bucket     = "${var.name}-artifacts-${local.account_id}"
}

###############################################################################
# KMS
###############################################################################

resource "aws_kms_key" "artifacts" {
  description = "Encrypts ${var.name} model artifacts, datasets and captured inference payloads"

  # Rotation is annual and automatic. The cost is one extra key version per year
  # and no operational work; the alternative is a manual rotation nobody does.
  enable_key_rotation = true

  # Seven days is the minimum. A longer window is safer against an accidental
  # deletion and means a longer wait when you genuinely want the key gone. Thirty
  # is the right default for a bucket holding the only copy of your models.
  deletion_window_in_days = var.kms_deletion_window_days

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Without this statement the key becomes unmanageable: IAM alone cannot
        # grant access to a key whose own policy does not delegate to IAM.
        Sid       = "EnableIAMPolicies"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.region}.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:*"
          }
        }
      },
    ]
  })

  tags = var.tags
}

resource "aws_kms_alias" "artifacts" {
  name          = "alias/${var.name}-artifacts"
  target_key_id = aws_kms_key.artifacts.key_id
}

###############################################################################
# S3
###############################################################################

resource "aws_s3_bucket" "artifacts" {
  bucket = local.bucket

  # force_destroy stays false. An ML artifact bucket holds the only copy of every
  # model you have ever promoted; a terraform destroy that empties it is not
  # recoverable. Emptying it is a deliberate, separate act.
  force_destroy = false

  tags = merge(var.tags, { Name = local.bucket })
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    # Versioning is what makes an overwritten model recoverable. It is also what
    # makes the noncurrent-version lifecycle rules below meaningful; without it
    # they are inert.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.artifacts.arn
    }
    # S3 bucket keys cut KMS request charges by a large factor on a bucket with
    # many small objects, which is exactly the captured-inference prefix. Without
    # it each object read is a separate KMS API call you pay for.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    # ACLs disabled. Every access decision is then made by a policy you can read
    # in one place, instead of being spread across per-object ACLs.
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  # An empty filter block, not a prefix. prefix on the rule is deprecated by S3
  # and the provider will remove it in the next major version; filter is the
  # supported form. An empty filter matches every object in the bucket.
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    # A failed multipart upload of a multi-gigabyte model checkpoint leaves parts
    # that are billed as storage and are invisible in the console object list.
    # This is the most commonly missed line in an S3 lifecycle policy.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "models-retain-noncurrent"
    status = "Enabled"

    filter {
      prefix = "models/"
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    # A year of overwritten model versions. Long, on purpose: the question "what
    # exactly was serving on the day of that incident" is asked months later.
    noncurrent_version_expiration {
      noncurrent_days = var.model_noncurrent_retention_days
    }
  }

  rule {
    id     = "datasets-cool-down"
    status = "Enabled"

    filter {
      prefix = "datasets/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 120
      storage_class = "GLACIER_IR"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  rule {
    id     = "captured-inference-expiry"
    status = "Enabled"

    filter {
      prefix = "inference/"
    }

    # The prefix that grows without bound. Drift is computed over a recent
    # window, so anything older than this is cost with no consumer.
    expiration {
      days = var.inference_capture_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# Deny anything that is not TLS, and anything that is not using the bucket's own
# KMS key. The second half matters more than it looks: without it a caller with
# PutObject can write an object encrypted with a key you do not control, and you
# then hold an object you cannot read.
data "aws_iam_policy_document" "artifacts" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyWrongEncryptionKey"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.artifacts.arn]
    }
  }

  statement {
    sid    = "DenyUnencryptedPut"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts.json

  # The public access block has to be in place before a policy is attached, or
  # the policy apply can race with the block and fail.
  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}

###############################################################################
# ECR
#
# Two repositories, because the two images have different lifetimes and very
# different sizes. The serving image is small and every promoted tag is a
# rollback target. The training image is large, includes CUDA, and only the
# recent ones are useful.
###############################################################################

resource "aws_ecr_repository" "this" {
  for_each = var.ecr_repositories

  name = "${var.name}/${each.key}"

  # IMMUTABLE is the setting that makes a deployment reproducible. With MUTABLE,
  # someone can push a different image to the tag a running Deployment
  # references, and the next pod to start runs code nobody deployed. It also
  # makes a rollback to "the previous tag" meaningless.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.artifacts.arn
  }

  force_delete = false

  tags = merge(var.tags, { Name = "${var.name}/${each.key}" })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = var.ecr_repositories

  repository = aws_ecr_repository.this[each.key].name

  # Rule order matters: ECR evaluates by ascending rulePriority and an image is
  # only ever matched by the first rule that applies. Untagged images are expired
  # first and aggressively, because an untagged image is an orphaned layer set no
  # deployment can reference.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last ${each.value.keep_last_images} images built from a git SHA"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = each.value.keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
