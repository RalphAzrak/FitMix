"""Stage 3: turning a SegFormer label map into garment crops on white. The model itself is replaced by fixed
label maps, so these tests need neither PyTorch nor a model download."""

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app import main
from app.config import Settings
from app.main import create_app, load_segmenter
from app.mock import MockDescriber
from app.pipeline import Pipeline
from app.segment import SegFormerSegmenter, clean, crop_box, label_ids, segments_from_labels

from .test_api import jpeg

# The label names of mattmdjaga/segformer_b2_clothes (a subset), as its config spells them.
ID2LABEL = {0: "Background", 2: "Hair", 4: "Upper-clothes", 5: "Skirt", 6: "Pants", 7: "Dress",
            9: "Left-shoe", 10: "Right-shoe", 11: "Face", 14: "Left-arm"}
IDS = label_ids(ID2LABEL)

OLIVE, NAVY, WHITE_SHOE = (95, 100, 50), (28, 38, 80), (230, 230, 230)
W, H = 200, 400


def outfit(shoe_size=12):
    """A photo and its label map: a top, pants, two shoes, a face and an arm."""
    pixels = np.full((H, W, 3), (180, 160, 140), dtype=np.uint8)  # skin-ish background
    labels = np.zeros((H, W), dtype=np.int64)

    def paint(label, color, x0, y0, x1, y1):
        labels[y0:y1, x0:x1] = label
        pixels[y0:y1, x0:x1] = color

    paint(11, (200, 170, 150), 80, 10, 120, 50)  # face: never a garment
    paint(4, OLIVE, 50, 60, 150, 200)  # top
    paint(14, (190, 160, 140), 30, 70, 50, 180)  # arm
    paint(6, NAVY, 60, 200, 140, 360)  # pants
    paint(9, WHITE_SHOE, 60, 370, 60 + shoe_size * 3, 370 + shoe_size)  # left shoe
    paint(10, WHITE_SHOE, 110, 370, 110 + shoe_size * 3, 370 + shoe_size)  # right shoe
    return Image.fromarray(pixels), labels


def test_label_ids_read_from_the_model_config():
    assert IDS == {"upper_clothes": [4], "dress": [7], "skirt": [5], "pants": [6], "shoes": [9, 10]}


def test_each_garment_becomes_a_crop_on_white():
    image, labels = outfit()
    segments = segments_from_labels(image, labels, IDS, min_area=0.01)
    assert [s.label for s in segments] == ["upper_clothes", "pants", "shoes"]  # top to bottom, shoes merged
    top = segments[0]
    assert top.area == pytest.approx(100 * 140 / (W * H), abs=0.01)
    pixels = np.asarray(top.crop)
    assert top.crop.width == top.crop.height  # centred on a white square
    assert tuple(pixels[0, 0]) == (255, 255, 255)
    centre = pixels[pixels.shape[0] // 2, pixels.shape[1] // 2]
    assert np.abs(centre.astype(int) - OLIVE).max() < 4
    # Nothing but the garment and white: no skin, face or arm pixels.
    colours = {tuple(p) for p in pixels.reshape(-1, 3)}
    assert colours <= {(255, 255, 255), OLIVE}


def test_both_shoes_share_one_crop():
    image, labels = outfit()
    shoes = segments_from_labels(image, labels, IDS, min_area=0.01)[-1]
    columns_with_shoe = (np.asarray(shoes.crop).min(axis=2) < 250).any(axis=0)
    # Two separate shoes → two separate runs of non-white columns.
    runs = np.diff(columns_with_shoe.astype(int))
    assert (runs == 1).sum() == 2


def test_small_garments_are_dropped_and_shoes_need_half_the_area():
    image, labels = outfit(shoe_size=12)  # shoes ≈ 0.011 of the photo
    shoes_area = segments_from_labels(image, labels, IDS, min_area=0.01)[-1].area
    assert [s.label for s in segments_from_labels(image, labels, IDS, min_area=shoes_area * 1.5)][-1] == "shoes"
    assert "shoes" not in [s.label for s in segments_from_labels(image, labels, IDS, min_area=shoes_area * 2.5)]
    assert segments_from_labels(image, labels, IDS, min_area=0.9) == []


def test_stray_pixels_are_removed_and_dont_stretch_the_crop():
    image, labels = outfit()
    labels[395, 5] = 4  # one stray "upper clothes" pixel in the bottom corner
    top = segments_from_labels(image, labels, IDS, min_area=0.01)[0]
    reference = segments_from_labels(*outfit(), IDS, min_area=0.01)[0]
    assert top.crop.size == reference.crop.size


def test_clean_and_crop_box_helpers():
    mask = np.zeros((50, 50), dtype=bool)
    mask[10:30, 20:40] = True
    mask[45, 2] = True  # speck
    cleaned = clean(mask)
    assert not cleaned[45, 2] and cleaned[20, 30]
    assert crop_box(cleaned, trim=0) == (20, 10, 40, 30)
    assert crop_box(np.zeros((5, 5), dtype=bool)) is None


# MARK: In the pipeline

class FakeSegFormer(SegFormerSegmenter):
    """The real segment() on a fixed label map, without loading PyTorch or a model."""

    def __init__(self, labels):
        self.labels, self.ids, self.min_area, self.name = labels, IDS, 0.01, "segformer (fake)"

    def predict(self, image):
        return self.labels


class RecordingDescriber(MockDescriber):
    def __init__(self):
        self.seen = []

    async def describe(self, crops, hints):
        self.seen.append(list(hints))
        return await super().describe(crops, hints)


def test_photo_is_segmented_then_each_crop_described():
    image, labels = outfit()
    describer = RecordingDescriber()
    pipeline = Pipeline(FakeSegFormer(labels), describer, None, None, None)
    client = TestClient(create_app(Settings(), pipeline=pipeline))
    body = client.post("/analyze", files={"image": ("p.png", _png(image), "image/png")}).json()
    assert describer.seen == [["upper_clothes", "pants", "shoes"]]  # one describe call for all crops
    assert [g["source_label"] for g in body["garments"]] == ["upper_clothes", "pants", "shoes"]
    assert [g["category"] for g in body["garments"]] == ["top", "pants", "shoes"]
    assert body["garments"][0]["attributes"]["color"] == "olive"
    assert {"segment", "describe", "total"} <= set(body["timings_ms"])
    crop = client.get(body["garments"][1]["crop_url"])
    assert crop.status_code == 200


def test_photo_with_no_garments_reports_it():
    _, labels = outfit()
    pipeline = Pipeline(FakeSegFormer(np.zeros_like(labels)), MockDescriber(), None, None, None)
    client = TestClient(create_app(Settings(), pipeline=pipeline))
    body = client.post("/analyze", files={"image": ("p.jpg", jpeg(), "image/jpeg")}).json()
    assert body["garments"] == [] and body["errors"][0]["code"] == "no_garments"


def test_segmenter_that_fails_to_load_falls_back_to_whole_photo(monkeypatch):
    def broken(*args, **kwargs):
        raise OSError("no network")

    monkeypatch.setattr("app.segment.SegFormerSegmenter.__init__", broken)
    assert load_segmenter(Settings()) is None
    assert load_segmenter(Settings(segmentation=False)) is None
    pipeline = main.build_pipeline(Settings(openai_api_key="k"))
    assert pipeline.segmenter is None and pipeline.describer is not None


def _png(image):
    import io

    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()
