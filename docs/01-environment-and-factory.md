# 01 - Environment, build and factory provisioning

This guide takes you from a fresh clone to a provisioned ESP32 running in QEMU. Each step lists the command and what you should see. If the output differs, stop at that step and check the "If it fails" note before going on.

Log lines below are examples: timestamps, addresses and hashes will differ on your machine.

## Step 1. Build the Docker image

```bash
make image
```

This pulls Espressif's official `espressif/idf:v5.5.6` image, which already contains ESP-IDF, its Python environment and QEMU, and adds `jq` and `xxd`. The first run downloads a few GB.

Check it:

```bash
make shell
idf.py --version            # ESP-IDF v5.5.6
which qemu-system-xtensa    # a path under /opt/esp/tools/
exit
```

If it fails: if Docker reports the tag `v5.5.6` is not found, pick another v5.5 tag from Docker Hub and run `make image IDF_VERSION=v5.5.x`. Use the same `IDF_VERSION` for every later command.

## Step 2. Build the firmware

```bash
make build
```

This builds three things from `firmware/esp32-ota/` with the QEMU profile (`sdkconfig.defaults` plus `sdkconfig.qemu`):

- the second-stage bootloader, with app rollback turned on
- the partition table from `partitions.csv`
- the firmware, version 1.0.0 from `version.txt`

The build ends with a summary like this:

```
Project build complete. To flash, run:
 idf.py flash
or
 python -m esptool --chip esp32 -b 460800 ... write_flash ... 0x1000 bootloader/bootloader.bin 0x20000 esp32-ota.bin 0x10000 partition_table/partition-table.bin 0x17000 ota_data_initial.bin
```

Check the addresses: the bootloader at `0x1000`, the partition table at `0x10000`, the firmware at `0x20000` (`ota_0`) and the OTA data at `0x17000`.

If it fails: delete `build/qemu` and build again, so no settings are left over from an earlier build.

## Step 3. Provision a simulated device

```bash
make factory SERIAL=SIM-0001
```

`factory/provision.sh` follows the factory flow from doc 001. Steps that need Secure Boot or the AWS identity print `SKIP` for now.

```
== 1. Test the board
SKIP: simulated board, no hardware to test

== 2. Flash bootloader and factory firmware (1.0.0)
flash image: /project/devices/SIM-0001/flash.bin

== 3. Turn on secure boot and flash encryption
SKIP: blank eFuses (chip revision 3); Secure Boot V2 is the next step

== 4. Give the device its identity
Created NVS binary: ===> /project/devices/SIM-0001/nvs.bin
identity written at 0x11000: serial SIM-0001 (AWS IoT certificate added in a later step)

== 5. Register in the fleet
SKIP: needs the AWS IoT identity (approach A), added in a later step

== 6. Check the device boots and passes its self-test
device reported: {"serial":"SIM-0001","version":"1.0.0","partition":"ota_0","state":"...","self_test":"pass","action":"none"}
ok: serial = SIM-0001
ok: version = 1.0.0
ok: partition = ota_0
ok: self_test = pass

== 7. Lock the debug port
SKIP: QEMU has no debug port; on the real board this is the JTAG-disable eFuse

== 8. Write the manufacturing record
record: /project/factory/records/SIM-0001.json

PASS: SIM-0001 provisioned. Boot it with: make run SERIAL=SIM-0001
```

A fresh factory image is not on trial, so `state` reads `none` or `undefined` and `action` is `none`. The rollback path only applies to an image installed by an OTA update.

The device now exists as:

| File | What it is |
| --- | --- |
| `devices/SIM-0001/flash.bin` | The device's 4 MB flash |
| `devices/SIM-0001/efuse.bin` | Its eFuse bits |
| `devices/SIM-0001/first-boot.log` | Serial output from the factory boot check |
| `factory/records/SIM-0001.json` | Manufacturing record: serial, firmware version, image hashes, security state |

If it fails:

- `no OTA_STATUS line within 90s`: open `devices/SIM-0001/first-boot.log`. If it stops before `ota_app` lines, the bootloader or partition table is wrong; rebuild from step 2. If it stops at the network, check that the build used the QEMU profile.
- `self_test is 'fail'`: the log line `self-test failed (identity ..., network ...)` says which check failed.
- `device SIM-0001 already exists`: run `make new-device SERIAL=SIM-0001`, or use another serial.

## Step 4. Boot the device

```bash
make run SERIAL=SIM-0001
```

This runs `idf.py qemu monitor` with the device's own flash and eFuse files. Look for:

```
I (...) ota_app: firmware 1.0.0, running from ota_0 at 0x020000, OTA state ...
I (...) ethernet_connect: Ethernet Link Up
I (...) ethernet_connect: Waiting for IP(s).
I (...) ethernet_connect: Got IPv4 event: Interface "example_netif_eth" address: 10.0.2.15
I (...) example_common: Connected to example_netif_eth
I (...) example_common: - IPv4 address: 10.0.2.15,
I (...) ota_app: self-test passed (identity ok, network ok)
OTA_STATUS {"serial":"SIM-0001","version":"1.0.0","partition":"ota_0",...}
I (...) ota_app: heartbeat serial=SIM-0001 uptime_s=30 free_heap=...
```

`10.0.2.15` is the address QEMU's built-in network gives the device, so it can reach the internet through your machine. Press `Ctrl-]` to exit.

## What comes next

1. **Secure Boot V2 and signed images:** a development signing key in `keys/` (never in git), a signed bootloader and firmware, the key digest burned into the simulated eFuses in factory step 3, and a check that an unsigned image is refused.
2. **AWS IoT identity (approach A):** factory steps 4 and 5 create the thing, certificate and policy and write the certificate into NVS.
3. **First OTA update through AWS IoT Jobs:** build 1.0.1, upload it to S3, create a job, and watch the trial boot and confirmation.
