# Ccache

## Current behavior

CoreShift no longer enables ccache in CI or in the default local build flow.

The previous ccache setup could preserve stale compiler and workspace state across ACK/GKI sync and build attempts. That made failures harder to reproduce, including stale repo state, stale toolchain paths, and unreliable ccache wrapper behavior.

## Policy

- GitHub Actions workflows do not restore or save ccache caches.
- `scripts/build-kernel.sh` sets `USE_CCACHE=0` by default.
- `CCACHE_*`, `USE_CCACHE`, and `CORESHIFT_CCACHE_DEBUG` are rejected as `--build-env` inputs.
- `scripts/setup-ccache.sh` and `scripts/setup-ccache-wrappers.sh` are compatibility no-ops that keep ccache disabled.

## Cleanup

Build workflows and `scripts/build-kernel.sh` clean generated state before normal setup/build paths:

- `.work/`
- `.ccache/`
- `.cache/`
- `out/`
- `bazel-*`

Source directories such as `.git/`, `scripts/`, `configs/`, `patches/`, `profiles/`, and `docs/` are not removed by this cleanup.
