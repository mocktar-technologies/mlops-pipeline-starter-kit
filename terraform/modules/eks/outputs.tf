output "cluster_name" {
  description = "Cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded cluster CA certificate. Decode it before passing it to a provider."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL, including the https:// scheme."
  value       = module.eks.cluster_oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN. Every IRSA role trusts this."
  value       = module.eks.oidc_provider_arn
}

output "cluster_security_group_id" {
  description = "Security group the control plane uses. Reference it when allowing a node or a database to accept traffic from the cluster."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group shared by the managed node groups. This is the source to allow on the RDS security group, because the MLflow pod's traffic leaves through a node."
  value       = module.eks.node_security_group_id
}

output "gpu_node_taint" {
  description = "The taint applied to GPU nodes, so a workload chart can render a matching toleration instead of hardcoding a string that can drift from this module."
  value       = local.gpu_taint.dedicated
}
