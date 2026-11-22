import asyncio
from decimal import Decimal

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import Settings, create_app
from app.outfit_match import Attributes, Listing, OutfitMatcher, ShopifyCatalog, product_codes
from app.visual_search import ProviderError


def crop():
    # Minimal JPEG signature. Endpoint validation checks the media signature and byte limit.
    return b"\xff\xd8\xff" + b"fixture"


def listing(name, amount, exact=False):
    return Listing(name, name, "Jackets", "", "", "Store", f"https://shop.example/products/{name}",
                   "https://shop.example/photo.jpg", Decimal(amount), exact)


class Analysis:
    count = 0

    async def describe(self, crop, media, category):
        self.count += 1
        assert media == "image/jpeg"
        return Attributes(color="black", cut="oversized", pattern="solid", brand="", details="zip")

    async def rank(self, attributes, candidates):
        assert attributes.color == "black"
        return {i: 92 - 10 * i for i, _ in enumerate(candidates)}


def test_match_miss_returns_close_and_budget_search_reuses_attributes():
    class Catalog:
        async def search(self, category, queries, codes):
            assert category == "jacket"
            if queries == ("jacket", "coat", "windbreaker"):
                return [listing("black-jacket", "90"), listing("black-windbreaker", "45")]
            return [listing("black-jacket", "90"), listing("long-coat", "110")]

    analysis = Analysis()
    client = TestClient(create_app(Settings(mock=True), outfit=OutfitMatcher(analysis, Catalog())))
    result = client.post("/v1/outfit-match", data={"category": "jacket"}, files={"crop": ("crop.jpg", crop())})
    assert result.status_code == 200
    data = result.json()
    closest = data["results"][0]
    assert (closest["match"], closest["visual_score"], closest["price"]) == (
        "similar", 92, {"value": "90", "currency": "CAD"})
    assert len(data["results"]) == 2
    expanded = client.post("/v1/outfit-match", data={
        "category": "jacket", "search_id": data["search_id"], "max_price": "70",
    })
    assert expanded.status_code == 200
    assert [p["id"] for p in expanded.json()["results"]] == ["black-windbreaker"]
    assert analysis.count == 1


def test_search_broadens_and_retailer_failure_does_not_block_another_garment():
    release = asyncio.Event()

    class Catalog:
        async def search(self, category, queries, codes):
            if category == "shoes":
                await release.wait()
                raise ProviderError("retailers_unavailable", "Retailer search is unavailable.")
            if "coat" in queries:
                return [listing("coat", "80")]
            return []

    async def run():
        app = create_app(Settings(mock=True), outfit=OutfitMatcher(Analysis(), Catalog()))
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            async def match(category):
                return await client.post("/v1/outfit-match", data={"category": category},
                                         files={"crop": ("crop.jpg", crop())})

            slow = asyncio.create_task(match("shoes"))
            fast = await asyncio.wait_for(match("jacket"), 2)
            assert fast.json()["results"][0]["id"] == "coat"
            assert not slow.done()
            release.set()
            failed = await slow
            assert failed.status_code == 502
            assert failed.json()["error"]["code"] == "retailers_unavailable"

    asyncio.run(run())


def test_storefront_validates_currency_stock_required_fields_and_exact_code():
    row = {"title": "Black jacket", "type": "Jacket", "available": True, "price": "40.00",
           "image": "https://cdn.shopify.com/jacket.jpg", "url": "/products/jacket?ref=search", "vendor": "Store"}

    def fake(request):
        if request.url.path == "/cart.js":
            return httpx.Response(200, json={"currency": "USD" if request.url.host == "ca.vessi.com" else "CAD"})
        if request.url.path == "/products/jacket.js":
            return httpx.Response(200, json={"variants": [{"sku": "ABC-12345", "id": 123,
                                                         "available": True, "price": 3900}]})
        return httpx.Response(200, json={"resources": {"results": {"products": [
            row, {**row, "available": False}, {**row, "url": "https://other.test/products/jacket"},
            {**row, "price": "NaN"}, {**row, "title": "Wide trousers", "type": "Pants"},
        ]}}})

    source = ShopifyCatalog(httpx.MockTransport(fake))
    found = asyncio.run(source.search("jacket", ("black jacket",), product_codes(["ABC-12345"])))
    assert len(found) == 2
    assert all(item.exact and item.amount == 39 and item.url.endswith("?variant=123") for item in found)
    assert all(item.result(88)["match"] == "exact" for item in found)


@pytest.mark.parametrize("params,status", [
    ({"category": "hat"}, 400),
    ({"category": "jacket", "search_id": "a" * 32, "max_price": "32"}, 410),
    ({"category": "jacket", "search_id": "a" * 32, "max_price": "-4"}, 400),
])
def test_invalid_or_expired_requests(params, status):
    client = TestClient(create_app(Settings(mock=True), outfit=OutfitMatcher(Analysis(), None)))
    assert client.post("/v1/outfit-match", data=params).status_code == status
