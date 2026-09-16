###############################################################################
# Network
#
# Three subnet tiers, and the third one is the part people leave out:
#
#   public    NAT gateways and nothing else. No workload ever lands here.
#   private   nodes, pods, the MLflow server, the RDS instance. Egress through NAT.
#   intra     no route to the internet at all. The EKS control plane ENIs and the
#             VPC interface endpoints live here. A subnet with no default route is
#             the cheapest way to prove that a component cannot reach the internet,
#             which is a much stronger statement than a security group rule that
#             somebody can widen later.
#
# Cost: NAT gateways are the single largest avoidable line item in an ML platform,
# because training pulls container images and datasets measured in gigabytes and
# every byte through a NAT gateway is billed twice, once for the hour and once for
# the data. The S3 gateway endpoint below removes S3 traffic from that path
# entirely and costs nothing per hour. The interface endpoints for ECR do the same
# for image pulls; those do carry an hourly charge per availability zone, so the
# module lets you turn them off in a development environment where a single NAT
# gateway is cheaper than three zones of endpoints.
###############################################################################

locals {
  # Deriving subnet CIDRs rather than asking for eighteen numbers keeps the
  # calling environment small and makes the layout consistent across accounts.
  # With a /16 and three zones: /20 per private subnet (4091 usable addresses,
  # which matters because the VPC CNI assigns a VPC address to every pod), /24
  # per public subnet, /24 per intra subnet.
  private_subnets = [for index in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 4, index)]
  public_subnets  = [for index in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 8, index + 48)]
  intra_subnets   = [for index in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 8, index + 52)]

  azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  # Interface endpoints worth having for an ML platform. ecr.api and ecr.dkr keep
  # image pulls off the NAT path; logs keeps the log shipper off it; sts is what
  # IRSA calls on every token exchange; kms is called on every encrypted S3 read.
  interface_endpoints = var.enable_interface_endpoints ? {
    "ecr.api"        = "com.amazonaws.${var.region}.ecr.api"
    "ecr.dkr"        = "com.amazonaws.${var.region}.ecr.dkr"
    "logs"           = "com.amazonaws.${var.region}.logs"
    "sts"            = "com.amazonaws.${var.region}.sts"
    "kms"            = "com.amazonaws.${var.region}.kms"
    "sagemaker.api"  = "com.amazonaws.${var.region}.sagemaker.api"
    "secretsmanager" = "com.amazonaws.${var.region}.secretsmanager"
  } : {}
}

data "aws_availability_zones" "available" {
  state = "available"

  # Local zones and wavelength zones do not run EKS control plane ENIs, and a
  # node group placed in one fails to join. Filtering them out here rather than
  # discovering it during an apply.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets
  intra_subnets   = local.intra_subnets

  enable_nat_gateway = true
  # One NAT gateway is a single point of failure and a cross-zone data charge for
  # two thirds of your traffic. Three is three times the hourly cost. The default
  # here is one for development and per-zone for production, decided by the caller.
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  # The VPC CNI resolves pod DNS through the VPC resolver, and interface endpoints
  # need private DNS, so both of these have to be on.
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Nodes get no public address. Anything that needs to be reachable from outside
  # goes behind a load balancer.
  map_public_ip_on_launch = false

  # The load balancer controller reads these tags to decide which subnets it may
  # place an internet-facing or internal load balancer in. Without them it fails
  # with a subnet discovery error that gives no hint about the cause.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    # Karpenter and the cluster autoscaler both use a discovery tag to find
    # subnets they may launch into. Tagging here keeps that decision in the
    # network module rather than scattered across workload manifests.
    "karpenter.sh/discovery" = var.name
  }

  tags = var.tags
}

###############################################################################
# VPC endpoints
###############################################################################

resource "aws_security_group" "endpoints" {
  count = var.enable_interface_endpoints ? 1 : 0

  name_prefix = "${var.name}-vpce-"
  description = "Ingress to VPC interface endpoints from inside the VPC"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}

# Separate rule resources rather than inline ingress blocks. Inline blocks are an
# exclusive set: anything added out of band is removed on the next apply, which
# is occasionally what you want and is never what you want during an incident.
resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  count = var.enable_interface_endpoints ? 1 : 0

  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS from within the VPC"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"

  tags = var.tags
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  # Attaching to the private route tables is what actually moves S3 traffic off
  # the NAT gateway. An endpoint with no route table association exists, costs
  # nothing, and does nothing, which is a mistake that shows up only on the bill.
  route_table_ids = module.vpc.private_route_table_ids

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id            = module.vpc.vpc_id
  service_name      = each.value
  vpc_endpoint_type = "Interface"

  # Intra subnets: the endpoints themselves need no internet route.
  subnet_ids          = module.vpc.intra_subnets
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

###############################################################################
# Flow logs
#
# Off by default because they are a real cost at ML traffic volumes and are not
# needed to run the platform. On when you need to answer "what talked to what",
# which in practice means during an investigation or under a compliance
# requirement. Written to CloudWatch with a short retention rather than to S3,
# because the question they answer is nearly always about the last few days.
###############################################################################

resource "aws_cloudwatch_log_group" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name}/flow"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.log_kms_key_arn

  tags = var.tags
}

resource "aws_iam_role" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name_prefix = "${var.name}-flow-"
  description = "Allows VPC flow logs to write to CloudWatch Logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*" }
      }
    }]
  })

  tags = var.tags
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "aws_iam_role_policy" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name_prefix = "flow-"
  role        = aws_iam_role.flow[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow[0].arn}:*"
    }]
  })
}

resource "aws_flow_log" "vpc" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = module.vpc.vpc_id
  traffic_type             = "ALL"
  iam_role_arn             = aws_iam_role.flow[0].arn
  log_destination          = aws_cloudwatch_log_group.flow[0].arn
  log_destination_type     = "cloud-watch-logs"
  max_aggregation_interval = 600

  tags = var.tags
}
