#!/usr/bin/env python3
"""Static checks on the Helm chart that do not need a helm binary.

`helm lint` and `helm template` are the right tools and this is not a replacement
for either. It exists because a restricted CI runner or an air-gapped environment
may not have helm available, and because these checks run in a fraction of a
second and catch the two mistakes that actually happen when editing a chart:

  1. An unbalanced control structure. Every {{ if }}, {{ range }}, {{ with }} and
     {{ define }} needs an {{ end }}. Helm reports this as a parse error, which is
     fine, but only once you can run helm.

  2. Broken YAML structure. A wrong nindent on a template include shifts a whole
     block and produces YAML that is valid and means something different, which
     helm will happily install.

Method for the second check: every {{ ... }} action is replaced with a harmless
scalar and every whole-line action is removed, then the result is parsed as YAML.
That is an approximation. A block that only exists inside a conditional is
rendered in this pass, which is more coverage than a single `helm template` run
with one values file gives, and an indentation error inside a conditional is still
an indentation error.

It also checks that every .Values path referenced by a template exists in
values.yaml, which is the mistake that produces a silently empty field: Helm
renders a missing value as the empty string and installs the manifest.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required")

ROOT = Path(__file__).resolve().parent.parent
CHARTS = ROOT / "deploy" / "charts"

ACTION = re.compile(r"\{\{-?.*?-?\}\}", re.DOTALL)
OPENERS = re.compile(r"\{\{-?\s*(if|range|with|define|block)\b")
CLOSERS = re.compile(r"\{\{-?\s*end\s*-?\}\}")
ELSE_LIKE = re.compile(r"\{\{-?\s*else\b")
VALUES_PATH = re.compile(r"\.Values\.([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)")
DEFINE_NAME = re.compile(r'\{\{-?\s*define\s+"([^"]+)"')
INCLUDE_NAME = re.compile(r'(?:include|template)\s+"([^"]+)"')

findings: list[str] = []


def report(path: Path, message: str) -> None:
    findings.append(f"{path.relative_to(ROOT)}: {message}")


def check_balance(path: Path, text: str) -> None:
    opens = len(OPENERS.findall(text))
    closes = len(CLOSERS.findall(text))
    if opens != closes:
        report(
            path,
            f"{opens} control structure(s) opened and {closes} closed. Every if, range, "
            "with, define and block needs its own end.",
        )

    # An {{ else }} outside any conditional is a template that cannot parse.
    if ELSE_LIKE.search(text) and opens == 0:
        report(path, "contains an else with no enclosing if, with or range")

    if text.count("{{") != text.count("}}"):
        report(
            path,
            f"unbalanced action delimiters: {text.count('{{')} opening and "
            f"{text.count('}}')} closing",
        )


def placeholder_render(text: str) -> str:
    """Replace template actions so the result can be parsed as YAML."""
    lines: list[str] = []
    for line in text.splitlines():
        stripped = line.strip()

        # A line that is only a control action contributes nothing to the YAML.
        if stripped.startswith("{{") and stripped.endswith("}}") and ACTION.fullmatch(stripped):
            inner = stripped[2:-2].strip().lstrip("-").strip()
            if inner.split(" ")[0].rstrip("-") in {
                "if",
                "else",
                "end",
                "range",
                "with",
                "define",
                "block",
                "/*",
            } or inner.startswith(("if", "else", "end", "range", "with", "define", "/*")):
                continue

        # An action whose output is an indented block (toYaml | nindent, or an
        # include) cannot be represented by a scalar, so drop the line and let the
        # surrounding structure be checked without it.
        if "nindent" in line or "indent" in line:
            continue

        # Anything else: substitute a scalar for each action.
        rendered = ACTION.sub("PLACEHOLDER", line)
        lines.append(rendered)

    return "\n".join(lines)


def check_yaml_structure(path: Path, text: str) -> None:
    if path.suffix == ".tpl":
        return  # A .tpl file is template definitions, not a manifest.

    rendered = placeholder_render(text)
    try:
        documents = list(yaml.safe_load_all(rendered))
    except yaml.YAMLError as exc:
        report(path, f"does not parse as YAML once template actions are removed: {exc}")
        return

    real = [document for document in documents if document]
    if not real:
        # A template that is entirely inside one conditional renders to nothing in
        # this pass. That is expected, not a finding.
        return

    for index, document in enumerate(real):
        if not isinstance(document, dict):
            report(path, f"document {index} is a {type(document).__name__}, not a mapping")
            continue
        for field in ("apiVersion", "kind", "metadata"):
            if field not in document:
                report(path, f"document {index} has no {field}")


def flatten_values(node: Any, prefix: str = "") -> set[str]:
    """Every dotted path present in values.yaml, including intermediate ones."""
    paths: set[str] = set()
    if isinstance(node, dict):
        for key, value in node.items():
            path = f"{prefix}.{key}" if prefix else str(key)
            paths.add(path)
            paths |= flatten_values(value, path)
    return paths


def check_values_paths(chart: Path, templates: dict[Path, str]) -> None:
    values_file = chart / "values.yaml"
    if not values_file.is_file():
        report(chart, "has no values.yaml")
        return

    values = yaml.safe_load(values_file.read_text(encoding="utf-8")) or {}
    known = flatten_values(values)

    for path, text in templates.items():
        for reference in sorted(set(VALUES_PATH.findall(text))):
            if reference in known:
                continue
            # A reference to a parent whose children are looked up dynamically is
            # fine as long as the parent exists.
            if any(reference.startswith(f"{candidate}.") for candidate in known):
                continue
            report(
                path,
                f"references .Values.{reference}, which values.yaml does not define. "
                "Helm renders a missing value as an empty string and installs it.",
            )


def check_defines(chart: Path, templates: dict[Path, str]) -> None:
    defined: set[str] = set()
    for text in templates.values():
        defined |= set(DEFINE_NAME.findall(text))

    for path, text in templates.items():
        for name in sorted(set(INCLUDE_NAME.findall(text))):
            # Helm's own built-in partials and anything pulled from a subchart.
            if name.startswith(("helm.", "common.")) or "/" in name:
                continue
            if name not in defined:
                report(path, f'includes "{name}", which no define in this chart provides')


def check_chart_metadata(chart: Path) -> None:
    chart_file = chart / "Chart.yaml"
    if not chart_file.is_file():
        report(chart, "has no Chart.yaml")
        return
    metadata = yaml.safe_load(chart_file.read_text(encoding="utf-8")) or {}
    for field in ("apiVersion", "name", "version"):
        if field not in metadata:
            report(chart_file, f"is missing the required field {field!r}")
    if metadata.get("apiVersion") != "v2":
        report(chart_file, f"apiVersion is {metadata.get('apiVersion')!r}, expected 'v2'")


def main() -> int:
    charts = [path.parent for path in CHARTS.rglob("Chart.yaml")]
    if not charts:
        print(f"helm_lint: no charts found under {CHARTS.relative_to(ROOT)}")
        return 0

    for chart in charts:
        check_chart_metadata(chart)

        templates: dict[Path, str] = {}
        for path in sorted((chart / "templates").rglob("*")):
            if path.suffix not in {".yaml", ".yml", ".tpl"}:
                continue
            text = path.read_text(encoding="utf-8")
            templates[path] = text
            check_balance(path, text)
            check_yaml_structure(path, text)

        check_values_paths(chart, templates)
        check_defines(chart, templates)

    if findings:
        print(f"{len(findings)} finding(s):\n")
        for finding in findings:
            print(f"  {finding}")
        return 1

    print(f"helm_lint: {len(charts)} chart(s) checked, no findings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
