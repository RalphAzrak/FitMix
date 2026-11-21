"""API and pipeline tests on the mock components: no model downloads, no network, no keys."""

import io

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image
from pydantic import ValidationError

from app.config import Settings
from app.main import create_app
from app.mock import MockCatalog, MockDescriber, MockEmbedder, MockOnlineSearch, MockSegmenter
from app.models import GarmentAttributes
from app.pipeline import Pipeline, StepFailure
from app.store import TTLCache


def jpeg(color=(95, 100, 50), size=(300, 600)) -> bytes:
    """A fake 'person photo': a coloured top half and a navy bottom half on white."""
    image = Image.new("RGB", size, (255, 255, 255))
    w, h = size
    image.paste(Image.new("RGB", (int(w * 0.6), int(h * 0.38)), color), (int(w * 0.2), int(h * 0.15)))
    image.paste(Image.new("RGB", (int(w * 0.45), int(h * 0.4)), (28, 38, 80)), (int(w * 0.28), int(h * 0.52)))
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG")
    return buffer.getvalue()


def png_crop(color) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (200, 240), color).save(buffer, format="PNG")
    return buffer.getvalue()


def mock_pipeline(**overrides) -> Pipeline:
    embedder = MockEmbedder()
    parts = dict(segmenter=MockSegmenter(), describer=MockDescriber(), embedder=embedder,
                 catalog=MockCatalog(embedder), online=MockOnlineSearch(top_k=10))
    parts.update(overrides)
    return Pipeline(**parts)


@pytest.fixture
def client():
    return TestClient(create_app(Settings(mock=True)))


def analyze_photo(client, data=None):
    response = client.post("/analyze", files={"image": ("person.jpg", data or jpeg(), "image/jpeg")})
    assert response.status_code == 200, response.text
    return response.json()


# MARK: /health

def test_health_reports_mock_components(client):
    body = client.get("/health").json()
    assert body["status"] == "ok" and body["ready"] and body["mock"]
    assert body["components"]["segmenter"] == "mock"
    assert body["keys"] == {"openai": False, "serpapi": False, "supabase": False}


def test_without_mock_or_models_analyze_says_not_configured():
    client = TestClient(create_app(Settings(mock=False)))
    assert client.get("/health").json()["ready"] is False
    response = client.post("/analyze", files={"image": ("p.jpg", jpeg(), "image/jpeg")})
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "not_configured"


# MARK: /analyze

def test_analyze_photo_returns_garments_with_crops_attributes_and_catalog(client):
    body = analyze_photo(client)
    assert body["input"] == "image" and body["mock"] is True and body["cached"] is False
    assert [g["category"] for g in body["garments"]] == ["top", "pants"]
    top, pants = body["garments"]
    assert top["attributes"]["color"] == "olive"  # measured from the photo's pixels
    assert pants["attributes"]["color"] == "navy"
    assert top["app_category"] == "tshirt" and top["source_label"] == "upper_clothes"
    assert top["online_matches"] == []  # online search is on demand only
    matches = top["catalog_matches"]
    assert len(matches) == 5
    assert all(m["id"].startswith("demo-top-") for m in matches)  # same category only
    assert [m["score"] for m in matches] == sorted((m["score"] for m in matches), reverse=True)
    assert set(body["timings_ms"]) >= {"segment", "describe", "embed", "catalog", "total"}


def test_crop_and_mock_image_urls_are_served(client):
    garment = analyze_photo(client)["garments"][0]
    crop = client.get(garment["crop_url"])
    assert crop.status_code == 200 and crop.headers["content-type"] == "image/jpeg"
    assert crop.content[:3] == b"\xff\xd8\xff"
    picture = client.get(garment["catalog_matches"][0]["image"])
    assert picture.status_code == 200 and picture.headers["content-type"] == "image/jpeg"


def test_unknown_crop_is_404(client):
    assert client.get("/crops/nope/0.jpg").status_code == 404
    analysis_id = analyze_photo(client)["analysis_id"]
    assert client.get(f"/crops/{analysis_id}/9.jpg").status_code == 404


def test_analyze_app_crops_skips_segmentation_and_uses_hints(client):
    files = [("crops", ("a.png", png_crop((25, 25, 28)), "image/png")),
             ("crops", ("b.png", png_crop((240, 240, 236)), "image/png"))]
    response = client.post("/analyze", files=files, data={"categories": "jacket,shoes"})
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["input"] == "crops" and "segment" not in body["timings_ms"]
    assert [g["category"] for g in body["garments"]] == ["jacket", "shoes"]
    assert [g["attributes"]["color"] for g in body["garments"]] == ["black", "white"]
    assert body["garments"][1]["catalog_matches"][0]["id"].startswith("demo-shoes-")


@pytest.mark.parametrize("categories", ["jacket", "jacket,hat"])
def test_categories_must_match_crops(client, categories):
    files = [("crops", ("a.png", png_crop((0, 0, 0)), "image/png")), ("crops", ("b.png", png_crop((0, 0, 0)), "image/png"))]
    response = client.post("/analyze", files=files, data={"categories": categories})
    assert response.status_code == 400 and response.json()["error"]["code"] == "invalid_categories"


def test_analyze_needs_exactly_one_kind_of_input(client):
    assert client.post("/analyze").status_code == 400
    both = client.post("/analyze", files=[("image", ("p.jpg", jpeg(), "image/jpeg")),
                                          ("crops", ("c.png", png_crop((0, 0, 0)), "image/png"))])
    assert both.status_code == 400


def test_non_image_upload_is_rejected(client):
    response = client.post("/analyze", files={"image": ("p.jpg", b"not a picture", "image/jpeg")})
    assert response.status_code == 400 and response.json()["error"]["code"] == "invalid_image"


def test_too_many_crops_is_rejected():
    client = TestClient(create_app(Settings(mock=True, max_crops=1)))
    files = [("crops", (f"{i}.png", png_crop((0, 0, 0)), "image/png")) for i in range(2)]
    assert client.post("/analyze", files=files).json()["error"]["code"] == "too_many_crops"


def test_token_is_required_when_set():
    client = TestClient(create_app(Settings(mock=True, app_token="s3cret")))
    files = {"image": ("p.jpg", jpeg(), "image/jpeg")}
    assert client.post("/analyze", files=files).status_code == 401
    assert client.post("/analyze", files=files, headers={"Authorization": "Bearer s3cret"}).status_code == 200


# MARK: /search and /refine

def test_search_returns_ranked_online_matches_and_caches(client):
    analysis_id = analyze_photo(client)["analysis_id"]
    first = client.post("/search", json={"analysis_id": analysis_id, "garment_index": 0}).json()
    assert first["query"] == "olive cotton crew neck t-shirt" and first["brand"] is None
    assert len(first["online_matches"]) == 10 and first["cached"] is False
    scores = [m["score"] for m in first["online_matches"]]
    assert scores == sorted(scores, reverse=True)
    assert all(m["url"].startswith("https://example.com/") for m in first["online_matches"])
    again = client.post("/search", json={"analysis_id": analysis_id, "garment_index": 0}).json()
    assert again["cached"] is True and again["online_matches"] == first["online_matches"]


def test_refine_adds_brand_to_query(client):
    analysis_id = analyze_photo(client)["analysis_id"]
    body = client.post("/refine", json={"analysis_id": analysis_id, "garment_index": 1, "brand": "Levi's"}).json()
    assert body["query"] == "Levi's navy straight leg jeans" and body["brand"] == "Levi's"
    assert body["cached"] is False


def test_search_unknown_analysis_or_garment_is_404(client):
    assert client.post("/search", json={"analysis_id": "missing", "garment_index": 0}).status_code == 404
    analysis_id = analyze_photo(client)["analysis_id"]
    response = client.post("/search", json={"analysis_id": analysis_id, "garment_index": 7})
    assert response.status_code == 404 and response.json()["error"]["code"] == "garment_not_found"


def test_refine_needs_a_brand(client):
    analysis_id = analyze_photo(client)["analysis_id"]
    response = client.post("/refine", json={"analysis_id": analysis_id, "garment_index": 0, "brand": ""})
    assert response.status_code == 400


# MARK: Partial failures

class FailingDescriber:
    name = "failing"

    async def describe(self, crops, hints):
        raise StepFailure("provider_unreachable", "The description service couldn't be reached.")


def test_failed_description_still_returns_crops_and_catalog_matches():
    client = TestClient(create_app(Settings(mock=True), pipeline=mock_pipeline(describer=FailingDescriber())))
    body = analyze_photo(client)
    top = body["garments"][0]
    assert top["attributes"] is None and top["category"] == "top"  # falls back to the segmentation label
    assert len(top["catalog_matches"]) == 5
    assert top["errors"] == [{"step": "describe", "code": "provider_unreachable",
                              "message": "The description service couldn't be reached."}]
    # Search still works from the segmentation category.
    search = client.post("/search", json={"analysis_id": body["analysis_id"], "garment_index": 0}).json()
    assert search["query"] == "shirt" and len(search["online_matches"]) == 10


def test_failed_online_search_returns_errors_and_is_not_cached():
    client = TestClient(create_app(Settings(mock=True), pipeline=mock_pipeline(online=MockOnlineSearch(fail="all"))))
    analysis_id = analyze_photo(client)["analysis_id"]
    for _ in range(2):
        body = client.post("/search", json={"analysis_id": analysis_id, "garment_index": 0}).json()
        assert body["online_matches"] == [] and body["cached"] is False
        assert body["errors"][0]["code"] == "provider_unreachable"


class EmptySegmenter:
    name = "empty"

    def segment(self, image):
        return []


def test_photo_without_garments_reports_why():
    client = TestClient(create_app(Settings(mock=True), pipeline=mock_pipeline(segmenter=EmptySegmenter())))
    body = analyze_photo(client)
    assert body["garments"] == [] and body["errors"][0]["code"] == "no_garments"


# MARK: Units

def test_llm_attributes_are_strict():
    good = dict(category="jacket", color="olive", pattern="solid", material="nylon", style="bomber",
                visible_brand=None, description="An olive bomber.", search_query="olive bomber jacket")
    assert GarmentAttributes(**good).layered_over_top is False
    with pytest.raises(ValidationError):
        GarmentAttributes(**{**good, "category": "hat"})
    with pytest.raises(ValidationError):
        GarmentAttributes(**{**good, "extra": "field"})
    with pytest.raises(ValidationError):
        GarmentAttributes(**{**good, "search_query": ""})


def test_mock_embeddings_are_normalised():
    vectors = MockEmbedder().embed([Image.new("RGB", (64, 64), (200, 10, 10)), Image.new("RGB", (64, 64), (10, 10, 200))])
    assert vectors.shape == (2, 48)
    assert np.allclose(np.linalg.norm(vectors, axis=1), 1.0)


def test_ttl_cache_expires_and_evicts():
    now = [0.0]
    cache = TTLCache(size=2, ttl_seconds=10, clock=lambda: now[0])
    cache.put("a", 1)
    cache.put("b", 2)
    cache.put("c", 3)
    assert cache.get("a") is None and cache.get("b") == 2  # "a" evicted as least recently used
    now[0] = 11
    assert cache.get("b") is None


def test_settings_read_weights_and_flags():
    settings = Settings.from_environment({"MOCK_MODE": "1", "RERANK_IMAGE_WEIGHT": "0.7", "RERANK_ATTR_WEIGHT": "0.3",
                                          "SERPAPI_KEY": " key "})
    assert settings.mock and settings.rerank_image_weight == 0.7 and settings.rerank_attr_weight == 0.3
    assert settings.serpapi_key == "key" and "key" not in repr(settings)
