# CoreShift ACK workspace

JSON-driven Android Common Kernel/GKI workspace builder for supported ACK KMI lines.

It is intended for repeatable ACK/GKI kernel builds and CI templates, not ROM building.

## Features

- Manifest-based ACK workspace setup
- Profile-specific manifest workspace policy
- KMI/profile-driven branch and build backend selection
- `google_build_sh` and Kleaf support
- Private Kconfig fragment support
- Profile-aware LTO
- Optional BBG, KernelSU, KernelSU SUSFS, and Droidspaces GKI support
- AnyKernel3 packaging
- GitHub Actions templates

## Quick start

```bash
git clone https://github.com/CoreShiftD/android_kernel_common_lts.git
cd android_kernel_common_lts
./scripts/install-build-tools.sh
./scripts/build-kernel.sh android12-5.10-lts
```

Build a variant:

```bash
./scripts/build-kernel.sh android12-5.10-lts --variant ksu
./scripts/build-kernel.sh android12-5.10-lts --variant ksu-susfs-bbg
```

Enable config-driven Droidspaces on a GKI profile:

```bash
./scripts/build-kernel.sh android16-6.12-lts --variant droidspaces
```

Use a local private fragment:

```bash
cp configs/fragments/private.fragment.example private.fragment
```

## GitHub Actions

- `Build.yml`: single selected profile and variant
- `Build-All.yml`: vanilla-only matrix across supported profiles
- `Build-Variants.yml`: JSON-resolved allowed profile/variant matrix
- `Test-Manifest-Trim.yml`: manifest workspace policy test only

## Supported KMI lines

All profiles support `vanilla`, `droidspaces`, `ksu`, `ksu-susfs-bbg`, and `ksu-susfs-bbg-droidspaces`.

| KMI | Profiles | LTO |
| --- | --- | --- |
| 5.4 | `android11-5.4-lts`, `android12-5.4-lts` | `full` |
| 5.10 | `android12-5.10-lts`, `android13-5.10-lts` | `full` |
| 5.15 | `android13-5.15-lts`, `android14-5.15-lts` | `full` |
| 6.1 | `android14-6.1-lts` | `full` |
| 6.6 | `android15-6.6-lts` | `full` |
| 6.12 | `android16-6.12-lts` | `thin` |

## Documentation

- [Profiles](docs/profiles.md)
- [Build guide](docs/build.md)
- [GitHub Actions workflows](docs/workflows.md)
- [Config fragments](docs/config-fragments.md)
- [Variants](docs/variants.md)
- [AnyKernel3 packaging](docs/packaging-ak3.md)
- [Ccache](docs/ccache.md)
- [Manifest workspace](docs/manifest-workspace.md)
- [Troubleshooting](docs/troubleshooting.md)

## Scope and non-goals

CoreShift builds ACK/GKI kernel artifacts and AnyKernel3 zip outputs.

- Device-specific `boot.img` or `vendor_boot.img` packaging remains separate.
- SUSFS is available through KernelSU variants.
- This is not a ROM builder.
