"""Google Lens product search: filtering, cache, in-flight de-duplication, usage cap and failure handling. Scrappa is replaced by httpx.MockTransport or a stub: no key, nothing sent."""

import asyncio
import json
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app.lens_search import LensSearch, credible
from app.main import Settings, create_app, default_lens_search
from app.providers import CropHost, ScrappaLensProvider
from app.visual_search import Candidate, Clues, ProviderError

JPEG = b"\xff\xd8\xff\xe0" + b"1" * 64
FIXTURES = Path(__file__).parent / "fixtures"


def cand(title, url, image="https://img.example/a.jpg", rank=0, price=None, retailer="Shop"):
    return Candidate(id=url, title=title, url=url, retailer=retailer, provider="google_lens", rank=rank,
                     image_url=image, price=price)


class Stub:
    name, fixture = "google_lens", False

    def __init__(self, answers=None, error=None, delay=0.0):
        self.answers, self.error, self.delay, self.calls = answers or [], error, delay, 0

    async def search(self, crop, clues):
        self.calls += 1
        if self.delay:
            await asyncio.sleep(self.delay)
        if self.error:
            raise self.error
        return list(self.answers)


class PageEnricher:
    """Pretends each listing page names its own product photo."""

    async def enrich(self, c):
        from dataclasses import replace
        return replace(c, image_url=c.url.rstrip("/") + "/product.jpg")


def app_with(lens):
    return TestClient(create_app(Settings(visual_providers=()), providers=[], enricher=None, lens=lens))


def post(client, category="tshirt", crop=JPEG):
    return client.post("/v1/lens-search", files={"crop": ("garment.jpg", crop, "image/jpeg")}, data={"category": category})


TEE = cand("Heavyweight Cotton T-Shirt Navy", "https://www.example-store.com/p/navy-tee", rank=0, retailer="Example Store")


# Search


def test_bad_category_or_non_image_never_reaches_the_provider():
    stub = Stub([TEE])
    client = app_with(LensSearch(stub))
    assert post(client, category="hat").status_code == 400
    assert post(client, crop=b"not an image").status_code == 400
    assert stub.calls == 0


def test_a_crop_returns_the_best_credible_listing_as_similar():
    stub = Stub([TEE])
    body = post(app_with(LensSearch(stub, PageEnricher()))).json()
    assert stub.calls == 1
    assert body["status"] == "matched" and body["source"] == "google_lens" and body["cached"] is False
    result = body["result"]
    assert result["match"] == "similar" and result["url"] == TEE.url and result["title"] == TEE.title
    # The retailer's own product photo from the listing page, not Lens's thumbnail.
    assert result["image_url"] == "https://www.example-store.com/p/navy-tee/product.jpg"
    assert result["image_source"] == "listing_page"


def test_even_an_exact_image_hit_is_labeled_similar():
    same = cand("Nike Tee", "https://www.nike.com/t/tee-1")
    same.same_image = True
    body = post(app_with(LensSearch(Stub([same])))).json()
    assert body["result"]["match"] == "similar"


# Filtering


@pytest.mark.parametrize("candidate", [
    cand("Navy T-Shirt", "https://www.pinterest.com/pin/1"),                    # not a retailer
    cand("Navy T-Shirt", "https://www.google.com/search?q=tee"),               # Google page
    cand("Navy T-Shirt", None),                                                 # no product link
    cand("Navy T-Shirt", "ftp://shop.example/tee"),                             # not a web link
    cand("Navy T-Shirt", "https://shop.example/tee", image=None),               # no photo
    cand("Navy T-Shirt", "https://shop.example/tee", image="http://img/a.jpg"),  # photo not https
    cand("Leather Ankle Boots", "https://shop.example/boots"),                  # another category
    cand("Ocean sunset wallpaper", "https://shop.example/poster"),              # unrelated, no price
])
def test_unusable_or_unrelated_results_are_dropped(candidate):
    assert not credible(candidate, "tshirt")
    body = post(app_with(LensSearch(Stub([candidate])))).json()
    assert body == {"status": "no_match", "category": "tshirt", "source": "google_lens", "cached": False, "result": None}


def test_a_priced_listing_page_counts_even_if_its_title_skips_the_category_word():
    assert credible(cand("Organic Crew Uniform Navy", "https://shop.example/crew", price={"value": "30.00", "currency": "USD"}), "tshirt")


def test_empty_lens_response_is_no_close_match():
    body = post(app_with(LensSearch(Stub([])))).json()
    assert body["status"] == "no_match" and body["result"] is None


def test_constructed_scrappa_fixture_picks_a_tee_and_skips_noise():
    raw = json.loads((FIXTURES / "lens_white_tee.json").read_text())
    host = CropHost()

    def scrappa(request):
        return httpx.Response(200, json=raw)

    provider = ScrappaLensProvider("k", "https://fitmix.example", host, search_type="visual_matches",
                                   http=httpx.AsyncClient(transport=httpx.MockTransport(scrappa)))
    body = post(app_with(LensSearch(provider))).json()
    assert body["status"] == "matched"
    assert "google.com" not in body["result"]["url"] and body["result"]["match"] == "similar"


# Cache


def test_the_same_crop_is_answered_from_cache(tmp_path):
    stub = Stub([TEE])
    lens = LensSearch(stub, state_path=tmp_path / "lens.json")
    client = app_with(lens)
    first, second = post(client).json(), post(client).json()
    assert stub.calls == 1 and first["cached"] is False and second["cached"] is True
    assert first["result"] == second["result"]
    # Survives a restart, without any image in the file.
    again = LensSearch(Stub([TEE]), state_path=tmp_path / "lens.json")
    assert post(app_with(again)).json()["cached"] is True and again.provider.calls == 0
    assert b"\xff\xd8" not in (tmp_path / "lens.json").read_bytes()


def test_no_close_match_is_cached_too_and_failures_are_not():
    empty = Stub([])
    client = app_with(LensSearch(empty))
    post(client), post(client)
    assert empty.calls == 1
    failing = Stub(error=ProviderError("provider_timeout", "slow"))
    client = app_with(LensSearch(failing, failure_threshold=99))
    assert post(client).status_code == 504 and post(client).status_code == 504
    assert failing.calls == 2


def test_cache_entries_expire():
    now = [1000.0]
    stub = Stub([TEE])
    client = app_with(LensSearch(stub, cache_ttl=60, clock=lambda: now[0]))
    post(client)
    now[0] += 61
    post(client)
    assert stub.calls == 2


def test_a_different_category_is_a_different_search():
    stub = Stub([TEE, cand("Slim Jeans", "https://shop.example/jeans")])
    client = app_with(LensSearch(stub))
    post(client, "tshirt"), post(client, "pants")
    assert stub.calls == 2


def test_concurrent_identical_searches_make_one_call():
    stub = Stub([TEE], delay=0.05)
    lens = LensSearch(stub)

    async def both():
        return await asyncio.gather(lens.search(JPEG, Clues("tshirt")), lens.search(JPEG, Clues("tshirt")))

    a, b = asyncio.run(both())
    assert stub.calls == 1 and a.result == b.result


# Missing configuration, budget, quota, failures


def test_missing_key_or_public_url_is_not_configured_without_calling_anyone(tmp_path):
    for settings, why in [(Settings(), "SCRAPPA_API_KEY"),
                          (Settings(scrappa_api_key="k", public_base_url="http://lan.local"), "https")]:
        lens = default_lens_search(settings, CropHost(), None, state_path=tmp_path / "x.json")
        response = post(app_with(lens))
        assert response.status_code == 503 and response.json()["error"]["code"] == "not_configured"
        assert why in response.json()["error"]["message"]
        assert "k" != response.json()["error"]["message"]


def test_configured_lens_uses_the_visual_matches_endpoint(tmp_path):
    lens = default_lens_search(Settings(scrappa_api_key="k", public_base_url="https://fitmix.example"), CropHost(), None,
                                 state_path=tmp_path / "x.json")
    assert lens.ready and lens.provider.search_type == "visual_matches"


def test_monthly_budget_stops_calls_before_the_free_allowance():
    stub = Stub([])
    client = app_with(LensSearch(stub, monthly_limit=2))
    codes = [post(client, crop=JPEG + bytes([i])).status_code for i in range(4)]
    assert codes == [200, 200, 503, 503] and stub.calls == 2
    assert post(client, crop=JPEG + bytes([0])).status_code == 200  # cached answers still work


def test_quota_exhaustion_stops_further_calls(tmp_path):
    stub = Stub(error=ProviderError("provider_quota", "used up", retryable=False))
    lens = LensSearch(stub, state_path=tmp_path / "lens.json")
    client = app_with(lens)
    first, second = post(client), post(client, crop=JPEG + b"2")
    assert first.status_code == 503 and first.json()["error"]["code"] == "provider_quota"
    assert second.json()["error"]["code"] == "provider_quota" and stub.calls == 1
    assert LensSearch(Stub(), state_path=tmp_path / "lens.json").status()["quota_exhausted"] is True


def test_scrappa_402_is_quota():
    host = CropHost()
    provider = ScrappaLensProvider("k", "https://fitmix.example", host, search_type="visual_matches",
                                   http=httpx.AsyncClient(transport=httpx.MockTransport(
                                       lambda r: httpx.Response(402, json={"error": "You've ran out of credits"}))))
    with pytest.raises(ProviderError) as error:
        asyncio.run(provider.search(JPEG, Clues("tshirt")))
    assert error.value.code == "provider_quota" and error.value.retryable is False


def test_refused_key_stops_further_calls():
    stub = Stub(error=ProviderError("provider_auth", "refused", retryable=False))
    client = app_with(LensSearch(stub))
    post(client), post(client, crop=JPEG + b"2")
    assert stub.calls == 1


def test_rate_limit_cools_down():
    now = [0.0]
    stub = Stub(error=ProviderError("RATE_LIMITED", "slow down"))
    client = app_with(LensSearch(stub, cooldown=60, clock=lambda: now[0]))
    assert post(client).status_code == 502
    assert post(client, crop=JPEG + b"2").json()["error"]["code"] == "provider_cooling_down" and stub.calls == 1
    now[0] = 61
    post(client, crop=JPEG + b"3")
    assert stub.calls == 2


def test_repeated_failures_cool_down():
    stub = Stub(error=ProviderError("provider_unreachable", "down"))
    client = app_with(LensSearch(stub, failure_threshold=2))
    for i in range(5):
        post(client, crop=JPEG + bytes([i]))
    assert stub.calls == 2


def test_timeout_is_504_and_the_key_never_reaches_a_response():
    host = CropHost()

    def slow(request):
        raise httpx.ReadTimeout("slow", request=request)

    provider = ScrappaLensProvider("super-secret-key", "https://fitmix.example", host, search_type="visual_matches",
                                   http=httpx.AsyncClient(transport=httpx.MockTransport(slow)))
    client = app_with(LensSearch(provider))
    response = post(client)
    assert response.status_code == 504 and response.json()["error"]["code"] == "provider_timeout"
    assert "super-secret-key" not in response.text
    assert "super-secret-key" not in json.dumps(client.get("/health").json())


def test_health_reports_lens_readiness_without_the_key():
    lens = default_lens_search(Settings(), CropHost(), None, state_path=None)
    health = app_with(lens).get("/health").json()["lens_search"]
    assert health["ready"] is False and "SCRAPPA_API_KEY" in health["message"]
