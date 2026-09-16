#!/usr/bin/env bash
#
# Verify a deployed inference release end to end.
#
# Four checks in order of increasing specificity. The fourth is the one people skip
# and the one that matters most: a ServiceMonitor that Prometheus is not honouring
# produces empty panels and alerts that never fire, and both of those look exactly
# like a healthy system.
#
# Usage:
#   scripts/verify_deployment.sh [namespace] [release]

set -euo pipefail

NAMESPACE="${1:-inference}"
RELEASE="${2:-inference}"
DEPLOYMENT="${RELEASE}-inference"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

echo "=== 1. rollout"
kubectl -n "$NAMESPACE" rollout status "deploy/${DEPLOYMENT}" --timeout=5m \
  || fail "the rollout did not complete. Check the fetch-model init container first: a failure there is a model URI or an IAM problem, not an application problem."

READY="$(kubectl -n "$NAMESPACE" get "deploy/${DEPLOYMENT}" -o jsonpath='{.status.readyReplicas}')"
echo "ready replicas: ${READY:-0}"

echo
echo "=== 2. loaded model"
kubectl -n "$NAMESPACE" exec "deploy/${DEPLOYMENT}" -c inference -- \
  curl -sf http://127.0.0.1:8080/model > /tmp/model.json \
  || fail "/model did not answer"
python3 - <<'PY'
import json
import sys

info = json.load(open("/tmp/model.json"))
print(f"  name:     {info['model_name']}")
print(f"  version:  {info['model_version']}")
print(f"  git sha:  {info['git_sha']}")
print(f"  features: {len(info['feature_names'])} in contract order")
if info.get("loaded") is not True:
    sys.exit("the pod reports no model loaded")
if info.get("model_version") in ("", "unknown"):
    sys.exit(
        "the model version is unset, so every metric this pod emits is "
        "unattributable to a version. Set model.version in the Helm values."
    )
PY

echo
echo "=== 3. prediction"
kubectl -n "$NAMESPACE" exec "deploy/${DEPLOYMENT}" -c inference -- \
  curl -sf -X POST http://127.0.0.1:8080/predict \
  -H 'content-type: application/json' \
  -d '{"instances":[{"hour":17,"dayofweek":2,"month":6,"is_holiday":0,"is_workingday":1,"temp_c":21.5,"humidity":0.55,"windspeed":3.2},{"hour":3,"dayofweek":6,"month":1,"is_holiday":0,"is_workingday":0,"temp_c":-2.0,"humidity":0.9,"windspeed":8.0}]}' \
  > /tmp/predict.json || fail "/predict did not answer"
python3 - <<'PY'
import json
import sys

body = json.load(open("/tmp/predict.json"))
predictions = body["predictions"]
print(f"  predictions: {predictions}")
if any(value < 0 for value in predictions):
    sys.exit("a negative rental count was returned, which the serving contract forbids")
if len(predictions) != 2:
    sys.exit(f"sent 2 rows and got {len(predictions)} predictions back")
PY

echo
echo "=== 4. prometheus is scraping it"
kubectl -n "$MONITORING_NAMESPACE" port-forward \
  svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 20); do
  curl -sf http://127.0.0.1:9090/-/ready >/dev/null 2>&1 && break
  sleep 1
done

curl -sf "http://127.0.0.1:9090/api/v1/targets?state=active" > /tmp/targets.json \
  || fail "could not reach Prometheus. Without it every model alert is inert."

python3 - <<'PY'
import json
import sys

data = json.load(open("/tmp/targets.json"))
active = data.get("data", {}).get("activeTargets", [])
ours = [t for t in active if "inference" in t.get("labels", {}).get("job", "")]
for target in ours:
    labels = target.get("labels", {})
    print(f"  {labels.get('pod', '?'):<40} {target.get('health')} {target.get('lastError', '')}")
if not any(t.get("health") == "up" for t in ours):
    sys.exit(
        "no inference target is up. Check serviceMonitorSelectorNilUsesHelmValues on "
        "the Prometheus resource, and that the NetworkPolicy allows ingress from the "
        "monitoring namespace."
    )
print(f"  {len(ours)} target(s), at least one up")
PY

echo
echo "=== 5. the model metrics have actually arrived"
curl -sf "http://127.0.0.1:9090/api/v1/query?query=inference_model_loaded" > /tmp/query.json
python3 - <<'PY'
import json
import sys

result = json.load(open("/tmp/query.json")).get("data", {}).get("result", [])
if not result:
    sys.exit(
        "inference_model_loaded returned no series. The target is up but its metrics "
        "are not queryable, which usually means a metricRelabeling dropped them."
    )
for series in result:
    labels = series["metric"]
    print(f"  {labels.get('pod', '?'):<40} loaded={series['value'][1]}")
PY

echo
echo "all checks passed"
