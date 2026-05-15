#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: scripts/setup-ccache-wrappers.sh <workspace-dir>" >&2
  exit 1
fi

if ! command -v ccache >/dev/null 2>&1; then
  echo "ccache is required but not installed. Run ./scripts/install-build-tools.sh first." >&2
  exit 1
fi

WORKSPACE_DIR="$1"
WRAPPER_DIR="$HOME/.local/lib/coreshift-ccache-wrappers"
CCACHE_BIN="$(command -v ccache)"
ORIGINAL_PATH="${PATH:-}"

if [ ! -d "$WORKSPACE_DIR" ]; then
  echo "Workspace not found: $WORKSPACE_DIR" >&2
  exit 1
fi

mkdir -p "$WRAPPER_DIR"

for tool in clang clang++ gcc g++ cc c++; do
  ln -sfn "$CCACHE_BIN" "$WRAPPER_DIR/$tool"
done

shopt -s nullglob
compiler_dirs=()
for dir in \
  "$WORKSPACE_DIR"/prebuilts/clang/host/linux-x86/*/bin \
  "$WORKSPACE_DIR"/common/prebuilts/clang/host/linux-x86/*/bin \
  "$WORKSPACE_DIR"/prebuilts/gcc/*/*/bin
do
  if [ -d "$dir" ]; then
    compiler_dirs+=("$dir")
  fi
done
shopt -u nullglob

CCACHE_PATH_VALUE="$ORIGINAL_PATH"
if [ "${#compiler_dirs[@]}" -gt 0 ]; then
  compiler_path_prefix="$(IFS=:; printf '%s' "${compiler_dirs[*]}")"
  CCACHE_PATH_VALUE="$compiler_path_prefix:$ORIGINAL_PATH"
fi

export CCACHE_WRAPPER_DIR="$WRAPPER_DIR"
export CCACHE_PATH="$CCACHE_PATH_VALUE"
export PATH="$CCACHE_WRAPPER_DIR:$ORIGINAL_PATH"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "CCACHE_WRAPPER_DIR=$CCACHE_WRAPPER_DIR" >> "$GITHUB_ENV"
  echo "CCACHE_PATH=$CCACHE_PATH" >> "$GITHUB_ENV"
fi

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$CCACHE_WRAPPER_DIR" >> "$GITHUB_PATH"
fi

echo "ccache path: $CCACHE_BIN"
echo "wrapper dir: $CCACHE_WRAPPER_DIR"
echo "CCACHE_PATH=$CCACHE_PATH"
command -v clang
clang --version || true
ccache -s || true
