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
USER_BUILD_ENV_KEYS=()
DEFAULT_BUILD_ENV_KEYS=()
PASSTHROUGH_BUILD_ENV_KEYS=()
USER_SET_UAPI_SYSROOT_CFLAGS=0
USER_SET_LTO=0
USER_LTO_VALUE=""
EXTRA_ARGS=()

has_build_env_key() {
  local wanted="$1"
  local existing_key
  for existing_key in "${BUILD_ENV_KEYS[@]}"; do
    if [ "$existing_key" = "$wanted" ]; then
      return 0
    fi
  done
  return 1
}

add_default_build_env() {
  local key="$1"
  local value="$2"
  if has_build_env_key "$key"; then
    return 0
  fi
  BUILD_ENV+=("$key=$value")
  BUILD_ENV_KEYS+=("$key")
  DEFAULT_BUILD_ENV_KEYS+=("$key")
}

append_passthrough_build_env_if_unset() {
  local key="$1"
  local value="${!key:-}"
  if [ -z "$value" ]; then
    return 0
  fi
  if has_build_env_key "$key"; then
    return 0
  fi
  BUILD_ENV+=("$key=$value")
  BUILD_ENV_KEYS+=("$key")
  PASSTHROUGH_BUILD_ENV_KEYS+=("$key")
}

get_build_env_value() {
  local wanted="$1"
  local entry
  local value=""
  for entry in "${BUILD_ENV[@]}"; do
    if [ "${entry%%=*}" = "$wanted" ]; then
      value="${entry#*=}"
    fi
  done
  printf '%s\n' "$value"
}

print_key_section() {
  local label="$1"
  shift
  if [ "$#" -gt 0 ]; then
    echo "  $label:"
    local key
    for key in "$@"; do
      echo "    $key"
    done
  else
    echo "  $label: none"
  fi
}

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
      build_env_value="${2#*=}"
      if ! [[ "$build_env_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Invalid --build-env key: $build_env_key" >&2
        exit 1
      fi
      BUILD_ENV+=("$2")
      BUILD_ENV_KEYS+=("$build_env_key")
      USER_BUILD_ENV_KEYS+=("$build_env_key")
      if [ "$build_env_key" = "UAPI_SYSROOT_CFLAGS" ]; then
        USER_SET_UAPI_SYSROOT_CFLAGS=1
      fi
      if [ "$build_env_key" = "LTO" ]; then
        USER_SET_LTO=1
        USER_LTO_VALUE="$build_env_value"
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

for passthrough_key in \
  CCACHE_DIR \
  CCACHE_BASEDIR \
  CCACHE_NOHASHDIR \
  CCACHE_COMPILERCHECK \
  CCACHE_SLOPPINESS \
  CCACHE_WRAPPER_DIR \
  CCACHE_PATH \
  USE_CCACHE
do
  append_passthrough_build_env_if_unset "$passthrough_key"
done

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
EFFECTIVE_LTO=""
EFFECTIVE_JOBS=""

if [ "$SELECTED_MODE" = "google_build_sh" ]; then
  add_default_build_env "SKIP_MRPROPER" "1"
  add_default_build_env "SKIP_CP_KERNEL_HDRS" "1"
  add_default_build_env "SKIP_UNSTRIPPED_MODULES" "1"
  add_default_build_env "SKIP_DEBUG_INFO" "1"
  add_default_build_env "SKIP_EXT_MODULES" "1"
  add_default_build_env "SKIP_HEADERS_INSTALL" "1"
  add_default_build_env "CORESHIFT_JOBS" "4"
  add_default_build_env "MAKEFLAGS" "-j4"
  if [ "$USER_SET_LTO" -eq 0 ]; then
    add_default_build_env "LTO" "thin"
    EFFECTIVE_LTO="thin"
  else
    EFFECTIVE_LTO="$USER_LTO_VALUE"
  fi
  if [ "$EFFECTIVE_LTO" = "full" ]; then
    add_default_build_env "LLVM_PARALLEL_LINK_JOBS" "1"
    add_default_build_env "LLD_PARALLEL_LINK_JOBS" "1"
  fi
  EFFECTIVE_JOBS="$(get_build_env_value "CORESHIFT_JOBS")"
fi

if [ "$is_54_profile" -eq 1 ]; then
  "$REPO_ROOT/scripts/patch-54-uapi-sysroot.sh" "$WORKSPACE_DIR"
  echo "Applied 5.4 UAPI sysroot patch"
  if [ "$USER_SET_UAPI_SYSROOT_CFLAGS" -eq 0 ]; then
    if [ ! -f /usr/aarch64-linux-gnu/include/sys/time.h ]; then
      echo "Warning: /usr/aarch64-linux-gnu/include/sys/time.h is missing; install-build-tools.sh should install libc6-dev-arm64-cross, and 5.4 header tests may still fail without it" >&2
    fi
    if [ ! -f /usr/aarch64-linux-gnu/include/sys/ioctl.h ]; then
      echo "Warning: /usr/aarch64-linux-gnu/include/sys/ioctl.h is missing; install-build-tools.sh should install libc6-dev-arm64-cross, and 5.4 header tests may still fail without it" >&2
    fi
    if [ ! -f /usr/aarch64-linux-gnu/include/sys/types.h ]; then
      echo "Warning: /usr/aarch64-linux-gnu/include/sys/types.h is missing; install-build-tools.sh should install libc6-dev-arm64-cross, and 5.4 header tests may still fail without it" >&2
    fi
    add_default_build_env "UAPI_SYSROOT_CFLAGS" "--target=aarch64-linux-gnu -isystem /usr/aarch64-linux-gnu/include"
    echo "Auto-added UAPI_SYSROOT_CFLAGS for 5.4 header tests: /usr/aarch64-linux-gnu/include"
  fi
fi

if [ "$SELECTED_MODE" = "google_build_sh" ] && command -v ccache >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$REPO_ROOT/scripts/setup-ccache-wrappers.sh" "$WORKSPACE_DIR"
  append_passthrough_build_env_if_unset "CCACHE_WRAPPER_DIR"
  append_passthrough_build_env_if_unset "CCACHE_PATH"
  echo "google_build_sh compiler diagnostics:"
  command -v clang
  clang --version | head -n 1 || true
  ccache -s || true
fi

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
if [ "$SELECTED_MODE" = "google_build_sh" ]; then
  echo "  effective LTO: ${EFFECTIVE_LTO:-}"
  echo "  effective jobs: ${EFFECTIVE_JOBS:-}"
fi
print_key_section "user build env" "${USER_BUILD_ENV_KEYS[@]}"
print_key_section "default build env" "${DEFAULT_BUILD_ENV_KEYS[@]}"
print_key_section "passthrough build env" "${PASSTHROUGH_BUILD_ENV_KEYS[@]}"
