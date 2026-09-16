#!/usr/bin/env bash
#
# Run a one-shot command in the cluster as a Kubernetes Job and print its output.
#
# Why a Job rather than `kubectl run --attach --rm`: with --attach, the exit status
# you get is kubectl's, not the container's, and a pod that is evicted or
# rescheduled mid-attach looks like a success. A Job has a Complete or Failed
# condition that says what actually happened, and `kubectl wait` blocks on it.
#
# Why this is a script rather than inline workflow YAML: the alternative is a
# JSON pod override built with a shell heredoc inside a command substitution inside
# a YAML block scalar, which is four levels of quoting and breaks the first time
# someone adds an apostrophe.
#
# The container's stdout is the return value. Everything this script says about
# itself goes to stderr, so `VALUE="$(kube_run.sh ...)"` captures only the output.
#
# Usage:
#   kube_run.sh <namespace> <service-account> <image> [-e KEY=VALUE ...] -- <args...>

set -euo pipefail

log() { printf '%s\n' "$*" >&2; }

if [[ $# -lt 4 ]]; then
  log "usage: $0 <namespace> <service-account> <image> [-e KEY=VALUE ...] -- <args...>"
  exit 64
fi

NAMESPACE="$1"
SERVICE_ACCOUNT="$2"
IMAGE="$3"
shift 3

ENV_PAIRS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e)
      ENV_PAIRS+=("$2")
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      log "unexpected argument: $1"
      exit 64
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  log "no command arguments given after --"
  exit 64
fi

JOB_NAME="oneshot-$(date -u +%s)-$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
MANIFEST="$(mktemp)"
# Clean up the Job whatever happens. ttlSecondsAfterFinished would do it too, and
# an explicit delete means a re-run in the same minute cannot collide with a Job
# the cluster has not reaped yet.
trap 'rm -f "$MANIFEST"; kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

ENV_JSON="$(
  printf '%s\n' "${ENV_PAIRS[@]:-}" | python3 -c '
import json
import sys

entries = []
for line in sys.stdin:
    line = line.strip()
    if not line or "=" not in line:
        continue
    name, _, value = line.partition("=")
    entries.append({"name": name, "value": value})
print(json.dumps(entries))
'
)"

ARGS_JSON="$(printf '%s\n' "$@" | python3 -c 'import json,sys; print(json.dumps([l.rstrip("\n") for l in sys.stdin]))')"

python3 - "$MANIFEST" <<PY
import json
import sys

manifest = {
    "apiVersion": "batch/v1",
    "kind": "Job",
    "metadata": {
        "name": "${JOB_NAME}",
        "namespace": "${NAMESPACE}",
        "labels": {"app.kubernetes.io/managed-by": "kube-run.sh"},
    },
    "spec": {
        # No retries. This runs a registry operation or a lookup; retrying a
        # partially applied alias move is worse than reporting the failure.
        "backoffLimit": 0,
        "ttlSecondsAfterFinished": 300,
        "template": {
            "spec": {
                "restartPolicy": "Never",
                "serviceAccountName": "${SERVICE_ACCOUNT}",
                "securityContext": {
                    "runAsNonRoot": True,
                    "runAsUser": 10001,
                    "seccompProfile": {"type": "RuntimeDefault"},
                },
                "containers": [
                    {
                        "name": "run",
                        "image": "${IMAGE}",
                        "args": json.loads('''${ARGS_JSON}'''),
                        "env": json.loads('''${ENV_JSON}'''),
                        "securityContext": {
                            "allowPrivilegeEscalation": False,
                            "readOnlyRootFilesystem": True,
                            "capabilities": {"drop": ["ALL"]},
                        },
                        "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}],
                        "resources": {
                            "requests": {"cpu": "100m", "memory": "256Mi"},
                            "limits": {"memory": "1Gi"},
                        },
                    }
                ],
                "volumes": [{"name": "tmp", "emptyDir": {}}],
            }
        },
    },
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY

log "running ${JOB_NAME} in ${NAMESPACE} as ${SERVICE_ACCOUNT}: $*"
kubectl apply -f "$MANIFEST" >&2

TIMEOUT="${KUBE_RUN_TIMEOUT:-300s}"

# Wait for either condition. `kubectl wait` on complete alone hangs for the whole
# timeout when the Job fails, which turns a two-second failure into a five-minute
# one.
if ! kubectl -n "$NAMESPACE" wait --for=condition=complete "job/${JOB_NAME}" --timeout="$TIMEOUT" >&2 2>/dev/null; then
  if kubectl -n "$NAMESPACE" get "job/${JOB_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null | grep -q True; then
    log "job ${JOB_NAME} failed; its log follows"
    kubectl -n "$NAMESPACE" logs "job/${JOB_NAME}" --tail=200 >&2 || true
    exit 1
  fi
  log "job ${JOB_NAME} did not complete within ${TIMEOUT}"
  kubectl -n "$NAMESPACE" describe "job/${JOB_NAME}" >&2 || true
  kubectl -n "$NAMESPACE" logs "job/${JOB_NAME}" --tail=200 >&2 || true
  exit 1
fi

# stdout, so a caller can capture it.
kubectl -n "$NAMESPACE" logs "job/${JOB_NAME}" --tail=-1
