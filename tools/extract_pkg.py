"""Extracts an ftl.dat file (FTL 1.6.x PKG format) to a folder.

Usage:
    python extract_pkg.py <path to ftl.dat> <destination folder> [--list]

Formato (big-endian):
    Header (16 bytes):
        "PKG\\n"            magic
        u16 header_size     (16)
        u16 entry_size      (20)
        u32 entry_count
        u32 path_region_size
    Entries (entry_count x 20 bytes):
        u32 path_hash
        u32 flags_and_path_offset   high byte = flags (0x01 = deflate),
                                    low 24 bits = offset into the path region
        u32 data_offset
        u32 data_size               size on disk
        u32 unpacked_size
    Path region: \\0-terminated ASCII strings.
    Data: zlib (if deflate flag) or raw.
"""
import struct
import sys
import zlib
from pathlib import Path

FLAG_DEFLATED = 0x01


def read_entries(f):
    magic = f.read(4)
    if magic != b"PKG\n":
        raise ValueError(f"Not an FTL PKG (magic={magic!r})")
    header_size, entry_size, count, path_size = struct.unpack(">HHII", f.read(12))
    f.seek(header_size)
    raw = f.read(entry_size * count)
    paths = f.read(path_size)
    entries = []
    for i in range(count):
        h, fo, off, size, unpacked = struct.unpack_from(">IIIII", raw, i * entry_size)
        if off == 0 and size == 0:
            continue  # free slot
        flags = fo >> 24
        name_off = fo & 0xFFFFFF
        end = paths.index(b"\0", name_off)
        name = paths[name_off:end].decode("ascii")
        entries.append((name, flags, off, size, unpacked))
    return entries


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    list_only = "--list" in sys.argv
    with src.open("rb") as f:
        entries = read_entries(f)
        if list_only:
            for name, *_ in entries:
                print(name)
            return
        total = 0
        for name, flags, off, size, unpacked in entries:
            f.seek(off)
            data = f.read(size)
            if flags & FLAG_DEFLATED:
                data = zlib.decompress(data)
            if len(data) != unpacked:
                print(f"WARNING: {name} size {len(data)} != {unpacked}")
            out = dst / name
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(data)
            total += len(data)
    print(f"{len(entries)} files, {total / 1e6:.1f} MB -> {dst}")


if __name__ == "__main__":
    main()
