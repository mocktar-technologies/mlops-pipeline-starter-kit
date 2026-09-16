output "vpc_id" {
  description = "VPC id."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "VPC CIDR block. Consumed by security group rules in other modules."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Private subnets. Nodes, pods, MLflow and RDS go here."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnets. NAT gateways and internet-facing load balancers only."
  value       = module.vpc.public_subnets
}

output "intra_subnet_ids" {
  description = "Subnets with no route to the internet. EKS control plane ENIs and the VPC interface endpoints."
  value       = module.vpc.intra_subnets
}

output "availability_zones" {
  description = "Availability zones actually used, after filtering out local and wavelength zones."
  value       = local.azs
}

output "nat_public_ips" {
  description = "Public addresses of the NAT gateways. These are the source addresses to allow-list on a third-party API the training job calls."
  value       = module.vpc.nat_public_ips
}

output "s3_vpc_endpoint_id" {
  description = "Gateway endpoint for S3. Referenced by the artifacts bucket policy so the bucket can be restricted to traffic arriving through it."
  value       = aws_vpc_endpoint.s3.id
}

output "interface_endpoint_security_group_id" {
  description = "Security group attached to the interface endpoints, or null when they are disabled."
  value       = var.enable_interface_endpoints ? aws_security_group.endpoints[0].id : null
}
