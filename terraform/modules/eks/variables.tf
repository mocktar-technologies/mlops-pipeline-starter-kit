variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes minor version, as "1.NN". Check the EKS release calendar before
    changing it: standard support for a version ends roughly 14 months after its
    EKS release, and a cluster past that date moves to extended support, which is
    billed at a higher hourly rate.
  EOT
  type        = string
  default     = "1.35"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must look like 1.35, with no patch component."
  }
}

variable "vpc_id" {
  description = "VPC the cluster is created in."
  type        = string
}

variable "control_plane_subnet_ids" {
  description = "Subnets for the control plane ENIs. Use the intra subnets: the control plane needs no route to the internet."
  type        = list(string)
}

variable "node_subnet_ids" {
  description = "Subnets for the managed node groups. Use the private subnets."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API endpoint to the internet. False is the default because CI assumes a role and connects from inside the VPC; set it true only with endpoint_public_access_cidrs narrowed to known addresses."
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach a public API endpoint. Leaving this at 0.0.0.0/0 while endpoint_public_access is true puts your API server in front of the whole internet; it is authenticated, and it is still not what you want."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is refused here on purpose. Narrow it to the addresses your operators and CI actually come from, or leave endpoint_public_access false."
  }
}

variable "kms_key_arn" {
  description = "KMS key used for Kubernetes secret envelope encryption and for the node root volumes."
  type        = string
}

variable "ebs_csi_irsa_role_arn" {
  description = "IRSA role ARN for the EBS CSI driver. The driver cannot create volumes without it, and PVCs sit Pending with no obvious cause."
  type        = string
}

variable "access_entries" {
  description = <<-EOT
    Additional EKS access entries, keyed by an arbitrary name. Each entry needs a
    principal_arn and, normally, one policy association. Use this to grant the CI
    deploy role and your operators access; the identity that ran terraform is
    already an admin.
  EOT
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string))
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = object({
        type       = string
        namespaces = optional(list(string))
      })
    })), {})
  }))
  default = {}
}

variable "system_instance_types" {
  description = "Instance types for the untainted system node group. Several types rather than one, so a capacity shortfall in a single type does not block a scale-up."
  type        = list(string)
  default     = ["m7i.large", "m6i.large", "m5.large"]
}

variable "inference_instance_types" {
  description = "Instance types for the inference node group. ONNX Runtime on CPU is memory-bandwidth bound more than core bound, so a current-generation general purpose type beats an older compute-optimised one."
  type        = list(string)
  default     = ["m7i.large", "m6i.large"]
}

variable "inference_min_size" {
  description = "Minimum inference nodes. Two, not one, so a node drain during an upgrade does not take the service to zero replicas."
  type        = number
  default     = 2

  validation {
    condition     = var.inference_min_size >= 2
    error_message = "inference_min_size must be at least 2, or a single node drain takes the service down."
  }
}

variable "inference_max_size" {
  description = "Maximum inference nodes."
  type        = number
  default     = 6
}

variable "gpu_instance_types" {
  description = <<-EOT
    Instance types for the spot GPU training group. Listing several families
    materially improves the odds of getting spot capacity, because the spot pools
    are per type per zone. g6 and g5 are the cheapest current NVIDIA families for
    single-GPU training; add a p-family type only if a model genuinely needs it.
  EOT
  type        = list(string)
  default     = ["g6.xlarge", "g5.xlarge", "g6.2xlarge", "g5.2xlarge"]
}

variable "gpu_max_size" {
  description = "Maximum GPU nodes. The group's minimum is fixed at 0, so an idle cluster carries no GPU cost."
  type        = number
  default     = 2
}

variable "gpu_root_volume_size" {
  description = "Root volume size in GB for GPU nodes. A CUDA base image plus a few checkpoints fills a 100 GB disk and triggers kubelet image garbage collection in the middle of a training run."
  type        = number
  default     = 200

  validation {
    condition     = var.gpu_root_volume_size >= 100
    error_message = "gpu_root_volume_size below 100 GB will not hold a CUDA image plus checkpoints."
  }
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
