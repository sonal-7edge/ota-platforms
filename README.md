# ota-platforms

Reference implementation of safe over-the-air (OTA) updates for ESP32 devices, built for the  OTA and fleet management OKR. It runs on a simulated ESP32 in QEMU first, then on an ESP32 DevKit V1.

Background and decisions are in the team documentation folder:

- *001 - OTA Updates for MCU Production Devices Using a Prebuilt Bootloader*: how a safe update works, the flash layout and the factory flow
- *003 - Decision Record: OTA Platform Choice*: boot chain, device identity and the AWS IoT trial architecture

## What works today

| Step | Status |
| --- | --- |
| Docker environment with ESP-IDF v5.5.6 and QEMU | Done |
| Firmware 1.0.0: two OTA slots, rollback enabled, self-test, status line | Done |
| Simulated factory: flash image, eFuses, identity, first-boot check, manufacturing record | Done |
| Secure Boot V2 and signed images, with unsigned and tampered images refused at the factory | Ready to test (`qemu-secure` profile) |
| AWS IoT identity at the factory (approach A) and OTA through AWS IoT Jobs | Next |
| Node.js fleet simulator | Later |

## Requirements

- Docker (Docker Desktop on macOS or Windows, Docker Engine on Linux)
- `make`
- About 4 GB of free disk space for the ESP-IDF image

Nothing else is installed on your machine; every step runs in the container.

## Quick start

```bash
make image                    # once: builds the Docker image (pulls espressif/idf:v5.5.6)
make build                    # builds bootloader, partition table and firmware for QEMU
make factory SERIAL=SIM-0001  # provisions a simulated device
make run SERIAL=SIM-0001      # boots it in QEMU; press Ctrl-] to exit
```

`make factory` ends with `PASS: SIM-0001 provisioned.` when the device booted and passed its self-test. Step-by-step instructions with the expected output are in [docs/01-environment-and-factory.md](docs/01-environment-and-factory.md).

### With Secure Boot V2

```bash
make keys                                         # once: creates keys/dev_secure_boot_signing_key.pem
make factory PROFILE=qemu-secure SERIAL=SEC-0001  # signed build, Secure Boot on, refusal tests
make run PROFILE=qemu-secure SERIAL=SEC-0001
```

Details and expected output: [docs/02-secure-boot.md](docs/02-secure-boot.md).

## Build profiles

| Profile | Files | What it builds |
| --- | --- | --- |
| `qemu` (default) | `sdkconfig.defaults` + `sdkconfig.qemu` | Unsigned firmware for QEMU, no Secure Boot |
| `qemu-secure` | `sdkconfig.defaults` + `sdkconfig.qemu-secure` | Signed bootloader and firmware for QEMU, Secure Boot V2 turned on at first boot |

Pass the profile to any target with `PROFILE=...`. Each profile builds into its own `build/<profile>/` folder.

## Make targets

| Command | What it does |
| --- | --- |
| `make image` | Builds the Docker image from `docker/Dockerfile` |
| `make shell` | Opens a shell in the container, with `idf.py`, `esptool` and QEMU on the path |
| `make keys` | Creates the development Secure Boot signing key in `keys/`; never overwrites an existing key |
| `make build` | Builds the firmware for the chosen profile into `build/<profile>/` |
| `make factory SERIAL=<serial>` | Builds if needed, then provisions a new simulated device in `devices/<serial>/` |
| `make run SERIAL=<serial>` | Boots that device in QEMU with its own flash and eFuse files; use the same `PROFILE` it was provisioned with |
| `make new-device SERIAL=<serial>` | Deletes a simulated device and its record, so the serial can be provisioned again |
| `make clean` | Deletes the build output |

## Repository layout

| Path | Contents |
| --- | --- |
| `docker/` | Dockerfile for the build environment |
| `firmware/esp32-ota/` | ESP-IDF project: `partitions.csv`, `sdkconfig.defaults`, `sdkconfig.qemu`, `sdkconfig.qemu-secure`, `version.txt`, `main/` |
| `keys/` | Development signing key (git-ignored; keep a backup outside the repository) |
| `factory/` | `provision.sh` (the simulated factory station) and `factory_tools.py` |
| `devices/` | Simulated devices, one folder per serial (git-ignored) |
| `factory/records/` | Manufacturing records, one JSON file per device (git-ignored) |
| `docs/` | Setup notes and test results |

## A simulated device

Each device is two files: `devices/<serial>/flash.bin` (its 4 MB flash) and `devices/<serial>/efuse.bin` (its one-time eFuse bits). Changes the device makes to its flash, such as an OTA update, stay in those files between runs. Deleting the folder gives a brand-new device, so settings that are permanent on a real chip, such as Secure Boot, can be tried here first.
