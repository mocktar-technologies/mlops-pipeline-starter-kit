# Operational runbook

Every alert rule in `deploy/charts/inference/templates/prometheusrule.yaml` carries a
`runbook_url` annotation pointing at a section of this file. Set
`alerts.runbookBaseUrl` in your Helm values to this file's URL in your repository so
the links resolve from the alert itself.

Read this first, before the sections: **the four layers, and which one is lying to
you.**

```
infrastructure   pods, CPU, memory, restarts        kube-state-metrics, cAdvisor
application      request rate, errors, latency      inference_requests_total, ...
data             what is arriving                   inference_input_rejected_total,
                                                    model_drift_psi
model            what is going out                  inference_prediction,
                                                    inference_prediction_clamped_total
```

The first two layers are the ones you already have for any service, and they can all
be green while the model is wrong. That is not a hypothetical: a model that has
started predicting near zero for everything returns 200s in single-digit
milliseconds. When an alert fires, the first question is which layer it came from,
because that determines whether rolling back the model can possibly help.

The second thing worth internalising: **a monitor that has stopped working looks
exactly like a healthy system.** An empty Grafana panel and an alert whose query
returns no series are both silent. `DriftMonitorStale` and the drift freshness panel
exist for that reason, and the fifth check in `make verify` exists for that reason.

---

## Common first moves

```bash
# Which model version is actually serving, according to the pod itself
kubectl -n inference exec deploy/inference-inference -c inference -- \
  curl -sf http://127.0.0.1:8080/model | python3 -m json.tool

# Which version the registry thinks is champion
make rollback            # no: this MOVES the alias. To only read it:
bash scripts/kube_run.sh mlops-pipelines pipelines "<training-image>" \
  -e "MLFLOW_TRACKING_URI=http://mlflow.mlflow.svc.cluster.local:5000" \
  -e "ARTIFACT_BUCKET=<bucket>" -- resolve --alias champion

# Everything at once
make verify

# Recent deploys, newest first
helm -n inference history inference
```

The two version numbers above disagreeing is the single most common cause of a
confusing dashboard. The registry is what the next deploy will pick up; the pod is
what is serving now. They are supposed to differ between a promotion and the deploy
that follows it.

---

## InferenceModelNotLoaded

**Severity: critical. The service is returning 503 to every inference request.**

The pod is serving HTTP but has no model. Readiness should already have removed it
from the Service, so if traffic is still arriving, the probe is misconfigured and
that is the more urgent finding.

1. Establish whether it is one pod or all of them.

   ```bash
   kubectl -n inference get pods -l app.kubernetes.io/name=inference
   ```

2. Look at the init container, not the application. This alert almost always means
   the model was never fetched.

   ```bash
   kubectl -n inference logs <pod> -c fetch-model
   ```

   | What you see | What it means | Fix |
   |---|---|---|
   | `AccessDenied` on `s3 cp` | The IRSA role cannot read the prefix, or cannot decrypt | Check the role has `kms:Decrypt` on the platform key, not only `s3:GetObject`. A missing KMS grant produces an error that names S3. |
   | `NoSuchKey` | `model.s3Uri` points at a version that was never uploaded | Check the version in the Helm values against what is in the bucket |
   | `model is only N bytes` | A truncated download | Re-run the rollout; if it recurs, the object itself is bad |
   | Nothing at all, pod Pending | Not an IAM problem | `kubectl describe pod`, look at events |

3. If the artifact is genuinely missing or corrupt, roll the model back rather than
   waiting to fix the upload.

   ```bash
   make rollback
   # then redeploy so the pods pick up the previous version
   ```

4. If the pods are serving but the alert fired anyway, check
   `inference_model_load_failures_total` on the dashboard. A non-zero count with
   healthy pods means a pod crash-looped and recovered, which is worth understanding
   even once the alert clears.

---

## InferenceHighErrorRate

**Severity: critical. More than 2 percent of requests are failing.**

The threshold is tighter than a typical web service on purpose: an inference client
usually has no retry, and a failed prediction becomes a missing value in someone's
decision rather than a spinner.

1. **Did this start at a deploy?** Look for the purple annotation lines on the
   dashboard, which mark model version changes.

   ```bash
   helm -n inference history inference
   ```

   A 5xx rise that begins at a deploy is a code or artifact problem. One that begins
   without a deploy is nearly always a dependency.

2. Split the errors by route. `/invocations` failing while `/predict` is fine, or the
   reverse, is a meaningful signal: both call the same function, so a difference
   means something in front of the service is treating them differently.

3. Read the actual errors.

   ```bash
   kubectl -n inference logs -l app.kubernetes.io/name=inference --tail=100 \
     | grep -i error
   ```

4. **Rolling back.** There are two rollbacks and they are not the same thing.

   ```bash
   helm -n inference rollback inference     # the application: container image, config
   make rollback                            # the model: moves the champion alias
   ```

   If the error started at a deploy that changed only the model version, roll back
   the model. If it changed the image, roll back the release. Doing both at once
   makes the cause unrecoverable.

---

## InferenceLatencyHigh

**Severity: warning. p99 above the configured threshold for ten minutes.**

The first move is one comparison, and it decides everything that follows.

```
inference:latency_p99:5m        total, including validation and serialisation
inference:model_latency_p99:5m  time inside the ONNX Runtime session
```

Both are on the "Total latency against model latency" panel.

**Model latency flat, total latency up.** The model is not the problem and rolling it
back will change nothing. In order of likelihood:

1. **CPU throttling.** The most common cause and the hardest to see. The chart sets
   no CPU limit by default for exactly this reason, so if one has been added, that is
   your answer.

   ```bash
   kubectl -n inference top pods
   # throttling, if your cAdvisor exposes it:
   # rate(container_cpu_cfs_throttled_seconds_total{namespace="inference"}[5m])
   ```

2. **Batch size.** Check the batch size distribution panel. A caller that started
   sending 400-row batches instead of 1-row batches has not broken anything, and your
   p99 is now describing a different workload. `MAX_BATCH_SIZE` bounds it.

3. **Saturation.** Replicas at the HPA maximum with CPU above the request means you
   are out of capacity, not slow.

   ```bash
   kubectl -n inference get hpa
   ```

4. **Thread oversubscription.** If `SERVING_INTRA_OP_THREADS` is above the pod's CPU
   allowance, ONNX Runtime creates more threads than the cgroup can run and they
   contend. It must be at or below the CPU limit, never above.

**Model latency also up.** Now it is the model or the data reaching it.

- A new model version with more parameters is the obvious case; the dashboard
  annotations will show it.
- A larger batch increases model latency too, so rule that out first.
- Same version, same batch size, slower: the node is the suspect. Check whether the
  slow pods share one node.

---

## InferencePredictionClamped

**Severity: critical, and it should never fire.**

The exported graph ends in `exp()`, so a prediction outside the configured bounds is
structurally impossible. This alert means the artifact in the pod is not the model
this service was written for.

1. Establish which artifact is loaded.

   ```bash
   kubectl -n inference exec deploy/inference-inference -c inference -- \
     curl -sf http://127.0.0.1:8080/model | python3 -m json.tool
   ```

2. Compare `model_version` with the champion alias in MLflow, and compare
   `model.s3Uri` in the Helm release with the object the registry points at.

3. **Assume predictions were wrong before the clamp caught them.** The clamp is a
   boundary guard, not a fix: it bounds what reaches a caller and it cannot repair a
   model that is producing nonsense inside the bounds too. Treat this as bad output
   having been served.

4. Roll the model back, then work out how a non-conforming artifact was promoted.
   The pipeline has three separate checks that should have stopped it: the ONNX
   parity check in `train.py`, the negative-prediction assertion on the test set, and
   the gate's own hard failure on negative predictions. One of them was bypassed, and
   finding out which matters more than the incident.

---

## InferenceInputRejectionSpike

**Severity: warning. Requests are being rejected before inference.**

Read the `reason` label first, because the two reasons need opposite responses.

**`reason="schema"`.** An upstream producer has changed its output. This is the
earliest signal you get of a data-quality regression, and it appears here before any
model metric moves, because the request never reaches the model.

```bash
kubectl -n inference logs -l app.kubernetes.io/name=inference --tail=200 \
  | grep "rejected request"
```

The log line contains the validation error, which names the field and the value. Then
go and talk to whoever produces that field. Do not widen the bounds in
`src/contract/features.py` to make the alert stop: those bounds are the same ones the
training data contract enforces, so widening them means the model is now being asked
about a distribution it never saw.

**`reason="batch_too_large"`.** A client changed its behaviour. Nothing is broken.
Decide whether to raise `limits.maxBatchSize` or ask the client to page its requests.
Raising it has a latency cost that lands on every other caller, and SageMaker allows
the model only 60 seconds per `/invocations` call.

---

## InferencePredictionDistributionShift

**Severity: warning. The mean prediction moved more than 25 percent against the same
window yesterday.**

This is the alert that catches the failure ordinary monitoring cannot see. Every
infrastructure and application signal can be green while this fires.

1. **Did the model version change?** Check the dashboard annotations and the Helm
   history. A different model predicting differently is expected, and the honest
   response is to decide whether the new distribution is better, not to treat it as
   an incident.

2. **If the version did not change, the inputs moved.** Look at `model_drift_psi` by
   feature. A prediction shift with a matching input shift is the system working as
   designed: the model is responding to different data.

3. **If the version did not change and the inputs did not move**, something else did.
   Check the clamp counter, check for a partial rollout with two versions serving, and
   check whether one pod is responsible by splitting the panel by pod.

4. Compare against the business outcome before retraining. Demand genuinely being 25
   percent lower than yesterday is not a model problem, and retraining on the new
   window would be chasing reality rather than correcting an error.

---

## ModelDriftWarning

**Severity: warning. PSI above 0.10 for an hour. Not yet a reason to do anything.**

The population stability index is a heuristic, read conventionally as: below 0.10 no
meaningful change, 0.10 to 0.25 worth investigating, above 0.25 a material shift. It
is not a statistical test and it does not tell you whether the model got worse.

1. Which feature moved? `model_drift_psi` is labelled per feature.

2. Is the comparison meaningful? Check the drift sample sizes panel. A PSI computed
   from a few hundred rows swings for reasons unrelated to drift, and the exporter
   refuses below 200 rows.

3. Is there a boring explanation? A seasonal change, a holiday, a new region
   onboarding, a client that started sending a different subset of traffic. All of
   these move PSI and none of them means the model is broken.

4. Record what you found and move on. Acting on every warning-level drift reading is
   how a team ends up retraining weekly for no measured benefit.

---

## ModelDriftCritical

**Severity: warning, deliberately not critical. PSI above 0.25 for two hours.**

Drift is not a page. It needs a decision within a working day, and paging someone at
3 a.m. for a distribution shift teaches them to ignore the channel. That is why this
is a warning with a two-hour `for` clause.

1. Everything under ModelDriftWarning above, first.

2. **Has model quality actually degraded?** PSI describes the inputs. If you have
   labels arriving, compare recent error against the test-set MAE recorded on the
   champion's MLflow run. If you do not have labels yet, the prediction distribution
   panel is your proxy.

3. **Decide, and record the decision.**

   | Finding | Action |
   |---|---|
   | Inputs moved, predictions and outcomes fine | Update the reference sample, do not retrain. The reference is stale, not the model. |
   | Inputs moved, quality measurably worse | Retrain. See below. |
   | One feature moved and it is an upstream bug | Fix the pipeline. Retraining on bad data bakes the bug into the model. |
   | Inputs moved because the world moved | Retrain, and expect to retrain again |

4. To retrain:

   ```
   Actions tab -> model-retrain-trigger -> Run workflow
     reason: "PSI 0.31 on temp_c sustained 4h, MAE degraded from 17 to 24"
   ```

   The workflow trains, registers a challenger, and runs the gate. If the gate holds
   the challenger back, that is information: the new data did not produce a better
   model, and the problem is not one retraining fixes.

5. If `enable_retrain_webhook` is on, this alert opens that run by itself. It still
   cannot promote anything: the gate and the environment approval both stand.

---

## DriftMonitorStale

**Severity: warning. No successful drift computation for the configured window.**

**While this is firing, every drift number on the dashboard is unknown, not green.**
The gauges hold their last value, and a stale healthy value is the most misleading
thing a dashboard can show.

```bash
kubectl -n inference logs deploy/inference-drift --tail=100
```

| What you see | Cause | Fix |
|---|---|---|
| `AccessDenied` | The drift IRSA role lost access | It needs read on both `datasets/` and `inference/`, plus `kms:Decrypt` |
| `no objects under s3://.../inference/` | The serving pods are not capturing inputs | This is the real finding. Investigate the capture path, not the exporter. |
| `window has only N rows` | Traffic too low for a stable index | Expected in a quiet environment; lower `window_rows` or accept it |
| Pod not running | Scheduling or image | `kubectl describe` |

---

## DriftMonitorFailing

**Severity: warning. More than two failed cycles in thirty minutes.**

Same investigation as DriftMonitorStale. The `reason` label narrows it:

- `missing_data` usually means the capture prefix is empty, which is itself worth
  investigating: the serving pods should be writing inputs there.
- `window_too_small` means traffic is too low.
- `bad_data` means a column is missing or a feature went constant.
- `unexpected` means read the traceback in the log.

The exporter deliberately does not exit on a failed cycle. An exporter that dies on a
transient S3 error takes the signal down with it and leaves the gauge reporting the
last healthy value forever.

---

## Rollback procedures

### Model rollback

The champion alias moves; nothing is rebuilt.

```bash
make rollback
```

This points `champion` at the `previous` alias and swaps them, so a second rollback
returns you to where you came from. It changes the registry only. The running pods
keep serving the artifact they already hold until you redeploy:

```
Actions tab -> ci-cd-pipeline -> Run workflow -> deploy: true
```

Keeping the registry change and the traffic change as two steps is deliberate. It
means "what is approved" and "what is serving" are two separately auditable facts.

### Application rollback

The image and configuration revert; the model version is whatever that revision
specified.

```bash
helm -n inference history inference
helm -n inference rollback inference <revision>
```

### Infrastructure rollback

There is no such command, and pretending otherwise is how an incident becomes an
outage. Revert the commit, open a pull request, read the plan comment, and apply
forward. The plan comment on the pull request is the control here: read the IAM
section first.

---

## Disaster recovery

### The MLflow database

This is the one component whose loss actually hurts: it holds the experiment history
and the record of which model version is serving production.

Protections in place: automated backups with 14 day retention, `deletion_protection`
on, `skip_final_snapshot = false`, and storage autoscaling so a runaway metric write
cannot fill the volume.

To restore:

```bash
aws rds describe-db-snapshots --db-instance-identifier <identifier> \
  --query 'DBSnapshots[].[DBSnapshotIdentifier,SnapshotCreateTime]' --output table

aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier <identifier> \
  --target-db-instance-identifier <identifier>-restored \
  --restore-time <timestamp>
```

Then update the MLflow deployment's config map to the new endpoint and roll the pods.

**What survives without it:** the artifacts. Every model is in S3 under
`models/`, versioned, with a year of noncurrent versions retained. You can serve any
of them by setting `model.s3Uri` directly in the Helm values. What you lose is the
record of which one was champion, which is why the retrain workflow writes a
version-stamped copy of the reference sample and the gate decision to S3 as well.

### The cluster

Recreate with `make apply` and redeploy. Nothing in the cluster holds state that
matters: MLflow's state is in RDS and S3, and Prometheus data is observability rather
than a system of record. Losing Prometheus loses your history, not your platform.

### The artifact bucket

Versioned, encrypted with a customer managed key, `force_destroy = false`, and a
bucket policy that denies plaintext access and writes with the wrong key. Enable
cross-region replication if your recovery objective requires surviving a region.

The KMS key has a 30 day deletion window. If someone schedules its deletion, cancel
within that window:

```bash
aws kms cancel-key-deletion --key-id <key-id>
```

After the window closes, every object in the bucket is unreadable. Permanently.

---

## Escalation

Before escalating, capture these. They are the questions the next person will ask,
and gathering them takes two minutes.

```bash
kubectl -n inference get pods,deploy,hpa -o wide            > /tmp/state.txt
kubectl -n inference exec deploy/inference-inference -c inference -- \
  curl -sf http://127.0.0.1:8080/model                      > /tmp/model.json
helm -n inference history inference                         > /tmp/history.txt
kubectl -n inference logs -l app.kubernetes.io/name=inference --tail=500 > /tmp/logs.txt
kubectl -n inference get events --sort-by=.lastTimestamp    > /tmp/events.txt
```

Plus, from Grafana, a screenshot of the full dashboard covering the period. The
lower half of it is the part nobody else will have.
