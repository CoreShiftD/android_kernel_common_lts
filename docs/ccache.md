# Ccache

## Current behavior

CoreShift does not enable ccache in CI or in the default local build flow.

Persistent compiler and workspace caches are disabled so ACK/GKI sync and build outputs are reproducible across runs.

## Policy

- GitHub Actions workflows do not restore or save ccache caches.
- `scripts/build-kernel.sh` sets `USE_CCACHE=0` by default.
- `CCACHE_*`, `USE_CCACHE`, and `CORESHIFT_CCACHE_DEBUG` are rejected as `--build-env` inputs.
- The ccache setup and wrapper helper scripts were removed.

## Cleanup

Build workflows and `scripts/build-kernel.sh` clean generated state before normal setup/build paths:

- `.work/`
- `.ccache/`
- `.cache/`
- `out/`
- `bazel-*`

Source directories such as `.git/`, `scripts/`, `configs/`, `patches/`, `profiles/`, and `docs/` are not removed by this cleanup.
