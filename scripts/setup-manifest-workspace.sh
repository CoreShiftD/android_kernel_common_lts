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
CORESHIFT_REPO_JOBS="${CORESHIFT_REPO_JOBS:-4}"
CORESHIFT_REPO_DEPTH="${CORESHIFT_REPO_DEPTH:-1}"
CORESHIFT_REPO_PARTIAL_CLONE="${CORESHIFT_REPO_PARTIAL_CLONE:-1}"
CORESHIFT_REPO_CLONE_FILTER="${CORESHIFT_REPO_CLONE_FILTER:-blob:none}"

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

repo_launcher_path="$(command -v repo)"
repo_version="$(
  repo --version 2>/dev/null | head -n 1 || true
)"

case "$CORESHIFT_REPO_PARTIAL_CLONE" in
  1)
    repo_partial_clone_enabled=1
    repo_partial_clone_label="on"
    ;;
  *)
    repo_partial_clone_enabled=0
    repo_partial_clone_label="off"
    ;;
esac

echo "Manifest workspace setup:"
echo "  repo launcher path: $repo_launcher_path"
echo "  repo version: ${repo_version:-unknown}"
echo "  manifest branch: $MANIFEST_BRANCH"
echo "  kernel source branch: $KERNEL_SOURCE_BRANCH"
echo "  repo jobs: $CORESHIFT_REPO_JOBS"
echo "  partial clone: $repo_partial_clone_label"
echo "  clone filter: $CORESHIFT_REPO_CLONE_FILTER"
echo "  workspace path: $WORKSPACE_DIR"

(
  cd "$WORKSPACE_DIR"

  repo_init_log="$(mktemp)"
  repo_sync_log="$(mktemp)"
  cleanup_logs() {
    rm -f "$repo_init_log" "$repo_sync_log"
  }
  trap cleanup_logs EXIT

  if [ -e .repo ] && [ ! -d .repo ]; then
    echo "Workspace has a non-directory .repo entry: $WORKSPACE_DIR" >&2
    exit 1
  fi

  repo_init_base_args=(
    -u "$MANIFEST_URL"
    -b "$MANIFEST_BRANCH"
    --depth="$CORESHIFT_REPO_DEPTH"
  )
  repo_init_optional_args=(
    --no-repo-verify
  )

  if [ "$repo_partial_clone_enabled" -eq 1 ]; then
    repo_init_optional_args+=(
      --partial-clone
      --clone-filter="$CORESHIFT_REPO_CLONE_FILTER"
    )
  fi

  if ! repo init \
    "${repo_init_base_args[@]}" \
    "${repo_init_optional_args[@]}" 2>&1 | tee "$repo_init_log"; then
    if grep -qiE 'unknown option|unrecognized option|unsupported option|no such option' "$repo_init_log"; then
      echo "repo init retrying without optional flags"
      repo init "${repo_init_base_args[@]}" 2>&1 | tee "$repo_init_log"
    else
      exit 1
    fi
  fi

  mkdir -p .repo/local_manifests
  cp "$OVERLAY_SOURCE" .repo/local_manifests/coreshift-overlay.xml

  if [ ! -f .repo/local_manifests/coreshift-overlay.xml ]; then
    echo "Failed to install local manifest overlay in workspace: $WORKSPACE_DIR" >&2
    exit 1
  fi

  repo_sync_base_args=(
    -c
    --fail-fast
    --no-clone-bundle
    --no-tags
    -j "$CORESHIFT_REPO_JOBS"
  )
  repo_sync_optional_args=(
    --optimized-fetch
    --prune
  )

  if ! repo sync \
    "${repo_sync_base_args[@]}" \
    "${repo_sync_optional_args[@]}" 2>&1 | tee "$repo_sync_log"; then
    if grep -qiE 'unknown option|unrecognized option|unsupported option|no such option' "$repo_sync_log"; then
      echo "repo sync retrying without optional flags"
      repo sync "${repo_sync_base_args[@]}" 2>&1 | tee "$repo_sync_log"
    else
      exit 1
    fi
  fi

  rm -rf common
  git clone \
    --depth="$CORESHIFT_REPO_DEPTH" \
    --branch "$KERNEL_SOURCE_BRANCH" \
    "$KERNEL_COMMON_URL" \
    common

  if [ ! -d common/.git ]; then
    echo "Failed to clone kernel/common branch $KERNEL_SOURCE_BRANCH into $WORKSPACE_DIR/common" >&2
    exit 1
  fi
)
