###############################################################################
# Remote state
#
# The bucket and lock table are created by scripts/bootstrap-state.sh before the
# first init, because they cannot be managed by the state they hold. That script
# is idempotent and prints the exact values to fill in below.
#
# Backend blocks cannot use variables, which is why these are literals. Keeping
# them in a separate file makes it obvious which lines are per-account and have to
# be edited rather than passed in.
#
# Alternative, if you would rather not edit this file: comment the values out and
# pass them at init time instead, which is what the Makefile does when
# TF_BACKEND_CONFIG is set:
#   tofu init -backend-config=backend.hcl
###############################################################################

terraform {
  backend "s3" {
    bucket = "CHANGE-ME-tfstate-ACCOUNT_ID"
    key    = "mlops-starter/dev/terraform.tfstate"
    region = "us-east-1"

    # Server-side encryption of the state file. State contains resource
    # attributes, and while this configuration keeps secrets out of state as far
    # as it can, treating the state file as sensitive is the only safe posture.
    encrypt = true

    # DynamoDB state locking. Without a lock, two applies running at once produce
    # a state file that describes neither of them, and the damage is discovered on
    # the third apply.
    dynamodb_table = "CHANGE-ME-tfstate-lock"
  }
}
