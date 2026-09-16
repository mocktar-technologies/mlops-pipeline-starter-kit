variable "name" {
  description = "Name prefix. The bucket becomes <name>-artifacts-<account id>, which keeps it globally unique without a random suffix that changes on every recreate."
  type        = string
}

variable "region" {
  description = "AWS region, used in the KMS key policy condition for CloudWatch Logs."
  type        = string
}

variable "kms_deletion_window_days" {
  description = "Waiting period before a scheduled KMS key deletion completes. This bucket holds the only copy of every promoted model, so a long window is the safe default."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

variable "model_noncurrent_retention_days" {
  description = "How long overwritten model objects are kept. The question 'what exactly was serving during that incident' is asked months later, so this is deliberately long."
  type        = number
  default     = 365
}

variable "inference_capture_retention_days" {
  description = "How long captured inference payloads are kept. Drift is computed over a recent window, so older data is cost with no consumer. This is the prefix that grows without bound if the rule is removed."
  type        = number
  default     = 90
}

variable "ecr_repositories" {
  description = "ECR repositories to create, keyed by short name. keep_last_images bounds how many git-SHA-tagged images are retained; set it high enough that every image you might roll back to survives."
  type = map(object({
    keep_last_images = number
  }))
  default = {
    # Small image, and every promoted tag is a rollback target, so keep more.
    inference = { keep_last_images = 30 }
    # Multi-gigabyte CUDA image. Only recent builds are useful, and each one
    # retained is real storage cost.
    training = { keep_last_images = 10 }
  }

  validation {
    condition     = alltrue([for repository in var.ecr_repositories : repository.keep_last_images >= 3])
    error_message = "keep_last_images must be at least 3, or a rollback has nothing to roll back to."
  }
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
