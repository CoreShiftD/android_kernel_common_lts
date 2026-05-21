# Variants

## JSON-Driven Variant Model

Variant behavior is defined by:

- `configs/variants.json`
- `configs/profile-variants.json`

`configs/variants.json` defines the production variant names, feature lists, and AK3 suffixes. `configs/profile-variants.json` controls which production variants are enabled on each profile.

## Production Variants

| Variant | KernelSU | SUSFS | BBG | Droidspaces |
| --- | --- | --- | --- | --- |
| `vanilla` | no | no | no | no |
| `droidspaces` | no | no | no | yes |
| `ksu` | yes | no | no | no |
| `ksu-susfs-bbg` | yes | yes | yes | no |
| `ksu-susfs-bbg-droidspaces` | yes | yes | yes | yes |

No other variant names or aliases are supported.

## Feature Integration

- KernelSU is staged by `scripts/apply-ksu.sh`, which links the resolved KernelSU kernel integration tree into `drivers/kernelsu`.
- SUSFS requires KernelSU and is integrated from Simonpunk GitLab: `https://gitlab.com/simonpunk/susfs4ksu.git`.
- BBG is integrated through the upstream Baseband-guard `setup.sh`.
- Droidspaces is a GKI-only feature. Droidspaces variants run `scripts/apply-droidspaces-gki-support.sh`, write `common/droidspaces.fragment`, and fail clearly if the prepared kernel tree is not GKI.

Feature application order is:

1. `droidspaces`
2. `ksu`
3. `susfs`
4. `bbg`

## 5.4 KMI KernelSU Setup

5.4 KMI profiles support the same production variants as newer KMI lines.

Plain `ksu` uses the default KernelSU source:

```text
https://github.com/KOWX712/KernelSU
```

The 5.4 KMI SUSFS variants use the configured `legacy-multisu` compatibility setup:

```text
https://github.com/xxblebleblexx/MultiSU
ref: legacy
```

CoreShift runs the fetched source `setup.sh` from the prepared kernel root, then normalizes `drivers/kernelsu`, `drivers/Makefile`, and `drivers/Kconfig` so repeated setup runs remain stable. Sources without a setup script use the repo-owned fallback layout integration.

## Pinning Feature Refs

Examples:

```bash
./scripts/build-kernel.sh android13-5.15-lts --variant ksu --build-env KSU_REF=<commit-or-tag>
./scripts/build-kernel.sh android13-5.15-lts --variant ksu-susfs-bbg --build-env SUSFS_REF=<branch-or-commit>
./scripts/build-kernel.sh android16-6.12-lts --variant droidspaces --build-env DROIDSPACES_REF=<branch-or-commit>
```

If `SUSFS_REF` is unset, CoreShift first checks `configs/susfs-refs.json`, then probes likely official branch names for the selected Android release and KMI line.

SUSFS config is variant-owned. It is written to `common/features.fragment`, not `configs/fragments/coreshift.fragment` or repo-root `private.fragment`.

Local SUSFS same-path overrides under `patches/susfs/<profile>/` are full replacements for the matching upstream file sections. They are not tiny post-patches; each override must preserve the complete upstream SUSFS behavior for that file and adjust only for kernel source drift.

Droidspaces config is feature-owned. It is written to `common/droidspaces.fragment`, not `common/arch/arm64/configs/gki_defconfig`.

## Feature Git Metadata Policy

- KernelSU, SUSFS, Baseband-guard, and Droidspaces remain build-scoped Git checkouts.
- Those directories are excluded from the prepared workspace commit.
- `KernelSU/.git`, `SUSFS/.git`, `Baseband-guard/.git`, and `Droidspaces/.git` are kept during build for version metadata.
- Staged gitlinks and submodule-like `160000` entries are refused.
