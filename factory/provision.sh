#!/usr/bin/env bash
# Simulated factory station: provisions one ESP32 device in QEMU.
#
# Follows the factory flow in doc 001, Section 6:
#   1. test the board                 (nothing to test on a simulated board)
#   2. flash bootloader and factory firmware
#   3. turn on secure boot            (qemu-secure profile: Secure Boot V2)
#   4. give the device its identity   (serial number now; AWS certificate next)
#   5. register in the fleet          (with the AWS identity, next)
#   6. check the device boots signed firmware and refuses unsigned or tampered firmware
#   7. lock the debug port
#   8. write the manufacturing record
#
# A simulated device is two files in devices/<serial>/: flash.bin and efuse.bin.
#
# Usage (inside the container): bash factory/provision.sh <serial> [profile]
#   profile: qemu (default, no Secure Boot) or qemu-secure
set -euo pipefail

SERIAL="${1:?usage: provision.sh <serial> [profile]}"
PROFILE="${2:-qemu}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO/firmware/esp32-ota"
PARTITIONS="$PROJECT/partitions.csv"
BUILD="$REPO/build/$PROFILE"
PLAIN_BUILD="$REPO/build/qemu"
DEVICE="$REPO/devices/$SERIAL"
RECORDS="$REPO/factory/records"
SIGNING_KEY="$REPO/keys/dev_secure_boot_signing_key.pem"
TOOLS="python3 $REPO/factory/factory_tools.py"
BOOT_TIMEOUT_S=90
REFUSE_TIMEOUT_S=40

case "$PROFILE" in
    qemu)        SECURE=0 ;;
    qemu-secure) SECURE=1 ;;
    *) echo "FAIL: unknown profile '$PROFILE' (use qemu or qemu-secure)" >&2; exit 1 ;;
esac

step() { echo; echo "== $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Boots a flash/eFuse pair in QEMU with the same arguments as 'idf.py qemu',
# writing the serial output to a log. Stops as soon as an OTA_STATUS line
# appears or the timeout passes. Prints the OTA_STATUS JSON, or nothing.
boot_device() { # <flash.bin> <efuse.bin> <log> <timeout_s>
    local flash="$1" efuse="$2" log="$3" timeout="$4" status="" pid
    : > "$log"
    qemu-system-xtensa -M esp32 -m 4M \
        -drive "file=$flash,if=mtd,format=raw" \
        -drive "file=$efuse,if=none,format=raw,id=efuse" \
        -global driver=nvram.esp32.efuse,property=drive,value=efuse \
        -global driver=timer.esp32.timg,property=wdt_disable,value=true \
        -nic user,model=open_eth \
        -display none -monitor none -serial "file:$log" >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq "$timeout"); do
        sleep 1
        if status="$($TOOLS status "$log" 2>/dev/null)"; then break; fi
        kill -0 "$pid" 2>/dev/null || break
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "$status"
}

# The serial goes into NVS as a string of at most 31 characters.
[[ "$SERIAL" =~ ^[A-Z0-9-]{3,31}$ ]] || fail "serial must be 3-31 characters of A-Z, 0-9 or '-'"
[[ -f "$BUILD/flash_args" ]] || fail "no build in $BUILD, run: make build PROFILE=$PROFILE"
[[ -e "$DEVICE" ]] && fail "device $SERIAL already exists; run 'make new-device SERIAL=$SERIAL' to start again"
if (( SECURE )); then
    [[ -f "$SIGNING_KEY" ]] || fail "no signing key at $SIGNING_KEY, run: make keys"
    [[ -f "$PLAIN_BUILD/esp32-ota.bin" ]] || fail "no unsigned build in $PLAIN_BUILD for the refusal test, run: make build PROFILE=qemu"
fi

VERSION="$(tr -d '[:space:]' < "$PROJECT/version.txt")"
NVS_INFO="$($TOOLS partition "$PARTITIONS" nvs)" || fail "cannot read the nvs partition"
read -r NVS_OFFSET NVS_SIZE <<<"$NVS_INFO"
mkdir -p "$DEVICE" "$RECORDS"

step "1. Test the board"
echo "SKIP: simulated board, no hardware to test"

step "2. Flash bootloader and factory firmware ($VERSION, profile $PROFILE)"
# The same images 'idf.py flash' writes: bootloader, partition table, otadata
# and the firmware in ota_0, merged into one 4 MB flash file. In the secure
# profile the bootloader and firmware are signed during the build.
( cd "$BUILD" && python3 -m esptool --chip=esp32 merge_bin \
      --output="$DEVICE/flash.bin" --fill-flash-size=4MB @flash_args )
echo "flash image: $DEVICE/flash.bin"

step "3. Turn on secure boot"
$TOOLS efuse "$DEVICE/efuse.bin"
if (( SECURE )); then
    echo "Secure Boot V2: the signed bootloader burns the key digest into eFuse on its first boot (step 6)"
    python3 -m espsecure digest_sbv2_public_key --keyfile "$SIGNING_KEY" --output "$DEVICE/key_digest.bin" >/dev/null
    KEY_DIGEST="$(od -An -tx1 "$DEVICE/key_digest.bin" | tr -d ' \n')"
    echo "signing key digest: $KEY_DIGEST"
else
    echo "SKIP: plain profile, blank eFuses (chip revision 3). Use PROFILE=qemu-secure for Secure Boot V2"
    KEY_DIGEST=none
fi

step "4. Give the device its identity"
cat > "$DEVICE/identity.csv" <<EOF
key,type,encoding,value
factory,namespace,,
serial,data,string,$SERIAL
hw_rev,data,string,esp32-devkitv1-qemu
mfg_date,data,string,$(date -u +%Y-%m-%d)
station,data,string,docker-sim
EOF
python3 "$IDF_PATH/components/nvs_flash/nvs_partition_generator/nvs_partition_gen.py" \
    generate --outdir "$DEVICE" "$DEVICE/identity.csv" nvs.bin "$NVS_SIZE"
# Write the identity into the device's nvs partition, as a station would over USB.
dd if="$DEVICE/nvs.bin" of="$DEVICE/flash.bin" bs=4096 seek=$((NVS_OFFSET / 4096)) conv=notrunc status=none
echo "identity written at $NVS_OFFSET: serial $SERIAL (AWS IoT certificate added in a later step)"

step "5. Register in the fleet"
echo "SKIP: needs the AWS IoT identity (approach A), added in a later step"

step "6. Check the device boots signed firmware and refuses anything else"
echo "first boot (QEMU stops itself once the device reports its status)"
STATUS="$(boot_device "$DEVICE/flash.bin" "$DEVICE/efuse.bin" "$DEVICE/first-boot.log" "$BOOT_TIMEOUT_S")"
[[ -n "$STATUS" ]] || fail "no OTA_STATUS line within ${BOOT_TIMEOUT_S}s, see $DEVICE/first-boot.log (device set aside)"
echo "device reported: $STATUS"

check() { # <field> <expected>
    local got
    got="$(jq -r ".$1" <<<"$STATUS")"
    [[ "$got" == "$2" ]] || fail "$1 is '$got', expected '$2' (device set aside, see $DEVICE/first-boot.log)"
    echo "ok: $1 = $got"
}
check serial "$SERIAL"
check version "$VERSION"
check partition ota_0
check self_test pass

UNSIGNED_RESULT=not_run
TAMPERED_RESULT=not_run
if (( SECURE )); then
    check secure_boot on

    # Each test boots a copy of the device as it is now (Secure Boot already on),
    # with a bad image in ota_0. The device must not start it.
    REFUSAL_PATTERN='signature verification failed|signature block is invalid|No valid applications signature|No bootable app partitions'
    refusal_test() { # <name> <image.bin>
        local name="$1" image="$2" dir="$DEVICE/test-$1" status
        mkdir -p "$dir"
        cp "$DEVICE/flash.bin" "$dir/flash.bin"
        cp "$DEVICE/efuse.bin" "$dir/efuse.bin"
        $TOOLS write-slot "$dir/flash.bin" "$PARTITIONS" ota_0 "$image"
        status="$(boot_device "$dir/flash.bin" "$dir/efuse.bin" "$dir/boot.log" "$REFUSE_TIMEOUT_S")"
        [[ -z "$status" ]] || fail "$name image was started: $status (see $dir/boot.log)"
        grep -Eq "$REFUSAL_PATTERN" "$dir/boot.log" \
            || fail "$name image did not start, but the log shows no signature failure (see $dir/boot.log)"
        echo "ok: $name image refused ($(grep -Eo "$REFUSAL_PATTERN" "$dir/boot.log" | head -1))"
    }

    echo "test: unsigned firmware (from the plain qemu build)"
    refusal_test unsigned "$PLAIN_BUILD/esp32-ota.bin"
    UNSIGNED_RESULT=refused

    echo "test: tampered firmware (signed image with one bit flipped)"
    $TOOLS tamper "$BUILD/esp32-ota.bin" "$DEVICE/tampered.bin"
    refusal_test tampered "$DEVICE/tampered.bin"
    TAMPERED_RESULT=refused
fi

step "7. Lock the debug port"
if (( SECURE )); then
    echo "JTAG is disabled by the bootloader when it turns on Secure Boot (ESP-IDF default)"
else
    echo "SKIP: plain profile; on the real board this is the JTAG-disable eFuse"
fi

step "8. Write the manufacturing record"
sha() { sha256sum "$1" | cut -d' ' -f1; }
$TOOLS record "$RECORDS/$SERIAL.json" \
    serial="$SERIAL" \
    result=PASS \
    provisioned_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    station=docker-sim \
    profile="$PROFILE" \
    firmware_version="$VERSION" \
    idf_version="$(idf.py --version 2>/dev/null | tr -d '\n')" \
    bootloader_sha256="$(sha "$BUILD/bootloader/bootloader.bin")" \
    partition_table_sha256="$(sha "$BUILD/partition_table/partition-table.bin")" \
    app_sha256="$(sha "$BUILD/esp32-ota.bin")" \
    secure_boot="$(jq -r '.secure_boot' <<<"$STATUS")" \
    secure_boot_key_digest="$KEY_DIGEST" \
    unsigned_image_test="$UNSIGNED_RESULT" \
    tampered_image_test="$TAMPERED_RESULT" \
    flash_encryption=off \
    aws_identity=none
echo "record: $RECORDS/$SERIAL.json"

echo
echo "PASS: $SERIAL provisioned. Boot it with: make run PROFILE=$PROFILE SERIAL=$SERIAL"
