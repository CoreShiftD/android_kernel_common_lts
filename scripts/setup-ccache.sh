#!/usr/bin/env bash
set -euo pipefail

if ! command -v ccache >/dev/null 2>&1; then
  echo "ccache is required but not installed. Run ./scripts/install-build-tools.sh first." >&2
  exit 1
fi

CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-10G}"

mkdir -p "$CCACHE_DIR"

ccache --set-config=max_size="$CCACHE_MAXSIZE"
ccache --set-config=compression=true
ccache --zero-stats || true

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "CCACHE_DIR=$CCACHE_DIR" >> "$GITHUB_ENV"
  echo "CCACHE_MAXSIZE=$CCACHE_MAXSIZE" >> "$GITHUB_ENV"
  echo "USE_CCACHE=1" >> "$GITHUB_ENV"
fi

echo "CCACHE_DIR=$CCACHE_DIR"
echo "CCACHE_MAXSIZE=$CCACHE_MAXSIZE"
ccache -s || true
