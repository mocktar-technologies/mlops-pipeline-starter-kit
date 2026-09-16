output "tracking_uri" {
  description = "In-cluster tracking URI. This is the value of MLFLOW_TRACKING_URI for every pipeline pod."
  value       = local.tracking_uri
}

output "namespace" {
  description = "Namespace the tracking server runs in."
  value       = kubernetes_namespace_v1.mlflow.metadata[0].name
}

output "service_name" {
  description = "Kubernetes Service name."
  value       = kubernetes_service_v1.mlflow.metadata[0].name
}

output "database_endpoint" {
  description = "RDS endpoint, host only."
  value       = aws_db_instance.mlflow.address
}

output "database_identifier" {
  description = "RDS instance identifier, for the restore procedure in the runbook."
  value       = aws_db_instance.mlflow.identifier
}

output "database_secret_arn" {
  description = "Secrets Manager ARN holding the RDS-managed master credentials. The IRSA policy must allow secretsmanager:GetSecretValue on exactly this ARN."
  value       = aws_db_instance.mlflow.master_user_secret[0].secret_arn
}

output "database_security_group_id" {
  description = "Security group on the database, for adding a bastion or a migration task as a source."
  value       = aws_security_group.database.id
}
