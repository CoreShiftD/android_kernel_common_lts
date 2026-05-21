#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/apply-ksu.sh <workspace-dir>
EOF
}

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 1
fi

WORKSPACE_DIR="$1"
COMMON_DIR="$WORKSPACE_DIR/common"
FEATURES_FRAGMENT="$COMMON_DIR/features.fragment"
KSU_SETUP="${CORESHIFT_KERNELSU_SETUP:-${KSU_SETUP:-default}}"
KSU_REPO="${KSU_REPO:-https://github.com/KOWX712/KernelSU}"
KSU_REF="${KSU_REF:-master}"
case "$KSU_SETUP" in
  ""|default)
    KSU_SETUP="default"
    KSU_DIR="$COMMON_DIR/KernelSU"
    ;;
  legacy-multisu)
    KSU_DIR="$COMMON_DIR/MultiSU"
    ;;
  *)
    echo "Unsupported KernelSU setup: $KSU_SETUP" >&2
    exit 1
    ;;
esac
if [ -n "${CORESHIFT_LOG_DIR:-}" ]; then
  KSU_LOG_DIR="$CORESHIFT_LOG_DIR/patches/ksu"
  mkdir -p "$KSU_LOG_DIR"
else
  KSU_LOG_DIR=""
fi

log() {
  echo "[ksu] $*"
}

ensure_line_once() {
  local wanted_line="$1"
  local target_file="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' RETURN
  grep -Fvx "$wanted_line" "$target_file" > "$tmp_file" || true
  printf '%s\n' "$wanted_line" >> "$tmp_file"
  mv "$tmp_file" "$target_file"
  trap - RETURN
}

normalize_makefile_entry() {
  local makefile="$1"
  local wanted_line="obj-\$(CONFIG_KSU) += kernelsu/"
  local tmp_file

  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' RETURN
  grep -Fvx "$wanted_line" "$makefile" > "$tmp_file" || true
  printf '%s\n' "$wanted_line" >> "$tmp_file"
  mv "$tmp_file" "$makefile"
  trap - RETURN
}

normalize_kconfig_entry() {
  local kconfig_file="$1"
  local source_line='source "drivers/kernelsu/Kconfig"'
  local tmp_file
  local tmp_out

  tmp_file="$(mktemp)"
  tmp_out="$(mktemp)"
  trap 'rm -f "$tmp_file" "$tmp_out"' RETURN
  grep -Fvx "$source_line" "$kconfig_file" > "$tmp_file" || true
  awk -v source_line="$source_line" '
    !inserted && $0 == "endmenu" {
      print source_line
      inserted = 1
    }
    { print }
    END {
      if (!inserted) {
        print source_line
      }
    }
  ' "$tmp_file" > "$tmp_out"
  mv "$tmp_out" "$kconfig_file"
  rm -f "$tmp_file"
  trap - RETURN
}

find_drivers_dir() {
  local candidate
  for candidate in "$COMMON_DIR/drivers" "$WORKSPACE_DIR/drivers"; do
    if [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

looks_like_kernelsu_kernel_dir() {
  local candidate="$1"
  [ -d "$candidate" ] || return 1
  [ -f "$candidate/Kconfig" ] || return 1
  [ -f "$candidate/Makefile" ] || [ -f "$candidate/Kbuild" ] || return 1
  [ -f "$candidate/ksu.c" ] ||
    [ -f "$candidate/setup.sh" ] ||
    [ -f "$candidate/extras.c" ] ||
    [ -f "$candidate/tiny_sulog.c" ]
}

resolve_kernelsu_kernel_dir() {
  local root="$1"
  local candidate
  for candidate in "$root/kernel" "$root"; do
    if looks_like_kernelsu_kernel_dir "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

find_source_setup_script() {
  local root="$1"
  local candidate
  for candidate in "$root/kernel/setup.sh" "$root/setup.sh"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

normalize_drivers_kernelsu() {
  local kernel_dir="$1"
  local drivers_dir="$2"
  local target="$drivers_dir/kernelsu"
  local makefile="$drivers_dir/Makefile"
  local kconfig="$drivers_dir/Kconfig"
  local resolved_target=""

  [ -f "$makefile" ] || {
    echo "Drivers Makefile not found: $makefile" >&2
    exit 1
  }
  [ -f "$kconfig" ] || {
    echo "Drivers Kconfig not found: $kconfig" >&2
    exit 1
  }

  if [ -e "$target" ] || [ -L "$target" ]; then
    resolved_target="$(readlink -f "$target" || true)"
  fi
  if [ "$resolved_target" != "$kernel_dir" ]; then
    rm -rf "$target"
    ln -s "$kernel_dir" "$target"
  fi

  normalize_makefile_entry "$makefile"
  normalize_kconfig_entry "$kconfig"
}

stage_drivers_kernelsu() {
  local kernel_dir="$1"
  local drivers_dir="$2"
  local target="$drivers_dir/kernelsu"
  local makefile="$drivers_dir/Makefile"
  local kconfig="$drivers_dir/Kconfig"

  [ -f "$makefile" ] || {
    echo "Drivers Makefile not found: $makefile" >&2
    exit 1
  }
  [ -f "$kconfig" ] || {
    echo "Drivers Kconfig not found: $kconfig" >&2
    exit 1
  }

  if [ -L "$target" ]; then
    rm -f "$target"
  elif [ -e "$target" ]; then
    rm -rf "$target"
  fi

  ln -s "$kernel_dir" "$target"
  normalize_makefile_entry "$makefile"
  normalize_kconfig_entry "$kconfig"
}

run_source_setup() {
  local setup_script="$1"
  local setup_log="$2"

  log "KernelSU: using source setup.sh"
  : > "$setup_log"
  if ! (cd "$COMMON_DIR" && sh "$setup_script" "$KSU_REF") >"$setup_log" 2>&1; then
    echo "KernelSU: source setup.sh failed: $setup_script" >&2
    sed -n '1,120p' "$setup_log" >&2
    return 1
  fi
  log "KernelSU: setup completed"
}

prune_nested_git_metadata() {
  local source_root="$1"
  while IFS= read -r nested_git; do
    if [ "$nested_git" != "$source_root/.git" ]; then
      rm -rf "$nested_git"
    fi
  done < <(find "$source_root" -mindepth 2 -name .git -print)
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
  git -C "$KSU_DIR" remote set-url origin "$KSU_REPO"
  git -C "$KSU_DIR" fetch --quiet --depth 1 origin "$KSU_REF" || true
else
  git clone --quiet --depth 1 --branch "$KSU_REF" "$KSU_REPO" "$KSU_DIR" ||
    git clone --quiet --depth 1 "$KSU_REPO" "$KSU_DIR"
  git -C "$KSU_DIR" fetch --quiet --depth 1 origin "$KSU_REF" || true
fi

git -C "$KSU_DIR" checkout -q "$KSU_REF" || true

DRIVERS_DIR="$(find_drivers_dir || true)"
[ -n "$DRIVERS_DIR" ] || {
  echo "Could not locate drivers directory under $COMMON_DIR or $WORKSPACE_DIR" >&2
  exit 1
}

KSU_KERNEL_DIR="$(resolve_kernelsu_kernel_dir "$KSU_DIR" || true)"
[ -n "$KSU_KERNEL_DIR" ] || {
  echo "Could not locate KernelSU kernel integration tree under $KSU_DIR" >&2
  exit 1
}

KSU_SETUP_SCRIPT="$(find_source_setup_script "$KSU_DIR" || true)"
KSU_SETUP_METHOD="fallback layout integration"
KSU_TEMP_SETUP_LOG=""
if [ -n "$KSU_LOG_DIR" ]; then
  KSU_SETUP_LOG="$KSU_LOG_DIR/setup.log"
else
  KSU_TEMP_SETUP_LOG="$(mktemp)"
  KSU_SETUP_LOG="$KSU_TEMP_SETUP_LOG"
fi
if [ -n "$KSU_SETUP_SCRIPT" ]; then
  run_source_setup "$KSU_SETUP_SCRIPT" "$KSU_SETUP_LOG"
  KSU_SETUP_METHOD="source setup.sh"
  normalize_drivers_kernelsu "$KSU_KERNEL_DIR" "$DRIVERS_DIR"
else
  log "KernelSU: using fallback layout integration"
  stage_drivers_kernelsu "$KSU_KERNEL_DIR" "$DRIVERS_DIR"
fi
if [ -n "$KSU_TEMP_SETUP_LOG" ]; then
  rm -f "$KSU_TEMP_SETUP_LOG"
fi
ensure_line_once 'CONFIG_KSU=y' "$FEATURES_FRAGMENT"

prune_nested_git_metadata "$KSU_DIR"
ksu_commit="$(git -C "$KSU_DIR" rev-parse HEAD)"
if [ -n "$KSU_LOG_DIR" ]; then
  {
    echo "KernelSU setup: $KSU_SETUP"
    echo "KernelSU repo: $KSU_REPO"
    echo "KernelSU ref: $KSU_REF"
    echo "KernelSU commit: $ksu_commit"
    echo "KernelSU source root: $KSU_DIR"
    echo "KernelSU kernel source path: $KSU_KERNEL_DIR"
    echo "KernelSU drivers link: $DRIVERS_DIR/kernelsu"
    echo "KernelSU setup method: $KSU_SETUP_METHOD"
    if [ -n "$KSU_SETUP_SCRIPT" ]; then
      echo "KernelSU setup script: $KSU_SETUP_SCRIPT"
    fi
  } > "$KSU_LOG_DIR/source.txt"
fi
rm -rf "$KSU_DIR/.github"
echo "KernelSU setup: $KSU_SETUP"
echo "KernelSU commit: $ksu_commit"
echo "KernelSU source staged at: $KSU_DIR"
echo "KernelSU kernel source path: $KSU_KERNEL_DIR"
echo "KernelSU drivers link: $DRIVERS_DIR/kernelsu"
echo "KernelSU setup method: $KSU_SETUP_METHOD"
