#!/usr/bin/env python3
"""scripts/pack_arm64_user_archive.py — pack several flat EL0 images into the
ONE blob the ARM64 LLVM kernel embeds (docs/arm64_llvm_scoping.md A11).

WHY AN ARCHIVE
--------------
Through A10 the kernel carried exactly ONE `.incbin`'d user image, so "load the
user program" and "load THE blob" were the same operation and nothing in the
lane could tell them apart. A shell needs to name a program and get THAT
program. This packer produces a tiny read-only archive with a name table, which
init/main.ad's arm64_a11_load_named_arm64() walks; the kernel then copies the
NAMED member into the EL0 window.

FORMAT (little-endian; everything 8-byte or 16-byte aligned by construction so
the kernel-side walk needs no unaligned loads):

    offset  size  field
    0       8     magic 'A11ARCHV' (0x5648435241313141)
    8       8     count
    16      32*N  table: per member { name[16] NUL-padded, u64 off, u64 size }
    ...           payloads, each 16-byte aligned, in table order

Payload offsets are relative to the START of the archive, so the kernel needs
only the base address it already gets from the arch layer.

The name field is a FIXED 16 bytes rather than a string pool on purpose: the
kernel-side walk is then a bounded byte compare with no pointer chasing, which
keeps arm64_a11_load_named_arm64 well inside the LLVM SSA subset (a bail there
would mean no loader at all -- exactly the class of ARM64 breakage the lane
keeps hitting).

Usage:
    pack_arm64_user_archive.py <out.bin> <name>=<file.bin> [<name>=<file.bin>...]
"""
import struct
import sys

MAGIC = 0x5648435241313141
NAME_LEN = 16
ENT_LEN = 32
ALIGN = 16


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: pack_arm64_user_archive.py <out.bin> <name>=<file.bin>...\n")
        return 2
    out_path = argv[1]
    members = []
    for spec in argv[2:]:
        if "=" not in spec:
            sys.stderr.write("ERROR: member spec %r is not <name>=<file>\n" % spec)
            return 2
        name, path = spec.split("=", 1)
        raw = name.encode("ascii")
        # A name that does not fit cannot be looked up, so refuse to build an
        # archive whose member is unreachable rather than silently truncating.
        if not raw or len(raw) >= NAME_LEN:
            sys.stderr.write("ERROR: member name %r must be 1..%d ASCII bytes\n"
                             % (name, NAME_LEN - 1))
            return 2
        with open(path, "rb") as fh:
            data = fh.read()
        if not data:
            sys.stderr.write("ERROR: member %r (%s) is EMPTY\n" % (name, path))
            return 2
        members.append((raw, data, path))

    names = [m[0] for m in members]
    if len(set(names)) != len(names):
        sys.stderr.write("ERROR: duplicate member names %r\n" % names)
        return 2

    off = 16 + ENT_LEN * len(members)
    table = b""
    payload = b""
    for raw, data, _path in members:
        pad = (-off) % ALIGN
        payload += b"\0" * pad
        off += pad
        table += raw.ljust(NAME_LEN, b"\0") + struct.pack("<QQ", off, len(data))
        payload += data
        off += len(data)

    blob = struct.pack("<QQ", MAGIC, len(members)) + table + payload
    with open(out_path, "wb") as fh:
        fh.write(blob)

    print("[pack-arm64-archive] %s: %d members, %d bytes" % (out_path, len(members), len(blob)))
    for raw, data, path in members:
        print("[pack-arm64-archive]   %-12s %7d bytes  <- %s"
              % (raw.decode(), len(data), path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
