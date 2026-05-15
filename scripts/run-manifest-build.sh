#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-manifest-build.sh <profile-json> <workspace-dir> <google_build_sh|kleaf> [extra-args...]

google_build_sh: runs build/build.sh with BUILD_CONFIG from the profile
kleaf: runs tools/bazel run with the Bazel target from the profile
EOF
}

if [ "$#" -lt 3 ]; then
  usage >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || {
  echo "Missing required tool: python3" >&2
  exit 1
}

PROFILE_JSON="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
WORKSPACE_DIR="$2"
BUILD_MODE="$3"
shift 3

if [ ! -f "$PROFILE_JSON" ]; then
  echo "Profile not found: $PROFILE_JSON" >&2
  exit 1
fi

if [ ! -d "$WORKSPACE_DIR" ]; then
  echo "Workspace not found: $WORKSPACE_DIR" >&2
  exit 1
fi

WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"

if [ ! -d "$WORKSPACE_DIR/.repo" ]; then
  echo "Workspace is not a repo manifest checkout: $WORKSPACE_DIR" >&2
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

for field in ("build_config", "bazel_target"):
    value = profile.get(field)
    if value is None:
        print(f"{field.upper()}=''")
        continue
    if not isinstance(value, str) or not value:
        raise SystemExit(
            f"{profile_path}: profile field {field!r} must be a non-empty string or null"
        )
    print(f"{field.upper()}={shlex.quote(value)}")
PY
)"

case "$BUILD_MODE" in
  google_build_sh)
    selected_build_config="${BUILD_CONFIG_OVERRIDE:-$BUILD_CONFIG}"
    jobs="${CORESHIFT_JOBS:-}"
    if [ -z "$selected_build_config" ]; then
      echo "Profile does not define build_config: $PROFILE_JSON" >&2
      exit 1
    fi
    if [ ! -f "$WORKSPACE_DIR/$selected_build_config" ]; then
      echo "BUILD_CONFIG not found in workspace: $WORKSPACE_DIR/$selected_build_config" >&2
      exit 1
    fi
    if [ ! -x "$WORKSPACE_DIR/build/build.sh" ]; then
      echo "Missing build/build.sh in workspace: $WORKSPACE_DIR" >&2
      exit 1
    fi
    (
      cd "$WORKSPACE_DIR"
      echo "selected BUILD_CONFIG=$selected_build_config"
      echo "LTO=${LTO:-}"
      echo "CORESHIFT_JOBS=${CORESHIFT_JOBS:-}"
      echo "MAKEFLAGS=${MAKEFLAGS:-}"
      echo "SKIP_HEADERS_INSTALL=${SKIP_HEADERS_INSTALL:-}"
      echo "SKIP_EXT_MODULES=${SKIP_EXT_MODULES:-}"
      echo "SKIP_CP_KERNEL_HDRS=${SKIP_CP_KERNEL_HDRS:-}"
      echo "LLVM_PARALLEL_LINK_JOBS=${LLVM_PARALLEL_LINK_JOBS:-}"
      echo "LLD_PARALLEL_LINK_JOBS=${LLD_PARALLEL_LINK_JOBS:-}"
      if [ -n "$jobs" ]; then
        BUILD_CONFIG="$selected_build_config" build/build.sh -j"$jobs" "$@"
      else
        BUILD_CONFIG="$selected_build_config" build/build.sh "$@"
      fi
    )
    ;;
  kleaf)
    if [ -z "$BAZEL_TARGET" ]; then
      echo "Profile does not define bazel_target: $PROFILE_JSON" >&2
      exit 1
    fi
    if [ ! -x "$WORKSPACE_DIR/tools/bazel" ]; then
      echo "Missing tools/bazel in workspace: $WORKSPACE_DIR" >&2
      exit 1
    fi
    (
      cd "$WORKSPACE_DIR"
      tools/bazel run "$@" "$BAZEL_TARGET"
    )
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
