"""The "vision" match provider. The FitMix vision service is replaced by httpx.MockTransport, so nothing is sent.
Its answers are shaped like vision-service's /analyze and /search responses; the products are not real."""

import asyncio
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import Settings, create_app, default_matcher
from app.retail import MAX_RESULTS, MatchError
from app.vision import VisionMatcher, listing_from_match

JPEG = b"\xff\xd8\xff\xe0" + b"0" * 64


def online(n, **changes):
    match = {"title": f"Olive Bomber Jacket {n}", "price": {"value": "49.00", "currency": "USD"},
             "retailer": "Northwind Apparel", "url": f"https://shop.example/item/{n}",
             "image": f"https://img.example/{n}.jpg", "score": round(0.9 - n / 100, 4), "source": "lens"}
    match.update(changes)
    return match


class FakeVision:
    def __init__(self, matches=None, search_errors=None, mock=False, garments=1, status=200, error=None):
        self.matches = [online(n) for n in range(1, 4)] if matches is None else matches
        self.search_errors, self.mock, self.garments = search_errors or [], mock, garments
        self.status, self.error = status, error
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.status != 200:
            return httpx.Response(self.status, json={"error": self.error or {"code": "x", "message": "Broken."}})
        if request.url.path == "/analyze":
            garments = [{"index": 0, "category": "jacket"}] * self.garments
            errors = [] if self.garments else [{"step": "describe", "code": "provider_busy", "message": "OpenAI is busy."}]
            return httpx.Response(200, json={"analysis_id": "abc123", "mock": self.mock, "garments": garments, "errors": errors})
        return httpx.Response(200, json={"analysis_id": "abc123", "garment_index": 0, "mock": self.mock,
                                         "online_matches": self.matches, "errors": self.search_errors})


def matcher(fake, token=""):
    return VisionMatcher("http://vision.local:8790/", token, transport=httpx.MockTransport(fake))


def run(coroutine):
    return asyncio.run(coroutine)


def test_forwards_the_crop_then_searches_that_analysis():
    fake = FakeVision()
    listings = run(matcher(fake).search("jacket", JPEG, "olive", ["alpha"]))
    analyze, search = fake.requests
    assert analyze.url == "http://vision.local:8790/analyze"
    body = analyze.content
    assert JPEG in body and b'name="crops"' in body and b'name="categories"' in body and b"jacket" in body
    assert search.url.path == "/search"
    assert json.loads(search.content) == {"analysis_id": "abc123", "garment_index": 0}
    assert [l.title for l in listings] == ["Olive Bomber Jacket 1", "Olive Bomber Jacket 2", "Olive Bomber Jacket 3"]


def test_matches_become_listings():
    listing = listing_from_match(online(1))
    assert listing.to_json() == {"id": listing.id, "title": "Olive Bomber Jacket 1", "retailer": "Northwind Apparel",
                                 "seller": None, "image_url": "https://img.example/1.jpg",
                                 "url": "https://shop.example/item/1", "price": {"value": "49.00", "currency": "USD"},
                                 "match": "similar"}
    assert len(listing.id) == 16 and listing.id != listing_from_match(online(2)).id
    no_shop = listing_from_match(online(1, retailer=None, price=None, url="https://www.store.example/p/1"))
    assert no_shop.retailer == "store.example" and no_shop.price is None
    assert listing_from_match(online(1, url=None)) is None and listing_from_match(online(1, title=" ")) is None


def test_keeps_the_vision_services_order_up_to_max_results():
    listings = run(matcher(FakeVision(matches=[online(n) for n in range(1, 11)])).search("jacket", JPEG, None, []))
    assert len(listings) == MAX_RESULTS and listings[0].title == "Olive Bomber Jacket 1"


def test_mock_mode_answers_are_labelled_as_fixtures():
    subject = matcher(FakeVision(mock=True))
    run(subject.search("jacket", JPEG, None, []))
    assert subject.fixture is True
    real = matcher(FakeVision(mock=False))
    run(real.search("jacket", JPEG, None, []))
    assert real.fixture is False


def test_no_results_is_no_match():
    assert run(matcher(FakeVision(matches=[])).search("jacket", JPEG, None, [])) == []


def test_failed_search_with_no_results_is_retryable():
    fake = FakeVision(matches=[], search_errors=[{"step": "lens", "code": "provider_busy", "message": "Search is busy."}])
    with pytest.raises(MatchError) as failure:
        run(matcher(fake).search("jacket", JPEG, None, []))
    assert (failure.value.code, failure.value.message) == ("provider_busy", "Search is busy.")


def test_partial_failure_with_results_still_returns_them():
    fake = FakeVision(search_errors=[{"step": "lens", "code": "storage_bucket", "message": "No bucket."}])
    assert len(run(matcher(fake).search("jacket", JPEG, None, []))) == 3


def test_unreadable_garment_is_reported():
    with pytest.raises(MatchError) as failure:
        run(matcher(FakeVision(garments=0)).search("jacket", JPEG, None, []))
    assert failure.value.code == "provider_error" and failure.value.message == "OpenAI is busy."


@pytest.mark.parametrize("status, error, code", [
    (401, {"code": "unauthorized", "message": "No."}, "provider_auth"),
    (503, {"code": "not_configured", "message": "No models yet."}, "not_configured"),
    (500, None, "provider_error"),
])
def test_vision_service_errors(status, error, code):
    with pytest.raises(MatchError) as failure:
        run(matcher(FakeVision(status=status, error=error)).search("jacket", JPEG, None, []))
    assert failure.value.code == code


def test_vision_service_not_running():
    def offline(request):
        raise httpx.ConnectError("refused", request=request)

    with pytest.raises(MatchError) as failure:
        run(matcher(offline).search("jacket", JPEG, None, []))
    assert failure.value.code == "provider_unreachable" and "vision-service/run.sh" in failure.value.message


def test_token_is_sent_when_set():
    fake = FakeVision()
    run(matcher(fake, token="s3cret").search("jacket", JPEG, None, []))
    assert all(r.headers["authorization"] == "Bearer s3cret" for r in fake.requests)
    plain = FakeVision()
    run(matcher(plain).search("jacket", JPEG, None, []))
    assert "authorization" not in plain.requests[0].headers


def test_provider_setting_selects_the_vision_matcher():
    chosen = default_matcher(Settings(match_provider="vision", vision_service_url="http://mac.local:8790", vision_app_token="t"))
    assert isinstance(chosen, VisionMatcher) and chosen.base_url == "http://mac.local:8790"


def test_garment_match_endpoint_uses_the_vision_service():
    fake = FakeVision(mock=True)
    client = TestClient(create_app(Settings(), matcher=matcher(fake)))
    response = client.post("/v1/garment-match", files={"crop": ("g.jpg", JPEG, "image/jpeg")}, data={"category": "jacket"})
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "matched" and body["provider"] == "vision" and body["fixture"] is True
    assert body["results"][0]["url"] == "https://shop.example/item/1"
    assert client.get("/health").json()["match_provider"] == "vision"
