terraform {
  # 1.9 is the floor because this module uses variable validation with
  # cross-referenced expressions, which earlier versions reject at parse time.
  # OpenTofu 1.8 and later is equivalent for everything in this repository.
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned to a minor range, not a major one. The 6.x line has introduced
      # required-argument changes inside minors before, and an ML platform is
      # not the place to discover one during an incident apply.
      version = "~> 6.64"
    }
  }
}
