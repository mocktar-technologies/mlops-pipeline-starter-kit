output "execution_role_arn" {
  description = "Role ARN to pass as RoleArn when creating a training job or batch transform job. Whatever submits the job needs iam:PassRole on exactly this ARN."
  value       = aws_iam_role.execution.arn
}

output "execution_role_name" {
  description = "Execution role name."
  value       = aws_iam_role.execution.name
}

output "job_security_group_id" {
  description = "Security group for VPC-attached training jobs, or null when VPC access is disabled."
  value       = var.enable_vpc_access ? aws_security_group.jobs[0].id : null
}

output "model_package_group_name" {
  description = "SageMaker model package group name, or null when the mirror is disabled."
  value       = var.enable_model_package_group ? aws_sagemaker_model_package_group.this[0].model_package_group_name : null
}

output "training_log_group_name" {
  description = "CloudWatch log group training jobs write to."
  value       = aws_cloudwatch_log_group.training.name
}
