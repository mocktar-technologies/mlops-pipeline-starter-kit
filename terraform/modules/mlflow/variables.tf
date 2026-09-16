variable "name" {
  description = "Platform name prefix, used for AWS resource names."
  type        = string
}

variable "region" {
  description = "AWS region, passed into the pod so boto3 does not have to guess."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for the tracking server."
  type        = string
  default     = "mlflow"
}

variable "service_account_name" {
  description = "Service account the server runs as. It must match the subject in the IRSA role's trust policy exactly."
  type        = string
  default     = "mlflow"
}

variable "irsa_role_arn" {
  description = "IRSA role ARN for the server. Needs S3 access to the artifact prefix, kms:Decrypt and kms:GenerateDataKey on the platform key, and secretsmanager:GetSecretValue on the RDS managed password secret."
  type        = string
}

variable "image" {
  description = <<-EOT
    Fully qualified image reference for the MLflow server, built from
    docker/mlflow.Dockerfile and pushed to ECR. Pin it by digest in production.
    The image must contain the mlflow CLI, the AWS CLI, psycopg2 and python, which
    is what the init container's credential resolution uses.
  EOT
  type        = string
}

variable "replicas" {
  description = "Server replicas. Two or more gives you a pod disruption budget and a rollout that does not drop requests; the server is stateless, so there is no coordination cost."
  type        = number
  default     = 2
}

variable "service_port" {
  description = "Port the server listens on and the Service exposes."
  type        = number
  default     = 5000
}

variable "gunicorn_workers" {
  description = "Gunicorn worker processes per replica. The server is IO bound on the database and on S3, so a handful of workers per replica is the right shape."
  type        = number
  default     = 4
}

variable "resources" {
  description = "Container resources. No CPU limit is set: CPU throttling on a gunicorn server presents as a slow database and sends you looking in the wrong place."
  type = object({
    cpu_request    = string
    memory_request = string
    memory_limit   = string
  })
  default = {
    cpu_request    = "250m"
    memory_request = "512Mi"
    memory_limit   = "2Gi"
  }
}

variable "allowed_client_namespaces" {
  description = "Namespaces allowed to reach the tracking server. The pipeline namespace and the namespace running the drift exporter, normally. An empty list makes the server unreachable, which is a valid way to quarantine it."
  type        = list(string)
  default     = ["mlops-pipelines", "inference"]
}

variable "vpc_id" {
  description = "VPC for the database security group."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the database subnet group."
  type        = list(string)
}

variable "node_security_group_id" {
  description = "EKS node security group, used as the source of the database ingress rule. The pod's traffic leaves through a node, so this is the correct source rather than a pod CIDR."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for database storage, the managed master password secret, and the artifacts the server writes."
  type        = string
}

variable "artifact_bucket" {
  description = "S3 bucket holding MLflow artifacts."
  type        = string
}

variable "artifact_prefix" {
  description = "Prefix inside the bucket for MLflow artifacts. Keeping MLflow under its own prefix is what lets the bucket lifecycle rules treat it differently from captured inference data."
  type        = string
  default     = "mlflow/"
}

variable "db_engine_version" {
  description = "PostgreSQL major version. Check the RDS supported-version list before changing it, and expect a maintenance window for a major upgrade."
  type        = string
  default     = "17"
}

variable "db_parameter_group_family" {
  description = "Parameter group family. Must match db_engine_version: postgres17 for engine 17."
  type        = string
  default     = "postgres17"
}

variable "db_instance_class" {
  description = "RDS instance class. The MLflow schema is small and the query pattern is light until the run table grows into the millions; a burstable class is genuinely adequate here and t4g is the cheapest way to get it."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage" {
  description = "Initial storage in GB."
  type        = number
  default     = 50
}

variable "db_max_allocated_storage" {
  description = "Ceiling for storage autoscaling. Autoscaling is what stops a runaway metric logging loop from filling the volume and taking the registry read-only."
  type        = number
  default     = 200
}

variable "db_multi_az" {
  description = "Run a standby in a second availability zone. Roughly doubles the instance cost and is the difference between a failover of about a minute and a restore of about an hour. False for development, true for anything whose registry you would miss."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Automated backup retention. Zero disables backups, which for the database holding your model registry is not a saving worth making, so the validation refuses it."
  type        = number
  default     = 14

  validation {
    condition     = var.db_backup_retention_days >= 7
    error_message = "db_backup_retention_days must be at least 7. This database holds the record of which model version is serving production."
  }
}

variable "db_deletion_protection" {
  description = "Block deletion of the database, including by terraform destroy. True everywhere you care; the runbook documents how to turn it off deliberately."
  type        = bool
  default     = true
}

variable "db_performance_insights" {
  description = "Enable Performance Insights with the free 7 day retention. Worth having the first time MLflow's run search becomes slow."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to the AWS resources in this module."
  type        = map(string)
  default     = {}
}
