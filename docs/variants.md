# Variants

## JSON-driven variant model

Variant behavior is defined by:

- `configs/variants.json`
- `configs/profile-variants.json`

`configs/variants.json` describes variant names, feature lists, and AK3 suffixes. `configs/profile-variants.json` controls which variants are enabled on each profile.

## Implemented variants

- `vanilla`
- `bbg`
- `ksu`
- `ksu-bbg`
- `ksu-susfs`
- `ksu-susfs-bbg`

## Feature integration

- BBG is integrated through the upstream Baseband-guard `setup.sh`.
- KernelSU is integrated through the upstream KernelSU `kernel/setup.sh`.
- On 5.4 profiles, the `ksu` feature is experimental and uses MultiSU legacy as the KSU provider.
- On 5.10+ profiles, the `ksu` feature continues to use the existing KernelSU provider.
- SUSFS is experimental, requires KernelSU, and is integrated from Simonpunk GitLab: `https://gitlab.com/simonpunk/susfs4ksu.git`.
- On 5.4 profiles, SUSFS uses the profile-specific external patch from `NonGKI_Kernel_Build_2nd` by default.
- SUSFS integration follows the old CoreShift-GKI phase order while using the Simonpunk branch layout.
- CoreShift copies `fs/susfs.c` and `include/linux/susfs*.h`, applies the core SUSFS patch from `common/`, locates the integrated KSU root through `*/kernel/include/ksu.h`, then applies `KernelSU/10_enable_susfs_for_ksu.patch` from that KSU root.
- SUSFS config is generated from the selected SUSFS patches and resulting Kconfig symbols.
- CoreShift enables every discovered `KSU_SUSFS*` symbol in `common/features.fragment`.
- Missing `KSU_SUSFS*` symbols abort the build. CoreShift never injects `CONFIG_KSU_SUSFS` by itself.
- SUSFS variants are enabled only on profiles that already support KernelSU.

Feature application order is:

1. `ksu`
2. `susfs`
3. `bbg`

## 5.4 policy

- BBG is enabled on supported 5.4 profiles.
- KSU, KSU+BBG, KSU+SUSFS, and KSU+SUSFS+BBG are enabled experimentally on 5.4 through MultiSU legacy.
- 4.9 and 4.19 legacy/device-kernel branches are intentionally out of scope for the main profile matrix for now.
- If 5.4 MultiSU or SUSFS fails, test in order: `ksu`, `ksu-bbg`, `ksu-susfs`, then `ksu-susfs-bbg`.

Users experimenting with 5.4 KSU can pin `MULTISU_REF` to a known-good branch or commit.

## Pinning feature refs

Examples:

```bash
./scripts/build-kernel.sh android13-5.15-lts --variant ksu --build-env KSU_REF=<commit-or-tag>
./scripts/build-kernel.sh android13-5.15-lts --variant bbg --build-env BBG_REF=<commit-or-tag>
./scripts/build-kernel.sh android13-5.15-lts --variant ksu-susfs --build-env SUSFS_REF=<branch-or-commit>
./scripts/build-kernel.sh android12-5.4-lts --variant ksu --build-env MULTISU_REF=<branch-or-commit>
./scripts/build-kernel.sh android12-5.4-lts --variant ksu-susfs --build-env SUSFS_PATCH_URLS=<url-or-local-path>
```

If `SUSFS_REF` is unset, CoreShift first checks `configs/susfs-refs.json`, then probes likely official branch names for the selected Android release and kernel version.

SUSFS config is variant-owned. It is written to `common/features.fragment`, not `configs/fragments/coreshift.fragment` or repo-root `private.fragment`.

## Feature Git metadata policy

- KernelSU, SUSFS, and Baseband-guard remain temporary Git checkouts during build.
- Those directories are excluded from the prepared workspace commit.
- `KernelSU/.git`, `SUSFS/.git`, and `Baseband-guard/.git` are kept during build for version metadata.
- Staged gitlinks and submodule-like `160000` entries are refused.
