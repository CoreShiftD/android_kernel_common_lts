#!/usr/bin/env bash
set -euo pipefail

persist_wrapper_state() {
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "CCACHE_WRAPPER_DIR=${CCACHE_WRAPPER_DIR:-}" >> "$GITHUB_ENV"
    echo "CCACHE_PATH=${CCACHE_PATH:-}" >> "$GITHUB_ENV"
    echo "CORESHIFT_CCACHE_WRAPPERS_ENABLED=${CORESHIFT_CCACHE_WRAPPERS_ENABLED:-0}" >> "$GITHUB_ENV"
  fi

  if [ -n "${GITHUB_PATH:-}" ] && [ "${CORESHIFT_CCACHE_WRAPPERS_ENABLED:-0}" = "1" ]; then
    echo "$CCACHE_WRAPPER_DIR" >> "$GITHUB_PATH"
  fi
}

disable_wrappers() {
  local message="$1"
  export CORESHIFT_CCACHE_WRAPPERS_ENABLED=0
  unset CCACHE_WRAPPER_DIR
  unset CCACHE_PATH
  export PATH="$ORIGINAL_PATH"
  persist_wrapper_state
  echo "$message"
}

setup_ccache_wrappers() {
  if [ "$#" -ne 1 ]; then
    echo "Usage: scripts/setup-ccache-wrappers.sh <workspace-dir>" >&2
    return 1
  fi

  if ! command -v ccache >/dev/null 2>&1; then
    echo "ccache is required but not installed. Run ./scripts/install-build-tools.sh first." >&2
    return 1
  fi

  WORKSPACE_DIR="$1"
  WRAPPER_DIR="$HOME/.local/lib/coreshift-ccache-wrappers"
  CCACHE_BIN="$(command -v ccache)"
  ORIGINAL_PATH="${PATH:-}"

  if [ ! -d "$WORKSPACE_DIR" ]; then
    echo "Workspace not found: $WORKSPACE_DIR" >&2
    return 1
  fi

  mapfile -t clang_candidates < <(
    find "$WORKSPACE_DIR" -type f -path '*/bin/clang' -perm -111 2>/dev/null | sort -u
  )

  filtered_candidates=()
  for candidate in "${clang_candidates[@]}"; do
    case "$candidate" in
      "$WRAPPER_DIR"/*|/usr/bin/clang|/usr/local/bin/clang)
        continue
        ;;
      "$WORKSPACE_DIR"/*)
        filtered_candidates+=("$candidate")
        ;;
    esac
  done

  echo "discovered clang candidates:"
  if [ "${#filtered_candidates[@]}" -gt 0 ]; then
    printf '  %s\n' "${filtered_candidates[@]}"
  else
    echo "  none"
  fi

  if [ "${#filtered_candidates[@]}" -eq 0 ]; then
    disable_wrappers "No repo/AOSP clang found in workspace; ccache wrapper will not be enabled to avoid falling back to system clang."
    return 0
  fi

  best_candidate=""
  best_weight=999
  for candidate in "${filtered_candidates[@]}"; do
    weight=50
    case "$candidate" in
      */prebuilts/clang/host/linux-x86/*/bin/clang)
        weight=0
        ;;
      */prebuilts-master/clang/host/linux-x86/*/bin/clang)
        weight=1
        ;;
      */common/prebuilts/clang/host/linux-x86/*/bin/clang)
        weight=2
        ;;
      */common/prebuilts-master/clang/host/linux-x86/*/bin/clang)
        weight=3
        ;;
      */*clang-r*/bin/clang)
        weight=4
        ;;
    esac
    if [ -z "$best_candidate" ] || [ "$weight" -lt "$best_weight" ] || { [ "$weight" -eq "$best_weight" ] && [[ "$candidate" < "$best_candidate" ]]; }; then
      best_candidate="$candidate"
      best_weight="$weight"
    fi
  done

  compiler_dirs=()
  seen_dirs=":"
  best_dir="$(dirname "$best_candidate")"
  compiler_dirs+=("$best_dir")
  seen_dirs="${seen_dirs}${best_dir}:"

  for candidate in "${filtered_candidates[@]}"; do
    candidate_dir="$(dirname "$candidate")"
    if [[ "$seen_dirs" != *":$candidate_dir:"* ]]; then
      compiler_dirs+=("$candidate_dir")
      seen_dirs="${seen_dirs}${candidate_dir}:"
    fi
  done

  mkdir -p "$WRAPPER_DIR"
  for tool in clang clang++ gcc g++ cc c++; do
    ln -sfn "$CCACHE_BIN" "$WRAPPER_DIR/$tool"
  done

  compiler_path_prefix="$(IFS=:; printf '%s' "${compiler_dirs[*]}")"
  export CCACHE_WRAPPER_DIR="$WRAPPER_DIR"
  export CCACHE_PATH="$compiler_path_prefix:$ORIGINAL_PATH"
  export CORESHIFT_CCACHE_WRAPPERS_ENABLED=1
  export PATH="$CCACHE_WRAPPER_DIR:$ORIGINAL_PATH"

  selected_real_clang_version="$("$best_candidate" --version 2>/dev/null | head -n 3 || true)"
  wrapper_clang_path="$(command -v clang)"
  wrapper_clang_version="$(clang --version 2>/dev/null | head -n 3 || true)"

  echo "selected real clang: $best_candidate"
  printf '%s\n' "$selected_real_clang_version"
  echo "wrapper clang path: $wrapper_clang_path"
  printf '%s\n' "$wrapper_clang_version"

  if printf '%s\n' "$wrapper_clang_version" | grep -Fq "Ubuntu clang"; then
    disable_wrappers "ccache wrapper resolved to system Ubuntu clang; wrappers disabled to avoid using the wrong compiler."
    return 0
  fi

  persist_wrapper_state
  echo "ccache path: $CCACHE_BIN"
  echo "wrapper dir: $CCACHE_WRAPPER_DIR"
  echo "CCACHE_PATH=$CCACHE_PATH"
  command -v clang
  clang --version || true
  ccache -s || true
}

setup_ccache_wrappers "$@"
