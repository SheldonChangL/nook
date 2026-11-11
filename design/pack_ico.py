#!/usr/bin/env python3
"""把各尺寸各自算好的 PNG 打包成 Windows 的 .ico。

    python3 design/pack_ico.py <輸出.ico> <16.png> <24.png> ...

只用標準函式庫，不重新縮放：.ico 裡每個尺寸直接嵌入 render_icon.swift
各自重畫的 PNG（Windows Vista 以後都讀得懂 PNG 壓縮的圖示項目），
小尺寸才不會是從大圖縮下來的糊邊。
"""
import struct
import sys


def png_size(data: bytes) -> tuple[int, int]:
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("不是 PNG")
    return struct.unpack(">II", data[16:24])


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    out, sources = sys.argv[1], sys.argv[2:]
    images = []
    for path in sources:
        with open(path, "rb") as f:
            data = f.read()
        w, h = png_size(data)
        if w != h or w > 256:
            raise ValueError(f"{path}: .ico 只收 256 以下的正方形，拿到 {w}x{h}")
        images.append((w, data))
    images.sort(key=lambda item: item[0])

    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries, blobs = b"", b""
    for size, data in images:
        # 寬高欄位只有一個位元組，256 要寫成 0。
        dim = 0 if size == 256 else size
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)
    with open(out, "wb") as f:
        f.write(header + entries + blobs)
    print(f"{out}: {', '.join(str(s) for s, _ in images)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
