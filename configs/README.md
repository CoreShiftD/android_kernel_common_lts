# Kernel Build Configs

This directory belongs to the `main` control branch. It is for build scripts,
workflow metadata, config profiles, release logic, and documentation.

The Android LTS branches are clean kernel source mirrors of upstream
`kernel/common`. Do not place these control files on kernel source branches.

## Files

- `branches.json` lists supported Android LTS mirror branches and their default
  build backend.
- `toolchains.json` pins Clang versions per branch for reproducible ACK/GKI
  builds.
- `profiles/*.json` defines one build profile per branch for the thin build
  wrapper.

## Backends

Profiles using `google_build_sh` dispatch through Google's `build.sh` flow and
use `common/build.config.gki.aarch64` by default.

Profiles using `kleaf` dispatch through Bazel/Kleaf and use
`//common:kernel_aarch64_dist` by default.

Backend-specific fields that do not apply to a profile are set to `null`. For
example, `google_build_sh` profiles use `bazel_target: null`, and `kleaf`
profiles use `build_config: null`.

## LTO

All profiles default to full LTO. This matches conservative GKI-oriented
defaults, but full LTO can be slower and require more memory in CI than thinner
link-time optimization modes.

## Toolchains

Clang versions are pinned per branch for reproducibility. Android Platform
Clang and Android Linux Kernel Clang can differ, and newer visible Clang
directories are not automatically the correct kernel compiler.

Use `toolchains.json` `by_branch` values as the first choice. The `default`
value is only a fallback for tooling that cannot map a branch yet.

## Validation

These profiles are conservative defaults and may need correction after real
test builds against each mirrored branch.
