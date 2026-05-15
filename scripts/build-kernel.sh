#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-kernel.sh <profile-name> [--workspace DIR] [--mode auto|google_build_sh|kleaf] [--skip-setup] [--clean] [--disable-defconfig-check on|off] [--disable-kmi-check on|off] [--build-env KEY=VALUE] [-- EXTRA_BUILD_ARGS...]

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
DISABLE_DEFCONFIG_CHECK="off"
DISABLE_KMI_CHECK="off"
BUILD_ENV=()
BUILD_ENV_KEYS=()
USER_SET_UAPI_CFLAGS=0
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
    --disable-defconfig-check)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --disable-defconfig-check" >&2
        exit 1
      fi
      DISABLE_DEFCONFIG_CHECK="$2"
      shift 2
      ;;
    --disable-kmi-check)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --disable-kmi-check" >&2
        exit 1
      fi
      DISABLE_KMI_CHECK="$2"
      shift 2
      ;;
    --build-env)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --build-env" >&2
        exit 1
      fi
      if [[ "$2" != *=* ]]; then
        echo "Invalid --build-env value, expected KEY=VALUE: $2" >&2
        exit 1
      fi
      build_env_key="${2%%=*}"
      if ! [[ "$build_env_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Invalid --build-env key: $build_env_key" >&2
        exit 1
      fi
      BUILD_ENV+=("$2")
      BUILD_ENV_KEYS+=("$build_env_key")
      if [ "$build_env_key" = "UAPI_CFLAGS" ]; then
        USER_SET_UAPI_CFLAGS=1
      fi
      shift 2
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

case "$DISABLE_DEFCONFIG_CHECK" in
  on|off)
    ;;
  *)
    echo "Unsupported value for --disable-defconfig-check: $DISABLE_DEFCONFIG_CHECK" >&2
    exit 1
    ;;
esac

case "$DISABLE_KMI_CHECK" in
  on|off)
    ;;
  *)
    echo "Unsupported value for --disable-kmi-check: $DISABLE_KMI_CHECK" >&2
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

case "$PROFILE_NAME" in
  android*-5.4-lts)
    is_54_profile=1
    ;;
  *)
    is_54_profile=0
    ;;
esac

if [ "$is_54_profile" -eq 1 ] && [ "$USER_SET_UAPI_CFLAGS" -eq 0 ]; then
  if [ ! -f /usr/aarch64-linux-gnu/include/sys/time.h ]; then
    echo "Warning: /usr/aarch64-linux-gnu/include/sys/time.h is missing; 5.4 UAPI header tests may fail unless install-build-tools.sh installed the Arm64 cross libc headers" >&2
  fi
  BUILD_ENV+=("UAPI_CFLAGS=-std=c90 -Wall -Werror=implicit-function-declaration --target=aarch64-linux-gnu -isystem /usr/aarch64-linux-gnu/include")
  BUILD_ENV_KEYS+=("UAPI_CFLAGS")
  echo "Auto-added UAPI_CFLAGS for 5.4 header tests: /usr/aarch64-linux-gnu/include"
fi

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

"$REPO_ROOT/scripts/prepare-private-fragment.sh" "$PROFILE_JSON" "$WORKSPACE_DIR"

mapfile -t profile_build_fields < <(
  python3 - "$PROFILE_JSON" <<'PY'
import json
import sys

profile_path = sys.argv[1]

with open(profile_path, encoding="utf-8") as fh:
    profile = json.load(fh)

for field in ("build_config", "bazel_target"):
    value = profile.get(field)
    if value is None:
        print("")
    elif isinstance(value, str) and value:
        print(value)
    else:
        raise SystemExit(
            f"{profile_path}: profile field {field!r} must be a non-empty string or null"
        )
PY
)

BUILD_CONFIG="${profile_build_fields[0]:-}"
BAZEL_TARGET="${profile_build_fields[1]:-}"

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

if [ "$DISABLE_DEFCONFIG_CHECK" = "on" ]; then
  "$REPO_ROOT/scripts/disable-defconfig-check.sh" "$WORKSPACE_DIR"
fi

if [ "$DISABLE_KMI_CHECK" = "on" ]; then
  "$REPO_ROOT/scripts/disable-kmi-check.sh" "$WORKSPACE_DIR"
fi

BUILD_CONFIG_OVERRIDE_VALUE=""
if [ "$SELECTED_MODE" = "google_build_sh" ] && [ -f "$WORKSPACE_DIR/common/build.config.coreshift.gki.aarch64" ]; then
  BUILD_CONFIG_OVERRIDE_VALUE="common/build.config.coreshift.gki.aarch64"
fi

run_cmd=(
  "$REPO_ROOT/scripts/run-manifest-build.sh"
  "$PROFILE_JSON"
  "$WORKSPACE_DIR"
  "$SELECTED_MODE"
  "${EXTRA_ARGS[@]}"
)

env_cmd=(
  "OUT_DIR=$WORKSPACE_DIR/out"
  "DIST_DIR=$WORKSPACE_DIR/dist"
  "BUILD_CONFIG_OVERRIDE=$BUILD_CONFIG_OVERRIDE_VALUE"
)

if [ "${#BUILD_ENV[@]}" -gt 0 ]; then
  env "${BUILD_ENV[@]}" "${env_cmd[@]}" "${run_cmd[@]}"
else
  env "${env_cmd[@]}" "${run_cmd[@]}"
fi

"$REPO_ROOT/scripts/collect-artifacts.sh" "$PROFILE_NAME" "$WORKSPACE_DIR" "$ARTIFACT_DIR"

echo
echo "Build summary:"
echo "  profile: $PROFILE_NAME"
echo "  workspace: $WORKSPACE_DIR"
echo "  build mode: $SELECTED_MODE"
echo "  artifacts: $ARTIFACT_DIR"
if [ -n "$BUILD_CONFIG_OVERRIDE_VALUE" ]; then
  echo "  build config override: $BUILD_CONFIG_OVERRIDE_VALUE"
fi
if [ "${#BUILD_ENV_KEYS[@]}" -gt 0 ]; then
  echo "  build env:"
  for key in "${BUILD_ENV_KEYS[@]}"; do
    echo "    $key"
  done
else
  echo "  build env: none"
fi
