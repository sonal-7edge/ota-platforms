#!/usr/bin/env bash
# Simulated factory station: provisions one ESP32 device in QEMU.
#
# Follows the factory flow in doc 001, Section 6:
#   1. test the board                 (nothing to test on a simulated board)
#   2. flash bootloader and factory firmware
#   3. turn on secure boot and flash encryption   (next step, not yet)
#   4. give the device its identity   (serial number now; AWS certificate next)
#   5. register in the fleet          (with the AWS identity, next)
#   6. check the device boots and passes its self-test
#   7. lock the debug port            (no debug port in QEMU)
#   8. write the manufacturing record
#
# A simulated device is two files in devices/<serial>/: flash.bin and efuse.bin.
#
# Usage (inside the container): bash factory/provision.sh <serial> [profile]
set -euo pipefail

SERIAL="${1:?usage: provision.sh <serial> [profile]}"
PROFILE="${2:-qemu}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO/firmware/esp32-ota"
BUILD="$REPO/build/$PROFILE"
DEVICE="$REPO/devices/$SERIAL"
RECORDS="$REPO/factory/records"
TOOLS="python3 $REPO/factory/factory_tools.py"
BOOT_TIMEOUT_S=90

step() { echo; echo "== $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# The serial goes into NVS as a string of at most 31 characters.
[[ "$SERIAL" =~ ^[A-Z0-9-]{3,31}$ ]] || fail "serial must be 3-31 characters of A-Z, 0-9 or '-'"
[[ -f "$BUILD/flash_args" ]] || fail "no build in $BUILD, run: make build"
[[ -e "$DEVICE" ]] && fail "device $SERIAL already exists; run 'make new-device SERIAL=$SERIAL' to start again"

VERSION="$(tr -d '[:space:]' < "$PROJECT/version.txt")"
NVS_INFO="$($TOOLS partition "$PROJECT/partitions.csv" nvs)" || fail "cannot read the nvs partition"
read -r NVS_OFFSET NVS_SIZE <<<"$NVS_INFO"
mkdir -p "$DEVICE" "$RECORDS"

step "1. Test the board"
echo "SKIP: simulated board, no hardware to test"

step "2. Flash bootloader and factory firmware ($VERSION)"
# The same images 'idf.py flash' writes: bootloader, partition table, otadata
# and the firmware in ota_0, merged into one 4 MB flash file.
( cd "$BUILD" && python3 -m esptool --chip=esp32 merge_bin \
      --output="$DEVICE/flash.bin" --fill-flash-size=4MB @flash_args )
echo "flash image: $DEVICE/flash.bin"

step "3. Turn on secure boot and flash encryption"
$TOOLS efuse "$DEVICE/efuse.bin"
echo "SKIP: blank eFuses (chip revision 3); Secure Boot V2 is the next step"

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

step "6. Check the device boots and passes its self-test"
LOG="$DEVICE/first-boot.log"
# Same QEMU arguments as 'idf.py qemu', with the serial port written to a file.
qemu-system-xtensa -M esp32 -m 4M \
    -drive "file=$DEVICE/flash.bin,if=mtd,format=raw" \
    -drive "file=$DEVICE/efuse.bin,if=none,format=raw,id=efuse" \
    -global driver=nvram.esp32.efuse,property=drive,value=efuse \
    -global driver=timer.esp32.timg,property=wdt_disable,value=true \
    -nic user,model=open_eth \
    -display none -monitor none -serial "file:$LOG" &
QEMU_PID=$!
trap 'kill $QEMU_PID 2>/dev/null || true' EXIT

STATUS=""
for _ in $(seq "$BOOT_TIMEOUT_S"); do
    sleep 1
    if STATUS="$($TOOLS status "$LOG" 2>/dev/null)"; then break; fi
    kill -0 $QEMU_PID 2>/dev/null || break
done
kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true
trap - EXIT

[[ -n "$STATUS" ]] || fail "no OTA_STATUS line within ${BOOT_TIMEOUT_S}s, see $LOG (device set aside)"
echo "device reported: $STATUS"

check() { # <field> <expected>
    local got
    got="$(jq -r ".$1" <<<"$STATUS")"
    [[ "$got" == "$2" ]] || fail "$1 is '$got', expected '$2' (device set aside, see $LOG)"
    echo "ok: $1 = $got"
}
check serial "$SERIAL"
check version "$VERSION"
check partition ota_0
check self_test pass

step "7. Lock the debug port"
echo "SKIP: QEMU has no debug port; on the real board this is the JTAG-disable eFuse"

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
    secure_boot=off \
    flash_encryption=off \
    aws_identity=none
echo "record: $RECORDS/$SERIAL.json"

echo
echo "PASS: $SERIAL provisioned. Boot it with: make run SERIAL=$SERIAL"
