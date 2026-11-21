"""Stage 6: the /analyze cache by input hash, and sharing one run between identical requests. Mock components
only: no models, no network."""

import asyncio

import httpx
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.mock import MockCatalog, MockDescriber, MockEmbedder, MockOnlineSearch, MockSegmenter
from app.pipeline import Pipeline

from .test_api import jpeg, png_crop
from .test_api import FailingDescriber


class CountingPipeline(Pipeline):
    def __init__(self, describer=None, delay=0.0):
        embedder = MockEmbedder()
        super().__init__(MockSegmenter(), describer or MockDescriber(), embedder, MockCatalog(embedder),
                         MockOnlineSearch(top_k=10))
        self.runs, self.delay = 0, delay

    async def analyze(self, *args, **kwargs):
        self.runs += 1
        if self.delay:
            await asyncio.sleep(self.delay)
        return await super().analyze(*args, **kwargs)


def app_with(pipeline, **settings):
    return create_app(Settings(mock=True, **settings), pipeline=pipeline)


def post_photo(client, data):
    response = client.post("/analyze", files={"image": ("p.jpg", data, "image/jpeg")})
    assert response.status_code == 200, response.text
    return response.json()


def post_crops(client, crops, categories=None):
    files = [("crops", (f"{i}.png", data, "image/png")) for i, data in enumerate(crops)]
    response = client.post("/analyze", files=files, data={"categories": categories} if categories else None)
    assert response.status_code == 200, response.text
    return response.json()


def test_the_same_photo_returns_the_same_analysis_instantly():
    pipeline = CountingPipeline()
    client = TestClient(app_with(pipeline))
    first, again = post_photo(client, jpeg()), post_photo(client, jpeg())
    assert pipeline.runs == 1
    assert again["cached"] is True and first["cached"] is False
    assert again["analysis_id"] == first["analysis_id"] and again["garments"] == first["garments"]
    assert set(again["timings_ms"]) == {"cache", "total"}
    assert client.get("/health").json()["cached_inputs"] == 1


def test_a_different_photo_is_analyzed():
    pipeline = CountingPipeline()
    client = TestClient(app_with(pipeline))
    post_photo(client, jpeg(color=(95, 100, 50)))
    other = post_photo(client, jpeg(color=(180, 35, 40)))
    assert pipeline.runs == 2 and other["cached"] is False


def test_crops_hit_only_with_the_same_bytes_order_and_hints():
    pipeline = CountingPipeline()
    client = TestClient(app_with(pipeline))
    black, white = png_crop((25, 25, 28)), png_crop((240, 240, 236))
    post_crops(client, [black, white], "jacket,shoes")
    assert post_crops(client, [black, white], "jacket,shoes")["cached"] is True
    assert post_crops(client, [black, white], "top,shoes")["cached"] is False  # other hints
    assert post_crops(client, [white, black], "jacket,shoes")["cached"] is False  # other order
    assert pipeline.runs == 3


def test_a_photo_and_the_same_bytes_as_a_crop_are_different_inputs():
    pipeline = CountingPipeline()
    client = TestClient(app_with(pipeline))
    data = png_crop((25, 25, 28))
    client.post("/analyze", files={"image": ("p.png", data, "image/png")})
    assert post_crops(client, [data])["cached"] is False


def test_analyses_with_a_failed_step_are_not_reused():
    pipeline = CountingPipeline(describer=FailingDescriber())
    client = TestClient(app_with(pipeline))
    first, again = post_photo(client, jpeg()), post_photo(client, jpeg())
    assert pipeline.runs == 2 and again["cached"] is False
    assert first["analysis_id"] != again["analysis_id"]


def test_expired_or_evicted_analyses_are_run_again():
    pipeline = CountingPipeline()
    client = TestClient(app_with(pipeline, cache_size=1))
    post_photo(client, jpeg(color=(95, 100, 50)))
    post_photo(client, jpeg(color=(180, 35, 40)))  # pushes the first one out
    assert post_photo(client, jpeg(color=(95, 100, 50)))["cached"] is False
    assert pipeline.runs == 3


def test_a_cached_analysis_keeps_its_cached_searches():
    client = TestClient(app_with(CountingPipeline()))
    analysis_id = post_photo(client, jpeg())["analysis_id"]
    client.post("/search", json={"analysis_id": analysis_id, "garment_index": 0})
    again = post_photo(client, jpeg())
    search = client.post("/search", json={"analysis_id": again["analysis_id"], "garment_index": 0}).json()
    assert search["cached"] is True


def test_identical_requests_at_the_same_time_share_one_run():
    pipeline = CountingPipeline(delay=0.2)
    app = app_with(pipeline)

    async def both():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            files = lambda: {"image": ("p.jpg", jpeg(), "image/jpeg")}  # noqa: E731
            first, second = await asyncio.gather(client.post("/analyze", files=files()),
                                                 client.post("/analyze", files=files()))
            crop = await client.get(second.json()["garments"][0]["crop_url"])
            return first.json(), second.json(), crop.status_code

    first, second, crop_status = asyncio.run(both())
    assert pipeline.runs == 1
    assert first["analysis_id"] == second["analysis_id"]
    assert sorted([first["cached"], second["cached"]]) == [False, True]
    assert crop_status == 200
