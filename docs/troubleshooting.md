# Troubleshooting

## 5.4 UAPI sysroot and header tests

5.4 profiles can still run UAPI header tests that need target libc headers.

CoreShift patches the prepared workspace so those tests can use `UAPI_SYSROOT_CFLAGS`, with the default sysroot pointing at `/usr/aarch64-linux-gnu/include`.

## `android16-6.12-lts` LTO policy

`android16-6.12-lts` requires ThinLTO for the 6.12 KMI build path.

Full-LTO override paths are rejected for that profile.

## BBG `CONFIG_LSM` / `baseband_guard`

BBG writes variant-owned config into `common/features.fragment` and ensures `CONFIG_LSM` includes `baseband_guard`.

If you hand-edit fragment inputs around BBG, do not remove that token from the effective LSM list.

## KernelSU on 5.4 KMI

5.4 KMI profiles support KernelSU variants. Plain `ksu` uses the normal KOWX KernelSU source. SUSFS variants use the configured MultiSU compatibility setup.

## SUSFS

SUSFS requires KernelSU. Use `ksu-susfs-bbg` or `ksu-susfs-bbg-droidspaces`; a raw `susfs` feature without `ksu` is rejected.

If SUSFS patching fails, check for patch rejects, a wrong branch/ref, or a missing `CONFIG_KSU_SUSFS` symbol after patching. Pin a known-good Simonpunk ref with `SUSFS_REF` when automatic branch resolution picks no compatible branch.

CoreShift scans the selected Simonpunk patch files and resulting Kconfig files, then writes every discovered `KSU_SUSFS*` symbol to `common/features.fragment`. SUSFS config is variant-owned, not part of `configs/fragments/coreshift.fragment` or repo-root `private.fragment`.

When a local same-path SUSFS override exists, `scripts/apply-susfs.sh` replaces the matching upstream file section with the local full replacement. If a SUSFS behavior disappears after an override change, audit the local replacement patch against the upstream section first.

If expected SUSFS symbols are missing, verify the selected SUSFS branch/ref and patch set. Use `SUSFS_REF` to pin a known-good Simonpunk branch/ref.

If `ksu-susfs-bbg` fails, test `ksu` first so KernelSU integration can be isolated from SUSFS and BBG integration.

## Build log artifacts

Every build workflow uploads a separate CoreShift logs artifact next to the AK3 artifact. The log zip includes `build-kernel.log`, manifest reports, generated overlay XML, patch logs, generated fragments, selected profile/variant metadata, workspace diagnostics, and reject files when present.

For SUSFS failures, inspect `patches/susfs/*.log`, `susfs-config-symbols.txt`, and any included `*.rej` files.

For manifest policy issues, inspect `manifest-trim-report.txt` and `coreshift-overlay.xml`.

## `KSU_GIT_VERSION` warning

CoreShift keeps `KernelSU/.git` during build on purpose so KernelSU version metadata remains available.

If version metadata is missing, inspect whether the prepared workspace lost the KernelSU git directory unexpectedly.

## Aggressive overlay failures

If aggressive overlay policy breaks `repo sync` or the later kernel build:

- Switch that profile `manifest_overlay_mode` back to `safe`
- Safe mode is the supported current policy
- Aggressive mode is not the default policy
- Run `Test-Manifest-Trim.yml` with `extra_remove_projects` only when you need to validate a larger explicit remove list
- Inspect `manifest-trim-report.txt`
- Promote working rules into `manifests/overlays/<profile>.json`
