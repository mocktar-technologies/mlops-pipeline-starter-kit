###############################################################################
# Development environment composition
#
# Read this file top to bottom to understand the platform: it is the only place
# where the modules meet, and every cross-module dependency is an explicit
# argument rather than a data source lookup. That is deliberate. A module that
# looks up its own inputs with a data source works until the thing it looks up is
# created in the same apply, at which point the plan is unresolvable and the error
# does not name the cause.
#
# Apply order is not something you choose. Terraform derives it from these
# references, with one exception noted at the inference namespace below.
###############################################################################

locals {
  name = "${var.project}-${var.environment}"

  tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      # The repository is the most useful tag on an unfamiliar resource: it tells
      # the next person where the code that created it lives.
      Repository = "${var.github_owner}/${var.github_repository}"
    },
    var.additional_tags,
  )

  # Namespaces created by workload charts rather than by Terraform. They are named
  # here because the IRSA trust policies need the exact namespace string, and a
  # typo produces a role that can never be assumed with an error that names only
  # the token.
  inference_namespace = "inference"
  pipelines_namespace = "mlops-pipelines"
}

###############################################################################
# Network
###############################################################################

module "network" {
  source = "../../modules/network"

  name   = local.name
  region = var.region

  vpc_cidr                = var.vpc_cidr
  availability_zone_count = var.availability_zone_count

  # Development: one NAT gateway. Production should set this false and accept
  # three, because a single NAT gateway is both a single point of failure and a
  # cross-zone data charge for two thirds of the traffic.
  single_nat_gateway         = var.single_nat_gateway
  enable_interface_endpoints = var.enable_interface_endpoints
  enable_flow_logs           = var.enable_flow_logs

  tags = local.tags
}

###############################################################################
# Artifacts
###############################################################################

module "artifacts" {
  source = "../../modules/artifacts"

  name   = local.name
  region = var.region

  inference_capture_retention_days = var.inference_capture_retention_days

  ecr_repositories = {
    inference = { keep_last_images = 30 }
    training  = { keep_last_images = 10 }
    mlflow    = { keep_last_images = 5 }
  }

  tags = local.tags
}

###############################################################################
# IRSA roles
#
# Created before the cluster's workloads and after the cluster itself, because
# each trust policy needs the OIDC provider ARN. The policies are written inline
# here rather than inside the modules so that every grant in the platform can be
# read in one place during a review.
###############################################################################

# The EBS CSI driver. Without this role the add-on installs, reports healthy, and
# every PersistentVolumeClaim sits Pending with no event that mentions IAM.
module "irsa_ebs_csi" {
  source = "../../modules/irsa"

  role_name         = "${local.name}-ebs-csi"
  description       = "EBS CSI driver for ${local.name}"
  oidc_provider_arn = module.eks.oidc_provider_arn

  service_accounts = [{ namespace = "kube-system", name = "ebs-csi-controller-sa" }]

  additional_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]

  # The driver needs to create volumes encrypted with the platform key, and the
  # managed policy grants KMS actions only through a condition on
  # kms:ViaService, so the grant for this specific key is added here.
  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "UseKeyForVolumeEncryption"
        Effect = "Allow"
        Action = [
          "kms:CreateGrant",
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:ReEncrypt*",
        ]
        Resource = module.artifacts.kms_key_arn
      },
    ]
  })

  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = local.tags
}

# The MLflow tracking server. It proxies artifact traffic (--serve-artifacts), so
# it is the only identity in the platform that needs write access to the MLflow
# prefix, and clients need none at all.
module "irsa_mlflow" {
  source = "../../modules/irsa"

  role_name         = "${local.name}-mlflow"
  description       = "MLflow tracking server for ${local.name}"
  oidc_provider_arn = module.eks.oidc_provider_arn

  service_accounts = [{ namespace = "mlflow", name = "mlflow" }]

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListArtifactBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = module.artifacts.bucket_arn
        Condition = {
          StringLike = {
            # Scoped by prefix. ListBucket without this condition lets the server
            # enumerate every object in the bucket, including captured inference
            # payloads it has no business reading.
            "s3:prefix" = ["${module.artifacts.prefixes.mlflow}*"]
          }
        }
      },
      {
        Sid    = "ReadWriteMlflowArtifacts"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
        ]
        Resource = "${module.artifacts.bucket_arn}/${module.artifacts.prefixes.mlflow}*"
      },
      {
        Sid    = "UseArtifactKey"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = module.artifacts.kms_key_arn
      },
      {
        Sid      = "ReadDatabaseCredentials"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = module.mlflow.database_secret_arn
      },
    ]
  })

  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = local.tags
}

# The inference service. Read the model, write captured inputs, and nothing else.
# In particular it has no write access to the model prefix: a compromised serving
# pod must not be able to replace the model it serves.
module "irsa_inference" {
  source = "../../modules/irsa"

  role_name         = "${local.name}-inference"
  description       = "Online inference service for ${local.name}"
  oidc_provider_arn = module.eks.oidc_provider_arn

  service_accounts = [{ namespace = local.inference_namespace, name = "inference" }]

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListModelPrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = module.artifacts.bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "${module.artifacts.prefixes.models}*",
              "${module.artifacts.prefixes.mlflow}*",
            ]
          }
        }
      },
      {
        Sid    = "ReadModelArtifacts"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = [
          "${module.artifacts.bucket_arn}/${module.artifacts.prefixes.models}*",
          "${module.artifacts.bucket_arn}/${module.artifacts.prefixes.mlflow}*",
        ]
      },
      {
        Sid    = "CaptureInferenceInputs"
        Effect = "Allow"
        # Put only. No Get and no Delete: the serving pod writes the audit trail
        # the drift monitor reads, and it should not be able to read back or
        # tamper with what it wrote.
        Action   = ["s3:PutObject"]
        Resource = "${module.artifacts.bucket_arn}/${module.artifacts.prefixes.inference}*"
      },
      {
        Sid    = "UseArtifactKey"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = module.artifacts.kms_key_arn
      },
    ]
  })

  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = local.tags
}

# The drift exporter. Read the training reference and the captured inputs. It
# writes nothing at all, which is why it can safely run continuously.
module "irsa_drift" {
  source = "../../modules/irsa"

  role_name         = "${local.name}-drift"
  description       = "Drift exporter for ${local.name}"
  oidc_provider_arn = module.eks.oidc_provider_arn

  service_accounts = [{ namespace = local.inference_namespace, name = "drift-monitor" }]

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListComparedPrefixes"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = module.artifacts.bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "${module.artifacts.prefixes.datasets}*",
              "${module.artifacts.prefixes.inference}*",
            ]
          }
        }
      },
      {
        Sid    = "ReadComparedData"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = [
          "${module.artifacts.bucket_arn}/${module.artifacts.prefixes.datasets}*",
          "${module.artifacts.bucket_arn}/${module.artifacts.prefixes.inference}*",
        ]
      },
      {
        Sid      = "UseArtifactKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = module.artifacts.kms_key_arn
      },
    ]
  })

  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = local.tags
}

# The training pipeline, when it runs as a Kubernetes Job rather than a SageMaker
# training job. Both paths exist; this is the identity for the in-cluster one.
module "irsa_pipelines" {
  source = "../../modules/irsa"

  role_name         = "${local.name}-pipelines"
  description       = "Training and promotion pipeline for ${local.name}"
  oidc_provider_arn = module.eks.oidc_provider_arn

  service_accounts = [{ namespace = local.pipelines_namespace, name = "pipelines" }]

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListDataAndModelPrefixes"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = module.artifacts.bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "${module.artifacts.prefixes.datasets}*",
              "${module.artifacts.prefixes.models}*",
            ]
          }
        }
      },
      {
        Sid    = "ReadTrainingData"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = [
          "${module.artifacts.bucket_arn}/${module.artifacts.prefixes.datasets}*",
          "${module.artifacts.bucket_arn}/${module.artifacts.prefixes.models}*",
        ]
      },
      {
        Sid    = "WriteDatasetsAndModels"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = [
          "${module.artifacts.bucket_arn}/${module.artifacts.prefixes.datasets}*",
          "${module.artifacts.bucket_arn}/${module.artifacts.prefixes.models}*",
        ]
      },
      {
        Sid    = "UseArtifactKey"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = module.artifacts.kms_key_arn
      },
      {
        Sid    = "SubmitTrainingJobs"
        Effect = "Allow"
        Action = [
          "sagemaker:CreateTrainingJob",
          "sagemaker:DescribeTrainingJob",
          "sagemaker:StopTrainingJob",
          "sagemaker:AddTags",
        ]
        Resource = "*"
      },
      {
        Sid      = "PassExecutionRoleToSageMakerOnly"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = module.sagemaker.execution_role_arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" }
        }
      },
    ]
  })

  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = local.tags
}

###############################################################################
# Cluster
###############################################################################

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.name
  kubernetes_version = var.kubernetes_version

  vpc_id                   = module.network.vpc_id
  control_plane_subnet_ids = module.network.intra_subnet_ids
  node_subnet_ids          = module.network.private_subnet_ids

  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  kms_key_arn           = module.artifacts.kms_key_arn
  ebs_csi_irsa_role_arn = module.irsa_ebs_csi.role_arn

  # The CI apply role gets namespace-scoped admin on the inference namespace and
  # nothing else. A deploy role that needs to roll out one Deployment does not
  # need to read every secret in the cluster.
  access_entries = merge(
    { ci = module.cicd_identity.eks_access_entry },
    var.additional_access_entries,
  )

  inference_min_size = var.inference_min_size
  inference_max_size = var.inference_max_size
  gpu_instance_types = var.gpu_instance_types
  gpu_max_size       = var.gpu_max_size

  tags = local.tags
}

###############################################################################
# SageMaker
###############################################################################

module "sagemaker" {
  source = "../../modules/sagemaker"

  name       = local.name
  region     = var.region
  model_name = var.model_name

  artifact_bucket_arn = module.artifacts.bucket_arn
  prefixes            = module.artifacts.prefixes
  kms_key_arn         = module.artifacts.kms_key_arn
  ecr_repository_arns = values(module.artifacts.ecr_repository_arns)

  enable_vpc_access = true
  vpc_id            = module.network.vpc_id
  vpc_cidr          = module.network.vpc_cidr_block

  enable_model_package_group = var.enable_sagemaker_model_registry

  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = local.tags
}

###############################################################################
# MLflow
###############################################################################

module "mlflow" {
  source = "../../modules/mlflow"

  name   = local.name
  region = var.region

  irsa_role_arn = module.irsa_mlflow.role_arn
  image         = var.mlflow_image

  vpc_id                 = module.network.vpc_id
  private_subnet_ids     = module.network.private_subnet_ids
  node_security_group_id = module.eks.node_security_group_id

  kms_key_arn     = module.artifacts.kms_key_arn
  artifact_bucket = module.artifacts.bucket_name
  artifact_prefix = module.artifacts.prefixes.mlflow

  allowed_client_namespaces = [local.pipelines_namespace, local.inference_namespace]

  db_multi_az            = var.db_multi_az
  db_deletion_protection = var.db_deletion_protection
  replicas               = var.mlflow_replicas

  tags = local.tags
}

###############################################################################
# Observability
#
# Applied after the cluster and before any workload chart, because this release
# installs the Prometheus Operator CRDs. A ServiceMonitor cannot exist until they
# do, and the failure is an unhelpful "no matches for kind ServiceMonitor".
###############################################################################

module "observability" {
  source = "../../modules/observability"

  name         = local.name
  cluster_name = module.eks.cluster_name
  environment  = var.environment

  dashboard_directory = "${path.module}/../../../monitoring/dashboards"

  enable_gpu_device_plugin = var.gpu_max_size > 0
  enable_grafana           = var.enable_grafana
  enable_retrain_webhook   = var.enable_retrain_webhook

  prometheus_retention      = var.prometheus_retention
  prometheus_retention_size = var.prometheus_retention_size
  prometheus_storage_size   = var.prometheus_storage_size
}

###############################################################################
# CI/CD identity
###############################################################################

module "cicd_identity" {
  source = "../../modules/cicd_identity"

  name   = local.name
  region = var.region

  github_owner      = var.github_owner
  github_repository = var.github_repository

  trusted_branches     = var.trusted_branches
  trusted_environments = var.trusted_environments
  create_oidc_provider = var.create_github_oidc_provider

  state_bucket_arn     = var.state_bucket_arn
  state_lock_table_arn = var.state_lock_table_arn

  artifact_bucket_arn = module.artifacts.bucket_arn
  prefixes            = module.artifacts.prefixes
  kms_key_arn         = module.artifacts.kms_key_arn
  ecr_repository_arns = values(module.artifacts.ecr_repository_arns)

  sagemaker_execution_role_arn = module.sagemaker.execution_role_arn
  apply_additional_policy_arns = var.ci_apply_additional_policy_arns

  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = local.tags
}
