#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/apply-droidspaces-gki-support.sh <workspace-dir>
EOF
}

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 1
fi

WORKSPACE_DIR="$1"
COMMON_DIR="$WORKSPACE_DIR/common"
GKI_DEFCONFIG="$COMMON_DIR/arch/arm64/configs/gki_defconfig"
MAKEFILE_PATH="$COMMON_DIR/Makefile"
DROIDSPACES_FRAGMENT="$COMMON_DIR/droidspaces.fragment"
PRIVATE_FRAGMENT="$COMMON_DIR/private.fragment"
LTO_FRAGMENT="$COMMON_DIR/lto.fragment"
FEATURES_FRAGMENT="$COMMON_DIR/features.fragment"
KLEAF_FRAGMENT="$COMMON_DIR/coreshift.kleaf.fragment"
DROIDSPACES_DIR="$COMMON_DIR/Droidspaces"
DROIDSPACES_REPO="${DROIDSPACES_REPO:-https://github.com/ravindu644/Droidspaces-OSS.git}"
DROIDSPACES_REF="${DROIDSPACES_REF:-main}"
DROIDSPACES_SYSVIPC_KABI_SLOT="${DROIDSPACES_SYSVIPC_KABI_SLOT:-6_7_8}"

if [ -n "${CORESHIFT_LOG_DIR:-}" ]; then
  DROIDSPACES_LOG_DIR="$CORESHIFT_LOG_DIR/patches/droidspaces"
  mkdir -p "$DROIDSPACES_LOG_DIR"
else
  DROIDSPACES_LOG_DIR=""
fi

log() {
  echo "[droidspaces] $*"
}

fail() {
  echo "[droidspaces] $*" >&2
  exit 1
}

patch_log_path() {
  local patch_file="$1"
  local patch_base

  patch_base="$(basename "$patch_file")"
  if [ -n "$DROIDSPACES_LOG_DIR" ]; then
    printf '%s\n' "$DROIDSPACES_LOG_DIR/$patch_base.log"
  else
    mktemp
  fi
}

cleanup_patch_log() {
  local patch_log="$1"
  if [ -z "$DROIDSPACES_LOG_DIR" ]; then
    rm -f "$patch_log"
  fi
}

apply_patch_file() {
  local patch_file="$1"
  local patch_log

  patch_log="$(patch_log_path "$patch_file")"
  : > "$patch_log"

  log "Dry-run kernel patch: $patch_file"
  if (cd "$COMMON_DIR" && patch --dry-run -p1 < "$patch_file") >"$patch_log" 2>&1; then
    log "Applying kernel patch: $patch_file"
    if ! (cd "$COMMON_DIR" && patch -p1 < "$patch_file") >>"$patch_log" 2>&1; then
      echo "Failed to apply kernel patch: $patch_file" >&2
      sed -n '1,120p' "$patch_log" >&2
      cleanup_patch_log "$patch_log"
      return 1
    fi
    cleanup_patch_log "$patch_log"
    return 0
  fi

  if (cd "$COMMON_DIR" && patch --dry-run -R -p1 < "$patch_file") >"$patch_log" 2>&1; then
    log "Skipping already-applied kernel patch: $patch_file"
    cleanup_patch_log "$patch_log"
    return 0
  fi

  echo "Failed dry-run for kernel patch: $patch_file" >&2
  echo "Patch target directory: $COMMON_DIR" >&2
  sed -n '1,120p' "$patch_log" >&2
  cleanup_patch_log "$patch_log"
  return 1
}

if [ ! -d "$COMMON_DIR" ]; then
  fail "Workspace common directory not found: $COMMON_DIR"
fi

if ! git -C "$COMMON_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "Workspace common directory is not a git repo: $COMMON_DIR"
fi

if [ ! -f "$GKI_DEFCONFIG" ]; then
  fail "Missing GKI defconfig: $GKI_DEFCONFIG"
fi

if [ ! -f "$MAKEFILE_PATH" ]; then
  fail "Missing kernel Makefile: $MAKEFILE_PATH"
fi

for required_fragment in "$PRIVATE_FRAGMENT" "$LTO_FRAGMENT" "$DROIDSPACES_FRAGMENT" "$FEATURES_FRAGMENT"; do
  if [ ! -f "$required_fragment" ]; then
    fail "Missing generated config fragment: $required_fragment"
  fi
done

command -v git >/dev/null 2>&1 || fail "Missing required tool: git"
command -v patch >/dev/null 2>&1 || fail "Missing required tool: patch"
command -v python3 >/dev/null 2>&1 || fail "Missing required tool: python3"

sync_kleaf_fragment() {
  python3 - "$PRIVATE_FRAGMENT" "$LTO_FRAGMENT" "$DROIDSPACES_FRAGMENT" "$FEATURES_FRAGMENT" "$KLEAF_FRAGMENT" <<'PY'
from pathlib import Path
import sys

private_fragment = Path(sys.argv[1])
lto_fragment = Path(sys.argv[2])
droidspaces_fragment = Path(sys.argv[3])
features_fragment = Path(sys.argv[4])
kleaf_fragment = Path(sys.argv[5])

def read_normalized(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")

def with_trailing_newline(text: str) -> str:
    if not text:
        return ""
    return text if text.endswith("\n") else text + "\n"

combined = (
    with_trailing_newline(read_normalized(private_fragment))
    + with_trailing_newline(read_normalized(lto_fragment))
    + with_trailing_newline(read_normalized(droidspaces_fragment))
    + with_trailing_newline(read_normalized(features_fragment))
)
kleaf_fragment.write_text(combined, encoding="utf-8")
PY
}

detect_kernel_version() {
  local version_output
  version_output="$(
    python3 - "$MAKEFILE_PATH" "$COMMON_DIR/include/config/kernel.release" 2>&1 <<'PY'
import re
import sys
from pathlib import Path

makefile_path = Path(sys.argv[1])
release_path = Path(sys.argv[2])

try:
    text = makefile_path.read_text(encoding="utf-8", errors="ignore").splitlines()
except OSError as exc:
    raise SystemExit(f"Could not read {makefile_path}: {exc}")

fields = {}
for key in ("VERSION", "PATCHLEVEL"):
    for line in text:
        match = re.match(rf"{key}\s*=\s*(\d+)\s*$", line)
        if match:
            fields[key] = int(match.group(1))
            break

if "VERSION" in fields and "PATCHLEVEL" in fields:
    print(f"{fields['VERSION']}.{fields['PATCHLEVEL']}")
    raise SystemExit(0)

if release_path.is_file():
    release = release_path.read_text(encoding="utf-8", errors="ignore").strip()
    match = re.match(r"(\d+)\.(\d+)", release)
    if match:
        print(f"{int(match.group(1))}.{int(match.group(2))}")
        raise SystemExit(0)

raise SystemExit("Could not detect kernel version from Makefile or include/config/kernel.release")
PY
  )" || fail "$version_output"

  printf '%s\n' "$version_output"
}

detect_kernel_flavor() {
  local gki_build_config

  gki_build_config="$(find "$COMMON_DIR" -maxdepth 1 -type f -name 'build.config.gki*' -print -quit)"
  if [ -n "$gki_build_config" ] && [ -f "$GKI_DEFCONFIG" ]; then
    printf 'GKI\n'
    return 0
  fi

  fail "Detected non-GKI kernel tree. Droidspaces support is GKI-only."
}

clone_droidspaces_source() {
  if [ -e "$DROIDSPACES_DIR" ] && [ ! -d "$DROIDSPACES_DIR/.git" ]; then
    log "Removing non-git Droidspaces directory: $DROIDSPACES_DIR"
    rm -rf "$DROIDSPACES_DIR"
  fi

  if [ -d "$DROIDSPACES_DIR/.git" ]; then
    log "Reusing existing Droidspaces checkout: $DROIDSPACES_DIR"
    git -C "$DROIDSPACES_DIR" fetch --depth 1 origin "$DROIDSPACES_REF" || true
  else
    git clone --depth 1 "$DROIDSPACES_REPO" "$DROIDSPACES_DIR"
    git -C "$DROIDSPACES_DIR" fetch --depth 1 origin "$DROIDSPACES_REF" || true
  fi

  if ! git -C "$DROIDSPACES_DIR" checkout "$DROIDSPACES_REF"; then
    if git -C "$DROIDSPACES_DIR" rev-parse --verify FETCH_HEAD >/dev/null 2>&1; then
      git -C "$DROIDSPACES_DIR" checkout --detach FETCH_HEAD
    else
      fail "Unable to checkout Droidspaces ref: $DROIDSPACES_REF"
    fi
  fi
}

select_patch_files() {
  local patch_root="$DROIDSPACES_DIR/Documentation/resources/kernel-patches/GKI"
  local selected=()

  if [ "$KERNEL_VERSION_MAJOR" -gt 6 ] || { [ "$KERNEL_VERSION_MAJOR" -eq 6 ] && [ "$KERNEL_VERSION_MINOR" -ge 12 ]; }; then
    selected+=("$patch_root/kernel-6.12/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch")
  else
    case "$DROIDSPACES_SYSVIPC_KABI_SLOT" in
      1_2_3|3_4_5|6_7_8)
        ;;
      *)
        fail "Unsupported DROIDSPACES_SYSVIPC_KABI_SLOT: $DROIDSPACES_SYSVIPC_KABI_SLOT"
        ;;
    esac
    selected+=("$patch_root/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_${DROIDSPACES_SYSVIPC_KABI_SLOT}.patch")
    if [ "$KERNEL_VERSION_MAJOR" -lt 5 ] || { [ "$KERNEL_VERSION_MAJOR" -eq 5 ] && [ "$KERNEL_VERSION_MINOR" -le 10 ]; }; then
      selected+=("$patch_root/below-kernel-6.12/002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch")
    fi
  fi

  printf '%s\n' "${selected[@]}"
}

write_droidspaces_fragment() {
  python3 - "$DROIDSPACES_FRAGMENT" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = """# Generated by scripts/apply-droidspaces-gki-support.sh
# Droidspaces GKI support fragment.

CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
CONFIG_PID_NS=y
CONFIG_DEVTMPFS=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_TARGET_REJECT=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_IP_SET=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_TMPFS_XATTR=y
"""

previous = path.read_text(encoding="utf-8") if path.exists() else ""
path.write_text(text, encoding="utf-8")
print("already up to date" if previous == text else "updated")
PY
}

ensure_export_symbol_once() {
  local target_file="$1"
  local symbol_line="$2"

  python3 - "$target_file" "$symbol_line" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
symbol = sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
updated = []
seen = False
duplicates = 0

for line in lines:
    if line == symbol:
        if not seen:
            updated.append(line)
            seen = True
        else:
            duplicates += 1
        continue
    updated.append(line)

action = "already present"
if not seen:
    updated.append("")
    updated.append(symbol)
    action = "added"
elif duplicates:
    action = "deduped"

path.write_text("\n".join(updated) + "\n", encoding="utf-8")
print(action)
PY
}

verify_droidspaces_fragment() {
  python3 - "$DROIDSPACES_FRAGMENT" \
    CONFIG_SYSVIPC \
    CONFIG_POSIX_MQUEUE \
    CONFIG_IPC_NS \
    CONFIG_PID_NS \
    CONFIG_DEVTMPFS \
    CONFIG_NETFILTER_XT_MATCH_ADDRTYPE \
    CONFIG_NETFILTER_XT_TARGET_REJECT \
    CONFIG_NETFILTER_XT_TARGET_LOG \
    CONFIG_NETFILTER_XT_MATCH_RECENT \
    CONFIG_IP_SET \
    CONFIG_IP_SET_HASH_IP \
    CONFIG_IP_SET_HASH_NET \
    CONFIG_NETFILTER_XT_SET \
    CONFIG_TMPFS_XATTR <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
required = sys.argv[2:]
lines = path.read_text(encoding="utf-8").splitlines()

for option in required:
    pattern = re.compile(rf"^(?:#\s+{re.escape(option)}\s+is\s+not\s+set|{re.escape(option)}=.*)$")
    matches = [line for line in lines if pattern.match(line)]
    if len(matches) != 1 or matches[0] != f"{option}=y":
        raise SystemExit(f"{path}: expected exactly one active {option}=y entry")
print("ok")
PY
}

verify_export_symbol_once() {
  local target_file="$1"
  local symbol_line="$2"

  python3 - "$target_file" "$symbol_line" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
symbol = sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
matches = [line for line in lines if line == symbol]
if len(matches) != 1:
    raise SystemExit(f"{path}: expected exactly one {symbol}")
print("ok")
PY
}

KERNEL_VERSION="$(detect_kernel_version)"
KERNEL_VERSION_MAJOR="${KERNEL_VERSION%%.*}"
KERNEL_VERSION_MINOR="${KERNEL_VERSION#*.}"
KERNEL_FLAVOR="$(detect_kernel_flavor)"

log "Detected kernel version: $KERNEL_VERSION"
log "Detected kernel flavor: $KERNEL_FLAVOR"

clone_droidspaces_source

droidspaces_commit="$(git -C "$DROIDSPACES_DIR" rev-parse HEAD)"
log "Selected Droidspaces repo: $DROIDSPACES_REPO"
log "Selected Droidspaces ref: $DROIDSPACES_REF"
log "Selected Droidspaces commit: $droidspaces_commit"

mapfile -t PATCH_FILES < <(select_patch_files)
if [ "${#PATCH_FILES[@]}" -eq 0 ]; then
  fail "No Droidspaces patches selected for kernel version: $KERNEL_VERSION"
fi

if [ "$KERNEL_VERSION_MAJOR" -lt 6 ] || { [ "$KERNEL_VERSION_MAJOR" -eq 6 ] && [ "$KERNEL_VERSION_MINOR" -lt 12 ]; }; then
  log "Selected SYSVIPC kABI slot: $DROIDSPACES_SYSVIPC_KABI_SLOT"
fi

for patch_file in "${PATCH_FILES[@]}"; do
  [ -f "$patch_file" ] || fail "Missing required Droidspaces patch: $patch_file"
  log "Selected Droidspaces patch file: $patch_file"
done

for patch_file in "${PATCH_FILES[@]}"; do
  apply_patch_file "$patch_file"
done

config_status="$(write_droidspaces_fragment)"
log "Droidspaces config fragment: $DROIDSPACES_FRAGMENT ($config_status)"
sync_kleaf_fragment
log "Synced Kleaf config fragment: $KLEAF_FRAGMENT"

if [ "$KERNEL_VERSION_MAJOR" -gt 6 ] || { [ "$KERNEL_VERSION_MAJOR" -eq 6 ] && [ "$KERNEL_VERSION_MINOR" -ge 12 ]; }; then
  [ -f "$COMMON_DIR/ipc/namespace.c" ] || fail "Missing IPC namespace source: $COMMON_DIR/ipc/namespace.c"
  [ -f "$COMMON_DIR/ipc/msgutil.c" ] || fail "Missing IPC msgutil source: $COMMON_DIR/ipc/msgutil.c"
  namespace_status="$(ensure_export_symbol_once "$COMMON_DIR/ipc/namespace.c" 'EXPORT_SYMBOL_GPL(put_ipc_ns);')"
  msgutil_status="$(ensure_export_symbol_once "$COMMON_DIR/ipc/msgutil.c" 'EXPORT_SYMBOL_GPL(init_ipc_ns);')"
  log "IPC symbol export $COMMON_DIR/ipc/namespace.c: $namespace_status"
  log "IPC symbol export $COMMON_DIR/ipc/msgutil.c: $msgutil_status"
else
  log "IPC symbol export step skipped for kernel version: $KERNEL_VERSION"
fi

verify_droidspaces_fragment >/dev/null
if [ "$KERNEL_VERSION_MAJOR" -gt 6 ] || { [ "$KERNEL_VERSION_MAJOR" -eq 6 ] && [ "$KERNEL_VERSION_MINOR" -ge 12 ]; }; then
  verify_export_symbol_once "$COMMON_DIR/ipc/namespace.c" 'EXPORT_SYMBOL_GPL(put_ipc_ns);' >/dev/null
  verify_export_symbol_once "$COMMON_DIR/ipc/msgutil.c" 'EXPORT_SYMBOL_GPL(init_ipc_ns);' >/dev/null
fi

if [ -n "$DROIDSPACES_LOG_DIR" ]; then
  {
    echo "Kernel version: $KERNEL_VERSION"
    echo "Kernel flavor: $KERNEL_FLAVOR"
    echo "Droidspaces repo: $DROIDSPACES_REPO"
    echo "Droidspaces ref: $DROIDSPACES_REF"
    echo "Droidspaces commit: $droidspaces_commit"
    if [ "$KERNEL_VERSION_MAJOR" -lt 6 ] || { [ "$KERNEL_VERSION_MAJOR" -eq 6 ] && [ "$KERNEL_VERSION_MINOR" -lt 12 ]; }; then
      echo "Selected SYSVIPC kABI slot: $DROIDSPACES_SYSVIPC_KABI_SLOT"
    fi
    printf 'Selected patch: %s\n' "${PATCH_FILES[@]}"
    echo "Droidspaces config fragment: $DROIDSPACES_FRAGMENT ($config_status)"
  } > "$DROIDSPACES_LOG_DIR/source.txt"
fi

echo "Droidspaces GKI support applied successfully"
