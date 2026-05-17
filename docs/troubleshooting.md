# Troubleshooting

## 5.4 UAPI sysroot and header tests

5.4 profiles can still run UAPI header tests that need target libc headers.

CoreShift patches the prepared workspace so those tests can use `UAPI_SYSROOT_CFLAGS`, with the default sysroot pointing at `/usr/aarch64-linux-gnu/include`.

## `android16-6.12-lts` full LTO and `rust_binder.ko`

`android16-6.12-lts` uses thin LTO because full LTO caused the Kleaf `rust_binder.ko` output to disappear.

Full-LTO override paths are intentionally rejected for that profile.

## BBG `CONFIG_LSM` / `baseband_guard`

BBG writes variant-owned config into `common/features.fragment` and ensures `CONFIG_LSM` includes `baseband_guard`.

If you hand-edit fragment inputs around BBG, do not remove that token from the effective LSM list.

## KSU on 5.4

5.4 KSU variants are experimental and use MultiSU legacy as the KSU provider.

For MultiSU setup or link failures, check that `drivers/kernelsu` points to `../MultiSU/kernel`, `drivers/Kconfig` contains `source "drivers/kernelsu/Kconfig"`, and `common/features.fragment` contains `CONFIG_KSU=y`.

Use `MULTISU_REF` to pin a known-good MultiSU branch or commit.

## SUSFS

SUSFS requires KernelSU. Use `ksu-susfs` or `ksu-susfs-bbg`; a raw `susfs` feature without `ksu` is rejected.

SUSFS integration follows the old CoreShift-GKI phase order while using the Simonpunk branch layout:

1. Copy `fs/susfs.c` and `include/linux/susfs*.h`
2. Apply the core SUSFS patch from `common/`
3. Locate the integrated KSU root through `*/kernel/include/ksu.h`
4. Apply `KernelSU/10_enable_susfs_for_ksu.patch` from that KSU root
5. Scan selected SUSFS patches and resulting tree Kconfig files for `KSU_SUSFS*`

CoreShift scans the selected SUSFS patch files and resulting Kconfig files, then writes every discovered `KSU_SUSFS*` symbol to `common/features.fragment`. SUSFS config is variant-owned, not part of `configs/fragments/coreshift.fragment` or repo-root `private.fragment`.

If no KSU root is found, KernelSU or MultiSU integration failed before SUSFS.

If no `KSU_SUSFS*` symbols are found, the KernelSU SUSFS patch did not apply or the wrong Simonpunk patch set was selected. CoreShift aborts in that case and never injects `CONFIG_KSU_SUSFS` by itself.

If the core SUSFS patch fails, the selected profile source does not match the chosen SUSFS patch set.

If the KernelSU SUSFS patch fails, the selected KSU provider tree does not match the selected Simonpunk patch set.

Use `SUSFS_REF` to pin a known-good Simonpunk branch or commit when automatic branch resolution picks no compatible branch.

If `ksu-susfs-bbg` fails, test `ksu-susfs` first so SUSFS and BBG failures are isolated.

For 5.4 SUSFS patch rejects or missing `KSU_SUSFS*` symbols, check `patches/susfs/*.log`, any included `*.rej` files, and `susfs-config-symbols.txt`. Use `SUSFS_PATCH_URLS` to pin or override experimental 5.4 SUSFS patches, and add `ksu_patches` in `configs/susfs-patches.json` if the external 5.4 patch set needs a separate KSU-side patch.

4.9 and 4.19 legacy/device-kernel branches are intentionally out of scope for this matrix for now. Keep MultiSU and SUSFS experiments limited to the existing 5.4 profiles.

## Build log artifacts

Every build workflow uploads a separate CoreShift logs artifact next to the AK3 artifact. The log zip includes `build-kernel.log`, manifest reports, generated overlay XML, patch logs, generated fragments, selected profile/variant metadata, workspace diagnostics, and reject files when present.

For SUSFS failures, inspect `patches/susfs/*.log`, `susfs-config-symbols.txt`, and any included `*.rej` files.

For manifest policy issues, inspect `manifest-trim-report.txt` and `coreshift-overlay.xml`.

## `KSU_GIT_VERSION` warning

CoreShift keeps `KernelSU/.git` during build on purpose so KernelSU version metadata remains available.

If version metadata is missing, inspect whether the prepared workspace lost the KernelSU git directory unexpectedly.

## Ccache zero-hit quick checks

If `ccache -s` shows no cacheable compiler calls:

- Confirm wrapper setup actually enabled
- Confirm the selected backend is using the wrapper path
- Confirm the chosen repo/AOSP clang exists and is runnable
- Confirm repeated builds are using the same profile, source revision, and relevant flags

## Aggressive overlay failures

If aggressive overlay policy breaks `repo sync` or the later kernel build:

- Switch that profile `manifest_overlay_mode` back to `safe`
- Safe mode is the supported current policy
- Aggressive mode is experimental
- Run `Test-Manifest-Trim.yml` with `extra_remove_projects` only when you need to validate a larger explicit remove list
- Inspect `manifest-trim-report.txt`
- Promote working rules into `manifests/overlays/<profile>.json`
