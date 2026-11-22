import asyncio
import base64
import io
import json
from decimal import Decimal
from types import SimpleNamespace

import httpx
import openai
from fastapi.testclient import TestClient
from PIL import Image

from app.main import Settings, create_app
from app.outfit_match import (DiscoveryPage, Hit, OpenAIVisualSearch, OpenAIWebSearch, OutfitMatcher, Rating,
                              VisibleGarment, WebProduct, web_hits)
from app.retailer_product import (PublicRetailerHTTP, RetailerVerifier, listing_key, page_listing, verified_offers)

SEARCH_ID = "9b1a67f9-9477-48e5-8a6c-11b70245e1d9"


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
                "plain.example": product_page("Black boxy jacket, identical wording"),
                "independent.example": product_page("The Elm"),
                "alternate.example": product_page("The Branch", amount="42", code="ELM-5473"),
                "soldout.example": product_page("Unavailable jacket", availability="OutOfStock"),
            }
            return url, pages[host]
        return url, jpeg((220, 200, 150) if host == "plain.example" else (18, 18, 18))


def reply(data, sources=None):
    item = {"id": "msg_test", "type": "message", "role": "assistant", "status": "completed",
            "content": [{"type": "output_text", "text": json.dumps(data), "annotations": []}]}
    tool = [{"id": "ws_test", "type": "web_search_call", "status": "completed",
             "action": {"type": "search", "query": "garment", "sources": [{"type": "url", "url": url} for url in sources]}}] if sources else []
    return httpx.Response(200, json={"id": "resp_test", "object": "response",
                                     "created_at": 0, "status": "completed", "output": [*tool, item]})


def model(request):
    payload = json.loads(request.content)
    assert payload["store"] is False
    content = payload["input"][0]["content"]
    assert base64.b64decode(content[1]["image_url"].split(",")[1]) == CROP
    if "tools" in payload:
        # The web search gets the garment photo itself, and no list of stores to stay within.
        assert [tool["type"] for tool in payload["tools"]] == ["web_search"]
        assert payload["tool_choice"] == "required"
        assert payload["include"] == ["web_search_call.action.sources"]
        assert "allowed_domains" not in request.content.decode()
        return reply({"products": [
            {"url": "https://plain.example/products/example", "store": None},
            {"url": "https://independent.example/garment/elm", "store": "Independent"},
            {"url": "https://soldout.example/products/example", "store": "Sold Out Shop"},
            {"url": "http://insecure.example/products/example", "store": "Insecure"},
            {"url": "https://invented.example/products/example", "store": "Unsourced"},
            {"url": "https://plain.example/products/example?colourId=99", "store": "Unsourced colorway"},
        ]}, sources=["https://plain.example/products/example?utm_source=openai",
                      "https://independent.example/garment/elm",
                      "https://soldout.example/products/example"])
    assert "The Elm" not in request.content.decode() and "identical wording" not in request.content.decode()
    photos = [base64.b64decode(photo["image_url"].split(",")[1]) for photo in payload["input"][1]["content"][2::2]]
    ratings = []
    for index, photo in enumerate(photos):
        close = Image.open(io.BytesIO(photo)).getpixel((16, 16))[0] < 30
        ratings.append({"index": index, "same_category": True, "color": 15 if close else 3,
                        "cut": 24, "pattern": 17, "details": 36 if close else 25,
                        "detail_evidence": "plain", "product_plain": True, "product_text": None})
    return reply({"ratings": ratings})


def test_web_search_from_the_photo_ranks_pages_by_their_photos():
    model_http = httpx.AsyncClient(transport=httpx.MockTransport(model))
    ai = OpenAIVisualSearch("", "gpt-4.1-mini", openai.AsyncOpenAI(api_key="fixture", http_client=model_http))
    matcher = OutfitMatcher(ai, OpenAIWebSearch(ai), RetailerVerifier(RetailerPages()))
    with TestClient(create_app(Settings(mock=True), outfit=matcher)) as client:
        result = client.post("/v1/outfit-match", data={"category": "jacket", "text": "ELM-5473", "mode": "photo"},
                             files={"crop": ("garment.jpg", CROP, "image/jpeg")})
        assert result.status_code == 200, result.text
        data = result.json()
        assert [(p["retailer"], p["match"], p["visual_score"], p["provider"]) for p in data["results"]] == [
            ("Independent", "similar", 92, "web"), ("plain.example", "similar", 69, "web"),
        ]
        # Each result carries the product photo that was compared, so the app can always show it.
        shades = [Image.open(io.BytesIO(base64.b64decode(p["thumbnail"]))).getpixel((16, 16))[0] for p in data["results"]]
        assert shades[0] < 30 and shades[1] > 200
        # A web search has no second page: a budget follow-up answers with nothing more.
        expanded = client.post("/v1/outfit-match", data={
            "category": "jacket", "search_id": data["search_id"], "max_price": "60",
        })
        assert expanded.status_code == 200, expanded.text
        assert expanded.json()["status"] == "no_match" and expanded.json()["results"] == []


def test_web_hits_keep_public_https_pages_and_a_few_per_store():
    found = [WebProduct(url=f"https://shop.example/products/{i}", store="Shop  Example") for i in range(4)]
    found += [WebProduct(url="http://shop.example/p", store=None), WebProduct(url="not a url", store=None),
              WebProduct(url="https://www.other.example/p#reviews", store=None)]
    assert [(hit.url, hit.name) for hit in web_hits(found)] == [
        ("https://shop.example/products/0", "Shop Example"), ("https://shop.example/products/1", "Shop Example"),
        ("https://www.other.example/p", "other.example"),
    ]


def test_matcher_reads_at_most_a_few_pages_per_store():
    read = []

    class Search:
        async def page(self, *_, department="any"):
            return DiscoveryPage([Hit(f"https://independent.example/garment/{i}", "www.independent.example", "")
                                  for i in range(5)], None, None)

    class Pages(RetailerPages):
        async def get(self, url, mime, limit):
            if mime == "text/html":
                read.append(url)
            return await super().get(url, mime, limit)

    class Rank:
        async def rank(self, category, crop, media, photos, description, attributes):
            return [Rating(index=index, same_category=True, color=15, cut=25, pattern=20, details=38,
                           detail_evidence="match", product_plain=None, product_text=None)
                    for index in range(len(photos))]

    matcher = OutfitMatcher(Rank(), Search(), RetailerVerifier(Pages()), per_store=2)
    _, results, _ = asyncio.run(matcher.match("jacket", CROP, "image/jpeg", [], None, None, mode="photo"))
    assert len(read) == 2 and len(results) == 1  # Same retailer and product photo.


def test_search_candidate_needs_retailer_verification_even_when_the_model_provides_product_data():
    read = []
    requested_url = "https://independent.example/garment/elm"

    class Search:
        async def matches(self, category, crop, media, description, brand, department, *, query=None, tried_stores=()):
            assert (category, crop, description.color) == ("jacket", CROP, "black")
            if query:
                assert tried_stores == ("closed.example", "independent.example")
            return web_hits([
                WebProduct.model_validate({
                    "url": "https://closed.example/p/boxy-jacket-12345", "store": "Closed Shop",
                    "title": "Boxy jacket", "price": "CA$120.00", "image_url": "https://cdn.closed.example/boxy.jpg",
                }),
                WebProduct.model_validate({"url": requested_url, "store": "Independent", "price": "CA$1.00"}),
            ])

    class Pages(RetailerPages):
        async def get(self, url, mime, limit):
            read.append((mime, url))
            if httpx.URL(url).host == "closed.example":
                return None
            return await super().get(url, mime, limit)

    class Analysis:
        async def describe(self, category, crop, media, words):
            return VisibleGarment(color="black", color_family="black", neckline=None, sleeves=None, fit=None,
                                  pattern=None, graphic=None, readable_text=None, brand=None, obscured=False, plain=True)

        async def rank(self, category, crop, media, photos, description, attributes):
            return [Rating(index=0, same_category=True, color=15, cut=25, pattern=20, details=38,
                           detail_evidence="plain", product_plain=True, product_text=None)]

    matcher = OutfitMatcher(Analysis(), Search(), RetailerVerifier(Pages()))
    _, results, _ = asyncio.run(matcher.match("jacket", CROP, "image/jpeg", [], None, None))
    assert [(row["url"], row["price"]) for row in results] == [(requested_url, {"value": "80", "currency": "CAD"})]
    assert results[0]["thumbnail"]
    assert ("text/html", requested_url) in read
    assert ("text/html", "https://closed.example/p/boxy-jacket-12345") in read
    assert all("cdn.closed.example" not in url for _, url in read)
    assert len(read) == len(set(read))


def test_a_page_without_a_structured_offer_is_listed_from_its_own_title_and_photo():
    url = "https://store.example/item/42"
    page = ('<meta property="og:type" content="product.item">'
            '<meta content="Black lightning tee &amp; more" property="og:title">'
            "<meta property='og:image' content='/photos/tee.jpg'>")
    listing = page_listing(page, url, "Store")
    assert (listing.title, listing.image_url, listing.amount, listing.url, listing.retailer) == (
        "Black lightning tee & more", "https://store.example/photos/tee.jpg", None, url, "Store")
    assert listing.result(70)["price"] is None
    priced = page_listing(page + '<meta property="product:price:amount" content="19.99">'
                                 '<meta property="product:price:currency" content="usd">', url, "")
    assert (str(priced.amount), priced.currency, priced.retailer) == ("19.99", "USD", "store.example")
    # A product record that doesn't say whether it is in stock is still a listing, with its stated price.
    unknown_stock = product_page("Plain tee").decode().replace('"availability": "https://schema.org/InStock"', '"note": ""')
    assert not verified_offers(unknown_stock, url, "", set())
    listed = page_listing(unknown_stock, url, "")
    assert (listed.title, listed.image_url, str(listed.amount), listed.currency) == (
        "Plain tee", "https://store.example/product.jpg", "80", "CAD")
    # Not about one product, sold out, or without a photo: nothing to show.
    assert page_listing('<meta property="og:type" content="website"><meta property="og:title" content="Tees">'
                        '<meta property="og:image" content="/logo.png">', url, "") is None
    assert page_listing(product_page("Sold", availability="OutOfStock").decode(), url, "") is None
    assert page_listing('<meta property="og:type" content="product"><meta property="og:title" content="Tee">', url, "") is None


def test_gap_colorway_url_and_breadcrumb_are_verified_on_the_retailer_page():
    page = "https://gap.example/browse/product.do?pid=440775023"
    black = f"{page}0004"
    blue = "https://gap.example/browse/product.do?pid=4407750240004"
    assert listing_key(black) == listing_key(page)
    assert listing_key(black) != listing_key(blue)
    product = {
        "@type": "Product", "name": "Classic T-Shirt", "color": "Black",
        "offers": [
            {"url": url, "image": image, "price": 19, "priceCurrency": "CAD", "availability": "InStock"}
            for url, image in ((black, "/black.jpg"), (blue, "/blue.jpg"))
        ],
    }
    breadcrumb = {"@type": "BreadcrumbList", "itemListElement": [{"item": {"name": "Men"}}]}
    html = f'<script type="application/ld+json">{json.dumps([product, breadcrumb])}</script>'
    offers = verified_offers(html, page, "Gap", set())
    assert [(offer.url, offer.image_url, offer.department) for offer in offers] == [
        (black, "https://gap.example/black.jpg", "men"),
    ]


def test_decathlon_group_uses_the_linked_variant_even_if_the_slug_differs():
    root = "https://www.decathlon.ca/en/p"
    requested = f"{root}/mens-shorts-black/300824/c378c344c344m8405360"
    black = f"{root}/men-s-shorts-black/300824/c378c344c344m8405360"
    blue = f"{root}/men-s-shorts-blue/300824/c195m8873601"
    assert listing_key(requested) == listing_key(black) != listing_key(blue)
    variants = [
        {"@type": "Product", "name": "Men's Fitness Shorts", "image": f"/{color}.jpg", "color": color,
         "offers": {"url": link, "availability": "InStock", "priceSpecification": {"price": cost,
                                                                                   "priceCurrency": "CAD"}}}
        for color, link, cost in (("Black", black, 17), ("Blue", blue, 12))
    ]
    group = {"@type": "ProductGroup", "name": "Men's Fitness Shorts", "hasVariant": variants}
    html = f'<script type="application/ld+json">{json.dumps(group)}</script>'
    offers = verified_offers(html, requested, "Decathlon", set())
    assert [(offer.url, offer.image_url, offer.department, offer.amount, offer.currency) for offer in offers] == [
        (black, "https://www.decathlon.ca/Black.jpg", "men", Decimal("17"), "CAD"),
    ]


def test_visual_score_ranks_ahead_of_exact_identity_and_keeps_foreign_currency():
    class Search:
        async def page(self, *_, department="any"):
            return DiscoveryPage([
                Hit("https://plain.example/products/example", "plain.example", ""),
                Hit("https://independent.example/garment/elm", "independent.example", ""),
                Hit("https://alternate.example/products/branch", "alternate.example", ""),
            ], None, None)

    class Rank:
        async def rank(self, category, crop, media, photos, description, attributes):
            return [
                Rating(index=0, same_category=True, color=12, cut=19, pattern=14, details=22,
                       detail_evidence="unclear", product_plain=None, product_text=None),
                Rating(index=1, same_category=True, color=15, cut=25, pattern=20, details=38,
                       detail_evidence="match", product_plain=None, product_text=None),
                Rating(index=2, same_category=True, color=10, cut=20, pattern=14, details=20,
                       detail_evidence="unclear", product_plain=None, product_text=None),
            ]

    class USDStore(RetailerPages):
        async def get(self, url, mime, limit):
            if mime == "text/html" and "plain.example" in url:
                return url, product_page("Exact product", code="ELM-5473", currency="USD")
            return await super().get(url, mime, limit)

    matcher = OutfitMatcher(Rank(), Search(), RetailerVerifier(USDStore()))
    _, results, _ = asyncio.run(matcher.match("jacket", CROP, "image/jpeg", ["ELM-5473"], None, None, mode="photo"))
    assert [(p["match"], p["visual_score"], p["price"]["currency"]) for p in results] == [
        ("similar", 98, "CAD"), ("exact", 67, "USD")
    ]
    assert [p["best_match"] for p in results] == [True, False]


def test_out_of_stock_unpriced_and_wrong_product_offers_are_rejected():
    url = "https://store.example/products/looks"
    assert not verified_offers(product_page("Sold", availability="OutOfStock").decode(), url, "", set())
    assert not verified_offers(product_page("Bad price", amount="NaN").decode(), url, "", set())
    wrong_page = product_page("A different product").decode().replace('"@type": "Product"', '"@type": "Product", "url": "/products/other"')
    assert not verified_offers(wrong_page, url, "", set())


def test_only_the_openai_key_is_needed_and_its_absence_is_reported():
    with TestClient(create_app(Settings(mock=True))) as client:
        assert client.get("/health").json()["outfit_match"] == {
            "ready": False, "currency": "CAD", "discovery": "openai_web_search"}
        answer = client.post("/v1/outfit-match", data={"category": "jacket"}, files={"crop": ("garment.jpg", CROP)})
        assert answer.status_code == 503
        assert answer.json()["error"]["message"] == "Set OPENAI_API_KEY on the FitMix backend."
    with TestClient(create_app(Settings(mock=True, api_key="fixture"))) as client:
        assert client.get("/health").json()["outfit_match"]["ready"] is True
        for removed in ("/v1/lens-search", "/v1/garment-match"):
            assert client.post(removed).status_code == 404


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
        async def page(self, crop, media, search_id=None, offset=0, *, department="any"):
            if offset == 0:
                return DiscoveryPage([Hit("https://soldout.example/products/jacket", "soldout.example", "")],
                                     SEARCH_ID, 12)
            assert crop == b"" and search_id == SEARCH_ID and offset == 12
            return DiscoveryPage([Hit("https://independent.example/garment/elm", "independent.example", "")],
                                 SEARCH_ID, None)

    class Rank:
        async def rank(self, category, crop, media, photos, description, attributes):
            return [SimpleNamespace(index=0, same_category=False, score=99)]

    matcher = OutfitMatcher(Rank(), Search(), RetailerVerifier(RetailerPages()))
    with TestClient(create_app(Settings(mock=True), outfit=matcher)) as client:
        response = client.post("/v1/outfit-match", data={"category": "jacket", "mode": "photo"},
                               files={"crop": ("garment.jpg", CROP, "image/jpeg")})
        assert response.status_code == 200
        assert response.json()["status"] == "no_match"
        assert response.json()["results"] == []
