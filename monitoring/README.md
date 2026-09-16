# Monitoring

Where each piece of the observability stack is defined, and how the alert routing
works. The short version: dashboards live here, alert rules live with the workload,
and Alertmanager routing lives in Terraform.

## Where things are defined, and why there

| Thing | Where | Why there |
|---|---|---|
| Prometheus, Alertmanager, Grafana | `terraform/modules/observability` | It installs the operator CRDs, so it must exist before any ServiceMonitor |
| Grafana dashboards | `monitoring/dashboards/*.json` | Loaded as ConfigMaps by that module. Editable in Grafana and exportable back |
| ServiceMonitor and PrometheusRule | `deploy/charts/inference/templates` | They belong to the workload. A team shipping a service should ship its own alerts |
| Alertmanager routing and inhibition | `terraform/modules/observability` | Platform policy, not workload policy |
| Metric definitions | `src/serving/metrics.py`, `src/pipelines/drift.py` | One definition per name, checked by `scripts/check_metric_names.py` |

Nothing is duplicated between these. That is deliberate: a metric name written in two
places eventually differs in one of them, and the symptom is an empty panel rather
than an error.

## The one setting that decides whether any of this works

```
prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues: false
```

Left at its default of `true`, Prometheus only discovers ServiceMonitors carrying the
kube-prometheus-stack release's own label. A ServiceMonitor created by a different
chart, which is every workload chart, is silently ignored. Nothing errors. The target
never appears, the panels stay empty, and the alerts never fire because their queries
return no series.

This single value is the most common reason a team believes their model metrics are
being collected when they are not. The same applies to `podMonitorSelector...`,
`ruleSelector...` and `probeSelector...`, and all four are set in the module.

To check, rather than assume:

```bash
make verify                     # check 4 and check 5 cover exactly this
# or by hand:
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# then open http://localhost:9090/targets and look for inference
```

## Alert routing

Three principles, implemented in the Alertmanager config in the observability module.

**Group, do not enumerate.** Alerts are grouped by `alertname`, `namespace` and
`severity`. Without grouping, a node failure that trips twelve rules sends twelve
notifications and the one that matters is the eleventh.

**Inhibit consequences.** When `InferenceModelNotLoaded` fires, the latency and error
rules for the same service will fire too. The inhibition rule suppresses them, so the
cause stays at the top of the notification rather than being pushed down by its own
symptoms.

**Drift is not a page.** `ModelDriftCritical` is a warning with a two-hour `for`
clause, routed to its own receiver with a 24 hour repeat interval. It needs a decision
within a working day. Paging someone at 3 a.m. for a distribution shift teaches them
to ignore the channel, and then the pages that matter go unread too.

### Severity, and what it means here

| Severity | Meaning | Alerts |
|---|---|---|
| critical | wake someone | ModelNotLoaded, HighErrorRate, PredictionClamped |
| warning | working hours | LatencyHigh, InputRejectionSpike, PredictionDistributionShift, all drift alerts, all monitor-health alerts |

`InferencePredictionClamped` is critical and should never fire. The exported graph
cannot produce a value outside the bounds, so a clamp means the artifact in the pod is
not the model the service was written for, and predictions may have been wrong before
the clamp caught them.

## Receivers

The module creates two receivers with no notification configuration, because where
your alerts should go is an organisational decision this repository cannot make.

```
default                a placeholder. Wire it to your paging tool
drift-notifications    a placeholder. Wire it to a chat channel, not a pager
retrain-webhook        optional, see below
```

To wire them up, set the receiver configuration through the module's Helm values. Keep
the URL or the routing key in a Kubernetes Secret and reference it with the `_file`
form of the setting, never as a literal: a literal lands in Terraform state and in git.

```yaml
# The pattern, using the file form for anything secret.
receivers:
  - name: default
    slack_configs:
      - api_url_file: /etc/alertmanager/secrets/slack/url
        channel: "#ml-platform-alerts"
```

## The retrain webhook

Off by default. Set `enable_retrain_webhook = true` and the module routes
`ModelDriftCritical` to a webhook that opens a retraining run.

This is safe to enable, and it is worth understanding exactly why before you do.

The webhook starts a pipeline. It cannot promote anything. Between the alert and any
change in what serves traffic there are still three separate barriers:

1. The training job registers a **challenger**. The champion alias does not move.
2. The **promotion gate** compares the challenger against the champion on the same
   held-out data and requires the improvement to exceed the metric's own bootstrap
   noise. A worse model, or a model whose improvement is inside the noise, is held.
3. The **promote job** runs in a GitHub environment that can require a named reviewer.

So the worst case of a spurious drift alert is a wasted training job, not a bad
deploy. That property is what makes closing the loop acceptable; without the gate it
would be an automated way to make production worse on a schedule.

### Setting it up

Create a fine-grained GitHub token with `repository_dispatch` permission on this
repository only, then:

```bash
kubectl -n monitoring create secret generic retrain-webhook \
  --from-literal=url="https://api.github.com/repos/OWNER/REPO/dispatches"
```

The GitHub dispatch API needs an `Authorization` header, which Alertmanager's webhook
receiver cannot set. Two workable shapes:

- Put a small relay in the cluster that holds the token and translates an Alertmanager
  webhook into a `repository_dispatch` call. The token then never leaves the cluster.
- Point the webhook at your existing automation platform, if it already has a GitHub
  credential and an audit trail.

Either way the token goes in a Secret, and the receiver references the URL with
`url_file`. Do not put a token in a Terraform variable.

## Dashboards

`monitoring/dashboards/mlops-inference.json` is loaded by the observability module as a
ConfigMap labelled `grafana_dashboard: "1"`, which the Grafana sidecar watches. The
sidecar scans every namespace, so a team can ship a dashboard with their own chart
instead of editing the platform module.

The file is the source of truth. Edit it in Grafana, export the JSON, and commit it
back. There is no generator, because a generated dashboard plus a committed dashboard
is two sources of truth that eventually disagree.

Five rows, top to bottom, in deliberate order:

1. **Service level.** Is a model loaded, which version, request rate, error ratio, p99.
2. **Application.** The signals you already have for any service. The useful panel is
   total latency against model latency: when total rises and model does not, the time
   is outside the model and rolling it back changes nothing.
3. **Data.** Rejected inputs by reason, drift by feature, and drift freshness. The
   freshness panel exists because a stale drift gauge holds its last healthy value.
4. **Model.** Prediction distribution as a heatmap, mean prediction against yesterday,
   clamped predictions, batch size, predictions per second by version.
5. **Monitoring health.** Whether the monitoring is itself working.

The prediction distribution heatmap is the cheapest early warning in the stack. A model
that has quietly started predicting near zero for everything still returns 200s in
single-digit milliseconds, so rows one and two stay green. This panel moves first.

## Adding a metric

1. Declare it in `src/serving/metrics.py` or `src/pipelines/drift.py`. Nowhere else.
2. Add a bounded label set. Nothing per-request, nothing per-user.
3. Query it somewhere: a dashboard panel or an alert rule.
4. Run `python scripts/check_metric_names.py`.

Step 4 fails the build if you query a metric nothing emits, and warns if you emit a
metric nothing queries. The second is not an error and is worth reading anyway: an
unused metric is cardinality you pay for with no consumer.
