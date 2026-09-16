variable "role_name" {
  description = "IAM role name. Include the cluster or environment so two clusters in one account do not collide."
  type        = string
}

variable "description" {
  description = "What this identity is for. It shows up in the console and in CloudTrail, and future you will read it during an investigation."
  type        = string
}

variable "path" {
  description = "IAM path for the role and its policy. A path makes it possible to write a permissions boundary or an SCP that applies to every platform role at once."
  type        = string
  default     = "/mlops/"
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider, from the EKS module's oidc_provider_arn output."
  type        = string
}

variable "service_accounts" {
  description = <<-EOT
    The exact service accounts allowed to assume this role. Each entry becomes one
    literal sub condition value, matched with StringEquals. There is deliberately
    no way to express a wildcard here: a wildcard sub lets every service account
    in the cluster assume the role.
  EOT
  type = list(object({
    namespace = string
    name      = string
  }))

  validation {
    condition     = length(var.service_accounts) > 0
    error_message = "at least one service account is required, or the role can never be assumed."
  }

  validation {
    condition = alltrue([
      for account in var.service_accounts :
      !strcontains(account.namespace, "*") && !strcontains(account.name, "*")
    ])
    error_message = "wildcards are not allowed in a service account namespace or name; list every subject explicitly."
  }
}

variable "policy_json" {
  description = "Inline permissions for this role as a JSON policy document. Null attaches no policy of its own, which is what you want for a role that only needs the managed policies in additional_policy_arns."
  type        = string
  default     = null
}

variable "additional_policy_arns" {
  description = "Existing managed policy ARNs to attach as well."
  type        = list(string)
  default     = []
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary. Caps what this role can ever be granted, no matter what a later policy attachment says."
  type        = string
  default     = null
}

variable "max_session_duration" {
  description = "Maximum session length in seconds. One hour is right for almost everything, because the AWS SDKs refresh automatically."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 900 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 900 and 43200 seconds."
  }
}

variable "tags" {
  description = "Tags applied to the role and policy."
  type        = map(string)
  default     = {}
}
