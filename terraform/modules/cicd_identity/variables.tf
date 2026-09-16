variable "name" {
  description = "Platform name prefix for the role names."
  type        = string
}

variable "region" {
  description = "AWS region, used to scope log group ARNs."
  type        = string
}

variable "github_owner" {
  description = "GitHub organisation or user that owns the repository."
  type        = string
}

variable "github_repository" {
  description = "Repository name, without the owner."
  type        = string
}

variable "trusted_branches" {
  description = <<-EOT
    Branches whose workflow runs may assume these roles. Keep this to your default
    branch. Adding a pattern here is not possible on purpose: every entry becomes
    a literal OIDC subject matched with StringEquals, because a wildcard subject
    means anyone who can push a branch can assume the role.
  EOT
  type        = list(string)
  default     = ["main"]

  validation {
    condition     = alltrue([for branch in var.trusted_branches : !strcontains(branch, "*")])
    error_message = "wildcards are not allowed in trusted_branches; list each branch explicitly."
  }
}

variable "trusted_environments" {
  description = "GitHub environments whose jobs may assume these roles. A GitHub environment with required reviewers is what turns 'the workflow can deploy' into 'a named human approved this deploy', and it is the strongest control available here."
  type        = list(string)
  default     = ["production"]

  validation {
    condition     = alltrue([for environment in var.trusted_environments : !strcontains(environment, "*")])
    error_message = "wildcards are not allowed in trusted_environments."
  }
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. An AWS account can hold only one provider per issuer URL, so set this false and pass existing_oidc_provider_arn in an account that already federates GitHub."
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider, used when create_oidc_provider is false."
  type        = string
  default     = null

  validation {
    condition     = var.existing_oidc_provider_arn == null || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/", var.existing_oidc_provider_arn))
    error_message = "existing_oidc_provider_arn must be an IAM OIDC provider ARN."
  }
}

variable "state_bucket_arn" {
  description = "ARN of the S3 bucket holding terraform state."
  type        = string
}

variable "state_lock_table_arn" {
  description = "ARN of the DynamoDB table used for state locking."
  type        = string
}

variable "state_kms_key_arn" {
  description = "KMS key protecting the state bucket, if it differs from the artifact key."
  type        = string
  default     = null
}

variable "artifact_bucket_arn" {
  description = "ARN of the artifact bucket."
  type        = string
}

variable "prefixes" {
  description = "Bucket prefixes from the artifacts module, so write access can be scoped to datasets and models and nothing else."
  type = object({
    models    = string
    datasets  = string
    inference = string
    mlflow    = string
  })
}

variable "kms_key_arn" {
  description = "KMS key protecting the artifact bucket."
  type        = string
}

variable "ecr_repository_arns" {
  description = "ECR repositories the apply role may push to. Named repositories only: a CI role with ecr:PutImage on the whole account can overwrite another team's production image."
  type        = list(string)
}

variable "sagemaker_execution_role_arn" {
  description = "The only role the apply role may pass, and only to SageMaker."
  type        = string
}

variable "apply_additional_policy_arns" {
  description = <<-EOT
    Extra managed policies for the apply role. Infrastructure changes need more
    than the scoped policy this module writes, and the honest way to grant that is
    to name the policies here so they appear in a code review, rather than
    attaching AdministratorAccess and moving on. If your organisation has no such
    policy yet, run terraform apply for infrastructure changes from a human
    session and leave this empty.
  EOT
  type        = list(string)
  default     = []
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary for both roles. This is the control that survives someone attaching an over-broad policy later."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
