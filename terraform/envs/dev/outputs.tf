###############################################################################
# Outputs
#
# Grouped by who consumes them. The github_repository_configuration output exists
# so that wiring the pipeline is a copy of one JSON object rather than a hunt
# through the console.
###############################################################################

output "cluster_name" {
  description = "EKS cluster name. Use it with: aws eks update-kubeconfig --name <this> --region <region>"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "artifact_bucket" {
  description = "Artifact bucket name."
  value       = module.artifacts.bucket_name
}

output "artifact_prefixes" {
  description = "Prefix layout. The pipeline configuration and the lifecycle rules both depend on these strings."
  value       = module.artifacts.prefixes
}

output "kms_key_arn" {
  description = "Platform KMS key. Any new role that reads an artifact needs kms:Decrypt on this, in addition to s3:GetObject."
  value       = module.artifacts.kms_key_arn
}

output "ecr_repository_urls" {
  description = "ECR repository URLs keyed by short name."
  value       = module.artifacts.ecr_repository_urls
}

output "mlflow_tracking_uri" {
  description = "In-cluster MLflow tracking URI. This is MLFLOW_TRACKING_URI for every pipeline pod. From a laptop, port-forward first: kubectl -n mlflow port-forward svc/mlflow 5000:5000"
  value       = module.mlflow.tracking_uri
}

output "mlflow_database_endpoint" {
  description = "MLflow backend store endpoint."
  value       = module.mlflow.database_endpoint
}

output "sagemaker_execution_role_arn" {
  description = "Role to pass as RoleArn when submitting a SageMaker training job."
  value       = module.sagemaker.execution_role_arn
}

output "irsa_role_arns" {
  description = "IRSA role ARNs by workload. Each one goes in the matching service account's eks.amazonaws.com/role-arn annotation; the Helm chart takes them as values."
  value = {
    inference = module.irsa_inference.role_arn
    drift     = module.irsa_drift.role_arn
    pipelines = module.irsa_pipelines.role_arn
    mlflow    = module.irsa_mlflow.role_arn
    ebs_csi   = module.irsa_ebs_csi.role_arn
  }
}

output "prometheus_service" {
  description = "In-cluster Prometheus address."
  value       = module.observability.prometheus_service
}

output "grafana_service" {
  description = "In-cluster Grafana address. Reach it with: kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
  value       = module.observability.grafana_service
}

output "github_repository_configuration" {
  description = <<-EOT
    Everything the GitHub Actions workflows need, as one object. Set the variables
    under `vars` as repository variables and nothing as a secret: there is no
    secret here, because the workflows authenticate with OIDC and hold no
    long-lived credential.
  EOT
  value = {
    vars = {
      AWS_REGION          = var.region
      AWS_PLAN_ROLE_ARN   = module.cicd_identity.plan_role_arn
      AWS_APPLY_ROLE_ARN  = module.cicd_identity.apply_role_arn
      ECR_INFERENCE_REPO  = module.artifacts.ecr_repository_urls["inference"]
      ECR_TRAINING_REPO   = module.artifacts.ecr_repository_urls["training"]
      EKS_CLUSTER_NAME    = module.eks.cluster_name
      ARTIFACT_BUCKET     = module.artifacts.bucket_name
      MLFLOW_TRACKING_URI = module.mlflow.tracking_uri
      MODEL_NAME          = var.model_name
      SAGEMAKER_ROLE_ARN  = module.sagemaker.execution_role_arn
      TF_STATE_BUCKET     = replace(var.state_bucket_arn, "arn:aws:s3:::", "")
    }
    notes = "Authentication is OIDC. Do not create an AWS access key for CI."
  }
}

output "ci_trust_review" {
  description = "The exact OIDC subjects that can assume each CI role. Read this after every apply: an unexpected entry here is the difference between 'main can deploy' and 'anyone who opens a pull request can deploy'."
  value = {
    plan  = module.cicd_identity.plan_trusted_subjects
    apply = module.cicd_identity.apply_trusted_subjects
  }
}
