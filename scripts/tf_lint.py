#!/usr/bin/env python3
"""Static checks on the Terraform in this repository that `fmt` cannot make.

`terraform fmt` parses the HCL, so it catches a syntax error. It does not catch a
reference to a variable that was never declared, a module input that the module
does not accept, or an output of a module that the caller reads and the module does
not define. Those are `init`-time errors, and `init` needs network access to the
provider registry, which a locked-down CI runner or a restricted sandbox may not
have.

This script closes that gap with a parse of the configuration using python-hcl2.
It is not a substitute for `terraform validate`; it is what you can run without a
registry, and it catches the class of mistake that appears when a module is edited
and its caller is not.

Checks:
  1. Every var.X referenced in a directory is declared in that directory.
  2. Every declared variable is used somewhere in its directory (an unused variable
     is usually a rename that was only half applied).
  3. Every local.X referenced is declared in a locals block in that directory.
  4. Every module block's arguments are declared as variables by the target module.
  5. Every required variable of a target module (no default) is supplied.
  6. Every module.NAME.OUTPUT read by a caller is declared as an output by that module.
  7. Every module block has an explicit version when its source is a registry address.

Exit code 0 when clean, 1 when any finding is reported.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

try:
    import hcl2
except ImportError:  # pragma: no cover
    sys.exit("python-hcl2 is required: pip install python-hcl2")

ROOT = Path(__file__).resolve().parent.parent
TERRAFORM = ROOT / "terraform"

VAR_REFERENCE = re.compile(r"\bvar\.([A-Za-z_][A-Za-z0-9_-]*)")
LOCAL_REFERENCE = re.compile(r"\blocal\.([A-Za-z_][A-Za-z0-9_-]*)")
MODULE_OUTPUT = re.compile(r"\bmodule\.([A-Za-z_][A-Za-z0-9_-]*)\.([A-Za-z_][A-Za-z0-9_-]*)")
REGISTRY_SOURCE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")

# Arguments accepted by every module block regardless of the module's own variables.
# The dunder names are not HCL at all: python-hcl2 8.x adds them to every block body
# to carry comment text and to mark a nested block, and they arrive looking exactly
# like an argument the module never declared.
META_ARGUMENTS = {
    "source",
    "version",
    "providers",
    "count",
    "for_each",
    "depends_on",
    "lifecycle",
    "__comments__",
    "__is_block__",
    "__start_line__",
    "__end_line__",
}

findings: list[str] = []


def report(where: Path, message: str) -> None:
    findings.append(f"{where.relative_to(ROOT)}: {message}")


def load_directory(directory: Path) -> tuple[dict[str, Any], str]:
    """Parse every .tf file in one directory into a merged dict, plus raw text."""
    merged: dict[str, list[Any]] = {}
    raw_parts: list[str] = []
    for path in sorted(directory.glob("*.tf")):
        text = path.read_text(encoding="utf-8")
        raw_parts.append(text)
        try:
            parsed = hcl2.loads(text)
        except Exception as exc:
            report(path, f"could not parse: {exc}")
            continue
        for key, value in parsed.items():
            merged.setdefault(key, []).extend(value if isinstance(value, list) else [value])
    return merged, "\n".join(raw_parts)


def unquote(value: Any) -> str | None:
    """A plain HCL string as Python, with the quotes python-hcl2 leaves on it.

    python-hcl2 returns both block labels and string attribute values with their
    surrounding quotes intact, so `source = "../../modules/network"` arrives as the
    9-character-longer '"../../modules/network"'. Anything that compares such a value
    against a real string, or calls startswith(".") on it, silently sees no match.
    That is a lint check that reports nothing and looks like it passed, which is worse
    than not having the check, so every string value read out of the parse goes
    through here. A list arrives when the same attribute appears more than once.
    """
    if isinstance(value, list):
        value = value[0] if value else None
    if not isinstance(value, str):
        return None
    return value.strip().strip('"')


def names_from_blocks(blocks: list[Any]) -> dict[str, Any]:
    """HCL2 renders `variable "x" {...}` as {"x": {...}}; flatten a list of those.

    Some python-hcl2 versions keep the quotes around a block label, so the key
    arrives as '"x"' rather than 'x'. Stripping them here means the rest of the
    script does not have to care which version is installed.
    """
    flattened: dict[str, Any] = {}
    for block in blocks:
        if isinstance(block, dict):
            for name, body in block.items():
                flattened[name.strip('"')] = body
    return flattened


def strip_comments(text: str) -> str:
    """Remove comments so a var. reference inside prose is not counted as a use."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    lines = []
    for line in text.splitlines():
        # Only strip a comment that starts the line or follows whitespace, so a
        # "#" inside a string is left alone. Good enough for this purpose.
        lines.append(re.sub(r"(^|\s)(#|//).*$", "", line))
    return "\n".join(lines)


def check_directory(directory: Path, all_modules: dict[Path, dict[str, Any]]) -> None:
    parsed, raw = load_directory(directory)
    body = strip_comments(raw)

    declared_variables = names_from_blocks(parsed.get("variable", []))
    declared_locals: set[str] = set()
    for block in parsed.get("locals", []):
        if isinstance(block, dict):
            declared_locals.update(block.keys())

    # 1. var.X must be declared.
    referenced_variables = set(VAR_REFERENCE.findall(body))
    for name in sorted(referenced_variables - set(declared_variables)):
        report(directory, f"references var.{name}, which is not declared here")

    # 2. every declared variable should be used.
    for name in sorted(set(declared_variables) - referenced_variables):
        report(directory, f"declares variable {name!r} and never uses it")

    # 3. local.X must be declared.
    for name in sorted(set(LOCAL_REFERENCE.findall(body)) - declared_locals):
        report(directory, f"references local.{name}, which is not declared here")

    # 4, 5, 7. module blocks.
    module_blocks = names_from_blocks(parsed.get("module", []))
    local_module_targets: dict[str, Path] = {}

    for module_name, module_body in module_blocks.items():
        source = unquote(module_body.get("source"))
        if source is None:
            report(directory, f"module {module_name!r} has no source")
            continue

        if REGISTRY_SOURCE.match(source) and "version" not in module_body:
            report(
                directory,
                f"module {module_name!r} uses registry source {source!r} with no version "
                "constraint, so an upstream release changes your infrastructure",
            )

        if not source.startswith("."):
            continue

        target = (directory / source).resolve()
        if target not in all_modules:
            report(
                directory, f"module {module_name!r} points at {source!r}, which has no .tf files"
            )
            # Deliberately not recorded in local_module_targets: check 6 below reads
            # all_modules[target], and recording an absent target here turns a clean
            # finding into a KeyError that takes the whole lint down.
            continue

        local_module_targets[module_name] = target
        target_variables = all_modules[target]["variables"]
        supplied = {key for key in module_body if key not in META_ARGUMENTS}

        for argument in sorted(supplied - set(target_variables)):
            report(
                directory,
                f"module {module_name!r} passes {argument!r}, which "
                f"{target.relative_to(ROOT)} does not declare",
            )

        required = {
            name for name, spec in target_variables.items() if "default" not in (spec or {})
        }
        for argument in sorted(required - supplied):
            report(
                directory,
                f"module {module_name!r} does not supply required input {argument!r} of "
                f"{target.relative_to(ROOT)}",
            )

    # 6. module.NAME.OUTPUT must exist.
    for module_name, output_name in sorted(set(MODULE_OUTPUT.findall(body))):
        reader_target = local_module_targets.get(module_name)
        if reader_target is None or reader_target not in all_modules:
            # Either a registry module, whose outputs we cannot see without a
            # download, a module declared in another directory, or one already
            # reported above as missing.
            continue
        declared_outputs = all_modules[reader_target]["outputs"]
        if output_name not in declared_outputs:
            report(
                directory,
                f"reads module.{module_name}.{output_name}, which "
                f"{reader_target.relative_to(ROOT)} does not output",
            )


def main() -> int:
    directories = sorted({path.parent for path in TERRAFORM.rglob("*.tf")})

    all_modules: dict[Path, dict[str, Any]] = {}
    for directory in directories:
        parsed, _ = load_directory(directory)
        all_modules[directory.resolve()] = {
            "variables": names_from_blocks(parsed.get("variable", [])),
            "outputs": names_from_blocks(parsed.get("output", [])),
        }

    for directory in directories:
        check_directory(directory, all_modules)

    if findings:
        print(f"{len(findings)} finding(s):\n")
        for finding in findings:
            print(f"  {finding}")
        return 1

    print(f"tf_lint: {len(directories)} directories checked, no findings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
