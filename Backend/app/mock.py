"""A stand-in portrait for testing the app without calling OpenAI (FITMIX_MOCK=1): no key, no cost, no upload."""

import struct
import zlib

WIDTH, HEIGHT = 512, 768
_BACKGROUND = (244, 240, 232)
_SKIN, _SHIRT, _PANTS, _SHOES, _SHADOW = (224, 172, 140), (92, 128, 196), (60, 66, 84), (240, 240, 240), (226, 220, 210)


def _spans(y: int) -> list[tuple[int, int, tuple[int, int, int]]]:
    """Horizontal runs of colour that make up a simple standing figure on row `y`."""
    cx = WIDTH // 2
    runs = []
    if 664 <= y < 684:  # floor shadow
        half = int(120 * (1 - ((y - 674) / 10) ** 2) ** 0.5)
        runs.append((cx - half, cx + half, _SHADOW))
    if 80 <= y < 180:  # head
        half = int(46 * max(0.0, 1 - ((y - 130) / 50) ** 2) ** 0.5)
        runs.append((cx - half, cx + half, _SKIN))
    if 180 <= y < 200:  # neck
        runs.append((cx - 16, cx + 16, _SKIN))
    if 200 <= y < 400:  # T-shirt
        runs.append((cx - 78, cx + 78, _SHIRT))
    if 210 <= y < 300:  # sleeves
        runs += [(cx - 112, cx - 84, _SHIRT), (cx + 84, cx + 112, _SHIRT)]
    if 300 <= y < 430:  # forearms and hands
        runs += [(cx - 110, cx - 88, _SKIN), (cx + 88, cx + 110, _SKIN)]
    if 400 <= y < 650:  # trousers
        runs += [(cx - 74, cx - 6, _PANTS), (cx + 6, cx + 74, _PANTS)]
    if 650 <= y < 672:  # sneakers
        runs += [(cx - 84, cx - 4, _SHOES), (cx + 4, cx + 84, _SHOES)]
    return runs


def placeholder_png() -> bytes:
    rows = bytearray()
    blank = bytes(_BACKGROUND) * WIDTH
    for y in range(HEIGHT):
        row = bytearray(blank)
        for start, end, colour in _spans(y):
            row[start * 3:end * 3] = bytes(colour) * (end - start)
        rows += b"\x00" + row

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b"")
