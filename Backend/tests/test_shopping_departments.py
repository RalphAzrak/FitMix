import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.main import Settings, create_app
from app.outfit_match import DiscoveryPage, Hit, OutfitMatcher, Rating
from app.retailer_product import RetailerVerifier, page_listing
from .test_hybrid_outfit_match import visible
from .test_outfit_match import jpeg
from .test_variant_match_quality import offer, structured_data


class RetailerFixture:
    def __init__(self, products):
        self.products = products
        self.read = []

    async def get(self, url, mime, limit):
        slug = url.split("/products/", 1)[1].split("?", 1)[0].removesuffix(".jpg")
        item = self.products[slug]
        if mime == "image/":
            return url, jpeg((item["id"] * 20, 10, 10))
        self.read.append(slug)
        return url, structured_data({
            "@type": "Product", "name": item["title"], "image": f"/products/{slug}.jpg",
            "color": item["color"], "audience": {"@type": "PeopleAudience", "suggestedGender": item["department"]},
            "offers": offer("44.95"),
        }).encode()


def hit(slug, tracking=""):
    return Hit(f"https://{slug}.example/products/{slug}{tracking}", f"{slug}.example", "")


def rank_products(photos, products, *, closure=None, bottom=None):
    by_id = {item["id"]: item for item in products.values()}
    ratings = []
    for index, photo in enumerate(photos):
        fixture_id = round(Image.open(io.BytesIO(photo)).getpixel((12, 12))[0] / 20)
        item = by_id[fixture_id]
        ratings.append(Rating(
            index=index, same_category=True, color=15, cut=25, pattern=20, details=40,
            detail_evidence="plain", product_plain=True, product_text=None,
            product_color_family=item["color"].casefold(), product_closure=item.get("closure", closure),
            product_bottom_cut=item.get("bottom", bottom), cut_evidence="match",
        ))
    return ratings


@pytest.mark.parametrize("department, expected", [
    ("men", {"men", "neutral"}),
    ("women", {"women", "neutral"}),
    ("unisex", {"neutral"}),
    ("any", {"men", "women", "neutral", "unknown"}),
])
def test_quarter_zip_prefers_verified_department(department, expected):
    products = {
        "men": {"id": 1, "title": "Black Quarter Zip", "department": "Male", "color": "Black"},
        "women": {"id": 2, "title": "Black Quarter Zip", "department": "Female", "color": "Black"},
        "neutral": {"id": 3, "title": "Unisex Black Quarter Zip", "department": None, "color": "Black"},
        "unknown": {"id": 4, "title": "Black Quarter Zip", "department": None, "color": "Black"},
        "wrongcut": {"id": 5, "title": "Men’s Black Full Zip", "department": None, "color": "Black"},
    }
    source = jpeg((20, 20, 20))
    description = visible(garment_type="quarter-zip pullover", closure="partial_zip",
                          color="black", plain=True, sleeves="long sleeves")
    queries = []
    prompt_term = {"men": "men's", "women": "women's", "unisex": "unisex", "any": ""}[department]

    class Discovery:
        async def page(self, crop, media, *, department):
            assert crop == source and media == "image/jpeg"
            assert department == selected
            return DiscoveryPage([hit(slug) for slug in products], None, None)

        async def text_hits(self, query):
            queries.append(query)
            return [hit(slug, "?utm_source=photo") for slug in products]

    class Analysis:
        async def describe(self, *args):
            return description

        async def rank(self, category, crop, media, photos, description, attributes):
            return rank_products(photos, products, closure="partial_zip")

    selected = department
    pages = RetailerFixture(products)
    matcher = OutfitMatcher(Analysis(), Discovery(), RetailerVerifier(pages))
    with TestClient(create_app(Settings(mock=True), outfit=matcher)) as client:
        response = client.post("/v1/outfit-match", data={"category": "tshirt", "department": department},
                               files={"crop": ("garment.jpg", source, "image/jpeg")})
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["status"] == "matched" and data["garment_label"] == "Quarter-zip"
    assert {row["url"].split(".example")[0].removeprefix("https://") for row in data["results"]} == expected
    assert data["alternatives"] == []
    assert all(query.startswith(prompt_term) and "quarter zip" in query for query in queries)
    assert len(pages.read) == len(set(pages.read))


def test_shorts_keep_their_construction_and_show_five_distinct_broader_options():
    colors = ["Green", "Red", "Blue", "Beige", "Gray", "White"]
    products = {f"shorts{index}": {"id": index, "title": f"Men’s {color} Shorts",
                                  "department": None, "color": color, "bottom": "shorts"}
                for index, color in enumerate(colors, 1)}
    products["trousers"] = {"id": 7, "title": "Men’s Black Trousers", "department": "Male",
                            "color": "Black", "bottom": "long_pants"}
    products["women"] = {"id": 8, "title": "Black Running Shorts", "department": "Female",
                         "color": "Black", "bottom": "shorts"}
    source = jpeg((20, 20, 20))
    description = visible(garment_type="shorts", bottom_cut="shorts", color="black", plain=True, fit="relaxed fit")
    queries = []

    class Discovery:
        async def page(self, crop, media, *, department):
            assert (crop, media, department) == (source, "image/jpeg", "men")
            return DiscoveryPage([hit("trousers"), hit("women")], None, None)

        async def text_hits(self, query):
            queries.append(query)
            if "black" in query:
                return [hit("trousers", "?utm_source=search"), hit("women")]
            return [*[hit(slug) for slug in products], hit("shorts1", "?utm_source=duplicate")]

    class Analysis:
        async def describe(self, *args):
            return description

        async def rank(self, category, crop, media, photos, description, attributes):
            return rank_products(photos, products)

    pages = RetailerFixture(products)
    matcher = OutfitMatcher(Analysis(), Discovery(), RetailerVerifier(pages))
    with TestClient(create_app(Settings(mock=True), outfit=matcher)) as client:
        response = client.post("/v1/outfit-match", data={"category": "pants", "department": "men"},
                               files={"crop": ("garment.jpg", source, "image/jpeg")})
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["status"] == "no_match" and data["results"] == [] and data["garment_label"] == "Shorts"
    assert "black" in queries[0] and queries[-1] == "men's shorts"
    assert all("shorts" in query and "men's" in query for query in queries)
    alternatives = data["alternatives"]
    assert len({row["url"] for row in alternatives}) == len(alternatives) == 5
    assert all("Shorts" in row["title"] and row["title"].startswith("Men’s") and row["match"] == "alternative"
               and not row["best_match"] and row["visual_score"] < 65 and row["thumbnail"] for row in alternatives)
    assert len(pages.read) == len(set(pages.read))


def test_listing_department_uses_page_metadata_and_explicit_conflicts():
    html = ('<meta property="og:type" content="product"><meta property="og:title" content="Quarter Zip">'
            '<meta property="og:image" content="/photo.jpg"><meta property="product:gender" content="female">')
    listing = page_listing(html, "https://store.example/products/black-quarter-zip", "")
    assert listing and listing.department == "women"
    conflicting = page_listing(html.replace('content="Quarter Zip"', 'content="Men’s Quarter Zip"'),
                               "https://store.example/products/black-quarter-zip", "")
    assert conflicting and conflicting.department == "conflict"
