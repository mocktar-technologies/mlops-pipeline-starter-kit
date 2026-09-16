output "plan_role_arn" {
  description = "Read-only role ARN. Set this as the AWS_PLAN_ROLE_ARN repository variable; pull request jobs assume it."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Deploy role ARN. Set this as the AWS_APPLY_ROLE_ARN repository variable. A pull request cannot assume it, by trust policy."
  value       = aws_iam_role.apply.arn
}

output "oidc_provider_arn" {
  description = "The OIDC provider in use, whether this module created it or it already existed."
  value       = local.provider_arn
}

output "plan_trusted_subjects" {
  description = "Exact OIDC subjects that may assume the plan role. Read this in a plan review: anything unexpected here is a wider trust than intended."
  value       = local.plan_subjects
}

output "apply_trusted_subjects" {
  description = "Exact OIDC subjects that may assume the apply role. A pull_request subject appearing here would mean anyone able to open a pull request can deploy."
  value       = local.apply_subjects
}

output "eks_access_entry" {
  description = "Ready-made access entry for the EKS module's access_entries variable, granting the apply role admin on the inference namespace only. Namespace-scoped rather than cluster-wide: the deploy role needs to roll out one Deployment, not to read every secret in the cluster."
  value = {
    principal_arn = aws_iam_role.apply.arn
    type          = "STANDARD"
    policy_associations = {
      inference = {
        policy_arn = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
        access_scope = {
          type       = "namespace"
          namespaces = ["inference"]
        }
      }
    }
  }
}
