#!/usr/bin/env python3
"""Helpers for factory/provision.sh.

Commands:
  partition <partitions.csv> <name>      print "<offset> <size>" of a partition
  efuse <out.bin>                        write a blank ESP32 eFuse file (chip revision 3)
  status <boot.log>                      print the OTA_STATUS JSON from a boot log
  record <out.json> key=value ...        write the manufacturing record
  write-slot <flash.bin> <csv> <name> <image.bin>
                                         erase a partition (0xFF) and write an image into it
  tamper <in.bin> <out.bin>              copy an image with one byte in the middle flipped
"""
import binascii
import csv
import json
import sys

# Default eFuse contents for an ESP32 at chip revision 3, copied from
# ESP-IDF v5.5.6 tools/idf_py_actions/qemu_ext.py (the values "idf.py qemu"
# uses for a new device). No security eFuses are burned in this image.
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


def cmd_tamper(in_path, out_path):
    with open(in_path, 'rb') as f:
        image = bytearray(f.read())
    middle = len(image) // 2
    image[middle] ^= 0x01
    with open(out_path, 'wb') as f:
        f.write(image)
    print(f'flipped one bit at byte {middle:#x}')


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
    elif cmd == 'tamper' and len(args) == 2:
        cmd_tamper(*args)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv)
