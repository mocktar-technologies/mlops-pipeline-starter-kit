terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.64"
    }
    kubernetes = {
      # The kubernetes provider v3 kept its SDKv2-style blocks: exec is a block,
      # and metadata on a resource is a block. That is different from the helm
      # provider v3, which moved to object attributes. Do not copy syntax between
      # the two.
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
}
