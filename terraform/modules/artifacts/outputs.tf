output "bucket_name" {
  description = "Artifact bucket name."
  value       = aws_s3_bucket.artifacts.id
}

output "bucket_arn" {
  description = "Artifact bucket ARN. Referenced by every IAM policy that grants access to a prefix inside it."
  value       = aws_s3_bucket.artifacts.arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name of the bucket."
  value       = aws_s3_bucket.artifacts.bucket_regional_domain_name
}

output "kms_key_arn" {
  description = "KMS key protecting the bucket and the ECR repositories. Any role that reads an object must also be granted kms:Decrypt on this key; being granted s3:GetObject alone produces an AccessDenied that names S3 and not KMS, which is a confusing hour to spend."
  value       = aws_kms_key.artifacts.arn
}

output "kms_key_id" {
  description = "KMS key id."
  value       = aws_kms_key.artifacts.key_id
}

output "kms_alias" {
  description = "KMS alias name."
  value       = aws_kms_alias.artifacts.name
}

output "ecr_repository_urls" {
  description = "Repository URLs keyed by short name. These are the values the CI workflow pushes to."
  value       = { for key, repository in aws_ecr_repository.this : key => repository.repository_url }
}

output "ecr_repository_arns" {
  description = "Repository ARNs keyed by short name, for scoping the CI push policy to exactly these repositories."
  value       = { for key, repository in aws_ecr_repository.this : key => repository.arn }
}

output "prefixes" {
  description = "The prefix layout other modules and the pipeline configuration must agree on. Kept as an output rather than repeated as string literals, so a change here cannot leave a lifecycle rule pointing at a prefix nothing writes to."
  value = {
    models    = "models/"
    datasets  = "datasets/"
    inference = "inference/"
    mlflow    = "mlflow/"
  }
}
