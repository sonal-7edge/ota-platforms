# ota-platforms

Reference implementation of safe over-the-air (OTA) updates for ESP32 devices, built for the 7EDGE OTA and fleet management OKR. It runs on a simulated ESP32 in QEMU first, then on an ESP32 DevKit V1.

Background and decisions are in the team documentation folder:

- *001 - OTA Updates for MCU Production Devices Using a Prebuilt Bootloader*: how a safe update works, the flash layout and the factory flow
- *003 - Decision Record: OTA Platform Choice*: boot chain, device identity and the AWS IoT trial architecture

## What works today

| Step | Status |
| --- | --- |
| Docker environment with ESP-IDF v5.5.6 and QEMU | Done |
| Firmware 1.0.0: two OTA slots, rollback enabled, self-test, status line | Done |
| Simulated factory: flash image, eFuses, identity, first-boot check, manufacturing record | Done |
| Secure Boot V2 and signed images | Next |
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

## Make targets

| Command | What it does |
| --- | --- |
| `make image` | Builds the Docker image from `docker/Dockerfile` |
| `make shell` | Opens a shell in the container, with `idf.py`, `esptool` and QEMU on the path |
| `make build` | Builds the firmware with the QEMU profile into `build/qemu/` |
| `make factory SERIAL=<serial>` | Builds if needed, then provisions a new simulated device in `devices/<serial>/` |
| `make run SERIAL=<serial>` | Boots that device in QEMU with its own flash and eFuse files |
| `make new-device SERIAL=<serial>` | Deletes a simulated device and its record, so the serial can be provisioned again |
| `make clean` | Deletes the build output |

## Repository layout

| Path | Contents |
| --- | --- |
| `docker/` | Dockerfile for the build environment |
| `firmware/esp32-ota/` | ESP-IDF project: `partitions.csv`, `sdkconfig.defaults`, `sdkconfig.qemu`, `version.txt`, `main/` |
| `factory/` | `provision.sh` (the simulated factory station) and `factory_tools.py` |
| `devices/` | Simulated devices, one folder per serial (git-ignored) |
| `factory/records/` | Manufacturing records, one JSON file per device (git-ignored) |
| `docs/` | Setup notes and test results |

## A simulated device

Each device is two files: `devices/<serial>/flash.bin` (its 4 MB flash) and `devices/<serial>/efuse.bin` (its one-time eFuse bits). Changes the device makes to its flash, such as an OTA update, stay in those files between runs. Deleting the folder gives a brand-new device, so settings that are permanent on a real chip, such as Secure Boot, can be tried here first.
