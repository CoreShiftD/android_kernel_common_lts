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

## Not implemented

- `susfs`

The repo still carries `susfs`-named variant definitions in `configs/variants.json`, but `scripts/apply-features.sh` rejects `susfs` with `Feature not implemented yet: susfs`.

## Feature integration

- BBG is integrated through the upstream Baseband-guard `setup.sh`.
- KernelSU is integrated through the upstream KernelSU `kernel/setup.sh`.

Feature application order is:

1. `ksu`
2. `bbg`

## 5.4 policy

- BBG is enabled on supported 5.4 profiles.
- KSU is disabled by default on 5.4 because current KernelSU `main` includes `linux/pgtable.h`, which is missing on the tested 5.4 ACK common trees.

Users experimenting with 5.4 KSU can edit `configs/profile-variants.json` locally and pin `KSU_REF` to a known-good branch or commit.

## Pinning feature refs

Examples:

```bash
./scripts/build-kernel.sh android13-5.15-lts --variant ksu --build-env KSU_REF=<commit-or-tag>
./scripts/build-kernel.sh android13-5.15-lts --variant bbg --build-env BBG_REF=<commit-or-tag>
```

## Feature Git metadata policy

- KernelSU and Baseband-guard remain temporary Git checkouts during build.
- Both directories are excluded from the prepared workspace commit.
- `KernelSU/.git` and `Baseband-guard/.git` are kept during build for version metadata.
- Staged gitlinks and submodule-like `160000` entries are refused.

