#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-manifest-workspace.sh <profile-json> <workspace-dir>

Initializes an ACK workspace from https://android.googlesource.com/kernel/manifest,
copies manifests/coreshift-overlay.xml into .repo/local_manifests/,
syncs the manifest checkout, then clones the requested kernel/common
source branch into common/.
EOF
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 1
fi

for tool in git python3 repo; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_JSON="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
WORKSPACE_DIR="$2"
OVERLAY_SOURCE="$REPO_ROOT/manifests/coreshift-overlay.xml"
MANIFEST_URL="https://android.googlesource.com/kernel/manifest"
KERNEL_COMMON_URL="https://android.googlesource.com/kernel/common"

if [ ! -f "$PROFILE_JSON" ]; then
  echo "Profile not found: $PROFILE_JSON" >&2
  exit 1
fi

if [ ! -f "$OVERLAY_SOURCE" ]; then
  echo "Overlay manifest not found: $OVERLAY_SOURCE" >&2
  exit 1
fi

eval "$(
  python3 - "$PROFILE_JSON" <<'PY'
import json
import shlex
import sys

profile_path = sys.argv[1]

with open(profile_path, encoding="utf-8") as fh:
    profile = json.load(fh)

for field in ("manifest_branch", "kernel_source_branch"):
    value = profile.get(field)
    if not isinstance(value, str) or not value:
        raise SystemExit(
            f"{profile_path}: profile field {field!r} must be a non-empty string"
        )
    print(f"{field.upper()}={shlex.quote(value)}")
PY
)"

mkdir -p "$WORKSPACE_DIR"
WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"

(
  cd "$WORKSPACE_DIR"

  if [ -e .repo ] && [ ! -d .repo ]; then
    echo "Workspace has a non-directory .repo entry: $WORKSPACE_DIR" >&2
    exit 1
  fi

  repo init \
    -u "$MANIFEST_URL" \
    -b "$MANIFEST_BRANCH" \
    --depth=1

  mkdir -p .repo/local_manifests
  cp "$OVERLAY_SOURCE" .repo/local_manifests/coreshift-overlay.xml

  if [ ! -f .repo/local_manifests/coreshift-overlay.xml ]; then
    echo "Failed to install local manifest overlay in workspace: $WORKSPACE_DIR" >&2
    exit 1
  fi

  repo sync \
    -c \
    --fail-fast \
    --no-clone-bundle \
    --no-tags \
    -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)"

  rm -rf common
  git clone \
    --depth=1 \
    --branch "$KERNEL_SOURCE_BRANCH" \
    "$KERNEL_COMMON_URL" \
    common

  if [ ! -d common/.git ]; then
    echo "Failed to clone kernel/common branch $KERNEL_SOURCE_BRANCH into $WORKSPACE_DIR/common" >&2
    exit 1
  fi
)
