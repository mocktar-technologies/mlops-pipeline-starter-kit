variable "name" {
  description = "Platform name prefix."
  type        = string
}

variable "region" {
  description = "AWS region, used to scope the log group ARNs in the execution policy."
  type        = string
}

variable "model_name" {
  description = "Model name, used for the optional model package group."
  type        = string
  default     = "demand-forecast"
}

variable "artifact_bucket_arn" {
  description = "ARN of the artifact bucket. Read is granted on the dataset and model prefixes; write only on the model prefix."
  type        = string
}

variable "prefixes" {
  description = "Bucket prefixes, taken from the artifacts module output so the two cannot drift apart."
  type = object({
    models    = string
    datasets  = string
    inference = string
    mlflow    = string
  })
}

variable "kms_key_arn" {
  description = "KMS key protecting the bucket and the training log group. A role with s3:GetObject and no kms:Decrypt produces an AccessDenied that names S3, not KMS."
  type        = string
}

variable "ecr_repository_arns" {
  description = "ECR repository ARNs the job may pull from. Scoping to specific repositories stops a compromised job definition from pulling an arbitrary image into your account's compute."
  type        = list(string)
}

variable "metric_namespace" {
  description = "Extra CloudWatch namespace the job may publish to, in addition to the SageMaker one. The namespace condition is what stops the role writing into the namespaces your alarms read."
  type        = string
  default     = "MLOps/Training"
}

variable "enable_vpc_access" {
  description = "Run training jobs inside the VPC. True is strongly recommended: a job with no VPC configuration runs on the SageMaker service network, reaches the internet, and cannot reach the in-cluster MLflow server."
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "VPC for the training job security group. Required when enable_vpc_access is true."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "VPC CIDR, used for the egress rule to the in-cluster MLflow server."
  type        = string
  default     = null
}

variable "mlflow_port" {
  description = "Port the MLflow tracking server listens on."
  type        = number
  default     = 5000
}

variable "enable_model_package_group" {
  description = <<-EOT
    Create a SageMaker model package group mirroring the MLflow registry. Off by
    default on purpose. MLflow's champion alias is the source of truth in this
    platform; running two registries means that on the day they disagree nobody
    can say which one is right. Turn this on only if your approval process is
    already built on SageMaker ApprovalStatus, and then write down which one wins.
  EOT
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retention for the SageMaker training log group. A group SageMaker creates itself never expires, which is a quiet way for a CloudWatch bill to grow."
  type        = number
  default     = 30
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary for the execution role."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
