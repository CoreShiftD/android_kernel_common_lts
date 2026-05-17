# CoreShift ACK workspace

JSON-driven Android Common Kernel/GKI workspace builder for multiple ACK LTS branches.

It is intended for repeatable ACK/GKI kernel builds and CI templates, not ROM building.

## Features

- Manifest-based ACK workspace setup
- Profile-specific manifest workspace policy
- Profile-driven branch and build backend selection
- `google_build_sh` and Kleaf support
- Private Kconfig fragment support
- Profile-aware LTO
- Optional BBG, KernelSU, and KernelSU SUSFS variants
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
./scripts/build-kernel.sh android12-5.10-lts --variant ksu-bbg
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

## Supported profiles

| Profile | LTO | Variants |
| --- | --- | --- |
| `android11-5.4-lts` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg` |
| `android12-5.4-lts` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg` |
| `android12-5.10-lts` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg` |
| `android13-5.10-lts` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg` |
| `android13-5.15-lts` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg` |
| `android14-5.15-lts` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg` |
| `android14-6.1-lts` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg` |
| `android15-6.6-lts` | `full` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg` |
| `android16-6.12-lts` | `thin` | `vanilla`, `bbg`, `ksu`, `ksu-bbg`, `ksu-susfs`, `ksu-susfs-bbg` |

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
- 5.4 KSU variants are experimental and use MultiSU legacy as the KSU provider.
- SUSFS is experimental and only available through KernelSU variants.
- 4.9 and 4.19 legacy/device-kernel branches are intentionally out of scope for this matrix for now.
- This is not a ROM builder.
