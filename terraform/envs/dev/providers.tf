###############################################################################
# Providers
#
# The kubernetes and helm providers are configured from the EKS module's outputs,
# which means the cluster has to exist before they can authenticate. Terraform
# tolerates that on a first apply because provider configuration is resolved
# lazily, but it is the reason a destroy of the whole environment can fail
# partway: once the cluster is gone the providers can no longer reach it to remove
# the Kubernetes objects. The Makefile's destroy target handles this by removing
# the Kubernetes-scoped resources in a first pass.
#
# exec authentication rather than a token. A token fetched at plan time expires in
# fifteen minutes, and a long apply then fails halfway through with an
# authentication error that looks like a permissions problem.
###############################################################################

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  # A block, not an attribute. The kubernetes provider kept SDKv2-style blocks in
  # v3; only the helm provider moved to object attributes.
  exec {
    api_version = "client.authentication.k8s.io/v1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  # An object attribute with an equals sign. The helm provider v3 moved to the
  # plugin framework and this is no longer a block. Writing `kubernetes { ... }`
  # here fails with a message about an unexpected block.
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
