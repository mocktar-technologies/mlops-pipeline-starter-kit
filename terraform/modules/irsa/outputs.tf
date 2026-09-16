output "role_arn" {
  description = "Role ARN. This is the value that goes in the service account's eks.amazonaws.com/role-arn annotation."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Role name."
  value       = aws_iam_role.this.name
}

output "service_account_annotation" {
  description = "The annotation map to merge into the Kubernetes service account, so the key is written once here rather than retyped in every chart."
  value       = { "eks.amazonaws.com/role-arn" = aws_iam_role.this.arn }
}

output "trusted_subjects" {
  description = "The exact OIDC subjects allowed to assume this role. Useful in a plan review: if this list contains something you did not expect, the role is wider than intended."
  value       = local.subjects
}
