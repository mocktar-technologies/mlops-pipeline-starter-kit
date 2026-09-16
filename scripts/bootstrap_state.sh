#!/usr/bin/env bash
#
# Create the Terraform state bucket and the DynamoDB lock table.
#
# These two cannot be managed by the Terraform state they hold, so they are created
# once per account by this script rather than by a Terraform module. That is not a
# workaround: a state bucket managed by its own state is a resource you cannot
# recover if the state file is lost, which is exactly the situation the bucket
# exists to prevent.
#
# The script is idempotent. Run it again after adding a region or an account and it
# creates only what is missing.
#
# Usage:
#   scripts/bootstrap_state.sh [--region us-east-1] [--prefix mlops-starter]

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PREFIX="mlops-starter"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${PREFIX}-tfstate-${ACCOUNT_ID}"
TABLE="${PREFIX}-tfstate-lock"

echo "account: ${ACCOUNT_ID}"
echo "region:  ${REGION}"
echo "bucket:  ${BUCKET}"
echo "table:   ${TABLE}"
echo

# ---------------------------------------------------------------------------
# Bucket
# ---------------------------------------------------------------------------
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "bucket already exists"
else
  echo "creating the bucket"
  if [[ "${REGION}" == "us-east-1" ]]; then
    # us-east-1 rejects a LocationConstraint, which is the one API inconsistency
    # everyone trips over exactly once.
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
  else
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
fi

echo "applying versioning, encryption and public access block"

# Versioning first. Without it a corrupted state write is unrecoverable, and this
# is the single most valuable setting on this bucket.
aws s3api put-bucket-versioning --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "${BUCKET}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"},
      "BucketKeyEnabled": true
    }]
  }'

aws s3api put-public-access-block --bucket "${BUCKET}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws s3api put-bucket-ownership-controls --bucket "${BUCKET}" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

# Expire old state versions after 90 days and clean up failed uploads. State files
# are small, and a bucket with two years of versions of a large state is not.
aws s3api put-bucket-lifecycle-configuration --bucket "${BUCKET}" \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "expire-old-state-versions",
        "Status": "Enabled",
        "Filter": {},
        "NoncurrentVersionExpiration": {"NoncurrentDays": 90},
        "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
      }
    ]
  }'

# Deny plaintext access. State contains resource attributes and is sensitive even
# when secrets are kept out of it.
aws s3api put-bucket-policy --bucket "${BUCKET}" --policy "$(
  cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::${BUCKET}", "arn:aws:s3:::${BUCKET}/*"],
      "Condition": {"Bool": {"aws:SecureTransport": "false"}}
    }
  ]
}
JSON
)"

# ---------------------------------------------------------------------------
# Lock table
# ---------------------------------------------------------------------------
if aws dynamodb describe-table --table-name "${TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  echo "lock table already exists"
else
  echo "creating the lock table"
  # PAY_PER_REQUEST, because the access pattern is a handful of writes per apply.
  # Provisioned capacity on a state lock table is money spent on nothing.
  aws dynamodb create-table \
    --table-name "${TABLE}" \
    --region "${REGION}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --sse-specification Enabled=true \
    --tags Key=ManagedBy,Value=bootstrap-script Key=Purpose,Value=terraform-state-lock \
    >/dev/null
  aws dynamodb wait table-exists --table-name "${TABLE}" --region "${REGION}"
  # Point-in-time recovery. A lost lock table is not a disaster, and it is one API
  # call to be able to restore one.
  aws dynamodb update-continuous-backups --table-name "${TABLE}" --region "${REGION}" \
    --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true >/dev/null
fi

cat <<OUT

Done. Put these in terraform/envs/dev/backend.tf:

  bucket         = "${BUCKET}"
  region         = "${REGION}"
  dynamodb_table = "${TABLE}"

And these in terraform/envs/dev/terraform.tfvars:

  state_bucket_arn     = "arn:aws:s3:::${BUCKET}"
  state_lock_table_arn = "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE}"

OUT
