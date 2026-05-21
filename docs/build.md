# Build guide

## One-command local build

Install host tools:

```bash
./scripts/install-build-tools.sh
```

Build a profile:

```bash
./scripts/build-kernel.sh android12-5.10-lts
```

Build a profile with a variant:

```bash
./scripts/build-kernel.sh android12-5.10-lts --variant ksu
./scripts/build-kernel.sh android12-5.10-lts --variant ksu-susfs-bbg
```

Build with Droidspaces GKI support:

```bash
./scripts/build-kernel.sh android16-6.12-lts --variant droidspaces
./scripts/build-kernel.sh android16-6.12-lts --variant ksu-susfs-bbg-droidspaces
```

Pin a SUSFS ref:

```bash
./scripts/build-kernel.sh android12-5.10-lts --variant ksu-susfs-bbg \
  --build-env SUSFS_REF=<branch-or-commit>
```

Force-enable Droidspaces support for local testing:

```bash
./scripts/build-kernel.sh android15-6.6-lts \
  --build-env DROIDSPACES_ENABLE=1
```

Select a different pre-6.12 SYSVIPC kABI slot if needed:

```bash
./scripts/build-kernel.sh android13-5.15-lts \
  --build-env DROIDSPACES_ENABLE=1 \
  --build-env DROIDSPACES_SYSVIPC_KABI_SLOT=3_4_5
```

## `build-kernel.sh` usage

```bash
scripts/build-kernel.sh <profile-name> [--workspace DIR] [--mode auto|google_build_sh|kleaf] [--variant VARIANT] [--skip-setup] [--clean] [--skip-ak3] [--no-commit-workspace] [--disable-defconfig-check on|off] [--disable-kmi-check on|off] [--build-env KEY=VALUE] [-- EXTRA_BUILD_ARGS...]
```

The script resolves the profile, prepares or reuses `.work/<profile>`, sets up the manifest workspace unless `--skip-setup` is used, applies feature fragments, runs the selected build backend, collects artifacts into `dist/<profile>/`, and packages an AnyKernel3 zip unless `--skip-ak3` is used.

## Local `private.fragment`

Copy the example and edit locally:

```bash
cp configs/fragments/private.fragment.example private.fragment
```

`private.fragment` lives at repo root, is gitignored, and is layered into the generated workspace fragments during setup.

## Installing host tooling

`./scripts/install-build-tools.sh` installs the normal Ubuntu build packages, Arm64 cross-libc headers, and the upstream `repo` launcher in `$HOME/.local/bin/repo`.

## Build environment passthrough

`--build-env KEY=VALUE` passes values through to the build flow. Common examples include:

- `LTO=full`
- `KSU_REF=<commit-or-tag>`
- `BBG_REF=<commit-or-tag>`
- `SUSFS_REF=<branch-or-commit>`
- `DROIDSPACES_ENABLE=1`
- `DROIDSPACES_ENABLE=0`
- `DROIDSPACES_SYSVIPC_KABI_SLOT=6_7_8`
- `CORESHIFT_REPO_JOBS=2`
- `CORESHIFT_REPO_PARTIAL_CLONE=0`
- `CORESHIFT_REPO_CLONE_FILTER=blob:none`

The workflows also expose `build_env` input in `Build.yml` for advanced per-run overrides.

ccache build environment keys are intentionally rejected. CoreShift sets `USE_CCACHE=0` by default and does not configure ccache wrappers.

## Clean build state

CI and normal `scripts/build-kernel.sh` setup remove generated state before sync/build to avoid stale cache behavior:

- `.work/`
- `.ccache/`
- `.cache/`
- `out/`
- `bazel-*`

The cleanup is limited to generated cache/work/output paths. Source directories such as `.git/`, `scripts/`, `configs/`, `patches/`, `profiles/`, `docs/`, and `README.md` are not removed.

## Droidspaces GKI support

Droidspaces is config-driven, not env-only. It is enabled by selecting a variant whose feature list includes `droidspaces`: `droidspaces` or `ksu-susfs-bbg-droidspaces`. Profiles allow Droidspaces by listing those variants in `configs/profile-variants.json`.

`scripts/apply-droidspaces-gki-support.sh` runs against the prepared workspace before the normal feature hooks when the selected variant includes `droidspaces`. The helper supports GKI kernels only, selects the upstream patch set from kernel version, writes the required Kconfig entries into `common/droidspaces.fragment`, refreshes `common/coreshift.kleaf.fragment`, and only adds the required IPC symbol exports for 6.12+ kernels.

`DROIDSPACES_ENABLE` is a developer override, not the normal enablement path:

- unset: follow the selected variant feature list
- `DROIDSPACES_ENABLE=1`: force-enable Droidspaces for local testing
- `DROIDSPACES_ENABLE=0`: force-disable Droidspaces for local testing

The generated `common/droidspaces.fragment` contains the required IPC, namespace, devtmpfs, netfilter/ipset, and tmpfs xattr options. It is merged between `common/lto.fragment` and `common/features.fragment` for both `google_build_sh` and Kleaf paths.

Vanilla builds do not receive Droidspaces, KernelSU, SUSFS, or BBG feature config. Feature fragments are merged only when the selected variant enables the corresponding feature.

The pre-6.12 `SYSVIPC` patch defaults to `DROIDSPACES_SYSVIPC_KABI_SLOT=6_7_8`. Supported override values are `1_2_3`, `3_4_5`, and `6_7_8`.

Patch selection is version-aware:

- GKI below 6.12 uses `GKI/below-kernel-6.12`.
- GKI 5.10 and lower also applies the POSIX mqueue padding patch.
- GKI 6.12 and newer uses `GKI/kernel-6.12/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch`.
- IPC symbol exports are added only for GKI 6.12 and newer.

## Private-build escape hatches

`build-kernel.sh` exposes:

- `--disable-defconfig-check on|off`
- `--disable-kmi-check on|off`

These are explicit private-build escape hatches. They do not guarantee ABI stability or device safety.

## 5.4 UAPI sysroot behavior

For `android*-5.4-lts` profiles, the build flow patches `common/usr/include/Makefile` in the prepared workspace so UAPI header tests can see target libc headers through `UAPI_SYSROOT_CFLAGS`.

The default sysroot points at:

```text
/usr/aarch64-linux-gnu/include
```

You can override it explicitly if needed:

```bash
./scripts/build-kernel.sh android12-5.4-lts \
  --build-env 'UAPI_SYSROOT_CFLAGS=--target=aarch64-linux-gnu -isystem /custom/sysroot/include'
```

## Swap helper

For memory-heavy local builds:

```bash
./scripts/add-swap.sh 24
```
