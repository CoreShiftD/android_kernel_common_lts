#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/apply-multisu.sh <workspace-dir> <profile-name>
EOF
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 1
fi

WORKSPACE_DIR="$1"
PROFILE_NAME="$2"
COMMON_DIR="$WORKSPACE_DIR/common"
FEATURES_FRAGMENT="$COMMON_DIR/features.fragment"
MULTISU_DIR="$COMMON_DIR/MultiSU"
MULTISU_REPO="${MULTISU_REPO:-https://github.com/xxblebleblexx/MultiSU.git}"
MULTISU_REF="${MULTISU_REF:-legacy}"
if [ -n "${CORESHIFT_LOG_DIR:-}" ]; then
  MULTISU_LOG_DIR="$CORESHIFT_LOG_DIR/patches/multisu"
  mkdir -p "$MULTISU_LOG_DIR"
else
  MULTISU_LOG_DIR=""
fi

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

insert_driver_kconfig_source() {
  local kconfig_file="$COMMON_DIR/drivers/Kconfig"
  if grep -Fxq 'source "drivers/kernelsu/Kconfig"' "$kconfig_file"; then
    return 0
  fi

  python3 - "$kconfig_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
insert = 'source "drivers/kernelsu/Kconfig"'
for index in range(len(lines) - 1, -1, -1):
    if lines[index].strip() == "endmenu":
        lines.insert(index, insert)
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        break
else:
    raise SystemExit(f"{path}: missing endmenu")
PY
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

if [ -e "$MULTISU_DIR" ] && [ ! -d "$MULTISU_DIR/.git" ]; then
  rm -rf "$MULTISU_DIR"
fi

if [ -d "$MULTISU_DIR/.git" ]; then
  git -C "$MULTISU_DIR" fetch --depth 1 origin "$MULTISU_REF" || true
else
  git clone --depth 1 "$MULTISU_REPO" "$MULTISU_DIR"
  git -C "$MULTISU_DIR" fetch --depth 1 origin "$MULTISU_REF" || true
fi

if ! git -C "$MULTISU_DIR" checkout "$MULTISU_REF"; then
  if git -C "$MULTISU_DIR" rev-parse --verify FETCH_HEAD >/dev/null 2>&1; then
    git -C "$MULTISU_DIR" checkout --detach FETCH_HEAD
  else
    echo "Unable to checkout MultiSU ref: $MULTISU_REF" >&2
    exit 1
  fi
fi

if [ ! -d "$MULTISU_DIR/kernel" ]; then
  echo "Missing MultiSU kernel directory: $MULTISU_DIR/kernel" >&2
  exit 1
fi

if [ ! -f "$COMMON_DIR/drivers/Makefile" ] || [ ! -f "$COMMON_DIR/drivers/Kconfig" ]; then
  echo "Missing drivers Makefile/Kconfig in workspace common" >&2
  exit 1
fi

if [ -e "$COMMON_DIR/drivers/kernelsu" ] && [ ! -L "$COMMON_DIR/drivers/kernelsu" ]; then
  rm -rf "$COMMON_DIR/drivers/kernelsu"
fi
ln -sfn ../MultiSU/kernel "$COMMON_DIR/drivers/kernelsu"
ensure_line_once 'obj-$(CONFIG_KSU) += kernelsu/' "$COMMON_DIR/drivers/Makefile"
insert_driver_kconfig_source
ensure_line_once 'CONFIG_KSU=y' "$FEATURES_FRAGMENT"

multisu_commit="$(git -C "$MULTISU_DIR" rev-parse HEAD)"
if [ -n "$MULTISU_LOG_DIR" ]; then
  {
    echo "MultiSU repo: $MULTISU_REPO"
    echo "MultiSU ref: $MULTISU_REF"
    echo "MultiSU commit: $multisu_commit"
    echo "MultiSU source path: $MULTISU_DIR"
    echo "MultiSU profile: $PROFILE_NAME"
  } > "$MULTISU_LOG_DIR/source.txt"
  {
    echo "drivers/kernelsu -> ../MultiSU/kernel"
    echo 'drivers/Makefile: obj-$(CONFIG_KSU) += kernelsu/'
    echo 'drivers/Kconfig: source "drivers/kernelsu/Kconfig"'
  } > "$MULTISU_LOG_DIR/setup.log"
fi

rm -rf "$MULTISU_DIR/.github"
echo "MultiSU repo: $MULTISU_REPO"
echo "MultiSU ref: $MULTISU_REF"
echo "MultiSU commit: $multisu_commit"
echo "MultiSU source path: $MULTISU_DIR"
