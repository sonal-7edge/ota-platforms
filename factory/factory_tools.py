#!/usr/bin/env python3
"""Helpers for factory/provision.sh.

Commands:
  partition <partitions.csv> <name>      print "<offset> <size>" of a partition
  efuse <out.bin>                        write a blank ESP32 eFuse file (chip revision 3)
  status <boot.log>                      print the OTA_STATUS JSON from a boot log
  record <out.json> key=value ...        write the manufacturing record
  write-slot <flash.bin> <csv> <name> <image.bin>
                                         erase a partition (0xFF) and write an image into it
  tamper <unsigned.bin> <signed.bin> <out.bin>
                                         make a tampered copy of a signed app image: one bit
                                         flipped in its code, with the image checksum and
                                         SHA-256 recomputed so only the signature can catch it
"""
import binascii
import csv
import hashlib
import json
import sys

# Default eFuse contents for an ESP32 at chip revision 3, copied from
# ESP-IDF v6.0.3 tools/idf_py_actions/qemu_ext.py, the values "idf.py qemu"
# uses for a new device (the same as in v5.5.6). No security eFuses are burned.
ESP32_DEFAULT_EFUSE = binascii.unhexlify(
    '00000000000000000000000000800000000000000000100000000000000000000000000000000000'
    '00000000000000000000000000000000000000000000000000000000000000000000000000000000'
    '00000000000000000000000000000000000000000000000000000000000000000000000000000000'
    '00000000'
)


def find_partition(csv_path, name):
    with open(csv_path, newline='') as f:
        rows = (line for line in f if line.strip() and not line.lstrip().startswith('#'))
        for row in csv.reader(rows):
            fields = [c.strip() for c in row]
            if fields and fields[0] == name:
                if not fields[3] or not fields[4]:
                    sys.exit(f'partition {name} has no fixed offset or size in {csv_path}')
                return int(fields[3], 0), int(fields[4], 0)
    sys.exit(f'partition {name} not found in {csv_path}')


def cmd_partition(csv_path, name):
    offset, size = find_partition(csv_path, name)
    print(f'{offset:#x} {size:#x}')


def cmd_write_slot(flash_path, csv_path, name, image_path):
    offset, size = find_partition(csv_path, name)
    with open(image_path, 'rb') as f:
        image = f.read()
    if len(image) > size:
        sys.exit(f'{image_path} ({len(image)} bytes) does not fit in {name} ({size} bytes)')
    with open(flash_path, 'r+b') as f:
        f.seek(offset)
        f.write(image + b'\xff' * (size - len(image)))


def cmd_tamper(unsigned_path, signed_path, out_path):
    """Model an attacker who changes the firmware and fixes everything that
    is not secret: the one-byte checksum and the SHA-256 appended to the image.
    The Secure Boot signature is the only thing left that can reject it."""
    from esptool.bin_image import LoadFirmwareImage  # available in the ESP-IDF environment

    with open(unsigned_path, 'rb') as f:
        unsigned = bytearray(f.read())
    with open(signed_path, 'rb') as f:
        signed = f.read()
    if signed[:len(unsigned)] != unsigned:
        sys.exit(f'{signed_path} does not start with {unsigned_path}; build both from the same build')

    image = LoadFirmwareImage('esp32', unsigned_path)
    if not image.append_digest or image.data_length is None:
        sys.exit(f'{unsigned_path} has no appended SHA-256')

    # Flip one bit in the middle of the largest segment's data
    # (segment header is 8 bytes, so data starts at file_offs + 8).
    segment = max(image.segments, key=lambda s: len(s.data))
    position = segment.file_offs + 8 + len(segment.data) // 2
    unsigned[position] ^= 0x01

    # The checksum XORs every segment data byte, so the same bit flips in it.
    # It is the last byte before the SHA-256, which covers everything before it.
    checksum_pos = image.data_length - 1
    unsigned[checksum_pos] ^= 0x01
    unsigned[image.data_length:image.data_length + 32] = hashlib.sha256(unsigned[:image.data_length]).digest()

    # Keep the original padding and signature sector from the signed image.
    with open(out_path, 'wb') as f:
        f.write(bytes(unsigned) + signed[len(unsigned):])
    print(f'flipped one bit at byte {position:#x}, checksum and SHA-256 recomputed, original signature kept')


def cmd_efuse(out_path):
    with open(out_path, 'wb') as f:
        f.write(ESP32_DEFAULT_EFUSE)


def cmd_status(log_path):
    with open(log_path, errors='replace') as f:
        for line in f:
            if 'OTA_STATUS ' in line:
                payload = line.split('OTA_STATUS ', 1)[1].strip()
                json.loads(payload)  # fail loudly if the line is malformed
                print(payload)
                return
    sys.exit(1)


def cmd_record(out_path, pairs):
    record = {}
    for pair in pairs:
        key, _, value = pair.partition('=')
        record[key] = value
    with open(out_path, 'w') as f:
        json.dump(record, f, indent=2)
        f.write('\n')


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd, args = argv[1], argv[2:]
    if cmd == 'partition' and len(args) == 2:
        cmd_partition(*args)
    elif cmd == 'efuse' and len(args) == 1:
        cmd_efuse(*args)
    elif cmd == 'status' and len(args) == 1:
        cmd_status(*args)
    elif cmd == 'record' and len(args) >= 1:
        cmd_record(args[0], args[1:])
    elif cmd == 'write-slot' and len(args) == 4:
        cmd_write_slot(*args)
    elif cmd == 'tamper' and len(args) == 3:
        cmd_tamper(*args)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv)
