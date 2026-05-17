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

5.4 does not enable KSU by default because current KernelSU `main` includes `linux/pgtable.h`, which is missing on the tested 5.4 ACK common trees.

## `KSU_GIT_VERSION` warning

CoreShift keeps `KernelSU/.git` during build on purpose so KernelSU version metadata remains available.

If version metadata is missing, inspect whether the prepared workspace lost the KernelSU git directory unexpectedly.

## Ccache zero-hit quick checks

If `ccache -s` shows no cacheable compiler calls:

- Confirm wrapper setup actually enabled
- Confirm the selected backend is using the wrapper path
- Confirm the chosen repo/AOSP clang exists and is runnable
- Confirm repeated builds are using the same profile, source revision, and relevant flags

## Manifest trim failures

If `repo sync` fails after aggressive manifest trimming, rerun with:

```bash
./scripts/build-kernel.sh android16-6.12-lts \
  --build-env CORESHIFT_MANIFEST_TRIM=safe
```

If safe mode works, inspect `manifest-trim-report.txt` in the workspace root and restore the needed keep pattern before trying aggressive mode again.
