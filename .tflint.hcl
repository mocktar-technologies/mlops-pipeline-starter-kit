# tflint configuration.
#
# The AWS ruleset is what makes tflint worth running on this repository: it catches
# an invalid instance type, a malformed ARN and a deprecated argument before an
# apply does, and those are the findings that otherwise cost you a failed apply
# halfway through creating a cluster.

tflint {
  required_version = ">= 0.50"
}

config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.48.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"

  # deep_check calls the AWS API to validate that referenced resources exist. It
  # needs credentials and it is slow, so it is off here and worth turning on in a
  # nightly run rather than on every pull request.
  deep_check = false
}

# Every variable carries a description in this repository, and the rule keeps it
# that way. A module input with no description is one the next person has to read
# the implementation to understand.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# Typed variables, so a wrong shape fails at plan rather than producing a confusing
# error inside a module.
rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Registry modules must be version-pinned. Without this an upstream release changes
# your infrastructure on the next init.
rule "terraform_module_pinned_source" {
  enabled = true
  style   = "flexible"
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

# Off: this repository deliberately keeps each module's variables, outputs and
# resources in separate files rather than following the one-file convention.
rule "terraform_standard_module_structure" {
  enabled = false
}
