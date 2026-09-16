variable "name" {
  description = "Name prefix for the VPC and every resource in this module. Also used as the Karpenter and load balancer subnet discovery tag."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be lowercase alphanumeric with hyphens, 3 to 32 characters, and cannot start or end with a hyphen."
  }
}

variable "region" {
  description = "AWS region. Used to build VPC endpoint service names, which are region qualified."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. A /16 is strongly recommended: the VPC CNI assigns a VPC address to every pod, so address exhaustion arrives much sooner on an ML platform than on a traditional one."
  type        = string
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) <= 18
    error_message = "vpc_cidr must be a valid CIDR of /18 or larger to leave room for the derived subnets."
  }
}

variable "availability_zone_count" {
  description = "Number of availability zones to spread across. Two is the minimum EKS accepts; three is the usual production choice."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 4
    error_message = "availability_zone_count must be between 2 and 4."
  }
}

variable "single_nat_gateway" {
  description = "Route all private egress through one NAT gateway. Cheaper, and a single point of failure plus a cross-zone data charge for traffic from the other zones. Use true in development, false in production."
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = "Create VPC interface endpoints for ECR, STS, KMS, Logs, SageMaker and Secrets Manager. Each endpoint is billed per hour per availability zone, so in a small development account a single NAT gateway can be cheaper. In production these pay for themselves on image pull traffic alone."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Capture VPC flow logs to CloudWatch. Off by default because flow logs at ML traffic volumes are a real cost and are not needed to operate the platform."
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for flow logs. Flow logs answer questions about the last few days, so a long retention buys little."
  type        = number
  default     = 14
}

variable "log_kms_key_arn" {
  description = "KMS key ARN for encrypting the flow log group. Null uses the CloudWatch service key."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
