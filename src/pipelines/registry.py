"""Model registry operations.

Aliases, not stages. MLflow deprecated model registry stages in 2.9.0 and the
3.16.0 client still carries the deprecation warning verbatim: "Model registry
stages will be removed in a future major release." Writing new code against
stages means writing code you will have to migrate. Aliases also express the
thing you actually want: `champion` is a movable pointer to whichever version is
serving, and moving a pointer is an atomic, auditable, reversible operation.

Three aliases are used, and the separation between them is the whole point:

  challenger  a version that passed training and export checks and is waiting for
              a promotion decision. Registering does not deploy.
  champion    the version serving production traffic. Only the promote step moves
              this, and only after the gate returns promote=True.
  previous    where champion pointed before the last promotion. This is the
              rollback target, and having it recorded explicitly means a rollback
              is one command rather than an archaeology exercise in the run list.
"""

from __future__ import annotations

import logging

from mlflow import MlflowClient
from mlflow.exceptions import MlflowException
from mlflow.tracking._model_registry import fluent as registry_fluent

logger = logging.getLogger(__name__)

ALIAS_CHALLENGER = "challenger"
ALIAS_CHAMPION = "champion"
ALIAS_PREVIOUS = "previous"


def register_candidate(
    model_uri: str,
    model_name: str,
    tags: dict[str, str] | None = None,
) -> str:
    """Register a run's model artifact as a new version and tag it challenger.

    Returns the new version number as a string, which is how the MLflow registry
    identifies versions.
    """
    version = registry_fluent.register_model(model_uri, model_name, tags=tags or {})
    client = MlflowClient()
    client.set_registered_model_alias(model_name, ALIAS_CHALLENGER, version.version)
    logger.info(
        "registered %s version %s from %s and set alias %r",
        model_name,
        version.version,
        model_uri,
        ALIAS_CHALLENGER,
    )
    return str(version.version)


def current_version_for_alias(model_name: str, alias: str) -> str | None:
    """Return the version an alias points to, or None when the alias is unset."""
    try:
        return str(MlflowClient().get_model_version_by_alias(model_name, alias).version)
    except MlflowException as exc:
        logger.info("alias %r is not set on %s (%s)", alias, model_name, exc.message)
        return None


def promote(model_name: str, version: str) -> dict[str, str | None]:
    """Move champion to `version`, recording the outgoing version as previous.

    The order matters. `previous` is written before `champion` moves, so an
    interruption between the two calls leaves you able to identify the version
    that was serving. Writing champion first and previous second would, if it
    failed in between, leave no record of what to roll back to.
    """
    client = MlflowClient()
    outgoing = current_version_for_alias(model_name, ALIAS_CHAMPION)

    if outgoing == version:
        logger.info("%s version %s is already champion, nothing to do", model_name, version)
        return {
            "champion": version,
            "previous": current_version_for_alias(model_name, ALIAS_PREVIOUS),
        }

    if outgoing is not None:
        client.set_registered_model_alias(model_name, ALIAS_PREVIOUS, outgoing)

    client.set_registered_model_alias(model_name, ALIAS_CHAMPION, version)
    logger.info(
        "promoted %s version %s to %r (previous=%s)",
        model_name,
        version,
        ALIAS_CHAMPION,
        outgoing,
    )
    return {"champion": version, "previous": outgoing}


def rollback(model_name: str) -> str:
    """Point champion back at the previous version.

    This is deliberately not a generic "set champion to any version" helper. In
    an incident you want one command with no arguments to get wrong. Choosing an
    arbitrary version is a separate, slower decision made from the run list.
    """
    previous = current_version_for_alias(model_name, ALIAS_PREVIOUS)
    if previous is None:
        raise RuntimeError(
            f"{model_name} has no {ALIAS_PREVIOUS!r} alias, so there is no recorded "
            "rollback target. Pick a version from the registry and set the champion "
            "alias explicitly."
        )
    current = current_version_for_alias(model_name, ALIAS_CHAMPION)
    client = MlflowClient()
    client.set_registered_model_alias(model_name, ALIAS_CHAMPION, previous)
    if current is not None:
        # Swap, so a second rollback returns to where you just came from rather
        # than getting stuck.
        client.set_registered_model_alias(model_name, ALIAS_PREVIOUS, current)
    logger.warning("rolled back %s champion to version %s", model_name, previous)
    return previous
