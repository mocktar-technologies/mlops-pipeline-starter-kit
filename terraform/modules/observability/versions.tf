terraform {
  required_version = ">= 1.9.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    helm = {
      # helm provider v3 moved to the plugin framework. Its provider config is an
      # object attribute (kubernetes = { ... }) and helm_release.set is a list of
      # objects (set = [{ name, value }]), unlike the kubernetes provider which
      # kept blocks. Do not copy syntax between the two.
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
  }
}
