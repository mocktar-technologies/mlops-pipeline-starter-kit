"""Command line entry point for the training and promotion pipeline.

One binary, explicit subcommands, no hidden coupling between them. In particular
`train` never promotes: it trains, exports, logs and registers a challenger, then
writes gate.json and exits with a status that says whether the gate passed. The
CI workflow reads that file and decides whether to run `promote`, which is a
separate command that a human can also run.

Exit codes, because a pipeline consumes them:

  0   the command succeeded and, for train, the gate passed
  2   the command succeeded but the gate held the model back. This is not an
      error: a scheduled retrain that produced a worse model and refused to
      promote it did its job. A workflow that treats it as a failure will page
      somebody every week for correct behaviour.
  1   something actually went wrong
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path

from pipelines import registry
from pipelines.config import RuntimeEnv, load_config

logger = logging.getLogger("pipelines")

EXIT_OK = 0
EXIT_FAILURE = 1
EXIT_GATE_HELD = 2

DEFAULT_CONFIG = "pipelines/config.yaml"


def _configure_logging() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)-7s %(name)s %(message)s",
    )


def _command_train(args: argparse.Namespace) -> int:
    # Imported inside the command so that `pipelines rollback` does not need
    # torch on the path. The rollback path has to work from the smallest possible
    # image during an incident.
    from pipelines import gate, tracking
    from pipelines.data import load_dataset
    from pipelines.train import train

    config = load_config(args.config)
    env = RuntimeEnv.from_environment()
    output = Path(args.output_dir)

    dataset = load_dataset(config.data)
    result = train(config, output, dataset=dataset)

    # Write the reference sample the drift exporter compares against. It has to
    # come from the split the model actually learned from, which is why it is
    # written here and not by a separate job that might read a different window.
    reference_path = output / "reference_sample.csv"
    _write_reference(dataset, reference_path)

    tracking.configure(env, experiment=args.experiment)
    run_id = tracking.log_run(
        config,
        env,
        result,
        run_name=args.run_name or f"{config.model_name}-{env.git_sha[:8]}",
        extra_tags={"trigger": args.trigger},
    )

    champion_dir = output / "champion"
    champion_onnx = tracking.download_champion_onnx(
        config.model_name, registry.ALIAS_CHAMPION, champion_dir
    )

    decision = gate.decide(
        config.gate,
        test_split=dataset.test,
        challenger_onnx=result.onnx_path,
        champion_onnx=champion_onnx,
    )

    version = registry.register_candidate(
        tracking.model_uri_for_run(run_id),
        config.model_name,
        tags={
            "git_sha": env.git_sha,
            "gate_metric": decision.metric,
            "gate_value": f"{decision.challenger_value:.6f}",
            "gate_passed": str(decision.promote).lower(),
            "trigger": args.trigger,
        },
    )

    payload = {
        **decision.as_dict(),
        "model_name": config.model_name,
        "model_version": version,
        "run_id": run_id,
        "onnx_path": str(result.onnx_path),
        "reference_sample": str(reference_path),
        "git_sha": env.git_sha,
    }
    gate_file = output / "gate.json"
    gate_file.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    logger.info("wrote %s", gate_file)
    print(decision.summary)

    if not decision.promote:
        logger.warning("the gate held version %s back; nothing was promoted", version)
        if args.exit_zero_on_hold:
            # For a runner that treats any non-zero exit as a failed job, which is
            # how SageMaker and most batch schedulers behave. A gate that correctly
            # refused a worse model is not a failure, and a pipeline that pages
            # someone for it every week teaches them to ignore the page. gate.json
            # is the interface; the exit code is a convenience.
            logger.info(
                "exiting 0 because --exit-zero-on-hold was set; read gate.json for the decision"
            )
            return EXIT_OK
        return EXIT_GATE_HELD
    return EXIT_OK


def _write_reference(dataset, path: Path) -> None:
    import pandas as pd

    from contract.features import FEATURE_NAMES

    frame = pd.DataFrame(dataset.train.features, columns=list(FEATURE_NAMES))
    path.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(path, index=False)
    logger.info("wrote drift reference sample with %d rows to %s", len(frame), path)


def _command_promote(args: argparse.Namespace) -> int:
    config = load_config(args.config)
    env = RuntimeEnv.from_environment()

    import mlflow

    mlflow.set_tracking_uri(env.tracking_uri)

    version = args.version
    if version is None:
        gate_file = Path(args.gate_file)
        if not gate_file.is_file():
            logger.error("no --version given and %s does not exist", gate_file)
            return EXIT_FAILURE
        payload = json.loads(gate_file.read_text(encoding="utf-8"))
        if not payload.get("promote"):
            # Refusing here as well as in the workflow is deliberate. The
            # workflow condition can be edited by anyone with repository write
            # access; this check travels with the code.
            logger.error(
                "%s records promote=false (%s). Refusing to promote.",
                gate_file,
                payload.get("summary"),
            )
            return EXIT_GATE_HELD
        version = str(payload["model_version"])

    aliases = registry.promote(config.model_name, version)
    print(json.dumps(aliases, sort_keys=True))
    return EXIT_OK


def _command_rollback(args: argparse.Namespace) -> int:
    config = load_config(args.config)
    env = RuntimeEnv.from_environment()

    import mlflow

    mlflow.set_tracking_uri(env.tracking_uri)

    version = registry.rollback(config.model_name)
    print(version)
    return EXIT_OK


def _command_resolve(args: argparse.Namespace) -> int:
    """Print the version behind an alias. Used by the deploy job."""
    config = load_config(args.config)
    env = RuntimeEnv.from_environment()

    import mlflow

    mlflow.set_tracking_uri(env.tracking_uri)

    version = registry.current_version_for_alias(config.model_name, args.alias)
    if version is None:
        logger.error("alias %r is not set on %s", args.alias, config.model_name)
        return EXIT_FAILURE
    print(version)
    return EXIT_OK


def _command_drift(args: argparse.Namespace) -> int:
    from pipelines.drift import run_once, serve

    config = load_config(args.config)
    if args.once:
        report = run_once(args.reference_uri, args.window_uri, config.drift)
        feature, value = report.worst
        print(json.dumps({"worst_feature": feature, "psi": value, **report.per_feature}, indent=2))
        return EXIT_OK if value < config.drift.alert_threshold else EXIT_GATE_HELD
    return serve(args.reference_uri, args.window_uri, config.drift, port=args.port)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pipelines", description=__doc__)
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="path to config.yaml")
    subparsers = parser.add_subparsers(dest="command", required=True)

    train_parser = subparsers.add_parser(
        "train", help="train, export, evaluate, register a challenger and run the gate"
    )
    train_parser.add_argument("--output-dir", default="artifacts")
    train_parser.add_argument("--experiment", default="demand-forecast")
    train_parser.add_argument("--run-name", default=None)
    train_parser.add_argument(
        "--trigger",
        default="manual",
        choices=("manual", "schedule", "drift", "data", "code"),
        help="recorded as a tag so the run list shows why a model exists",
    )
    train_parser.add_argument(
        "--exit-zero-on-hold",
        action="store_true",
        help=(
            "exit 0 even when the gate holds the model back. Use this on a runner "
            "that treats a non-zero exit as a failed job, and read the decision "
            "from gate.json instead"
        ),
    )
    train_parser.set_defaults(handler=_command_train)

    promote_parser = subparsers.add_parser(
        "promote", help="move the champion alias to a version that passed the gate"
    )
    promote_parser.add_argument("--version", default=None)
    promote_parser.add_argument("--gate-file", default="artifacts/gate.json")
    promote_parser.set_defaults(handler=_command_promote)

    rollback_parser = subparsers.add_parser(
        "rollback", help="point the champion alias back at the previous version"
    )
    rollback_parser.set_defaults(handler=_command_rollback)

    resolve_parser = subparsers.add_parser("resolve", help="print the version behind an alias")
    resolve_parser.add_argument("--alias", default=registry.ALIAS_CHAMPION)
    resolve_parser.set_defaults(handler=_command_resolve)

    drift_parser = subparsers.add_parser("drift", help="compute drift once, or run the exporter")
    drift_parser.add_argument("--reference-uri", required=True)
    drift_parser.add_argument("--window-uri", required=True)
    drift_parser.add_argument("--once", action="store_true")
    drift_parser.add_argument("--port", type=int, default=9102)
    drift_parser.set_defaults(handler=_command_drift)

    return parser


def main(argv: list[str] | None = None) -> int:
    _configure_logging()
    args = build_parser().parse_args(argv)
    try:
        return int(args.handler(args))
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        logger.error("%s failed: %s", args.command, exc)
        logger.debug("traceback", exc_info=True)
        return EXIT_FAILURE


if __name__ == "__main__":
    sys.exit(main())
