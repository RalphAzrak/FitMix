"""Garment segmentation with a clothes-parsing SegFormer model (default `mattmdjaga/segformer_b2_clothes`).

The model labels every pixel (background, hair, face, upper clothes, pants, left shoe, …). This module turns
that label map into one crop per garment, cut out onto white:

1. Group labels into garments (left and right shoe become one "shoes" garment).
2. Clean each mask (a small opening removes stray pixels) and drop garments smaller than `min_area` of the
   photo, e.g. shoes cut off at the edge.
3. Paint everything outside the mask white, crop to the mask (ignoring the outermost 0.5 % of its pixels, so a
   stray speck can't stretch the crop), and centre it on a white square.

The model merges a jacket and the top under it into "upper clothes"; the vision LLM says whether it's layered.
Only `SegFormerSegmenter` needs PyTorch, and it imports it when created.
"""

import logging
import threading
import time

import numpy as np
from PIL import Image, ImageFilter

from .images import pad_on_white
from .pipeline import Segment

log = logging.getLogger("vision")

DEFAULT_MODEL = "mattmdjaga/segformer_b2_clothes"

# Garment → the model's label names (lower-case, "-" and " " as "_"), in the order crops are returned.
GARMENT_LABELS: dict[str, tuple[str, ...]] = {
    "upper_clothes": ("upper_clothes",),
    "dress": ("dress",),
    "skirt": ("skirt",),
    "pants": ("pants",),
    "shoes": ("left_shoe", "right_shoe"),
}
# Shoes are small even when fully in frame, so they need only half the minimum area.
AREA_FACTOR = {"shoes": 0.5}
TRIM = 0.005  # fraction of mask pixels ignored at each edge when finding the crop box


def label_ids(id2label: dict[int, str]) -> dict[str, list[int]]:
    """The model's label ids for each garment, read from its own config."""
    by_name = {name.strip().lower().replace("-", "_").replace(" ", "_"): int(i) for i, name in id2label.items()}
    return {garment: [by_name[name] for name in names if name in by_name] for garment, names in GARMENT_LABELS.items()}


def clean(mask: np.ndarray, size: int = 3) -> np.ndarray:
    """Morphological opening (erode, then dilate): removes specks thinner than `size` pixels."""
    picture = Image.fromarray(mask.astype(np.uint8) * 255)
    opened = picture.filter(ImageFilter.MinFilter(size)).filter(ImageFilter.MaxFilter(size))
    return np.asarray(opened) > 127


def crop_box(mask: np.ndarray, trim: float = TRIM) -> tuple[int, int, int, int] | None:
    """(left, top, right, bottom) around the mask, ignoring the outermost `trim` of its pixels on each side."""
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return None
    low, high = trim * 100, (1 - trim) * 100
    left, right = np.percentile(xs, [low, high])
    top, bottom = np.percentile(ys, [low, high])
    return int(left), int(top), int(right) + 1, int(bottom) + 1


def cut_out(image: Image.Image, mask: np.ndarray) -> Image.Image | None:
    """The garment pixels on white, cropped to the garment and centred on a white square."""
    box = crop_box(mask)
    if box is None:
        return None
    pixels = np.asarray(image.convert("RGB")).copy()
    pixels[~mask] = 255
    return pad_on_white(Image.fromarray(pixels).crop(box))


def segments_from_labels(image: Image.Image, labels: np.ndarray, ids: dict[str, list[int]], min_area: float) -> list[Segment]:
    """One Segment per garment found in a label map the size of `image` (height × width)."""
    total = labels.size
    segments = []
    for garment, garment_ids in ids.items():
        if not garment_ids:
            continue
        mask = clean(np.isin(labels, garment_ids))
        area = float(mask.sum()) / total
        if area < min_area * AREA_FACTOR.get(garment, 1.0):
            continue
        crop = cut_out(image, mask)
        if crop is not None:
            segments.append(Segment(label=garment, crop=crop, area=round(area, 4)))
    return segments


class SegFormerSegmenter:
    """Loads the model once. Inference is serialised: one photo at a time on the shared model."""

    def __init__(self, model_id: str = DEFAULT_MODEL, min_area: float = 0.01, device: str | None = None):
        import torch
        from transformers import AutoModelForSemanticSegmentation, SegformerImageProcessor

        from .device import best_device

        started = time.perf_counter()
        self.torch = torch
        self.device = device or best_device()
        self.processor = SegformerImageProcessor.from_pretrained(model_id)
        self.model = AutoModelForSemanticSegmentation.from_pretrained(model_id).to(self.device).eval()
        self.ids = label_ids(self.model.config.id2label)
        self.min_area = min_area
        self.name = f"segformer ({self.device})"
        self.lock = threading.Lock()
        missing = [garment for garment, found in self.ids.items() if not found]
        if missing:
            log.warning("segmentation model %s has no labels for: %s", model_id, ", ".join(missing))
        log.info("segmentation model %s ready on %s in %.1fs", model_id, self.device, time.perf_counter() - started)

    def predict(self, image: Image.Image) -> np.ndarray:
        """The model's label for every pixel of `image`, as a height × width array."""
        torch = self.torch
        inputs = self.processor(images=image, return_tensors="pt").to(self.device)
        with self.lock, torch.inference_mode():
            logits = self.model(**inputs).logits
            upsampled = torch.nn.functional.interpolate(logits, size=(image.height, image.width), mode="bilinear",
                                                        align_corners=False)
            return upsampled.argmax(dim=1)[0].to("cpu").numpy()

    def segment(self, image: Image.Image) -> list[Segment]:
        return segments_from_labels(image, self.predict(image), self.ids, self.min_area)
