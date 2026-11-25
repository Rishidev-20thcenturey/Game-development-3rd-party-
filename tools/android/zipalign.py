#!/usr/bin/env python3
"""Minimal zipalign: rewrite an APK so every STORED entry's data starts on a 4-byte boundary
(16 KiB for native .so files), which Android requires for resources.arsc on targetSdk >= 30.

Usage: zipalign.py <in.apk> <out.apk>

Padding is added in the local-header "extra" field, exactly like the SDK zipalign tool.
Run it BEFORE apksigner (signing v2/v3 protects the final byte layout).
"""
import struct
import sys
import zipfile
import zlib

ALIGN = 4
SO_ALIGN = 16384


def main(src: str, dst: str) -> None:
    with zipfile.ZipFile(src) as zin, open(dst, 'wb') as out:
        entries = []
        for info in zin.infolist():
            data = zin.read(info.filename)
            entries.append((info, data))

        central = []
        for info, data in entries:
            name = info.filename.encode('utf-8')
            if info.compress_type == zipfile.ZIP_STORED:
                payload = data
                method = 0
            else:
                c = zlib.compressobj(9, zlib.DEFLATED, -15)
                payload = c.compress(data) + c.flush()
                method = 8
            crc = zlib.crc32(data) & 0xFFFFFFFF
            offset = out.tell()
            extra = b''
            if method == 0:
                align = SO_ALIGN if info.filename.endswith('.so') else ALIGN
                header_end = offset + 30 + len(name)
                pad = (-header_end) % align
                extra = b'\x00' * pad
            dostime = (info.date_time[3] << 11) | (info.date_time[4] << 5) | (info.date_time[5] // 2)
            dosdate = ((info.date_time[0] - 1980) << 9) | (info.date_time[1] << 5) | info.date_time[2]
            flags = 0x0800 if any(b > 0x7F for b in name) else 0
            out.write(struct.pack('<IHHHHHIIIHH', 0x04034B50, 20, flags, method, dostime, dosdate,
                                  crc, len(payload), len(data), len(name), len(extra)))
            out.write(name)
            out.write(extra)
            out.write(payload)
            central.append((name, flags, method, dostime, dosdate, crc, len(payload), len(data), offset,
                            info.external_attr))

        cd_start = out.tell()
        for name, flags, method, dostime, dosdate, crc, csize, usize, offset, ext in central:
            out.write(struct.pack('<IHHHHHHIIIHHHHHII', 0x02014B50, 20, 20, flags, method, dostime, dosdate,
                                  crc, csize, usize, len(name), 0, 0, 0, 0, ext, offset))
            out.write(name)
        cd_size = out.tell() - cd_start
        out.write(struct.pack('<IHHHHIIH', 0x06054B50, 0, 0, len(central), len(central), cd_size, cd_start, 0))


def verify(path: str) -> bool:
    ok = True
    with open(path, 'rb') as f, zipfile.ZipFile(path) as z:
        for info in z.infolist():
            if info.compress_type != zipfile.ZIP_STORED:
                continue
            f.seek(info.header_offset)
            hdr = f.read(30)
            nlen, xlen = struct.unpack('<HH', hdr[26:30])
            data_off = info.header_offset + 30 + nlen + xlen
            align = SO_ALIGN if info.filename.endswith('.so') else ALIGN
            if data_off % align:
                print(f'misaligned: {info.filename} @ {data_off}', file=sys.stderr)
                ok = False
    return ok


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--check':
        sys.exit(0 if verify(sys.argv[2]) else 1)
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
    if not verify(sys.argv[2]):
        sys.exit('alignment verification failed')
