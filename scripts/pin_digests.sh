#!/usr/bin/env bash
#
# Resolve the base image tag in each Dockerfile to a digest and rewrite the file.
#
# Why: a tag is a mutable pointer maintained by someone else. python:3.12-slim-trixie
# today and python:3.12-slim-trixie in six weeks are different images with different
# packages and different vulnerabilities. Until the FROM line names a digest, the
# image you rebuild is not the image you tested, and "what is running in production"
# has no answer you can verify.
#
# Run this before promoting to staging or production, commit the result, and let
# Renovate raise the pull request that moves the digest forward.
#
# Usage:
#   scripts/pin_digests.sh [--check]
#
#   --check  report whether any Dockerfile is still tag-pinned and exit non-zero,
#            without modifying anything. Useful as a CI gate for a release branch.

set -euo pipefail

CHECK_ONLY=false
if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
fi

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

UNPINNED=0

for dockerfile in docker/*.Dockerfile; do
  # The base image comes from an ARG, so read that rather than the FROM line.
  line="$(grep -E '^ARG BASE_IMAGE=' "$dockerfile" || true)"
  if [[ -z "$line" ]]; then
    echo "${dockerfile}: no ARG BASE_IMAGE, skipping"
    continue
  fi

  value="${line#ARG BASE_IMAGE=}"
  if [[ "$value" == *"@sha256:"* ]]; then
    echo "${dockerfile}: already digest-pinned"
    continue
  fi

  UNPINNED=$((UNPINNED + 1))

  if [[ "$CHECK_ONLY" == true ]]; then
    echo "${dockerfile}: still pinned to a tag (${value})"
    continue
  fi

  # Expand ${PYTHON_VERSION} from the sibling ARG so the reference is concrete.
  python_version="$(grep -E '^ARG PYTHON_VERSION=' "$dockerfile" | cut -d= -f2)"
  reference="${value//\$\{PYTHON_VERSION\}/$python_version}"

  echo "${dockerfile}: resolving ${reference}"
  docker pull --quiet "$reference" >/dev/null

  digest="$(docker image inspect "$reference" --format '{{index .RepoDigests 0}}' | cut -d@ -f2)"
  if [[ -z "$digest" ]]; then
    echo "  could not resolve a digest. An image built locally and never pushed has no RepoDigest." >&2
    exit 1
  fi

  repository="${reference%%:*}"
  pinned="${repository}@${digest}"

  # Keep the tag in a comment. A bare digest tells a reviewer nothing about which
  # version it is, which is the same problem as an unannotated action SHA.
  tmp="$(mktemp)"
  awk -v pinned="$pinned" -v original="$reference" '
    /^ARG BASE_IMAGE=/ {
      print "# Digest-pinned from " original " by scripts/pin_digests.sh."
      print "# Renovate will raise a pull request when a newer digest is published."
      print "ARG BASE_IMAGE=" pinned
      next
    }
    { print }
  ' "$dockerfile" > "$tmp"
  mv "$tmp" "$dockerfile"
  echo "  pinned to ${digest}"
done

if [[ "$CHECK_ONLY" == true && "$UNPINNED" -gt 0 ]]; then
  echo
  echo "${UNPINNED} Dockerfile(s) are pinned to a mutable tag." >&2
  echo "Run scripts/pin_digests.sh without --check, then commit the result." >&2
  exit 1
fi

echo
echo "done. Review the diff, then rebuild so the lock and the image agree."
