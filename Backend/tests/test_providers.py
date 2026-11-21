"""Scrappa (Google Lens) adapter, the crop host, and listing-page enrichment. Network is replaced by
httpx.MockTransport: no keys, nothing sent."""

import asyncio
import json
import time
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from fastapi.testclient import TestClient

from app.listing import ListingEnricher, parse_listing
from app.main import Settings, create_app
from app.providers import CropHost, ScrappaLensProvider, parse_price_text, unwrap_link
from app.visual_search import Candidate, Clues, ProviderError

JPEG = b"\xff\xd8\xff\xe0" + b"1" * 64


# Scrappa


class FakeScrappa:
    def __init__(self, host: CropHost, status=200, body=None):
        self.host, self.status, self.body, self.requests, self.crop_seen = host, status, body, [], None

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        # Scrappa fetches the image from the URL it was given, while the request is in flight.
        token = urlparse(request.url.params["url"]).path.split("/")[-1].removesuffix(".jpg")
        self.crop_seen = self.host.fetch(token)
        return httpx.Response(self.status, json=self.body or {"visual_matches": [], "exact_matches": [], "related_content": []})


def lens(fake, host):
    return ScrappaLensProvider("secret-key", "https://fitmix.example", host, http=httpx.AsyncClient(transport=httpx.MockTransport(fake)))


def test_scrappa_gets_only_a_short_lived_url_to_the_crop_and_the_key_in_its_header():
    host = CropHost()
    fake = FakeScrappa(host)
    asyncio.run(lens(fake, host).search(JPEG, Clues("shoes")))
    [request] = fake.requests
    assert request.method == "GET" and str(request.url).startswith("https://scrappa.co/api/google/lens")
    assert request.headers["X-API-KEY"] == "secret-key" and request.url.params["type"] == "all"
    url = request.url.params["url"]
    assert url.startswith("https://fitmix.example/v1/crops/") and len(url.split("/")[-1]) > 40
    assert set(parse_qs(request.url.query.decode())) == {"url", "type"}  # nothing about the user or the clues
    assert fake.crop_seen == JPEG
    assert host.fetch(url.split("/")[-1].removesuffix(".jpg")) is None  # revoked once the search returns


def test_scrappa_fields_map_onto_candidates():
    host = CropHost()
    body = {"visual_matches": [{"position": 2, "source": "Foot Locker", "title": "Converse Chuck Taylor All Star Hi",
                                "link": "https://www.google.com/goto?url=https://www.footlocker.com/product/x/M9160.html",
                                "thumbnail": "https://t.example/1.jpg", "price": "US$65.00"},
                               {"position": 3, "source": "Pinterest", "title": None, "link": "https://p.example", "price": None}],
            "exact_matches": [{"position": 1, "source": "Nike", "title": "Converse Chuck Taylor All Star High Top",
                               "link": "https://www.nike.com/t/x/M9160-000", "thumbnail": None, "price": None}],
            "related_content": []}
    found = asyncio.run(lens(FakeScrappa(host, body=body), host).search(JPEG, Clues("shoes")))
    assert [(c.retailer, c.rank, c.same_image) for c in found] == [("Nike", 0, True), ("Foot Locker", 1, False)]
    assert found[1].url == "https://www.footlocker.com/product/x/M9160.html"
    assert found[1].price == {"value": "65.00", "currency": "USD"} and found[0].price is None


@pytest.mark.parametrize("status,body,code,retryable", [
    (401, {}, "provider_auth", False),
    (429, {"error_code": "rate_limited", "retryable": True}, "rate_limited", True),
    (502, {"error_code": "upstream_failed", "retryable": True}, "upstream_failed", True),
    (400, {"error_code": "invalid_url", "retryable": False}, "invalid_url", False),
])
def test_scrappa_errors_keep_its_retryable_flag(status, body, code, retryable):
    host = CropHost()
    with pytest.raises(ProviderError) as error:
        asyncio.run(lens(FakeScrappa(host, status=status, body=body), host).search(JPEG, Clues("shoes")))
    assert error.value.code == code and error.value.retryable is retryable


@pytest.mark.parametrize("text,expected", [
    ("US$65.00", {"value": "65.00", "currency": "USD"}), ("CA$89.99", {"value": "89.99", "currency": "CAD"}),
    ("€59,95", {"value": "59.95", "currency": "EUR"}), ("£1,299.00", {"value": "1299.00", "currency": "GBP"}),
    ("$65.00", None), ("65", None), (None, None), ("Free", None),
])
def test_price_text_only_counts_with_an_unambiguous_currency(text, expected):
    assert parse_price_text(text) == expected


def test_unwrap_link():
    assert unwrap_link("https://www.google.com/goto?url=https%3A%2F%2Fshop.example%2Fp") == "https://shop.example/p"
    assert unwrap_link("https://shop.example/p") == "https://shop.example/p"


# Crop host


def test_crop_host_tokens_expire_and_allow_few_fetches():
    host = CropHost(lifetime=0.2, max_fetches=2)
    token = host.publish(JPEG)
    assert host.fetch(token) == JPEG and host.fetch(token) == JPEG and host.fetch(token) is None
    late = host.publish(JPEG)
    time.sleep(0.25)
    assert host.fetch(late) is None


def test_crop_endpoint_serves_only_published_crops():
    host = CropHost()
    c = TestClient(create_app(Settings(listing_enrichment=False), providers=[], crop_host=host))
    token = host.publish(JPEG)
    response = c.get(f"/v1/crops/{token}.jpg")
    assert response.status_code == 200 and response.content == JPEG and response.headers["cache-control"] == "no-store"
    assert c.get("/v1/crops/guess.jpg").status_code == 404


# Listing enrichment

PAGE = """<html><head>
<meta property="og:image" content="/img/og.jpg">
<script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"BreadcrumbList"},
 {"@type":"Product","name":"Chuck Taylor All Star High Top","image":["https://cdn.example/m9160.jpg"],
  "brand":{"@type":"Brand","name":"Converse"},"sku":"M9160","mpn":"M9160C",
  "offers":{"@type":"Offer","price":"65.00","priceCurrency":"USD","availability":"InStock"}}]}</script>
</head></html>"""


def test_parse_listing_reads_schema_org_product():
    page = parse_listing(PAGE, "https://shop.example/p")
    assert page["price"] == {"value": "65.00", "currency": "USD"} and page["brand"] == "Converse"
    assert page["image_url"] == "https://cdn.example/m9160.jpg" and {"M9160", "M9160C"} <= set(page["codes"])


def test_parse_listing_falls_back_to_meta_tags_and_never_invents_a_price():
    meta = '<meta property="og:image" content="/i.jpg"><meta property="product:price:amount" content="1,299.00">' \
           '<meta property="product:price:currency" content="CAD">'
    page = parse_listing(meta, "https://shop.example/a/b")
    assert page["image_url"] == "https://shop.example/i.jpg" and page["price"] == {"value": "1299.00", "currency": "CAD"}
    assert parse_listing("<html>no data</html>", "https://x.example")["price"] is None


def enricher(handler, public=True):
    return ListingEnricher(http=httpx.AsyncClient(transport=httpx.MockTransport(handler)), check_host=lambda host: public)


def test_enrich_fills_from_the_page_and_keeps_provider_values_when_the_page_has_none():
    e = enricher(lambda r: httpx.Response(200, text=PAGE, headers={"content-type": "text/html"}))
    c = asyncio.run(e.enrich(Candidate("1", "t", "https://shop.example/p", "Shop", "lens", 0, image_url="https://thumb")))
    assert c.price == {"value": "65.00", "currency": "USD"} and c.image_url == "https://cdn.example/m9160.jpg" and "M9160" in c.codes
    empty = enricher(lambda r: httpx.Response(200, text="<html></html>", headers={"content-type": "text/html"}))
    kept = asyncio.run(empty.enrich(Candidate("1", "t", "https://shop.example/p", "Shop", "lens", 0, image_url="https://thumb")))
    assert kept.image_url == "https://thumb" and kept.price is None


def test_enrich_refuses_private_hosts():
    hits = []
    e = enricher(lambda r: hits.append(r) or httpx.Response(200, text=PAGE, headers={"content-type": "text/html"}), public=False)
    c = asyncio.run(e.enrich(Candidate("1", "t", "http://169.254.169.254/latest", "x", "lens", 0)))
    assert hits == [] and c.price is None


def test_real_host_check_rejects_loopback_and_link_local():
    from app.listing import _public_host
    assert not _public_host("127.0.0.1") and not _public_host("169.254.169.254") and not _public_host("10.0.0.1")


def test_enrich_skips_fixtures_and_survives_errors():
    def boom(request):
        raise httpx.ConnectError("down", request=request)
    c = Candidate("1", "t", "https://shop.example/p", "Shop", "lens", 0)
    assert asyncio.run(enricher(boom).enrich(c)) == c
    fixture = Candidate("2", "t", "https://shop.example/p", "Shop", "fixture", 0, fixture=True)
    assert asyncio.run(enricher(boom).enrich(fixture)) == fixture
