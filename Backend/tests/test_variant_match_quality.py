import asyncio
import io
import json

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.main import Settings, create_app
from app.outfit_match import DiscoveryPage, Hit, OutfitMatcher, Rating, evidence_score
from app.retailer_product import RetailerVerifier, listing_key, page_listing, verified_offers
from .test_hybrid_outfit_match import sample_photo, visible
from .test_outfit_match import jpeg, product_page


STORE = "https://corner.example"
PAGE = f"{STORE}/products/essential"


def structured_data(record):
    return f'<script type="application/ld+json">{json.dumps(record)}</script>'


def offer(amount, **fields):
    return {"@type": "Offer", "price": str(amount), "priceCurrency": "CAD",
            "availability": "https://schema.org/InStock", **fields}


def tee(color, pattern, variant, amount):
    return {"@type": "Product", "name": "Essential Slim Tee", "url": f"{PAGE}?variant={variant}",
            "image": f"/{color.lower()}.jpg", "color": color, "pattern": pattern, "sku": "ESS-1234",
            "offers": offer(amount)}


@pytest.mark.parametrize("search_url, include_black, blue_score", [
    (PAGE, True, 30),
    (PAGE + "?variant=101", False, 98),
    (PAGE, False, 30),
])
def test_black_patterned_tee_never_matches_plain_blue_variant(search_url, include_black, blue_score):
    # Replay the screenshot's failure with a controlled crop, listing and visual-score fixture.
    source = sample_photo("tshirt", pattern="diagonal streaks")
    blue = tee("Blue", "Solid", 101, "24.50")
    black = tee("Black", "Diagonal streaks", 102, "35.00")
    group = {"@type": "ProductGroup", "url": PAGE, "variesBy": ["https://schema.org/color",
             "https://schema.org/pattern"], "brand": {"name": "Corner Shop"},
             "hasVariant": [blue, black] if include_black or "?" in search_url else [blue]}
    hit = Hit(search_url, "corner.example", "Corner Shop")
    calls = set()
    queries = []
    ranked_variants = []

    class Search:
        async def page(self, crop, media, *, department="any"):
            assert (crop, media) == (source, "image/jpeg")
            calls.add("photo")
            return DiscoveryPage([hit], None, None)

        async def text_hits(self, query):
            assert "t shirt" in query
            if not queries:
                assert "black" in query and "diagonal streaks" in query
            queries.append(query)
            calls.add("text")
            return [hit]

    class Pages:
        async def get(self, url, mime, limit):
            if mime == "text/html":
                return PAGE, structured_data(group).encode()  # Simulates stripping the variant on redirect.
            assert mime == "image/"
            images = {f"{STORE}/blue.jpg": jpeg((48, 122, 200)), f"{STORE}/black.jpg": source}
            return url, images[url]

    class Rank:
        async def describe(self, category, crop, media, words):
            assert (category, crop, media) == ("tshirt", source, "image/jpeg")
            return visible(garment_type="T-shirt", color="black", color_family="black", pattern="diagonal streaks",
                           neckline="crew neck", sleeves="short sleeves", plain=False, readable_text="ESS-1234")

        async def rank(self, category, crop, media, photos, description, attributes):
            assert crop == source and description.pattern == "diagonal streaks"
            ratings = []
            for index, (photo, attributes) in enumerate(zip(photos, attributes, strict=True)):
                color = attributes["color"]
                ranked_variants.append(color)
                # The bytes sent to rank must belong to the very same colorway as the listed attributes.
                r, g, b = Image.open(io.BytesIO(photo)).getpixel((16, 16) if color == "Blue" else (110, 120))
                if color == "Blue":
                    assert b > 150 and r < 80 and attributes["pattern"] == "Solid"
                    if blue_score == 30:
                        ratings.append(Rating(index=index, same_category=True, color=0, cut=25, pattern=0, details=5,
                                              detail_evidence="unclear", product_plain=None, product_text=None))
                    else:
                        # Even inflated points and corroborated SKU cannot override a confirmed conflict.
                        ratings.append(Rating(index=index, same_category=True, color=15, cut=25, pattern=20, details=38,
                                              detail_evidence="match", product_plain=True, product_text=None,
                                              product_color_family="blue"))
                else:
                    assert max(r, g, b) < 85 and attributes["pattern"] == "Diagonal streaks"
                    ratings.append(Rating(index=index, same_category=True, color=15, cut=25, pattern=20, details=35,
                                          detail_evidence="match", product_plain=False, product_text=None,
                                          product_color_family="black"))
            return ratings

    matcher = OutfitMatcher(Rank(), Search(), RetailerVerifier(Pages()))
    with TestClient(create_app(Settings(mock=True), outfit=matcher)) as client:
        response = client.post("/v1/outfit-match", data={"category": "tshirt", "text": "ESS-1234"},
                               files={"crop": ("garment.jpg", source, "image/jpeg")})
    assert response.status_code == 200, response.text
    result = response.json()
    assert calls == {"photo", "text"}
    assert "Blue" in ranked_variants and ("Black" in ranked_variants) == include_black
    if include_black:
        assert result["status"] == "matched"
        assert len(result["results"]) == 1
        match = result["results"][0]
        assert (match["variant_color"], match["url"], match["image_url"], match["price"]["value"]) == (
            "Black", black["url"], f"{STORE}/black.jpg", "35.00"
        )
        assert match["best_match"] and match["match"] == "exact"
    else:
        assert result["status"] == "no_match" and result["results"] == []


def test_offers_that_cannot_be_tied_to_a_photo_give_one_listing_from_the_page_itself():
    product = {"@type": "Product", "name": "Essential Slim Tee", "image": "/blue.jpg", "color": "Blue",
               "offers": [offer("24.50", url=PAGE + "?variant=101"), offer("35", url=PAGE + "?variant=102"),
                          offer("37", url=PAGE + "?variant=103")]}
    html = structured_data(product)
    assert verified_offers(html, PAGE, "", set()) == []
    requests = []

    class Pages:
        async def get(self, url, mime, limit):
            requests.append(mime)
            if mime == "text/html":
                return PAGE, html.encode()
            assert url == f"{STORE}/blue.jpg"
            return url, jpeg((48, 122, 200))

    verifier = RetailerVerifier(Pages())
    assert not asyncio.run(verifier.verify(PAGE + "?variant=102", "corner.example", "", set(), None))
    assert requests == ["text/html"]
    requests.clear()
    [(option, _)] = asyncio.run(verifier.verify(PAGE, "frankandoak.example", "", set(), None))
    # The page's own photo and colour, and no price: its offers disagree and none is tied to that photo.
    assert (option.title, option.color, option.image_url, option.amount, option.url) == (
        "Essential Slim Tee", "Blue", f"{STORE}/blue.jpg", None, PAGE)
    assert requests == ["text/html", "image/"]  # The store's page is read once.
    # A budget can't use a listing with no stated price.
    assert not asyncio.run(verifier.verify(PAGE, "corner.example", "", set(), 100))
    assert listing_key(PAGE + "?utm_medium=search&variant=102") == listing_key(PAGE + "?variant=102")
    assert listing_key(PAGE + "?variant=102") != listing_key(PAGE + "?variant=101")

    black = tee("Black", "Solid", 102, "35")
    black.pop("offers")
    selected_page = structured_data(black) + '<meta property="og:image" content="/blue.jpg">'
    item = page_listing(selected_page, black["url"], "")
    assert item and (item.image_url, item.amount, item.url) == (f"{STORE}/black.jpg", None, black["url"])
    black.pop("image")
    assert not page_listing(structured_data(black) + '<meta property="og:image" content="/blue.jpg">', black["url"], "")


@pytest.mark.parametrize("category, fields, expected", [
    ("tshirt", {"garment_type": "T-shirt", "color": "white", "pattern": "solid",
                "sleeves": "short sleeves", "neckline": "V neck"}, {"white", "solid"}),
    ("tshirt", {"garment_type": "polo", "color": "green", "pattern": "horizontal stripes"}, {"polo", "green", "stripes"}),
    ("tshirt", {"garment_type": "graphic T-shirt", "color": "red", "pattern": "all-over print",
                "graphic": "white roses"}, {"graphic", "red", "all over print", "white roses"}),
    ("tshirt", {"garment_type": "rugby shirt", "color": "navy", "pattern": "chest logo",
                "readable_text": "ORBIT CLUB"}, {"rugby shirt", "navy", "chest logo", "orbit club"}),
    ("tshirt", {"color": "yellow", "pattern": "unclear", "obscured": True, "readable_text": "ORB"}, {"yellow"}),
    ("pants", {"garment_type": "jeans", "color": "blue", "pattern": "pinstripe"}, {"jeans", "blue", "pinstripe"}),
    ("jacket", {"garment_type": "zip hoodie", "color": "gray", "pattern": "camouflage"}, {"zip hoodie", "gray", "camouflage"}),
    ("jacket", {"garment_type": "bomber jacket", "color": "green", "pattern": "floral"}, {"bomber jacket", "green", "floral"}),
    ("shoes", {"garment_type": "high top sneakers", "color": "purple", "pattern": "checkerboard"},
     {"high top sneakers", "purple", "checkerboard"}),
])
def test_query_uses_visible_type_base_color_and_pattern(category, fields, expected):
    queries = visible(**fields).queries(category, "Label")
    assert queries
    for query in queries[:-1]:
        assert all(term in query for term in expected | {"label"})
        assert "unclear" not in query
        assert not fields.get("obscured") or "orb" not in query
    assert "label" in queries[-1]
    for field in ("neckline", "sleeves"):
        if field in fields:
            assert fields[field].lower() in queries[0]


@pytest.mark.parametrize("color_evidence, pattern_evidence, expected", [
    ("conflict", "match", (64, True)),
    ("match", "conflict", (64, True)),
    ("unknown", "unknown", (85, False)),
])
def test_unknown_attributes_stay_neutral_and_visual_conflicts_reject(color_evidence, pattern_evidence, expected):
    row = Rating(index=0, same_category=True, color=14, cut=22, pattern=16, details=33,
                 detail_evidence="unclear", product_plain=None, product_text=None,
                 color_evidence=color_evidence, pattern_evidence=pattern_evidence)
    assert evidence_score(row, visible(obscured=True)) == expected


@pytest.mark.parametrize("scenario", ["focused", "fallback", "miss"])
def test_black_quarter_zip_uses_color_and_closure_even_with_a_tee_camera_hint(scenario):
    source = jpeg((20, 20, 20))
    description = visible(garment_type="quarter-zip pullover", neckline="standing collar", sleeves="long sleeves",
                          plain=True, color="black", closure="partial_zip")
    products = {
        "navy": ("Navy Quarter Zip", "Navy", "blue", "partial_zip", "match"),
        # Even if the visual model misses the full zipper or tee neckline, the listing states the cut.
        "jacket": ("Black Full Zip", "Black", "black", "partial_zip", "match"),
        "tee": ("Black Basic Tee", "Black", "black", "partial_zip", "match"),
        "unknown": ("Dark Quarter Zip", None, None, "partial_zip", "unknown"),
        "black": ("Black Quarter Zip", "Black", "black", "partial_zip", "match"),
    }
    photo_hits = [Hit(f"{STORE}/products/{slug}", "frankandoak.example", "") for slug in ("navy", "tee", "jacket")]
    queries, fetched = [], []

    class Search:
        async def page(self, crop, media, *, department="any"):
            assert crop == source
            return DiscoveryPage(photo_hits, None, None)

        async def text_hits(self, query):
            queries.append(query)
            target_found = scenario == "focused" or (scenario == "fallback" and len(queries) == 2)
            slugs = ("black", "unknown", "navy") if target_found else ("unknown", "navy")
            return [Hit(f"{STORE}/products/{slug}", "frankandoak.example", "") for slug in slugs]

    class Pages:
        async def get(self, url, mime, limit):
            slug = url.rsplit("/", 1)[1].removesuffix(".jpg")
            if mime == "text/html":
                fetched.append(slug)
                name, color, _, _, _ = products[slug]
                return url, product_page(name).replace(b'"/product.jpg"', f'"/{slug}.jpg", "color": {json.dumps(color)}'.encode())
            return url, jpeg(((list(products).index(slug) + 1) * 40, 30, 30))

    class Rank:
        async def describe(self, category, crop, media, words):
            assert category == "tshirt" and crop == source
            return description

        async def rank(self, category, crop, media, photos, observed, attributes):
            assert observed == description and crop == source
            ratings = []
            for index, photo in enumerate(photos):
                product_index = round(Image.open(io.BytesIO(photo)).getpixel((12, 12))[0] / 40) - 1
                _, _, color, closure, evidence = list(products.values())[product_index]
                ratings.append(Rating(index=index, same_category=True, color=15, cut=25, pattern=20, details=38,
                                      detail_evidence="plain", product_plain=True, product_text=None,
                                      product_color_family=color, color_evidence=evidence, product_closure=closure,
                                      cut_evidence="match"))
            return ratings

    matcher = OutfitMatcher(Rank(), Search(), RetailerVerifier(Pages()))
    with TestClient(create_app(Settings(mock=True), outfit=matcher)) as client:
        response = client.post("/v1/outfit-match", data={"category": "tshirt"},
                               files={"crop": ("garment.jpg", source, "image/jpeg")})
    assert response.status_code == 200, response.text
    result = response.json()
    assert len(queries) == {"focused": 1, "fallback": 2, "miss": 3}[scenario]
    assert all("quarter zip pullover" in query for query in queries)
    assert "black solid" in queries[0]
    assert len(fetched) == len(set(fetched))
    assert result["garment_label"] == "Quarter-zip"
    stocked = scenario != "miss"
    assert result["status"] == ("matched" if stocked else "no_match")
    assert [row["title"] for row in result["results"]] == (["Black Quarter Zip"] if stocked else [])
