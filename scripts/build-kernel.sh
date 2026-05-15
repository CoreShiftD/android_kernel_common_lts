#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-kernel.sh <profile-name> [--workspace DIR] [--mode auto|google_build_sh|kleaf] [--skip-setup] [--clean] [-- EXTRA_BUILD_ARGS...]

Builds an ACK/GKI kernel for the named profile using the manifest workspace helpers.

Defaults:
  workspace: .work/<profile-name>
  mode: auto
  artifacts: dist/<profile-name>
EOF
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 1
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

PROFILE_NAME="$1"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_JSON="$REPO_ROOT/profiles/$PROFILE_NAME.json"
WORKSPACE_DIR="$REPO_ROOT/.work/$PROFILE_NAME"
ARTIFACT_DIR="$REPO_ROOT/dist/$PROFILE_NAME"
MODE="auto"
SKIP_SETUP=0
CLEAN=0
EXTRA_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --workspace" >&2
        exit 1
      fi
      WORKSPACE_DIR="$2"
      shift 2
      ;;
    --mode)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --mode" >&2
        exit 1
      fi
      MODE="$2"
      shift 2
      ;;
    --skip-setup)
      SKIP_SETUP=1
      shift
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --)
      shift
      EXTRA_ARGS=("$@")
      break
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$MODE" in
  auto|google_build_sh|kleaf)
    ;;
  *)
    echo "Unsupported build mode: $MODE" >&2
    usage >&2
    exit 1
    ;;
esac

if [ ! -f "$PROFILE_JSON" ]; then
  echo "Profile not found: $PROFILE_JSON" >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || {
  echo "Missing required tool: python3" >&2
  exit 1
}

python3 "$REPO_ROOT/scripts/validate-profiles.py"

for tool in git repo; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

mkdir -p "$(dirname "$WORKSPACE_DIR")" "$(dirname "$ARTIFACT_DIR")"

if [ "$CLEAN" -eq 1 ]; then
  rm -rf "$WORKSPACE_DIR" "$ARTIFACT_DIR"
fi

if [ "$SKIP_SETUP" -eq 0 ]; then
  "$REPO_ROOT/scripts/setup-manifest-workspace.sh" "$PROFILE_JSON" "$WORKSPACE_DIR"
elif [ ! -d "$WORKSPACE_DIR" ]; then
  echo "Workspace not found with --skip-setup: $WORKSPACE_DIR" >&2
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
    elif isinstance(value, str) and value:
        print(f"{field.upper()}={shlex.quote(value)}")
    else:
        raise SystemExit(
            f"{profile_path}: profile field {field!r} must be a non-empty string or null"
        )
PY
)"

resolve_mode() {
  if [ "$MODE" != "auto" ]; then
    printf '%s\n' "$MODE"
    return 0
  fi

  if [ -n "${BUILD_CONFIG:-}" ]; then
    if [ -x "$WORKSPACE_DIR/build/build.sh" ] && [ -f "$WORKSPACE_DIR/$BUILD_CONFIG" ]; then
      printf '%s\n' "google_build_sh"
      return 0
    fi

    if [ -n "${BAZEL_TARGET:-}" ] && [ -x "$WORKSPACE_DIR/tools/bazel" ]; then
      printf '%s\n' "kleaf"
      return 0
    fi

    printf '%s\n' "google_build_sh"
    return 0
  fi

  if [ -n "${BAZEL_TARGET:-}" ]; then
    printf '%s\n' "kleaf"
    return 0
  fi

  echo "Profile does not define a usable build mode: $PROFILE_JSON" >&2
  exit 1
}

SELECTED_MODE="$(resolve_mode)"

OUT_DIR="$WORKSPACE_DIR/out" \
DIST_DIR="$WORKSPACE_DIR/dist" \
  "$REPO_ROOT/scripts/run-manifest-build.sh" \
  "$PROFILE_JSON" \
  "$WORKSPACE_DIR" \
  "$SELECTED_MODE" \
  "${EXTRA_ARGS[@]}"

"$REPO_ROOT/scripts/collect-artifacts.sh" "$PROFILE_NAME" "$WORKSPACE_DIR" "$ARTIFACT_DIR"

echo
echo "Build summary:"
echo "  profile: $PROFILE_NAME"
echo "  workspace: $WORKSPACE_DIR"
echo "  build mode: $SELECTED_MODE"
echo "  artifacts: $ARTIFACT_DIR"
