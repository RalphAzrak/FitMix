"""Small image helpers: format checks, decoding, white padding, JPEG encoding."""

import io

from PIL import Image, ImageOps

MAX_EDGE = 1024  # long edge kept for analysis; larger photos are scaled down first
CROP_PAD = 0.08  # white margin around each garment, as a fraction of its size


def media_type(data: bytes) -> str | None:
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def decode(data: bytes) -> Image.Image:
    """Opens a JPEG, PNG or WebP upright (EXIF rotation applied), in RGB, with the long edge ≤ MAX_EDGE.
    Transparent areas become white, so app cutouts look like garments on white."""
    with Image.open(io.BytesIO(data)) as raw:
        image = ImageOps.exif_transpose(raw)
        if image.mode in ("RGBA", "LA", "P"):
            image = image.convert("RGBA")
            background = Image.new("RGBA", image.size, (255, 255, 255, 255))
            image = Image.alpha_composite(background, image)
        image = image.convert("RGB")
    image.thumbnail((MAX_EDGE, MAX_EDGE))
    return image


def pad_on_white(image: Image.Image, pad: float = CROP_PAD) -> Image.Image:
    """Centres the image on a white square with a margin, the shape every crop is given."""
    side = int(max(image.size) * (1 + 2 * pad))
    canvas = Image.new("RGB", (side, side), (255, 255, 255))
    canvas.paste(image, ((side - image.width) // 2, (side - image.height) // 2))
    return canvas


def to_jpeg(image: Image.Image, quality: int = 88) -> bytes:
    buffer = io.BytesIO()
    image.convert("RGB").save(buffer, format="JPEG", quality=quality)
    return buffer.getvalue()
