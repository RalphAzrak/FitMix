"""Stage 5: Google Lens through Supabase signed links, merging with Google Shopping, and re-ranking. Supabase,
SerpAPI and thumbnail hosts are replaced by httpx.MockTransport, and FashionCLIP by the mock colour embedder,
so nothing is sent. Search answers are shaped like SerpAPI's documented responses; they are not real listings."""

import asyncio
import io

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import build_online_search, create_app
from app.mock import MockDescriber, MockEmbedder, product_picture
from app.models import GarmentAttributes, OnlineMatch
from app.pipeline import OnlineRequest, Pipeline, StepFailure, Timer
from app.rerank import attribute_match, rerank
from app.search import OnlineSearch, SerpApiClient, ShoppingSearch, ThumbnailFetcher, lens_matches, merge_matches
from app.storage import SupabaseStorage

from .test_api import png_crop

SUPABASE = "https://proj.supabase.co"
EMBEDDER = MockEmbedder()


def png(category, color):
    buffer = io.BytesIO()
    product_picture(category, color).save(buffer, format="PNG")
    return buffer.getvalue()


def attributes(**changes):
    values = dict(category="jacket", color="olive", pattern="solid", material="nylon", style="bomber jacket",
                  visible_brand=None, description="An olive bomber.", search_query="olive nylon bomber jacket")
    values.update(changes)
    return GarmentAttributes(**values)


def run(coroutine):
    return asyncio.run(coroutine)


# MARK: Fakes

class FakeSupabase:
    def __init__(self, upload_status=200, upload_body=None):
        self.upload_status, self.upload_body = upload_status, upload_body or {"Key": "ok"}
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        path = request.url.path
        if request.method == "POST" and path.startswith("/storage/v1/object/sign/"):
            return httpx.Response(200, json={"signedURL": path.removeprefix("/storage/v1") + "?token=signed"})
        if request.method == "POST":
            return httpx.Response(self.upload_status, json=self.upload_body)
        if request.method == "DELETE":
            return httpx.Response(200, json=[])
        return httpx.Response(404)

    def calls(self, method):
        return [r for r in self.requests if r.method == method]


class FakeSerp:
    def __init__(self, lens=None, shopping=None, lens_status=200, shopping_status=200):
        self.lens, self.shopping = lens or [], shopping or []
        self.lens_status, self.shopping_status = lens_status, shopping_status
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if request.url.params["engine"] == "google_lens":
            return httpx.Response(self.lens_status, json={"visual_matches": self.lens} if self.lens_status == 200 else {})
        return httpx.Response(self.shopping_status, json={"shopping_results": self.shopping} if self.shopping_status == 200 else {})

    def engine(self, name):
        return [r for r in self.requests if r.url.params["engine"] == name]


THUMBNAILS = {
    "https://img.example/olive-1.png": png("jacket", "olive"),
    "https://img.example/olive-2.png": png("jacket", "olive"),
    "https://img.example/black.png": png("jacket", "black"),
    "https://img.example/red.png": png("jacket", "red"),
}


def thumbnails(request: httpx.Request) -> httpx.Response:
    data = THUMBNAILS.get(str(request.url))
    return httpx.Response(200, content=data) if data else httpx.Response(404)


def shopping_item(n, title, image, link=None, price="$50.00"):
    return {"position": n, "title": title, "link": link or f"https://shop.example/{n}", "source": "Northwind Apparel",
            "thumbnail": image, "price": price, "extracted_price": float(price.strip("$"))}


def lens_item(n, title, image, link):
    return {"position": n, "title": title, "link": link, "source": "Contoso Closet", "thumbnail": image,
            "price": {"value": "$60.00*", "extracted_value": 60.0, "currency": "$"}}


def search(serp: FakeSerp, storage: FakeSupabase | None = FakeSupabase, **options) -> OnlineSearch:
    client = SerpApiClient("serp-key", transport=httpx.MockTransport(serp))
    store = None
    if storage is not None:
        fake = storage() if storage is FakeSupabase else storage
        store = SupabaseStorage(SUPABASE, "service-key", "vision-crops", 300, transport=httpx.MockTransport(fake))
        store.fake = fake
    fetcher = ThumbnailFetcher(transport=httpx.MockTransport(thumbnails))
    return OnlineSearch(client, EMBEDDER, store, fetcher, **options)


def request(brand=None, query="olive nylon bomber jacket", key="a1/0"):
    crop = product_picture("jacket", "olive")
    return OnlineRequest(crop=crop, crop_jpeg=png("jacket", "olive"), embedding=EMBEDDER.embed([crop])[0],
                         attributes=attributes(), category="jacket", query=query, key=key, brand=brand)


# MARK: Lens + Shopping + re-rank

def test_lens_and_shopping_are_merged_and_reranked_by_picture():
    serp = FakeSerp(
        shopping=[shopping_item(1, "Black Bomber Jacket", "https://img.example/black.png"),
                  shopping_item(2, "Olive Bomber Jacket", "https://img.example/olive-1.png", link="https://shop.example/olive?utm_source=g")],
        lens=[lens_item(1, "Olive Bomber Jacket", "https://img.example/olive-1.png", "https://www.shop.example/olive"),
              lens_item(2, "Olive Flight Jacket", "https://img.example/olive-2.png", "https://other.example/flight")])
    subject = search(serp)
    timer = Timer("t")
    result = run(subject.search(request(), timer))
    assert result.errors == []
    titles = [m.title for m in result.matches]
    assert titles[0] == "Olive Bomber Jacket" and titles[-1] == "Black Bomber Jacket"  # picture beats Google's order
    first = result.matches[0]
    assert first.source == "lens+shopping" and first.price.value == "50.00"  # the shared link is one result
    assert len(result.matches) == 3
    scores = [m.score for m in result.matches]
    assert scores == sorted(scores, reverse=True)
    assert {"lens", "shopping", "thumbnails", "rerank"} <= set(timer.ms)


def test_lens_gets_a_signed_link_and_the_crop_is_deleted_afterwards():
    serp = FakeSerp(lens=[lens_item(1, "Olive Jacket", "https://img.example/olive-1.png", "https://shop.example/1")])
    subject = search(serp)
    run(subject.search(request(), Timer("t")))
    fake = subject.storage.fake
    upload = fake.calls("POST")[0]
    assert upload.url.path == "/storage/v1/object/vision-crops/crops/a1/0.jpg"
    assert upload.headers["authorization"] == "Bearer service-key" and upload.headers["apikey"] == "service-key"
    assert upload.headers["x-upsert"] == "true" and upload.headers["content-type"] == "image/jpeg"
    assert upload.content[:8] == b"\x89PNG\r\n\x1a\n"  # the crop bytes as given
    lens_call = serp.engine("google_lens")[0]
    assert lens_call.url.params["url"] == f"{SUPABASE}/storage/v1/object/sign/vision-crops/crops/a1/0.jpg?token=signed"
    assert fake.calls("DELETE") and b"crops/a1/0.jpg" in fake.calls("DELETE")[0].content


def test_refine_reuses_lens_results_and_adds_the_brand():
    serp = FakeSerp(
        lens=[lens_item(1, "Olive Bomber Jacket", "https://img.example/olive-1.png", "https://shop.example/l1")],
        shopping=[shopping_item(1, "Alpha Industries Olive Bomber Jacket", "https://img.example/olive-2.png"),
                  shopping_item(2, "Olive Bomber Jacket", "https://img.example/olive-1.png", link="https://shop.example/s2")])
    subject = search(serp)
    run(subject.search(request(), Timer("t")))
    refined = run(subject.search(request(brand="Alpha Industries", query="Alpha Industries olive nylon bomber jacket"), Timer("t")))
    assert len(serp.engine("google_lens")) == 1  # one Lens search for both
    assert serp.engine("google_shopping")[-1].url.params["q"] == "Alpha Industries olive nylon bomber jacket"
    assert refined.matches[0].title == "Alpha Industries Olive Bomber Jacket"  # the brand lifts it above equal pictures


def test_storage_failure_skips_lens_but_keeps_shopping():
    serp = FakeSerp(shopping=[shopping_item(1, "Olive Bomber Jacket", "https://img.example/olive-1.png")])
    subject = search(serp, storage=FakeSupabase(upload_status=404, upload_body={"error": "Bucket not found"}))
    result = run(subject.search(request(), Timer("t")))
    assert [m.title for m in result.matches] == ["Olive Bomber Jacket"]
    assert [(e.step, e.code) for e in result.errors] == [("lens", "storage_bucket")]
    assert serp.engine("google_lens") == []


def test_shopping_failure_keeps_lens():
    serp = FakeSerp(lens=[lens_item(1, "Olive Jacket", "https://img.example/olive-1.png", "https://shop.example/1")],
                    shopping_status=500)
    result = run(search(serp).search(request(), Timer("t")))
    assert [m.source for m in result.matches] == ["lens"]
    assert [(e.step, e.code) for e in result.errors] == [("shopping", "provider_error")]


def test_without_a_crop_store_lens_is_skipped_quietly():
    serp = FakeSerp(shopping=[shopping_item(1, "Olive Bomber Jacket", "https://img.example/olive-1.png")])
    subject = search(serp, storage=None)
    result = run(subject.search(request(), Timer("t")))
    assert result.errors == [] and serp.engine("google_lens") == []
    assert subject.name == "serpapi-shopping+rerank"


def test_a_missing_thumbnail_counts_as_no_visual_match():
    serp = FakeSerp(shopping=[shopping_item(1, "Olive Bomber Jacket", "https://img.example/gone.png"),
                              shopping_item(2, "Red Bomber Jacket", "https://img.example/red.png")])
    result = run(search(serp, storage=None, image_weight=0.8, attr_weight=0.2).search(request(), Timer("t")))
    gone = next(m for m in result.matches if m.title == "Olive Bomber Jacket")
    assert gone.score == pytest.approx(0.2)  # attributes only: category and colour both in the title


def test_weights_are_configurable():
    serp = FakeSerp(shopping=[shopping_item(1, "Olive Bomber Jacket", "https://img.example/red.png"),
                              shopping_item(2, "Something Else", "https://img.example/olive-1.png")])
    by_text = run(search(serp, storage=None, image_weight=0.0, attr_weight=1.0).search(request(), Timer("t")))
    by_picture = run(search(serp, storage=None, image_weight=1.0, attr_weight=0.0).search(request(), Timer("t")))
    assert by_text.matches[0].title == "Olive Bomber Jacket"
    assert by_picture.matches[0].title == "Something Else"


def test_top_k_and_candidate_limit():
    shopping = [shopping_item(n, f"Olive Bomber Jacket {n}", "https://img.example/olive-1.png") for n in range(1, 30)]
    result = run(search(FakeSerp(shopping=shopping), storage=None, top_k=10, max_candidates=15).search(request(), Timer("t")))
    assert len(result.matches) == 10


# MARK: Units

def test_lens_matches_parse_prices_and_skip_incomplete_results():
    body = {"visual_matches": [lens_item(1, "A", "https://img.example/a.png", "https://shop.example/a"),
                               {"title": "No link"}, lens_item(3, "A again", None, "https://shop.example/a/")]}
    matches = lens_matches(body, "us")
    assert len(matches) == 1 and matches[0].price.model_dump() == {"value": "60.00", "currency": "USD"}


def test_merge_fills_missing_details_from_the_other_source():
    a = OnlineMatch(title="A", price=None, retailer="X", url="https://shop.example/a", image=None, score=0, source="shopping")
    b = OnlineMatch(title="A (lens)", price={"value": "5.00", "currency": "USD"}, retailer="Y",
                    url="https://shop.example/a?utm_source=x", image="https://img.example/a.png", score=0, source="lens")
    merged = merge_matches([a], [b])
    assert len(merged) == 1 and merged[0].title == "A" and merged[0].source == "lens+shopping"
    assert merged[0].price.value == "5.00" and merged[0].image == "https://img.example/a.png"


@pytest.mark.parametrize("title, attrs, brand, expected", [
    ("Olive Nylon Bomber Jacket", dict(), None, 1.0),  # category + colour (solid pattern left out)
    ("Men's Army Green Bomber Coat", dict(), None, 1.0),  # synonyms
    ("Black Bomber Jacket", dict(), None, 0.5),
    ("Grey Striped Tee", dict(category="top", color="gray", pattern="striped"), None, 1.0),
    ("Grey Tee", dict(category="top", color="gray", pattern="striped"), None, 2 / 3),
    ("Olive Bomber Jacket", dict(), "Alpha Industries", 2 / 3),
    ("alpha industries olive bomber jacket", dict(), "Alpha Industries", 1.0),
    ("Light Wash Relaxed Jeans", dict(category="pants", color="light blue"), None, 1.0),
    ("Jacketed potato", dict(), None, 0.0),  # whole words only
])
def test_attribute_match(title, attrs, brand, expected):
    assert attribute_match(title, attributes(**attrs), None, brand) == pytest.approx(expected)


def test_attribute_match_without_description_uses_the_category():
    assert attribute_match("Leather Boots", None, "shoes") == 1.0
    assert attribute_match("Leather Boots", None, None) == 0.0


def test_rerank_keeps_provider_order_on_ties():
    matches = [OnlineMatch(title=f"Item {i}", price=None, retailer=None, url=f"https://s.example/{i}", image=None,
                           score=0, source="shopping") for i in range(3)]
    ranked = rerank(matches, None, [None] * 3, None, None, None, 0.8, 0.2, 10)
    assert [m.title for m in ranked] == ["Item 0", "Item 1", "Item 2"]


def test_storage_errors_are_readable():
    def refuse(request):
        return httpx.Response(403, json={"error": "Unauthorized", "message": "invalid signature"})

    storage = SupabaseStorage(SUPABASE, "bad", "vision-crops", transport=httpx.MockTransport(refuse))
    with pytest.raises(StepFailure) as failure:
        run(storage.signed_link("crops/x.jpg", b"jpeg"))
    assert failure.value.code == "storage_auth"


def test_build_online_search_picks_what_the_keys_allow():
    assert build_online_search(Settings(), EMBEDDER) is None
    assert isinstance(build_online_search(Settings(serpapi_key="s"), None), ShoppingSearch)
    assert build_online_search(Settings(serpapi_key="s"), EMBEDDER).name == "serpapi-shopping+rerank"
    with_lens = build_online_search(Settings(serpapi_key="s", supabase_url=SUPABASE, supabase_service_role_key="k"), EMBEDDER)
    assert with_lens.name == "serpapi-lens+shopping+rerank"


# MARK: Through the API

def test_search_and_refine_through_the_api():
    serp = FakeSerp(
        lens=[lens_item(1, "Olive Bomber Jacket", "https://img.example/olive-1.png", "https://shop.example/l1")],
        shopping=[shopping_item(1, "Black Bomber Jacket", "https://img.example/black.png"),
                  shopping_item(2, "Olive Flight Jacket", "https://img.example/olive-2.png")])
    online = search(serp)
    pipeline = Pipeline(None, MockDescriber(), EMBEDDER, None, online)
    client = TestClient(create_app(Settings(), pipeline=pipeline))
    analysis = client.post("/analyze", files=[("crops", ("j.png", png("jacket", "olive"), "image/png"))],
                           data={"categories": "jacket"}).json()
    assert serp.requests == []  # /analyze spends no searches
    body = client.post("/search", json={"analysis_id": analysis["analysis_id"], "garment_index": 0}).json()
    assert body["errors"] == [] and body["online_matches"][-1]["title"] == "Black Bomber Jacket"
    assert {"lens", "shopping", "thumbnails", "rerank", "total"} <= set(body["timings_ms"])
    refined = client.post("/refine", json={"analysis_id": analysis["analysis_id"], "garment_index": 0, "brand": "Alpha"}).json()
    assert refined["query"].startswith("Alpha ") and len(serp.engine("google_lens")) == 1
