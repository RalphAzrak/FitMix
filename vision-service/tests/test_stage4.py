"""Stage 4: the demo catalog and catalog matching. FashionCLIP is replaced by the mock colour embedder, and
remote images by a fake fetcher, so nothing is downloaded."""

import io
import json
import shutil
import sys
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.catalog import Catalog, load_items
from app.config import SERVICE_ROOT, Settings
from app.main import create_app, load_catalog, load_embedder
from app.mock import MockDescriber, MockEmbedder, product_picture
from app.pipeline import Pipeline

from .test_api import png_crop

sys.path.insert(0, str(SERVICE_ROOT / "scripts"))
import seed_catalog_ebay  # noqa: E402

SAMPLE_CATALOG = SERVICE_ROOT / "catalog" / "catalog.json"


class CountingEmbedder(MockEmbedder):
    def __init__(self):
        self.embedded = 0

    def embed(self, images):
        self.embedded += len(images)
        return super().embed(images)


def png_bytes(image):
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def make_catalog(tmp_path: Path, entries: list[dict], pictures: dict[str, Image.Image]) -> Path:
    (tmp_path / "images").mkdir()
    for name, picture in pictures.items():
        picture.save(tmp_path / "images" / name)
    path = tmp_path / "catalog.json"
    path.write_text(json.dumps(entries))
    return path


def entry(product_id, category, image, **extra):
    return {"id": product_id, "title": product_id.replace("-", " ").title(), "category": category,
            "price": {"value": "10.00", "currency": "USD"}, "image": image, **extra}


@pytest.fixture
def small_catalog(tmp_path):
    entries = [entry("olive-jacket", "jacket", "images/olive.png"),
               entry("black-jacket", "jacket", "images/black.png"),
               entry("navy-jeans", "pants", "images/navy.png"),
               entry("remote-tee", "top", "https://cdn.example/tee.jpg")]
    pictures = {"olive.png": product_picture("jacket", "olive"), "black.png": product_picture("jacket", "black"),
                "navy.png": product_picture("pants", "navy")}
    return make_catalog(tmp_path, entries, pictures)


def fake_fetch(url):
    return png_bytes(product_picture("top", "white"))


# MARK: Loading

def test_catalog_loads_local_and_remote_images(small_catalog):
    catalog = Catalog(small_catalog, MockEmbedder(), "model", fetch=fake_fetch)
    assert [item.id for item in catalog.items] == ["olive-jacket", "black-jacket", "navy-jeans", "remote-tee"]
    assert catalog.vectors.shape == (4, 48)


def test_embeddings_are_cached_by_model_and_content(small_catalog):
    first = CountingEmbedder()
    Catalog(small_catalog, first, "model", fetch=fake_fetch)
    assert first.embedded == 4 and (small_catalog.parent / "embeddings.npz").exists()

    def no_fetch(url):
        raise AssertionError("a cached remote image must not be downloaded again")

    second = CountingEmbedder()
    Catalog(small_catalog, second, "model", fetch=no_fetch)
    assert second.embedded == 0
    # A changed picture, or another model, is embedded again.
    product_picture("jacket", "red").save(small_catalog.parent / "images" / "olive.png")
    third = CountingEmbedder()
    Catalog(small_catalog, third, "model", fetch=no_fetch)
    assert third.embedded == 1
    fourth = CountingEmbedder()
    Catalog(small_catalog, fourth, "other-model", fetch=fake_fetch)
    assert fourth.embedded == 4


def test_bad_entries_and_unloadable_images_are_skipped(tmp_path):
    entries = [entry("ok", "jacket", "images/ok.png"),
               entry("bad-category", "hat", "images/ok.png"),
               {"id": "no-title", "category": "top", "image": "images/ok.png"},
               entry("ok", "jacket", "images/ok.png"),  # repeated id
               entry("missing-file", "top", "images/nope.png"),
               entry("escape", "top", "../secret.png"),
               entry("dead-link", "top", "https://cdn.example/gone.jpg")]
    path = make_catalog(tmp_path, entries, {"ok.png": product_picture("jacket", "olive")})
    (tmp_path.parent / "secret.png").write_bytes(png_bytes(product_picture("top", "red")))

    def broken_fetch(url):
        raise OSError("404")

    catalog = Catalog(path, MockEmbedder(), "model", fetch=broken_fetch)
    assert [item.id for item in catalog.items] == ["ok"]


def test_the_sample_catalog_in_the_repo_is_valid(tmp_path):
    copy = tmp_path / "catalog"
    shutil.copytree(SAMPLE_CATALOG.parent, copy, ignore=shutil.ignore_patterns("embeddings.npz"))
    items = load_items(copy / "catalog.json")
    assert len(items) >= 30 and all(item.sample for item in items if item.id.startswith("demo-"))
    assert {item.category for item in items} == {"top", "jacket", "pants", "shoes", "dress", "skirt"}
    assert len(Catalog(copy / "catalog.json", MockEmbedder(), "model")) == len(items)


# MARK: Matching

def test_match_keeps_the_category_and_ranks_by_similarity(small_catalog):
    embedder = MockEmbedder()
    catalog = Catalog(small_catalog, embedder, "model", fetch=fake_fetch)
    olive_crop = embedder.embed([product_picture("jacket", "olive")])[0]
    matches = catalog.match("jacket", olive_crop, k=5)
    assert [m.id for m in matches] == ["olive-jacket", "black-jacket"]
    assert matches[0].score == pytest.approx(1.0, abs=1e-3) and matches[0].score > matches[1].score
    assert matches[0].image == "catalog-images/olive.png"
    assert catalog.match("top", olive_crop, k=5)[0].image == "https://cdn.example/tee.jpg"
    assert catalog.match("dress", olive_crop, k=5) == []
    assert len(catalog.match(None, olive_crop, k=3)) == 3


def test_analyze_returns_catalog_matches_from_the_catalog(small_catalog):
    embedder = MockEmbedder()
    catalog = Catalog(small_catalog, embedder, "model", fetch=fake_fetch)
    pipeline = Pipeline(None, MockDescriber(), embedder, catalog, None, catalog_top_k=5)
    settings = Settings(catalog_path=str(small_catalog))
    client = TestClient(create_app(settings, pipeline=pipeline))
    body = client.post("/analyze", files=[("crops", ("j.png", png_bytes(product_picture("jacket", "olive")), "image/png"))],
                       data={"categories": "jacket"}).json()
    garment = body["garments"][0]
    assert [m["id"] for m in garment["catalog_matches"]] == ["olive-jacket", "black-jacket"]
    assert {"embed", "catalog"} <= set(body["timings_ms"])
    picture = client.get(garment["catalog_matches"][0]["image"])
    assert picture.status_code == 200 and picture.content[:8] == b"\x89PNG\r\n\x1a\n"


@pytest.mark.parametrize("name", ["..%2Fcatalog.json", ".hidden", "nope.png"])
def test_catalog_images_route_only_serves_files_in_images(small_catalog, name):
    client = TestClient(create_app(Settings(catalog_path=str(small_catalog))))
    assert client.get(f"/catalog-images/{name}").status_code == 404


def test_catalog_entries_say_whether_they_are_samples(tmp_path):
    path = make_catalog(tmp_path, [entry("demo", "jacket", "images/a.png", sample=True, retailer="FitMix demo")],
                        {"a.png": product_picture("jacket", "olive")})
    embedder = MockEmbedder()
    match = Catalog(path, embedder, "model").match("jacket", embedder.embed([product_picture("jacket", "olive")])[0], 1)[0]
    assert match.sample is True and match.retailer == "FitMix demo"


# MARK: Startup

def test_missing_catalog_or_model_turns_matching_off(tmp_path, monkeypatch):
    assert load_catalog(Settings(catalog_path=str(tmp_path / "none.json")), MockEmbedder()) is None
    (tmp_path / "empty.json").write_text("[]")
    assert load_catalog(Settings(catalog_path=str(tmp_path / "empty.json")), MockEmbedder()) is None

    def broken(*args, **kwargs):
        raise OSError("no network")

    monkeypatch.setattr("app.embed.FashionCLIPEmbedder.__init__", broken)
    assert load_embedder(Settings()) is None
    assert load_embedder(Settings(embeddings=False)) is None


def test_catalog_path_in_env_is_relative_to_the_service():
    settings = Settings.from_environment({"CATALOG_PATH": "catalog/other.json"})
    assert settings.catalog_path == str(SERVICE_ROOT / "catalog" / "other.json")
    assert Settings.from_environment({}).catalog_path == str(SAMPLE_CATALOG)


# MARK: eBay seed script

def ebay_summary(item_id, **changes):
    summary = {"itemId": item_id, "title": f"Listing {item_id}", "image": {"imageUrl": f"https://i.ebayimg.com/{item_id}.jpg"},
               "price": {"value": "25.00", "currency": "USD"}, "itemWebUrl": f"https://www.ebay.com/itm/{item_id}",
               "seller": {"username": "seller1"}}
    summary.update(changes)
    return summary


def test_seed_keeps_complete_listings_only():
    entries = seed_catalog_ebay.listings_to_entries("jacket", [
        ebay_summary("1"), ebay_summary("2", image=None), ebay_summary("3", price=None), ebay_summary("4", itemWebUrl=None)])
    assert [e["id"] for e in entries] == ["ebay-1"]
    assert entries[0] == {"id": "ebay-1", "title": "Listing 1", "category": "jacket",
                          "price": {"value": "25.00", "currency": "USD"}, "image": "https://i.ebayimg.com/1.jpg",
                          "retailer": "eBay · seller1", "retailer_url": "https://www.ebay.com/itm/1", "sample": False}


def test_seed_replaces_previous_ebay_entries_and_keeps_the_rest():
    existing = [{"id": "demo-jacket-01", "sample": True}, {"id": "ebay-old"}, {"id": "my-own"}]
    fresh = [{"id": "ebay-1"}, {"id": "ebay-1"}, {"id": "ebay-2"}]
    assert [e["id"] for e in seed_catalog_ebay.merge(existing, fresh)] == ["demo-jacket-01", "my-own", "ebay-1", "ebay-2"]


def test_seeded_entries_load_as_catalog_items(tmp_path):
    entries = seed_catalog_ebay.listings_to_entries("shoes", [ebay_summary("9")])
    (tmp_path / "catalog.json").write_text(json.dumps(entries))
    item = load_items(tmp_path / "catalog.json")[0]
    assert item.is_remote and item.category == "shoes" and item.price.value == "25.00"
