#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: scripts/commit-workspace-changes.sh <workspace-dir> [message]" >&2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 1
fi

WORKSPACE_DIR="$1"
MESSAGE="${2:-CoreShift: prepare build workspace}"
COMMON_DIR="$WORKSPACE_DIR/common"

if [ ! -d "$WORKSPACE_DIR" ]; then
  echo "Workspace directory not found: $WORKSPACE_DIR" >&2
  exit 1
fi

if [ ! -d "$COMMON_DIR" ]; then
  echo "Workspace common directory not found: $COMMON_DIR" >&2
  exit 1
fi

if ! git -C "$COMMON_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Warning: common workspace is not a git repo, skipping workspace commit: $COMMON_DIR" >&2
  exit 0
fi

git -C "$COMMON_DIR" config user.name "CoreShift Builder"
git -C "$COMMON_DIR" config user.email "coreshift-builder@localhost"

git -C "$COMMON_DIR" add -A -- . \
  ":(exclude)out/" \
  ":(exclude)dist/" \
  ":(exclude).packaging/"

if ! git -C "$COMMON_DIR" diff --cached --quiet; then
  git -C "$COMMON_DIR" commit -m "$MESSAGE"
else
  echo "No workspace changes to commit"
fi

git -C "$COMMON_DIR" status --short -- . \
  ":(exclude)out/" \
  ":(exclude)dist/" \
  ":(exclude).packaging/"
git -C "$COMMON_DIR" rev-parse --short HEAD
