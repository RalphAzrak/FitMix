"""POST /v1/garment-match and the eBay provider. eBay is replaced by recorded-shape answers (httpx.MockTransport):
no keys, nothing sent. The item summaries are fixtures shaped like eBay's documented ItemSummary schema."""

import base64
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import Settings, create_app, default_providers
from app.providers import CropHost, EbayProvider, FixtureProvider
from app.retail import EBAY_CATEGORY_IDS, EbayMatcher, keep
from app.visual_search import Candidate, Clues, ProviderError

JPEG = b"\xff\xd8\xff\xe0" + b"0" * 64


def item(item_id, title, category_name, price=("59.99", "USD")):
    summary = {"itemId": item_id, "title": title, "categories": [{"categoryId": "1", "categoryName": category_name}],
               "itemWebUrl": f"https://www.ebay.com/itm/{item_id}", "seller": {"username": "seller_" + item_id},
               "image": {"imageUrl": f"https://i.ebayimg.com/images/{item_id}.jpg"}}
    if price:
        summary["price"] = {"value": price[0], "currency": price[1]}
    return summary


class FakeEbay:
    def __init__(self, pages=None, search_status=200, token_status=200, expire_first=False):
        self.pages, self.search_status, self.token_status, self.expire_first = pages or {}, search_status, token_status, expire_first
        self.searches, self.tokens = [], 0

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if request.url.path == "/identity/v1/oauth2/token":
            self.tokens += 1
            if self.token_status != 200:
                return httpx.Response(self.token_status, json={"error": "invalid_client"})
            return httpx.Response(200, json={"access_token": f"token-{self.tokens}", "expires_in": 7200})
        body = json.loads(request.content)
        self.searches.append({"category": request.url.params["category_ids"], "filter": request.url.params.get("filter"),
                              "image": body["image"]})
        if self.expire_first and len(self.searches) == 1:
            return httpx.Response(401, json={"errors": [{"errorId": 1001}]})
        if self.search_status != 200:
            return httpx.Response(self.search_status, json={"errors": [{"errorId": 12000}]})
        return httpx.Response(200, json={"itemSummaries": self.pages.get(request.url.params["category_ids"], [])})


def ebay(fake):
    return EbayProvider(EbayMatcher("id", "secret", "EBAY_US", http=httpx.AsyncClient(transport=httpx.MockTransport(fake))))


class Recorder:
    name, fixture = "recorder", False

    def __init__(self, candidates=None, error=None):
        self.candidates, self.error, self.calls = candidates or [], error, []

    async def search(self, crop, clues):
        self.calls.append((crop, clues))
        if self.error:
            raise self.error
        return self.candidates


def client(*providers, **settings):
    return TestClient(create_app(Settings(listing_enrichment=False, **settings), providers=list(providers)))


def post(c, category="shoes", crop=JPEG, headers=None, **fields):
    return c.post("/v1/garment-match", files={"crop": ("g.jpg", crop, "image/jpeg")},
                  data={"category": category, **fields}, headers=headers or {})


# eBay provider


def test_ebay_searches_only_the_selected_category_with_the_crop():
    men, women = EBAY_CATEGORY_IDS["shoes"]
    fake = FakeEbay(pages={men: [item("1", "Nike Air Max 90 White Sneakers", "Athletic Shoes")],
                           women: [item("2", "White Leather Sneakers", "Women's Shoes")]})
    body = post(client(ebay(fake))).json()
    assert sorted(s["category"] for s in fake.searches) == sorted([men, women])
    assert all(s["image"] == base64.b64encode(JPEG).decode() and s["filter"] == "buyingOptions:{FIXED_PRICE}" for s in fake.searches)
    assert {r["id"] for r in body["results"]} == {"1", "2"}
    assert body["providers"] == [{"name": "ebay", "status": "ok", "count": 2}]


def test_ebay_drops_listings_outside_the_category_and_keeps_missing_prices_missing():
    men, _ = EBAY_CATEGORY_IDS["pants"]
    fake = FakeEbay(pages={men: [item("3", "Straight Jeans", "Jeans", price=None), item("4", "Jacket", "Coats & Jackets")]})
    [result] = post(client(ebay(fake)), category="pants").json()["results"]
    assert result["id"] == "3" and result["price"] is None


def test_ebay_refreshes_an_expired_token_once():
    fake = FakeEbay(expire_first=True)
    post(client(ebay(fake)), category="pants")
    assert fake.tokens == 2


@pytest.mark.parametrize("status,code", [(429, "provider_busy"), (500, "provider_error"), (403, "provider_auth")])
def test_ebay_failures_become_app_errors(status, code):
    response = post(client(ebay(FakeEbay(search_status=status))))
    assert response.status_code in (502, 503) and response.json()["error"]["code"] == code


def test_womens_tops_count_as_tshirt_only_when_the_title_says_so():
    assert keep("tshirt", {"title": "Graphic Tee", "categories": [{"categoryName": "Tops"}]})
    assert not keep("tshirt", {"title": "Silk Blouse", "categories": [{"categoryName": "Tops"}]})


# Endpoint


def test_endpoint_passes_category_crop_and_every_clue():
    recorder = Recorder([Candidate("1", "Converse Chuck Taylor All Star Hi Black", "https://shop.example/1", "Shop", "recorder", 0,
                                   image_url="https://img.example/1.jpg", price={"value": "65.00", "currency": "USD"})])
    body = post(client(recorder), color="Black", brand_hints="converse", text="converse,all,star,m9160",
                pattern="", style="sneaker").json()
    crop, clues = recorder.calls[0]
    assert crop == JPEG
    assert clues == Clues(category="shoes", color="black", brand_hints=["converse"], text=["converse", "all", "star", "m9160"],
                          pattern=None, style="sneaker")
    [result] = body["results"]
    assert result["match"] == "exact" and result["brand"] == "Converse"
    assert result["price"] == {"value": "65.00", "currency": "USD"} and result["image_url"] == "https://img.example/1.jpg"
    assert body["status"] == "matched" and body["fixture"] is False


def test_one_failing_provider_does_not_sink_the_others():
    good = Recorder([Candidate("1", "Black high top sneaker", "https://a.example/1", "A", "recorder", 0)])
    bad = Recorder(error=ProviderError("provider_busy", "busy"))
    bad.name = "broken"
    body = post(client(good, bad)).json()
    assert [r["id"] for r in body["results"]] == ["1"]
    assert {p["name"]: p["status"] for p in body["providers"]} == {"recorder": "ok", "broken": "error"}


def test_all_providers_failing_is_a_retryable_error():
    response = post(client(Recorder(error=ProviderError("provider_busy", "busy"))))
    assert response.status_code == 503 and response.json()["error"]["code"] == "provider_busy"


def test_endpoint_reports_no_match():
    body = post(client(Recorder([])), category="pants").json()
    assert body["status"] == "no_match" and body["results"] == []


def test_endpoint_without_providers_says_what_is_missing():
    response = post(TestClient(create_app(Settings(visual_providers=("ebay", "google_lens"), listing_enrichment=False))))
    error = response.json()["error"]
    assert response.status_code == 503 and error["code"] == "not_configured"
    assert "EBAY_CLIENT_ID" in error["message"] and "SCRAPPA_API_KEY" in error["message"]


def test_endpoint_rejects_other_categories_and_non_images():
    c = client(Recorder())
    assert post(c, category="hat").json()["error"]["code"] == "invalid_category"
    assert post(c, crop=b"not an image").json()["error"]["code"] == "invalid_image"


def test_endpoint_requires_the_app_token_when_set():
    c = client(Recorder(), app_token="s3cret")
    assert post(c).status_code == 401
    assert post(c, headers={"Authorization": "Bearer s3cret"}).status_code == 200


def test_fixture_provider_is_labeled_and_links_nowhere():
    c = TestClient(create_app(Settings(visual_providers=("fixture",), listing_enrichment=False)))
    body = post(c, category="tshirt").json()
    assert body["fixture"] is True
    assert all(r["fixture"] and r["url"] is None and "not a real listing" in r["title"] for r in body["results"])
    assert body["results"][1]["price"] is None


# Provider selection: nothing receives garment photos unless listed


def test_google_lens_is_never_enabled_by_default():
    providers, skipped = default_providers(Settings(scrappa_api_key="k", public_base_url="https://x.example"), CropHost())
    assert [p.name for p in providers] == [] and skipped[0]["name"] == "ebay"


def test_google_lens_needs_the_key_and_an_https_address_scrappa_can_reach():
    host = CropHost()
    _, skipped = default_providers(Settings(visual_providers=("google_lens",)), host)
    assert "SCRAPPA_API_KEY" in skipped[0]["message"]
    _, skipped = default_providers(Settings(visual_providers=("google_lens",), scrappa_api_key="k", public_base_url="http://10.0.0.2"), host)
    assert "https" in skipped[0]["message"]
    providers, _ = default_providers(Settings(visual_providers=("google_lens",), scrappa_api_key="k",
                                              public_base_url="https://fitmix.example"), host)
    assert [p.name for p in providers] == ["google_lens"]


def test_health_lists_ready_and_skipped_providers():
    health = TestClient(create_app(Settings(visual_providers=("fixture", "google_lens"), listing_enrichment=False))).get("/health").json()
    assert health["match_providers"] == ["fixture"] and health["match_skipped"][0]["name"] == "google_lens"


def test_fixture_file_has_every_category():
    import asyncio
    from app.main import FIXTURE_PATH
    provider = FixtureProvider(FIXTURE_PATH)
    for category in ("jacket", "tshirt", "pants", "shoes"):
        assert asyncio.run(provider.search(JPEG, Clues(category=category)))
