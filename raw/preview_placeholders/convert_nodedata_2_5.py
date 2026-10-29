"""Converts a sector from the 2.31 format (version 62) to the 2.5 one (version 68).

Usage: python convert_nodedata_2_5.py <sector_in> <sector_out> [oodle dll]

The two formats differ only by the sector version and the nodeData records.
Records stay 144 bytes and offsets 0-111 are unchanged. Offsets 112-143:
  2.31: f32 secondary ref distance, f32 streaming distance,
        u64 bits (node index 20, flags 21, priority 8), 16 zero bytes
  2.5:  u64 bits (node index 19, flags 21, priority 8, todvis mask 16),
        f32 secondary ref distance, f32 streaming distance, u32 instance index, u8 data group, 11 zero bytes
The nodeData buffer must be the last one in the file.
"""
import ctypes
import struct
import sys
import zlib

DEFAULT_OODLE = "C:/Games/Cyberpunk 2077/bin/x64/oo2ext_7_win64.dll"
RECORD = 144
NO_INSTANCE = 0xFFFFFFFF
VERSION_2_31 = 62
VERSION_2_5 = 68

oodle = None


def load_oodle(path):
    global oodle
    oodle = ctypes.WinDLL(path)
    oodle.OodleLZ_Decompress.restype = ctypes.c_int64
    oodle.OodleLZ_Decompress.argtypes = [ctypes.c_void_p, ctypes.c_int64, ctypes.c_void_p, ctypes.c_int64,
                                         ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int64,
                                         ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int64, ctypes.c_int]
    oodle.OodleLZ_Compress.restype = ctypes.c_int64
    oodle.OodleLZ_Compress.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int64, ctypes.c_void_p, ctypes.c_int,
                                       ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int64]


def decompress(raw, size):
    if len(raw) == size:
        return raw
    if raw[:4] != b"KARK":
        sys.exit("unknown buffer compression")
    out = ctypes.create_string_buffer(size)
    if oodle.OodleLZ_Decompress(raw[8:], len(raw) - 8, out, size, 0, 0, 0, None, 0, None, None, None, 0, 3) != size:
        sys.exit("buffer decompression failed")
    return out.raw


def compress(data):
    # Kraken, level Optimal2, in the KARK container.
    cap = len(data) + 274 * ((len(data) + 0x3FFFF) // 0x40000) + 64
    out = ctypes.create_string_buffer(cap)
    n = oodle.OodleLZ_Compress(8, data, len(data), out, 5, None, None, None, None, 0)
    if n <= 0:
        sys.exit("buffer compression failed")
    return b"KARK" + struct.pack("<I", len(data)) + out.raw[:n]


def crc(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def header_crc(d):
    head = bytearray(d[:160])
    struct.pack_into("<I", head, 32, 0xDEADBEEF)
    return crc(bytes(head))


def chunk_names(d):
    tables = [struct.unpack_from("<III", d, 40 + i * 12) for i in range(10)]
    strings = d[tables[0][0]:tables[0][0] + tables[0][1]]
    names = []
    for i in range(tables[1][1]):
        off = struct.unpack_from("<I", d, tables[1][0] + i * 8)[0]
        names.append(strings[off:strings.index(b"\0", off)].decode())
    return [names[struct.unpack_from("<H", d, tables[4][0] + i * 24)[0]] for i in range(tables[4][1])]


def convert(rec, node_count):
    sec_dist, stream_dist = struct.unpack_from("<2f", rec, 112)
    bits = struct.unpack_from("<Q", rec, 120)[0]
    node_idx = bits & 0xFFFFF
    flags = (bits >> 20) & 0x1FFFFF
    priority = (bits >> 41) & 0xFF
    if bits >> 49 or any(rec[128:]):
        sys.exit("record uses fields with no measured 2.5 mapping")
    if node_idx >= node_count:
        sys.exit("node index %d out of range (%d nodes)" % (node_idx, node_count))
    new_bits = node_idx | (flags << 19) | (priority << 40)
    return rec[:112] + struct.pack("<Q2fIB", new_bits, sec_dist, stream_dist, NO_INSTANCE, 0) + bytes(11)


def version_offset(d):
    """Offset of the sector version: first field after the root chunk's properties."""
    e_off = struct.unpack_from("<I", d, 40 + 4 * 12)[0]
    p = struct.unpack_from("<I", d, e_off + 12)[0] + 1
    while struct.unpack_from("<H", d, p)[0]:
        p += 4 + struct.unpack_from("<I", d, p + 4)[0]
    return p + 2


def main():
    sector_in, sector_out = sys.argv[1:3]
    load_oodle(sys.argv[3] if len(sys.argv) > 3 else DEFAULT_OODLE)
    d = bytearray(open(sector_in, "rb").read())
    if d[:4] != b"CR2W":
        sys.exit("not a CR2W file")
    names = chunk_names(d)
    if names[0] != "worldStreamingSector":
        sys.exit("root chunk is %s, not worldStreamingSector" % names[0])
    node_count = sum(1 for n in names[1:] if n.endswith("Node"))
    v_off = version_offset(d)
    version = struct.unpack_from("<i", d, v_off)[0]
    if version == VERSION_2_5:
        sys.exit("already in the 2.5 format")
    if version != VERSION_2_31:
        sys.exit("unknown sector version %d" % version)

    b_off, b_cnt, _ = struct.unpack_from("<III", d, 40 + 5 * 12)
    if b_cnt != 1:
        sys.exit("expected a single (nodeData) buffer, found %d" % b_cnt)
    flags, index, offset, disk, mem, _ = struct.unpack_from("<6I", d, b_off)
    if offset + disk != len(d):
        sys.exit("nodeData buffer is not at the end of the file")
    data = decompress(bytes(d[offset:offset + disk]), mem)
    if mem % RECORD:
        sys.exit("buffer size %d is not a multiple of %d" % (mem, RECORD))
    records = [data[i:i + RECORD] for i in range(0, mem, RECORD)]

    packed = compress(b"".join(convert(r, node_count) for r in records))
    struct.pack_into("<i", d, v_off, VERSION_2_5)
    d = d[:offset] + packed
    struct.pack_into("<6I", d, b_off, flags, index, offset, len(packed), mem, crc(packed))
    struct.pack_into("<I", d, 40 + 5 * 12 + 8, crc(bytes(d[b_off:b_off + 24])))
    struct.pack_into("<I", d, 28, len(d))
    struct.pack_into("<I", d, 32, header_crc(d))
    open(sector_out, "wb").write(d)
    print("%s: %d records, %d nodes, buffer %d -> %d bytes" % (sector_out, len(records), node_count, disk, len(packed)))


if __name__ == "__main__":
    main()
