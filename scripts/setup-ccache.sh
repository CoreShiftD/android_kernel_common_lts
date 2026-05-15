#!/usr/bin/env bash
set -euo pipefail

if ! command -v ccache >/dev/null 2>&1; then
  echo "ccache is required but not installed. Run ./scripts/install-build-tools.sh first." >&2
  exit 1
fi

CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-10G}"
CCACHE_BASEDIR="${CCACHE_BASEDIR:-$PWD}"
CCACHE_NOHASHDIR="${CCACHE_NOHASHDIR:-true}"
CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-file_macro,time_macros,include_file_mtime,include_file_ctime}"

mkdir -p "$CCACHE_DIR"

ccache --set-config=max_size="$CCACHE_MAXSIZE"
ccache --set-config=compression=true
ccache --set-config=compiler_check="$CCACHE_COMPILERCHECK"

if [ "${CORESHIFT_CCACHE_ZERO_STATS:-0}" = "1" ]; then
  ccache --zero-stats || true
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "CCACHE_DIR=$CCACHE_DIR" >> "$GITHUB_ENV"
  echo "CCACHE_MAXSIZE=$CCACHE_MAXSIZE" >> "$GITHUB_ENV"
  echo "CCACHE_BASEDIR=$CCACHE_BASEDIR" >> "$GITHUB_ENV"
  echo "CCACHE_NOHASHDIR=$CCACHE_NOHASHDIR" >> "$GITHUB_ENV"
  echo "CCACHE_COMPILERCHECK=$CCACHE_COMPILERCHECK" >> "$GITHUB_ENV"
  echo "CCACHE_SLOPPINESS=$CCACHE_SLOPPINESS" >> "$GITHUB_ENV"
  echo "USE_CCACHE=1" >> "$GITHUB_ENV"
fi

echo "CCACHE_DIR=$CCACHE_DIR"
echo "CCACHE_MAXSIZE=$CCACHE_MAXSIZE"
echo "CCACHE_BASEDIR=$CCACHE_BASEDIR"
echo "CCACHE_NOHASHDIR=$CCACHE_NOHASHDIR"
echo "CCACHE_COMPILERCHECK=$CCACHE_COMPILERCHECK"
echo "CCACHE_SLOPPINESS=$CCACHE_SLOPPINESS"
ccache -s || true
