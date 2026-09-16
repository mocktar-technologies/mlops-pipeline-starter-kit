#!/usr/bin/env bash
#
# Run a one-shot container inside the VPC and wait for it.
#
# Why this exists: the MLflow tracking server is a ClusterIP service inside the
# VPC, and the EKS API endpoint is private by default. A GitHub-hosted runner can
# reach neither. Anything that has to talk to MLflow (training, the promotion gate,
# moving the champion alias) therefore cannot run on the runner itself.
#
# The options are a self-hosted runner inside the VPC, a public MLflow endpoint, or
# submitting the work to a service that already runs inside the VPC. This script
# takes the third: it submits a SageMaker training job attached to the private
# subnets, waits for it, and streams the tail of its log.
#
# A SageMaker training job is used even for a short registry operation. That is
# deliberate: it is the cheapest VPC-attached one-shot container runner that needs
# no IAM beyond what the pipeline already has. A Processing job is the semantically
# tidier choice and needs sagemaker:CreateProcessingJob added to the CI role; if
# your organisation prefers that, the change is one API call and the same arguments.
#
# Usage:
#   run_vpc_job.sh <job-name-prefix> <image-uri> <command...>
#
# Required environment:
#   AWS_REGION              region to submit in
#   SAGEMAKER_ROLE_ARN      execution role, from terraform output
#   SUBNET_IDS              comma-separated private subnet ids
#   SECURITY_GROUP_IDS      comma-separated security group ids
#   ARTIFACT_BUCKET         bucket for job output
#   MLFLOW_TRACKING_URI     in-cluster tracking URI
#   DATA_URI                dataset location
#   GIT_SHA                 recorded as a tag on the MLflow run
# Optional:
#   INSTANCE_TYPE           default ml.m5.xlarge; use an ml.g-family type to train on a GPU
#   MAX_RUNTIME_SECONDS     default 3600
#   JOB_KMS_KEY_ID          KMS key for the job's output and volume

set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <job-name-prefix> <image-uri> <command...>" >&2
  exit 64
fi

PREFIX="$1"
IMAGE="$2"
shift 2

: "${AWS_REGION:?AWS_REGION is required}"
: "${SAGEMAKER_ROLE_ARN:?SAGEMAKER_ROLE_ARN is required}"
: "${SUBNET_IDS:?SUBNET_IDS is required}"
: "${SECURITY_GROUP_IDS:?SECURITY_GROUP_IDS is required}"
: "${ARTIFACT_BUCKET:?ARTIFACT_BUCKET is required}"
: "${MLFLOW_TRACKING_URI:?MLFLOW_TRACKING_URI is required}"

INSTANCE_TYPE="${INSTANCE_TYPE:-ml.m5.xlarge}"
MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-3600}"

# SageMaker job names must be unique in the account and region, at most 63
# characters, and may contain only letters, digits and hyphens. A timestamp plus a
# short random suffix survives two jobs submitted in the same second, which happens
# when a workflow is re-run.
SUFFIX="$(date -u +%Y%m%d-%H%M%S)-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
JOB_NAME="$(printf '%s-%s' "$PREFIX" "$SUFFIX" | cut -c1-63)"

# The container's command. SageMaker passes ContainerArguments after the image's
# entrypoint, which for the training image is `python -m pipelines.cli`.
ARGUMENTS_JSON="$(printf '%s\n' "$@" | python3 -c 'import json,sys; print(json.dumps([line.rstrip("\n") for line in sys.stdin]))')"

# Only non-secret configuration. SageMaker environment values are visible in
# DescribeTrainingJob to anyone with that permission, so nothing sensitive goes
# here; the job resolves anything it needs through its own execution role.
ENVIRONMENT_JSON="$(
  python3 - <<'PY'
import json
import os

environment = {
    "MLFLOW_TRACKING_URI": os.environ["MLFLOW_TRACKING_URI"],
    "ARTIFACT_BUCKET": os.environ["ARTIFACT_BUCKET"],
    "AWS_DEFAULT_REGION": os.environ["AWS_REGION"],
    "GIT_SHA": os.environ.get("GIT_SHA", "unknown"),
    "LOG_LEVEL": os.environ.get("LOG_LEVEL", "INFO"),
}
if os.environ.get("DATA_URI"):
    environment["DATA_URI"] = os.environ["DATA_URI"]
print(json.dumps(environment))
PY
)"

# SageMaker appends <JobName>/output/model.tar.gz to S3OutputPath, so the prefix
# must not already contain the job name or the path ends up doubled.
OUTPUT_PREFIX="s3://${ARTIFACT_BUCKET}/jobs"
OUTPUT_ARCHIVE="${OUTPUT_PREFIX}/${JOB_NAME}/output/model.tar.gz"

REQUEST_FILE="$(mktemp)"
trap 'rm -f "$REQUEST_FILE"' EXIT

python3 - "$REQUEST_FILE" <<PY
import json
import os
import sys

request = {
    "TrainingJobName": "${JOB_NAME}",
    "RoleArn": os.environ["SAGEMAKER_ROLE_ARN"],
    "AlgorithmSpecification": {
        "TrainingImage": "${IMAGE}",
        "TrainingInputMode": "File",
        "ContainerArguments": json.loads('''${ARGUMENTS_JSON}'''),
    },
    "ResourceConfig": {
        "InstanceType": "${INSTANCE_TYPE}",
        "InstanceCount": 1,
        "VolumeSizeInGB": 50,
    },
    "OutputDataConfig": {"S3OutputPath": "${OUTPUT_PREFIX}"},
    "StoppingCondition": {"MaxRuntimeInSeconds": int("${MAX_RUNTIME_SECONDS}")},
    "Environment": json.loads('''${ENVIRONMENT_JSON}'''),
    # Attaching to the VPC is what lets the job reach the in-cluster MLflow server.
    # A job with no VpcConfig runs on the SageMaker service network, cannot resolve
    # a cluster-internal hostname, and fails with a connection timeout that reads
    # like an MLflow outage.
    "VpcConfig": {
        "SecurityGroupIds": os.environ["SECURITY_GROUP_IDS"].split(","),
        "Subnets": os.environ["SUBNET_IDS"].split(","),
    },
    # Encrypt the inter-node traffic and the attached volume. The volume holds the
    # training data and the model checkpoint.
    "EnableInterContainerTrafficEncryption": True,
    "EnableManagedSpotTraining": os.environ.get("USE_SPOT", "false").lower() == "true",
    "Tags": [
        {"Key": "ManagedBy", "Value": "github-actions"},
        {"Key": "GitSha", "Value": os.environ.get("GIT_SHA", "unknown")},
    ],
}

if os.environ.get("JOB_KMS_KEY_ID"):
    request["OutputDataConfig"]["KmsKeyId"] = os.environ["JOB_KMS_KEY_ID"]
    request["ResourceConfig"]["VolumeKmsKeyId"] = os.environ["JOB_KMS_KEY_ID"]

if request["EnableManagedSpotTraining"]:
    # Managed spot requires a stopping condition that allows for waiting, and the
    # wait time has to be at least the runtime.
    request["StoppingCondition"]["MaxWaitTimeInSeconds"] = int("${MAX_RUNTIME_SECONDS}") * 2

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(request, handle)
PY

echo "submitting ${JOB_NAME}"
echo "  image:   ${IMAGE}"
echo "  command: $*"
echo "  output:  ${OUTPUT_ARCHIVE}"

aws sagemaker create-training-job --cli-input-json "file://${REQUEST_FILE}" >/dev/null

{
  echo "job-name=${JOB_NAME}"
  echo "output-prefix=${OUTPUT_PREFIX}"
  echo "output-archive=${OUTPUT_ARCHIVE}"
} >>"${GITHUB_OUTPUT:-/dev/null}"

# Poll rather than using `aws sagemaker wait`, so progress is visible in the log.
# A workflow that prints nothing for twenty minutes is a workflow people cancel.
STATUS="InProgress"
ELAPSED=0
while [[ "$STATUS" == "InProgress" || "$STATUS" == "Stopping" ]]; do
  sleep 20
  ELAPSED=$((ELAPSED + 20))
  STATUS="$(aws sagemaker describe-training-job --training-job-name "$JOB_NAME" --query TrainingJobStatus --output text)"
  SECONDARY="$(aws sagemaker describe-training-job --training-job-name "$JOB_NAME" --query SecondaryStatus --output text)"
  printf '  %4ds  %s / %s\n' "$ELAPSED" "$STATUS" "$SECONDARY"
done

echo
echo "final status: ${STATUS}"

# The last hundred lines of the job log, whatever the outcome. On a failure this is
# the difference between a usable CI log and a link to the console.
LOG_STREAM="$(aws logs describe-log-streams \
  --log-group-name /aws/sagemaker/TrainingJobs \
  --log-stream-name-prefix "${JOB_NAME}/" \
  --query 'logStreams[0].logStreamName' --output text 2>/dev/null || echo "None")"

if [[ "$LOG_STREAM" != "None" && -n "$LOG_STREAM" ]]; then
  echo "::group::job log tail (${LOG_STREAM})"
  aws logs get-log-events \
    --log-group-name /aws/sagemaker/TrainingJobs \
    --log-stream-name "$LOG_STREAM" \
    --limit 100 --no-start-from-head \
    --query 'events[].message' --output text || true
  echo "::endgroup::"
fi

if [[ "$STATUS" != "Completed" ]]; then
  REASON="$(aws sagemaker describe-training-job --training-job-name "$JOB_NAME" --query FailureReason --output text 2>/dev/null || echo "none reported")"
  echo "job ${JOB_NAME} ended with status ${STATUS}: ${REASON}" >&2
  exit 1
fi
