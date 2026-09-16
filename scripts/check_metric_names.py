#!/usr/bin/env python3
"""Cross-check every metric name the dashboards and alert rules query.

The failure this prevents: someone renames a metric in src/serving/metrics.py, the
tests still pass because they assert behaviour rather than names, and a Grafana
panel silently renders an empty graph while an alert silently never fires because
its query returns no series. Nothing errors anywhere. An empty panel and a
never-firing alert both look exactly like a healthy system, which is why this has
to be a build-time check and not something you notice.

Three sources are compared:

  emitted    metric names declared in src/serving/metrics.py and src/pipelines/drift.py
  recorded   recording rules defined in the chart's PrometheusRule
  queried    everything referenced by the dashboards and the alert expressions

Anything queried that is neither emitted, recorded, nor a known platform metric is
reported as a finding. Anything emitted that nothing queries is reported as a
warning: an unused metric is cardinality you are paying for with no consumer.
"""

from __future__ import annotations

import json
import re
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required")

ROOT = Path(__file__).resolve().parent.parent

SOURCE_FILES = [
    ROOT / "src" / "serving" / "metrics.py",
    ROOT / "src" / "pipelines" / "drift.py",
]
RULE_FILE = ROOT / "deploy" / "charts" / "inference" / "templates" / "prometheusrule.yaml"
DASHBOARD_DIR = ROOT / "monitoring" / "dashboards"

# The first string argument to a prometheus_client collector constructor is the
# metric name.
DECLARATION = re.compile(
    r"\b(?:Counter|Gauge|Histogram|Summary|Info|Enum)\s*\(\s*[\"']([a-zA-Z_:][a-zA-Z0-9_:]*)[\"']"
)

HELM_ACTION = re.compile(r"\{\{-?.*?-?\}\}", re.DOTALL)
IDENTIFIER = re.compile(r"[a-zA-Z_][a-zA-Z0-9_]*(?::[a-zA-Z0-9_:]+)?")
LABEL_SELECTOR = re.compile(r"\{[^{}]*\}")
GROUPING_CLAUSE = re.compile(r"\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^()]*\)")
# Range selectors and offset modifiers only. Bare numbers are deliberately left
# alone: stripping them would also strip the "5m" out of a recording rule name
# like inference:request_rate:5m and turn it into an unrecognised metric.
DURATION = re.compile(r"\[[^\]]*\]|\boffset\s+\d+[smhdwy]\b")
STRING_LITERAL = re.compile(r"\"[^\"]*\"|'[^']*'")

# Suffixes prometheus_client derives from a declared metric name. A dashboard
# querying inference_prediction_bucket is querying the inference_prediction
# histogram, and the check has to know that.
DERIVED_SUFFIXES = ("_total", "_bucket", "_sum", "_count", "_created", "_info", "_max")

# Metrics produced by the platform rather than by this repository's code. Listed
# explicitly rather than pattern-matched, so a typo in one of them is still caught.
PLATFORM_METRICS = {
    # cAdvisor, via the kubelet
    "container_cpu_usage_seconds_total",
    "container_cpu_cfs_throttled_seconds_total",
    "container_memory_working_set_bytes",
    # kube-state-metrics
    "kube_deployment_spec_replicas",
    "kube_deployment_status_replicas_ready",
    "kube_deployment_status_replicas_available",
    "kube_pod_container_resource_requests",
    "kube_pod_container_resource_limits",
    "kube_pod_container_status_restarts_total",
    "kube_pod_status_phase",
    "kube_node_status_allocatable",
    "kube_horizontalpodautoscaler_status_current_replicas",
    "kube_horizontalpodautoscaler_spec_max_replicas",
}

# PromQL functions, operators and keywords. The identifier scan cannot tell a
# function call from a metric selector on its own, so these are subtracted.
PROMQL_TOKENS = {
    "abs",
    "absent",
    "absent_over_time",
    "and",
    "avg",
    "avg_over_time",
    "bool",
    "bottomk",
    "by",
    "ceil",
    "changes",
    "clamp",
    "clamp_max",
    "clamp_min",
    "count",
    "count_over_time",
    "count_values",
    "day_of_month",
    "day_of_week",
    "day_of_year",
    "days_in_month",
    "delta",
    "deriv",
    "exp",
    "floor",
    "group",
    "group_left",
    "group_right",
    "histogram_quantile",
    "holt_winters",
    "hour",
    "idelta",
    "ignoring",
    "increase",
    "irate",
    "label_join",
    "label_replace",
    "label_values",
    "last_over_time",
    "le",
    "ln",
    "log10",
    "log2",
    "max",
    "max_over_time",
    "min",
    "min_over_time",
    "minute",
    "month",
    "offset",
    "on",
    "or",
    "predict_linear",
    "present_over_time",
    "quantile",
    "quantile_over_time",
    "rate",
    "resets",
    "round",
    "scalar",
    "sgn",
    "sort",
    "sort_desc",
    "sqrt",
    "stddev",
    "stddev_over_time",
    "stdvar",
    "sum",
    "sum_over_time",
    "time",
    "timestamp",
    "topk",
    "unless",
    "vector",
    "without",
    "year",
    "Inf",
    "NaN",
    "e",
    # What strip_helm substitutes for a template action.
    "PLACEHOLDER",
}

findings: list[str] = []
warnings: list[str] = []


def base_name(metric: str) -> str:
    for suffix in DERIVED_SUFFIXES:
        if metric.endswith(suffix):
            return metric[: -len(suffix)]
    return metric


def strip_helm(text: str) -> str:
    """Remove Helm actions, dropping lines that consist only of one."""
    lines: list[str] = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("{{") and stripped.endswith("}}"):
            continue
        if "nindent" in line or "toYaml" in line:
            continue
        lines.append(HELM_ACTION.sub("PLACEHOLDER", line))
    return "\n".join(lines)


def metric_references(expression: str) -> set[str]:
    """Identifiers in a PromQL expression that are metric or recording-rule names."""
    text = HELM_ACTION.sub(" 0 ", expression)
    text = STRING_LITERAL.sub(" ", text)
    text = GROUPING_CLAUSE.sub(" ", text)
    text = LABEL_SELECTOR.sub(" ", text)
    text = DURATION.sub(" ", text)

    found: set[str] = set()
    for match in IDENTIFIER.finditer(text):
        name = match.group(0)
        if name in PROMQL_TOKENS:
            continue
        # A function call is followed by an opening parenthesis; a metric selector
        # is not. Any grouping clause has already been removed above.
        rest = text[match.end() :].lstrip()
        if rest.startswith("("):
            continue
        found.add(name)
    return found


def walk_for_expressions(node: Any) -> Iterator[str]:
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "expr" and isinstance(value, str):
                yield value
            else:
                yield from walk_for_expressions(value)
    elif isinstance(node, list):
        for item in node:
            yield from walk_for_expressions(item)


def collect_emitted() -> set[str]:
    emitted: set[str] = set()
    for path in SOURCE_FILES:
        if not path.is_file():
            findings.append(f"{path.relative_to(ROOT)} does not exist")
            continue
        emitted |= set(DECLARATION.findall(path.read_text(encoding="utf-8")))
    return emitted


def load_rules() -> dict[str, Any]:
    if not RULE_FILE.is_file():
        findings.append(f"{RULE_FILE.relative_to(ROOT)} does not exist")
        return {}
    rendered = strip_helm(RULE_FILE.read_text(encoding="utf-8"))
    try:
        return yaml.safe_load(rendered) or {}
    except yaml.YAMLError as exc:
        findings.append(
            f"{RULE_FILE.relative_to(ROOT)} does not parse after stripping Helm actions: {exc}"
        )
        return {}


def main() -> int:
    emitted = collect_emitted()
    rules = load_rules()

    recorded: set[str] = set()
    queried: set[str] = set()

    for group in rules.get("spec", {}).get("groups", []) or []:
        for rule in group.get("rules", []) or []:
            if "record" in rule:
                recorded.add(rule["record"])

    for expression in walk_for_expressions(rules):
        queried |= metric_references(expression)

    for path in sorted(DASHBOARD_DIR.glob("*.json")):
        try:
            dashboard = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            findings.append(f"{path.relative_to(ROOT)} is not valid JSON: {exc}")
            continue
        for expression in walk_for_expressions(dashboard):
            queried |= metric_references(expression)
        for variable in dashboard.get("templating", {}).get("list", []) or []:
            query = variable.get("query")
            if isinstance(query, str) and "(" in query:
                # label_values(metric{...}, label)
                inner = query[query.index("(") + 1 : query.rindex(")")]
                queried |= metric_references(inner.split(",")[0])

    # prometheus_client appends _total to a Counter's exposed name, so both forms
    # are acceptable to a query.
    available = set(emitted) | {f"{name}_total" for name in emitted} | recorded | PLATFORM_METRICS

    for metric in sorted(queried):
        if metric in available or base_name(metric) in available:
            continue
        findings.append(
            f"queried but never emitted or recorded: {metric}. A panel or alert using "
            "it returns no series, which looks identical to a healthy system."
        )

    queried_bases = {base_name(reference) for reference in queried} | queried
    for metric in sorted(emitted):
        if metric not in queried_bases:
            warnings.append(
                f"emitted but never queried: {metric}. That is cardinality with no consumer."
            )

    print(f"emitted:  {len(emitted)}")
    print(f"recorded: {len(recorded)}")
    print(f"queried:  {len(queried)}")

    if warnings:
        print(f"\n{len(warnings)} warning(s):")
        for warning in warnings:
            print(f"  {warning}")

    if findings:
        print(f"\n{len(findings)} finding(s):")
        for finding in findings:
            print(f"  {finding}")
        return 1

    print("\nno findings: every queried metric is emitted or recorded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
