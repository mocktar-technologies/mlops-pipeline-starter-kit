###############################################################################
# Inputs
#
# Every variable either has a safe default or is required. Nothing silently
# defaults to something insecure: the public endpoint is off, deletion protection
# is on, and the CIDR list that would open the API server refuses 0.0.0.0/0 in the
# module's own validation.
###############################################################################

variable "project" {
  description = "Short project name. Combined with environment to prefix every resource."
  type        = string
  default     = "mlops-starter"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric with hyphens, starting with a letter, at most 21 characters."
  }
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "additional_tags" {
  description = "Extra tags merged into every resource. A cost centre or an owner belongs here."
  type        = map(string)
  default     = {}
}

###############################################################################
# Network
###############################################################################

variable "vpc_cidr" {
  description = "VPC CIDR. A /16, because the VPC CNI gives every pod a VPC address."
  type        = string
  default     = "10.42.0.0/16"
}

variable "availability_zone_count" {
  description = "Availability zones to spread across."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "One NAT gateway instead of one per zone. True saves money in development; false is correct for production, where a single NAT gateway is both a single point of failure and a cross-zone data charge."
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = "VPC interface endpoints for ECR, STS, KMS, Logs, SageMaker and Secrets Manager. They pay for themselves on container image pull traffic once training runs regularly."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "VPC flow logs. Off by default: real cost at ML traffic volumes, and not needed to operate the platform."
  type        = bool
  default     = false
}

###############################################################################
# Cluster
###############################################################################

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version. Check the EKS release calendar before pinning: a version past its standard support date is billed at the extended support rate."
  type        = string
  default     = "1.35"
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API to the internet. False by default; CI reaches the cluster with an assumed role from inside the VPC."
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach a public API endpoint. The EKS module refuses 0.0.0.0/0 here."
  type        = list(string)
  default     = []
}

variable "inference_min_size" {
  description = "Minimum inference nodes. At least 2, so a node drain does not take the service to zero."
  type        = number
  default     = 2
}

variable "inference_max_size" {
  description = "Maximum inference nodes."
  type        = number
  default     = 6
}

variable "gpu_instance_types" {
  description = "Spot GPU instance types for training. Several families materially improves the odds of getting capacity, because spot pools are per type per zone."
  type        = list(string)
  default     = ["g6.xlarge", "g5.xlarge", "g6.2xlarge", "g5.2xlarge"]
}

variable "gpu_max_size" {
  description = "Maximum GPU nodes. Set 0 to create the group at zero and never scale it, which is the right setting if you train on SageMaker rather than in-cluster. The NVIDIA device plugin is skipped when this is 0."
  type        = number
  default     = 2
}

variable "additional_access_entries" {
  description = "Extra EKS access entries beyond the CI role, for your operators. Prefer namespace-scoped policy associations over cluster admin."
  type        = any
  default     = {}
}

###############################################################################
# MLflow
###############################################################################

variable "mlflow_image" {
  description = "Image reference for the MLflow server, built from docker/mlflow.Dockerfile. Push it to the mlflow ECR repository this stack creates, then set this to the digest-pinned reference. There is no default: an unpinned public image is not something this module will choose for you."
  type        = string
}

variable "mlflow_replicas" {
  description = "MLflow server replicas. The server is stateless, so two costs little and buys a rollout that does not drop requests."
  type        = number
  default     = 2
}

variable "db_multi_az" {
  description = "Multi-AZ for the MLflow backend store. Roughly doubles the instance cost and turns an hour-long restore into a minute-long failover."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Block deletion of the MLflow database. Leave this true: the database holds the record of which model version is serving production."
  type        = bool
  default     = true
}

###############################################################################
# Model and artifacts
###############################################################################

variable "model_name" {
  description = "Registered model name, shared by the pipeline config and the SageMaker model package group."
  type        = string
  default     = "demand-forecast"
}

variable "inference_capture_retention_days" {
  description = "How long captured inference payloads are kept. This is the prefix that grows without bound if the lifecycle rule is removed."
  type        = number
  default     = 90
}

variable "enable_sagemaker_model_registry" {
  description = "Create a SageMaker model package group mirroring MLflow. Off by default: two registries means that on the day they disagree, nobody can say which is right."
  type        = bool
  default     = false
}

###############################################################################
# Observability
###############################################################################

variable "enable_grafana" {
  description = "Install Grafana alongside Prometheus. Turn it off if your organisation runs a central Grafana that reads this Prometheus as a data source."
  type        = bool
  default     = true
}

variable "enable_retrain_webhook" {
  description = "Route a sustained critical drift alert to a webhook that opens a retraining run. Requires the retrain-webhook secret to exist in the monitoring namespace."
  type        = bool
  default     = false
}

variable "prometheus_retention" {
  description = "Local Prometheus retention window."
  type        = string
  default     = "15d"
}

variable "prometheus_retention_size" {
  description = "Size-based retention. Keep it below prometheus_storage_size: Prometheus needs headroom for compaction and a full volume is an unrecoverable Prometheus."
  type        = string
  default     = "40GB"
}

variable "prometheus_storage_size" {
  description = "Prometheus volume size."
  type        = string
  default     = "50Gi"
}

###############################################################################
# CI/CD and state
###############################################################################

variable "github_owner" {
  description = "GitHub organisation or user that owns this repository."
  type        = string
}

variable "github_repository" {
  description = "Repository name, without the owner."
  type        = string
}

variable "trusted_branches" {
  description = "Branches whose workflow runs may assume the CI roles. Keep this to your default branch."
  type        = list(string)
  default     = ["main"]
}

variable "trusted_environments" {
  description = "GitHub environments whose jobs may assume the CI roles. An environment with required reviewers is the strongest deploy control available here."
  type        = list(string)
  default     = ["production"]
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false in an account that already federates GitHub, since only one provider per issuer URL can exist."
  type        = bool
  default     = true
}

variable "state_bucket_arn" {
  description = "ARN of the terraform state bucket, created by scripts/bootstrap-state.sh."
  type        = string
}

variable "state_lock_table_arn" {
  description = "ARN of the DynamoDB state lock table, created by scripts/bootstrap-state.sh."
  type        = string
}

variable "ci_apply_additional_policy_arns" {
  description = "Extra managed policies for the CI apply role. Infrastructure changes need more than the scoped policy the module writes; name them here so the grant appears in a code review rather than attaching AdministratorAccess."
  type        = list(string)
  default     = []
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary applied to every role this stack creates. The one control that survives someone attaching an over-broad policy later."
  type        = string
  default     = null
}
