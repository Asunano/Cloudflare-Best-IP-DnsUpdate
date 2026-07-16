#!/usr/bin/env python3
"""Generate placeholder app icons for the cfopt Tauri GUI.

Pure Python standard library (no Pillow / ImageMagick required). Emits a
vertical-gradient RGB PNG at the requested sizes, plus a valid Windows .ico
(PNG-wrapped) and macOS .icns (PNG-based) file, matching Tauri v2's expected
icon set under tauri/icons/.

Usage:
    python3 scripts/gen-icons.py [output_dir]

Default output_dir: <repo_root>/tauri/icons
"""
import os
import struct
import sys
import zlib

# Gradient endpoints (cfopt brand-ish: blue -> orange)
TOP = (31, 111, 235)     # #1f6feb
BOTTOM = (246, 130, 31)  # #f6821f


def make_png(size, top=TOP, bottom=BOTTOM):
    """Build an RGB PNG (8-bit) with a vertical gradient. Each row is a single
    solid colour, so we compute it once per scanline (fast even at 1024px)."""
    raw = bytearray()
    denom = max(1, size - 1)
    for y in range(size):
        t = y / denom
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        raw.append(0)  # PNG filter type 0 (None) for this scanline
        raw += bytes((r, g, b)) * size
    compressed = zlib.compress(bytes(raw), 9)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)  # 8-bit, RGB
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", ihdr)
    png += chunk(b"IDAT", compressed)
    png += chunk(b"IEND", b"")
    return png


def make_ico(png256):
    """ICONDIR + one ICONDIRENTRY wrapping a 256x256 PNG (Vista+ supported)."""
    icon_dir = struct.pack("<HHH", 0, 1, 1)
    # width, height (0 => 256), colors, reserved, planes, bitcount, bytesInRes, offset
    entry = struct.pack("<BBBBHHII", 0, 0, 0, 0, 1, 32, len(png256), 6 + 16)
    return icon_dir + entry + png256


def make_icns(pngs):
    """ICNS container with PNG-based OSType entries (macOS 10.7+)."""
    body = b""
    for otype, png in pngs.items():
        body += otype + struct.pack(">I", len(png) + 8) + png
    return b"icns" + struct.pack(">I", len(body) + 8) + body


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "tauri", "icons")
    out = os.path.abspath(out)
    os.makedirs(out, exist_ok=True)

    png32 = make_png(32)
    png128 = make_png(128)
    png256 = make_png(256)
    png512 = make_png(512)
    png1024 = make_png(1024)

    files = {
        "32x32.png": png32,
        "128x128.png": png128,
        "128x128@2x.png": png256,
        "icon.png": png1024,
    }
    for name, data in files.items():
        with open(os.path.join(out, name), "wb") as f:
            f.write(data)

    with open(os.path.join(out, "icon.ico"), "wb") as f:
        f.write(make_ico(png256))

    icns = make_icns({
        b"ic07": png128,    # 128x128
        b"ic08": png256,    # 256x256
        b"ic09": png512,    # 512x512
        b"ic10": png1024,   # 512x512@2x (1024)
    })
    with open(os.path.join(out, "icon.icns"), "wb") as f:
        f.write(icns)

    print("Generated icons in:", out)
    for n in sorted(files) + ["icon.ico", "icon.icns"]:
        print(f"  {n}: {os.path.getsize(os.path.join(out, n))} bytes")


if __name__ == "__main__":
    main()
