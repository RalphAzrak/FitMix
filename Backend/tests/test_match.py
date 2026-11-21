"""Garment matching. eBay is replaced with recorded-shape responses (httpx.MockTransport): no keys, nothing sent.

The item summaries below are test fixtures shaped like eBay's documented ItemSummary schema; they are not
real listings.
"""

import asyncio
import base64
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import Settings, create_app
from app.retail import EBAY_CATEGORY_IDS, EbayMatcher, FixtureMatcher, Listing, keep, rank

JPEG = b"\xff\xd8\xff\xe0" + b"0" * 64


def item(item_id, title, category_name, price=("59.99", "USD"), image=True):
    summary = {
        "itemId": item_id,
        "title": title,
        "categories": [{"categoryId": "1", "categoryName": category_name}],
        "itemWebUrl": f"https://www.ebay.com/itm/{item_id}",
        "seller": {"username": "seller_" + item_id},
    }
    if image:
        summary["image"] = {"imageUrl": f"https://i.ebayimg.com/images/{item_id}.jpg"}
    if price:
        summary["price"] = {"value": price[0], "currency": price[1]}
    return summary


class FakeEbay:
    """Answers the token and search_by_image calls the way eBay's API does, and records them."""

    def __init__(self, pages=None, search_status=200, token_status=200, expire_first=False):
        self.pages = pages or {}
        self.search_status, self.token_status, self.expire_first = search_status, token_status, expire_first
        self.searches, self.tokens = [], 0

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if request.url.path == "/identity/v1/oauth2/token":
            self.tokens += 1
            assert request.headers["authorization"].startswith("Basic ")
            assert b"grant_type=client_credentials" in request.content
            if self.token_status != 200:
                return httpx.Response(self.token_status, json={"error": "invalid_client"})
            return httpx.Response(200, json={"access_token": f"token-{self.tokens}", "expires_in": 7200})
        assert request.url.path == "/buy/browse/v1/item_summary/search_by_image"
        body = json.loads(request.content)
        self.searches.append({"category": request.url.params["category_ids"], "filter": request.url.params.get("filter"),
                              "marketplace": request.headers.get("x-ebay-c-marketplace-id"),
                              "auth": request.headers["authorization"], "image": body["image"]})
        if self.expire_first and len(self.searches) == 1:
            return httpx.Response(401, json={"errors": [{"errorId": 1001}]})
        if self.search_status != 200:
            return httpx.Response(self.search_status, json={"errors": [{"errorId": 12000}]})
        return httpx.Response(200, json={"itemSummaries": self.pages.get(request.url.params["category_ids"], [])})


def matcher(fake):
    return EbayMatcher("id", "secret", "EBAY_US", http=httpx.AsyncClient(transport=httpx.MockTransport(fake)))


def run(coro):
    return asyncio.run(coro)


def test_searches_only_the_selected_category_for_men_and_women_with_the_crop():
    men, women = EBAY_CATEGORY_IDS["shoes"]
    fake = FakeEbay(pages={men: [item("1", "Nike Air Max 90 White Sneakers", "Athletic Shoes")],
                           women: [item("2", "White Leather Sneakers", "Women's Shoes")]})
    results = run(matcher(fake).search("shoes", JPEG, "white", []))
    assert sorted(s["category"] for s in fake.searches) == sorted([men, women])
    assert all(s["image"] == base64.b64encode(JPEG).decode() for s in fake.searches)
    assert all(s["filter"] == "buyingOptions:{FIXED_PRICE}" and s["marketplace"] == "EBAY_US" for s in fake.searches)
    assert {r.id for r in results} == {"1", "2"}


def test_listing_fields_come_straight_from_the_listing():
    fake = FakeEbay(pages={EBAY_CATEGORY_IDS["jacket"][0]: [item("9", "Olive Bomber Jacket", "Coats & Jackets", price=("148.00", "CAD"))]})
    [result] = run(matcher(fake).search("jacket", JPEG, None, []))
    assert result == Listing(id="9", title="Olive Bomber Jacket", retailer="eBay", seller="seller_9",
                             image_url="https://i.ebayimg.com/images/9.jpg", url="https://www.ebay.com/itm/9",
                             price={"value": "148.00", "currency": "CAD"}, match="similar")


def test_missing_price_stays_missing():
    fake = FakeEbay(pages={EBAY_CATEGORY_IDS["pants"][0]: [item("3", "Straight Jeans", "Jeans", price=None)]})
    [result] = run(matcher(fake).search("pants", JPEG, None, []))
    assert result.price is None


def test_drops_listings_outside_the_selected_category():
    men, _ = EBAY_CATEGORY_IDS["shoes"]
    fake = FakeEbay(pages={men: [item("1", "Shoe Laces", "Shoe Accessories"), item("2", "Jacket", "Coats & Jackets")]})
    assert run(matcher(fake).search("shoes", JPEG, None, [])) == []


def test_womens_tops_count_as_tshirt_only_when_the_title_says_so():
    assert keep("tshirt", {"title": "Graphic Tee", "categories": [{"categoryName": "Tops"}]})
    assert not keep("tshirt", {"title": "Silk Blouse", "categories": [{"categoryName": "Tops"}]})
    assert keep("tshirt", {"title": "Crew Neck", "categories": [{"categoryName": "T-Shirts"}]})


def test_colour_and_brand_read_on_the_garment_move_listings_up():
    a = Listing("a", "Black Hoodie Jacket", "eBay", None, None, None, None)
    b = Listing("b", "Carhartt Navy Work Jacket", "eBay", None, None, None, None)
    assert [x.id for x in rank([(0, a), (1, b)], None, [])] == ["a", "b"]
    assert [x.id for x in rank([(0, a), (1, b)], "navy", ["carhartt"])] == ["b", "a"]


def test_refreshes_an_expired_token_once():
    fake = FakeEbay(pages={}, expire_first=True)
    run(matcher(fake).search("pants", JPEG, None, []))
    assert fake.tokens == 2


@pytest.mark.parametrize("status,code", [(429, "provider_busy"), (500, "provider_error"), (403, "provider_auth")])
def test_provider_failures_become_app_errors(status, code):
    fake = FakeEbay(search_status=status)
    c = TestClient(create_app(Settings(), matcher=matcher(fake)))
    response = post(c)
    assert response.status_code in (502, 503) and response.json()["error"]["code"] == code


def test_rejected_keys_are_reported_as_such():
    fake = FakeEbay(token_status=401)
    c = TestClient(create_app(Settings(), matcher=matcher(fake)))
    assert post(c).json()["error"]["code"] == "provider_auth"


# Endpoint


class Recorder:
    name, fixture = "recorder", False

    def __init__(self, results):
        self.results, self.calls = results, []

    async def search(self, category, image, color, brand_hints):
        self.calls.append((category, image, color, brand_hints))
        return self.results


def post(c, category="shoes", crop=JPEG, headers=None, **fields):
    return c.post("/v1/garment-match", files={"crop": ("g.jpg", crop, "image/jpeg")},
                  data={"category": category, **fields}, headers=headers or {})


def test_endpoint_passes_category_crop_and_attributes():
    recorder = Recorder([Listing("1", "White Sneakers", "eBay", "s", "https://i/1.jpg", "https://e/1", {"value": "59.99", "currency": "USD"})])
    c = TestClient(create_app(Settings(), matcher=recorder))
    response = post(c, color="White", brand_hints="nike, air ,x")
    assert response.status_code == 200
    assert response.json() == {"status": "matched", "category": "shoes", "provider": "recorder", "fixture": False, "results": [
        {"id": "1", "title": "White Sneakers", "retailer": "eBay", "seller": "s", "image_url": "https://i/1.jpg",
         "url": "https://e/1", "price": {"value": "59.99", "currency": "USD"}, "match": "similar"}]}
    assert recorder.calls == [("shoes", JPEG, "white", ["nike", "air", "x"])]


def test_endpoint_reports_no_match():
    c = TestClient(create_app(Settings(), matcher=Recorder([])))
    body = post(c, category="pants").json()
    assert body["status"] == "no_match" and body["results"] == []


def test_endpoint_without_keys_says_it_is_not_configured():
    response = post(TestClient(create_app(Settings())))
    assert response.status_code == 503 and response.json()["error"]["code"] == "not_configured"


def test_endpoint_rejects_other_categories_and_non_images():
    c = TestClient(create_app(Settings(), matcher=Recorder([])))
    assert post(c, category="hat").json()["error"]["code"] == "invalid_category"
    assert post(c, crop=b"not an image").json()["error"]["code"] == "invalid_image"


def test_endpoint_requires_the_app_token_when_set():
    c = TestClient(create_app(Settings(app_token="s3cret"), matcher=Recorder([])))
    assert post(c).status_code == 401
    assert post(c, headers={"Authorization": "Bearer s3cret"}).status_code == 200


def test_fixture_provider_is_labeled_as_a_fixture():
    c = TestClient(create_app(Settings(match_provider="fixture")))
    body = post(c, category="tshirt").json()
    assert body["fixture"] is True and body["provider"] == "fixture"
    assert "not a real listing" in body["results"][0]["title"] and body["results"][0]["url"] is None


def test_health_reports_whether_search_is_ready():
    assert TestClient(create_app(Settings())).get("/health").json()["match_ready"] is False
    assert TestClient(create_app(Settings(match_provider="fixture"))).get("/health").json()["match_provider"] == "fixture"


def test_fixture_matcher_does_not_need_network():
    assert run(FixtureMatcher().search("shoes", JPEG, None, []))[0].retailer == "FitMix test fixture"
