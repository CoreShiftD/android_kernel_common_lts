#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/apply-ksu.sh <workspace-dir> [profile-name]
EOF
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage >&2
  exit 1
fi

WORKSPACE_DIR="$1"
PROFILE_NAME="${2:-$(basename "$WORKSPACE_DIR")}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_DIR="$WORKSPACE_DIR/common"
FEATURES_FRAGMENT="$COMMON_DIR/features.fragment"
KSU_DIR="$COMMON_DIR/KernelSU"
KSU_PROVIDERS_CONFIG="$REPO_ROOT/configs/ksu-providers.json"
if [ -n "${CORESHIFT_LOG_DIR:-}" ]; then
  KSU_LOG_DIR="$CORESHIFT_LOG_DIR/patches/ksu"
  mkdir -p "$KSU_LOG_DIR"
else
  KSU_LOG_DIR=""
fi

requested_ksu_provider="${KSU_PROVIDER:-}"
mapfile -t provider_fields < <(
  python3 - "$KSU_PROVIDERS_CONFIG" "$PROFILE_NAME" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
profile = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
default = data.get("default", {})
selected = dict(default)
selected.update(data.get("profiles", {}).get(profile, {}))
print(selected.get("provider", "kernelsu"))
print(selected.get("repo", "https://github.com/tiann/KernelSU.git"))
print(selected.get("ref", "main"))
PY
)

KSU_PROVIDER="${requested_ksu_provider:-${provider_fields[0]}}"
case "$KSU_PROVIDER" in
  kernelsu|multisu) ;;
  *)
    echo "Unsupported KSU provider: $KSU_PROVIDER" >&2
    exit 1
    ;;
esac

if [ "$KSU_PROVIDER" = "multisu" ]; then
  if [ -z "${MULTISU_REPO:-}" ] && [ -n "${KSU_REPO:-}" ] && [ "$requested_ksu_provider" = "multisu" ]; then
    export MULTISU_REPO="$KSU_REPO"
  fi
  if [ -z "${MULTISU_REF:-}" ] && [ -n "${KSU_REF:-}" ]; then
    export MULTISU_REF="$KSU_REF"
  fi
  if [ "${provider_fields[0]}" = "multisu" ]; then
    MULTISU_REPO="${MULTISU_REPO:-${provider_fields[1]}}"
    MULTISU_REF="${MULTISU_REF:-${provider_fields[2]}}"
  else
    MULTISU_REPO="${MULTISU_REPO:-https://github.com/xxblebleblexx/MultiSU.git}"
    MULTISU_REF="${MULTISU_REF:-legacy}"
  fi
  export MULTISU_REPO MULTISU_REF
  "$SCRIPT_DIR/apply-multisu.sh" "$WORKSPACE_DIR" "$PROFILE_NAME"
  exit 0
fi

if [ "${provider_fields[0]}" = "kernelsu" ]; then
  KSU_REPO="${KSU_REPO:-${provider_fields[1]}}"
  KSU_REF="${KSU_REF:-${provider_fields[2]}}"
else
  KSU_REPO="${KSU_REPO:-https://github.com/tiann/KernelSU.git}"
  KSU_REF="${KSU_REF:-main}"
fi

ensure_line_once() {
  local wanted_line="$1"
  local target_file="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' EXIT
  grep -Fvx "$wanted_line" "$target_file" > "$tmp_file" || true
  printf '%s\n' "$wanted_line" >> "$tmp_file"
  mv "$tmp_file" "$target_file"
  trap - EXIT
}

if [ ! -d "$COMMON_DIR" ]; then
  echo "Workspace common directory not found: $COMMON_DIR" >&2
  exit 1
fi

if ! git -C "$COMMON_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Workspace common directory is not a git repo: $COMMON_DIR" >&2
  exit 1
fi

if [ ! -f "$FEATURES_FRAGMENT" ]; then
  echo "Workspace features fragment not found: $FEATURES_FRAGMENT" >&2
  exit 1
fi

if [ -e "$KSU_DIR" ] && [ ! -d "$KSU_DIR/.git" ]; then
  rm -rf "$KSU_DIR"
fi

if [ -d "$KSU_DIR/.git" ]; then
  git -C "$KSU_DIR" fetch --depth 1 origin "$KSU_REF" || true
else
  git clone --depth 1 "$KSU_REPO" "$KSU_DIR"
  git -C "$KSU_DIR" fetch --depth 1 origin "$KSU_REF" || true
fi

git -C "$KSU_DIR" checkout "$KSU_REF" || true

if [ ! -f "$KSU_DIR/kernel/setup.sh" ]; then
  echo "Missing upstream KernelSU setup script: $KSU_DIR/kernel/setup.sh" >&2
  exit 1
fi

(
  cd "$COMMON_DIR"
  if [ -n "$KSU_LOG_DIR" ]; then
    sh "$KSU_DIR/kernel/setup.sh" "$KSU_REF" 2>&1 | tee "$KSU_LOG_DIR/setup.log"
  else
    sh "$KSU_DIR/kernel/setup.sh" "$KSU_REF"
  fi
)

ensure_line_once 'CONFIG_KSU=y' "$FEATURES_FRAGMENT"

ksu_commit="$(git -C "$KSU_DIR" rev-parse HEAD)"
if [ -n "$KSU_LOG_DIR" ]; then
  {
    echo "KernelSU repo: $KSU_REPO"
    echo "KernelSU ref: $KSU_REF"
    echo "KernelSU commit: $ksu_commit"
    echo "KernelSU source path: $KSU_DIR"
  } > "$KSU_LOG_DIR/source.txt"
fi
rm -rf "$KSU_DIR/.github"
echo "KernelSU commit: $ksu_commit"
echo "KernelSU source staged at: $KSU_DIR"
