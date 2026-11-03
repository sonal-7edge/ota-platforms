# 02 - Secure Boot V2 and signed images

The `qemu-secure` profile builds a signed bootloader and signed firmware. On the device's first boot, the bootloader turns on Secure Boot V2; from then on the device only starts firmware signed with our key. The factory check proves this by booting an unsigned image and a tampered image and confirming both are refused.

The plain `qemu` profile from guide 01 is unchanged, so you can always go back to it.

## How it works

| What | Where | When |
| --- | --- | --- |
| Development signing key (RSA-3072) | `keys/dev_secure_boot_signing_key.pem` on your machine, never in git | Created once with `make keys` |
| Signed bootloader and firmware | `build/qemu-secure/` | Signed during `make build PROFILE=qemu-secure` |
| Public-key digest | eFuse block BLK2 of the device | Burned by the bootloader on the device's first boot |
| Signature check of the firmware | Second-stage bootloader | Every boot, and on every OTA update |

The bootloader holds only the public key. The private key is needed to sign new firmware, so whoever holds it controls what every device will run. For the trial it lives on your laptop. For production it moves to a key service or HSM (`espsecure sign_data` supports signing through an HSM), which decision record 003 will settle.

Losing the key means existing devices can never be updated again, and replacing it means devices provisioned with the old key refuse firmware signed with the new one. `make keys` therefore never overwrites an existing key. Keep a backup copy of `keys/` outside the repository.

## Step 1. Create the signing key

```bash
make keys
```

Expected output:

```
RSA 3072 private key in PEM format written to "keys/dev_secure_boot_signing_key.pem".
```

Running it again prints `keys/dev_secure_boot_signing_key.pem already exists, keeping it`.

If you already created the key under ESP-IDF v5.5.6, keep it: the key file is the same format, and devices you provisioned with it still accept firmware signed with it.

## Step 2. Build the signed firmware

```bash
make build PROFILE=qemu-secure
```

The build is in `build/qemu-secure/`. Its output now includes lines like these, one for the bootloader and one for the firmware, showing the images were signed:

```
1 signing key(s) found.
Signed ... bytes of data from ".../bootloader-unsigned.bin". Signature sector now has 1 signature blocks.
Signed ... bytes of data from ".../esp32-ota-unsigned.bin". Signature sector now has 1 signature blocks.
```

ESP-IDF also prints a reminder that Secure Boot is enabled without flash encryption. That is expected: flash encryption is a separate, later step.

If it fails with "Secure Boot V2 requires chip revision v3.0" or a similar Kconfig error: check that `sdkconfig.qemu-secure` still contains `CONFIG_ESP32_REV_MIN_3=y`, then delete `build/qemu-secure` and build again.

## Step 3. Provision a secure device

Use a new serial, so the plain device from guide 01 stays as it is:

```bash
make factory PROFILE=qemu-secure SERIAL=SEC-0001
```

This builds both profiles (the plain build supplies the unsigned image for the refusal test), then runs the factory steps. The parts that differ from guide 01:

```
== 3. Turn on secure boot
Secure Boot V2: the signed bootloader burns the key digest into eFuse on its first boot (step 6)
signing key digest: <64 hex characters>

== 6. Check the device boots signed firmware and refuses anything else
first boot (QEMU stops itself once the device reports its status)
device reported: {"serial":"SEC-0001","version":"1.0.0","partition":"ota_0","state":"valid","secure_boot":"on","self_test":"pass","action":"none"}
ok: serial = SEC-0001
ok: version = 1.0.0
ok: partition = ota_0
ok: self_test = pass
ok: secure_boot = on
test: unsigned firmware (from the plain qemu build)
ok: unsigned image refused (...)
test: tampered firmware (one bit changed, checksum and SHA-256 fixed, signature kept)
flipped one bit at byte 0x..., checksum and SHA-256 recomputed, original signature kept
ok: tampered image refused (signature verification failed)

== 7. Lock the debug port
JTAG is disabled by the bootloader when it turns on Secure Boot (ESP-IDF default)

...
PASS: SEC-0001 provisioned. Boot it with: make run PROFILE=qemu-secure SERIAL=SEC-0001
```

The text in brackets after "refused" is the bootloader's own message. A refusal only counts if that message is a signature failure.

The two tests cover different attacks:

| Test | What the image is | What catches it |
| --- | --- | --- |
| Unsigned | A valid firmware image built without signing (from the plain `qemu` build) | No signature block, so signature verification fails |
| Tampered | Our signed firmware with one bit changed. The image's checksum and SHA-256 are recalculated, as an attacker would do, since neither is secret. | The signature no longer matches the image, so signature verification fails |

Changing a bit without fixing the checksum and SHA-256 would also be refused, but by the integrity check, before the signature is ever read. That proves nothing about Secure Boot, so the test fixes them first.

Each refusal test runs on a copy of the device in `devices/SEC-0001/test-unsigned/` and `devices/SEC-0001/test-tampered/`, each with its own `boot.log`. The device's own `flash.bin` is never changed by the tests.

The manufacturing record `factory/records/SEC-0001.json` now holds `secure_boot: on`, the key digest and the results of both tests.

If it fails:

- `secure_boot is 'off'`: the bootloader did not turn on Secure Boot. Search `devices/SEC-0001/first-boot.log` for `secure_boot` lines; the build may have used the plain profile.
- `no OTA_STATUS line`: the device did not start even the signed firmware. If `first-boot.log` shows a signature error, the build and the key do not match; delete `build/qemu-secure`, rebuild and provision a new serial.
- `unsigned image was started`: Secure Boot is not enforcing signatures. Stop here and send me `first-boot.log` and `test-unsigned/boot.log`.
- `image did not start, but the log shows no signature failure`: the device refused it for another reason. Send me the test's `boot.log` so I can check the message and adjust the test.

## Step 4. Boot the secure device

```bash
make run PROFILE=qemu-secure SERIAL=SEC-0001
```

The boot log now shows the bootloader checking signatures, and the firmware line reads `secure boot on`.

## Before using this on the real board

Secure Boot is permanent on a real chip: once the digest is burned, the board only runs firmware signed with that key, and JTAG is disabled.

- The `qemu-secure` profile uses the emulated network, so its firmware does not run on the real board anyway. A board profile comes later.
- Check the board's chip revision first with `esptool.py chip_id`. Secure Boot V2 needs revision v3.0 or later.
- Use a board you are willing to dedicate to this, and keep the key safe.

## What comes next

Factory steps 4 and 5 with the AWS IoT identity (approach A), then the first OTA update through AWS IoT Jobs, signed with this key.
