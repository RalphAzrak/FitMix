import asyncio
import base64
import io
import json
from types import SimpleNamespace

import httpx
import openai
from fastapi.testclient import TestClient
from PIL import Image

from app.main import Settings, create_app
from app.outfit_match import DiscoveryPage, Hit, OpenAIVisualSearch, OutfitMatcher, TrendtrackImageSearch
from app.retailer_product import PublicRetailerHTTP, RetailerVerifier, verified_offers

SEARCH_ID = "9b1a67f9-9477-48e5-8a6c-11b70245e1d9"
SHOP_ID = "3f8aa146-6f96-46e8-9781-64db5166f9a8"


def jpeg(color):
    buffer = io.BytesIO()
    Image.new("RGB", (32, 32), color).save(buffer, format="JPEG")
    return buffer.getvalue()


CROP = jpeg((15, 15, 15))


def product_page(name, *, currency="CAD", amount="80", code="OTHER-123", availability="InStock"):
    record = {
        "@type": "Product", "name": name, "sku": code, "image": "/product.jpg",
        "offers": {"@type": "Offer", "price": amount, "priceCurrency": currency,
                   "availability": f"https://schema.org/{availability}"},
    }
    return f'<script type="application/ld+json">{json.dumps(record)}</script>'.encode()


class RetailerPages:
    async def get(self, url, mime, limit):
        host = httpx.URL(url).host
        if mime == "text/html":
            pages = {
                "frankandoak.com": product_page("Black boxy jacket, identical wording"),
                "independent.example": product_page("The Elm"),
                "alternate.example": product_page("The Branch", amount="42", code="ELM-5473"),
                "soldout.example": product_page("Unavailable jacket", availability="OutOfStock"),
            }
            return url, pages[host]
        return url, jpeg((220, 200, 150) if host == "frankandoak.com" else (18, 18, 18))


def trendtrack(request):
    if request.method == "GET":
        assert request.url.path == f"/v1/products/{SHOP_ID}:42"
        return httpx.Response(200, json={"data": {"url": "https://independent.example/garment/elm"}})

    assert request.url.path == "/v1/products/image-search"
    if request.headers["content-type"].startswith("multipart/form-data"):
        assert CROP in request.content and b'name="image"; filename="garment.jpg"' in request.content
        assert b"Black boxy jacket" not in request.content
        rows = [
            {"product": {"url": "https://frankandoak.com/products/example"}, "shop": {"domain": "frankandoak.com"}},
            {"product": {"shopifyId": 42}, "shop": {"id": SHOP_ID, "domain": "independent.example", "name": "Independent"}},
            {"product": {"url": "https://soldout.example/products/example"}, "shop": {"domain": "soldout.example"}},
        ]
    else:
        assert json.loads(request.content)["searchId"] == SEARCH_ID
        assert json.loads(request.content)["offset"] == 12
        rows = [{"product": {"url": "https://alternate.example/products/branch"}, "shop": {"domain": "alternate.example"}}]
    return httpx.Response(200, json={"data": rows, "meta": {"searchId": SEARCH_ID}, "pagination": {"total": 24}})


def model(request):
    payload = json.loads(request.content)
    assert payload["store"] is False
    if "tools" in payload:
        assert payload["tool_choice"]["name"] == "discover_products_by_image"
        assert payload["tools"][0]["parameters"]["properties"] == {}
        item = {"id": "fc_test", "type": "function_call", "call_id": "call_test",
                "name": "discover_products_by_image", "arguments": "{ }", "status": "completed"}
    else:
        content = payload["input"][0]["content"]
        assert base64.b64decode(content[1]["image_url"].split(",")[1]) == CROP
        assert "The Elm" not in request.content.decode() and "identical wording" not in request.content.decode()
        photos = [base64.b64decode(photo["image_url"].split(",")[1]) for photo in content[3::2]]
        ratings = []
        for index, photo in enumerate(photos):
            red = Image.open(io.BytesIO(photo)).getpixel((16, 16))[0]
            ratings.append({"index": index, "same_category": True, "color": 35 if red < 30 else 12,
                            "cut": 29, "pattern": 18, "details": 10})
        item = {"id": "msg_test", "type": "message", "role": "assistant", "status": "completed",
                "content": [{"type": "output_text", "text": json.dumps({"ratings": ratings}), "annotations": []}]}
    return httpx.Response(200, json={"id": "resp_test", "object": "response",
                                     "created_at": 0, "status": "completed", "output": [item]})


def test_actual_image_tool_contract_photo_ranking_and_budget_pagination():
    discovery_http = httpx.AsyncClient(base_url="https://api.trendtrack.io", transport=httpx.MockTransport(trendtrack))
    model_http = httpx.AsyncClient(transport=httpx.MockTransport(model))
    ai = OpenAIVisualSearch("", "gpt-4.1-mini", openai.AsyncOpenAI(api_key="fixture", http_client=model_http))
    matcher = OutfitMatcher(ai, TrendtrackImageSearch("fixture", discovery_http), RetailerVerifier(RetailerPages()))
    with TestClient(create_app(Settings(mock=True), outfit=matcher)) as client:
        result = client.post("/v1/outfit-match", data={"category": "jacket", "text": "ELM-5473"},
                             files={"crop": ("garment.jpg", CROP, "image/jpeg")})
        assert result.status_code == 200, result.text
        data = result.json()
        listings = data["results"]
        assert [(p["retailer"], p["match"], p["visual_score"]) for p in listings] == [
            ("Independent", "similar", 92), ("frankandoak.com", "similar", 69),
        ]
        expanded = client.post("/v1/outfit-match", data={
            "category": "jacket", "search_id": data["search_id"], "max_price": "60",
        })
        assert expanded.status_code == 200, expanded.text
        assert [(p["title"], p["match"], p["price"]) for p in expanded.json()["results"]] == [
            ("The Branch", "exact", {"value": "42", "currency": "CAD"}),
        ]


def test_exact_identity_sorts_ahead_of_a_higher_visual_score_and_keeps_foreign_currency():
    class Search:
        async def page(self, *_):
            return DiscoveryPage([
                Hit("https://frankandoak.com/products/example", "frankandoak.com", ""),
                Hit("https://independent.example/garment/elm", "independent.example", ""),
            ], None, None)

    class Rank:
        async def discover(self, category, tool):
            return await tool()

        async def rank(self, category, crop, media, photos):
            return [SimpleNamespace(index=0, same_category=True, score=67),
                    SimpleNamespace(index=1, same_category=True, score=98)]

    class USDStore(RetailerPages):
        async def get(self, url, mime, limit):
            if mime == "text/html" and "frankandoak" in url:
                return url, product_page("Exact product", code="ELM-5473", currency="USD")
            return await super().get(url, mime, limit)

    matcher = OutfitMatcher(Rank(), Search(), RetailerVerifier(USDStore()))
    _, results = asyncio.run(matcher.match("jacket", CROP, "image/jpeg", ["ELM-5473"], None, None))
    assert [(p["match"], p["visual_score"], p["price"]["currency"]) for p in results] == [
        ("exact", 67, "USD"), ("similar", 98, "CAD")
    ]


def test_out_of_stock_unpriced_and_wrong_product_offers_are_rejected():
    url = "https://store.example/products/looks"
    assert not verified_offers(product_page("Sold", availability="OutOfStock").decode(), url, "", set())
    assert not verified_offers(product_page("Bad price", amount="NaN").decode(), url, "", set())
    wrong_page = product_page("A different product").decode().replace('"@type": "Product"', '"@type": "Product", "url": "/products/other"')
    assert not verified_offers(wrong_page, url, "", set())


def test_missing_configuration_returns_unavailable_without_alternate_discovery():
    with TestClient(create_app(Settings(mock=True))) as client:
        assert client.get("/health").json()["outfit_match"]["ready"] is False
        reply = client.post("/v1/outfit-match", data={"category": "jacket"}, files={"crop": ("garment.jpg", CROP)})
        assert reply.status_code == 503
        assert "TRENDTRACK_API_KEY" in reply.json()["error"]["message"]


def test_verified_retailer_fetch_pins_dns_and_rechecks_redirects():
    def handle(request):
        assert request.url.host == "1.1.1.1"
        assert request.headers["host"] == "store.example"
        assert request.extensions["sni_hostname"] == "store.example"
        return httpx.Response(302, headers={"location": "https://internal.example/data"})

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as http:
            service = PublicRetailerHTTP(http, resolve=lambda host: ["1.1.1.1"] if host == "store.example" else [])
            assert await service.get("https://store.example/product", "text/html", 1_000) is None

    asyncio.run(run())


def test_unverified_or_wrong_category_pages_result_in_an_honest_miss():
    class Search:
        async def page(self, crop, media, search_id=None, offset=0):
            if offset == 0:
                return DiscoveryPage([Hit("https://soldout.example/products/jacket", "soldout.example", "")],
                                     SEARCH_ID, 12)
            assert crop == b"" and search_id == SEARCH_ID and offset == 12
            return DiscoveryPage([Hit("https://independent.example/garment/elm", "independent.example", "")],
                                 SEARCH_ID, None)

    class Rank:
        async def discover(self, category, tool):
            return await tool()

        async def rank(self, category, crop, media, photos):
            return [SimpleNamespace(index=0, same_category=False, score=99)]

    matcher = OutfitMatcher(Rank(), Search(), RetailerVerifier(RetailerPages()))
    with TestClient(create_app(Settings(mock=True), outfit=matcher)) as client:
        response = client.post("/v1/outfit-match", data={"category": "jacket"},
                               files={"crop": ("garment.jpg", CROP, "image/jpeg")})
        assert response.status_code == 200
        assert response.json()["status"] == "no_match"
        assert response.json()["results"] == []
