"""Stage 2: OpenAI garment descriptions and Google Shopping search. OpenAI is replaced by a fake client and
SerpAPI by httpx.MockTransport, so nothing is sent and no keys are needed. The Shopping answers are shaped
like SerpAPI's documented `shopping_results`; they are not real listings."""

import asyncio
import json

import httpx
import openai
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.config import Settings
from app.describe import OpenAIDescriber, parse_garments, response_schema
from app.main import build_pipeline, create_app
from app.mock import MockDescriber
from app.pipeline import WHOLE_PHOTO, OnlineRequest, Pipeline, StepFailure, Timer
from app.search import SerpApiClient, ShoppingSearch, normalize_url, parse_price

from .test_api import jpeg, png_crop


def attrs(category="jacket", color="olive", **extra):
    return {"category": category, "color": color, "pattern": "solid", "material": "nylon", "style": "bomber jacket",
            "visible_brand": None, "description": f"An {color} {category}.", "search_query": f"{color} {category}",
            "layered_over_top": False, **extra}


# MARK: Fake OpenAI

class Message:
    def __init__(self, content, refusal=None):
        self.content, self.refusal = content, refusal


class Completions:
    def __init__(self, answers):
        self.answers, self.calls = list(answers), []

    async def create(self, **kwargs):
        self.calls.append(kwargs)
        answer = self.answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        message = answer if isinstance(answer, Message) else Message(answer)
        return type("Response", (), {"choices": [type("Choice", (), {"message": message})()]})()


class FakeOpenAI:
    def __init__(self, *answers):
        self.chat = type("Chat", (), {})()
        self.chat.completions = Completions(answers)


def describer(*answers) -> tuple[OpenAIDescriber, Completions]:
    fake = FakeOpenAI(*answers)
    return OpenAIDescriber("key", "gpt-test", client=fake), fake.chat.completions


def crops(n):
    return [Image.new("RGB", (120, 160), (95, 100, 50)) for _ in range(n)]


def run(coroutine):
    return asyncio.run(coroutine)


REQUEST = httpx.Request("POST", "https://api.openai.com/v1/chat/completions")


# MARK: OpenAI describer

def test_one_call_for_all_crops_with_strict_schema():
    answer = json.dumps({"garments": [{"index": 1, **attrs("pants", "navy")}, {"index": 0, **attrs()}]})
    subject, calls = describer(answer)
    result = run(subject.describe(crops(2), ["upper_clothes", None]))
    assert [a.category for a in result] == ["jacket", "pants"]  # put back in picture order
    assert len(calls.calls) == 1
    call = calls.calls[0]
    assert call["model"] == "gpt-test"
    assert call["response_format"]["type"] == "json_schema" and call["response_format"]["json_schema"]["strict"] is True
    images = [part for part in call["messages"][1]["content"] if part["type"] == "image_url"]
    assert len(images) == 2 and images[0]["image_url"]["url"].startswith("data:image/jpeg;base64,")
    assert "detected as: upper clothes" in json.dumps(call["messages"][1]["content"])


def test_invalid_answer_is_retried_once():
    good = json.dumps({"garments": [{"index": 0, **attrs()}]})
    subject, calls = describer("not json", good)
    assert run(subject.describe(crops(1), [None]))[0].color == "olive"
    assert len(calls.calls) == 2


def test_two_invalid_answers_fail_the_step():
    wrong_category = json.dumps({"garments": [{"index": 0, **attrs(category="hat")}]})
    subject, _ = describer(wrong_category, json.dumps({"garments": []}))
    with pytest.raises(StepFailure) as failure:
        run(subject.describe(crops(1), [None]))
    assert failure.value.code == "invalid_description"


@pytest.mark.parametrize("garments", [
    [{"index": 0, **attrs()}],  # one missing
    [{"index": 0, **attrs()}, {"index": 0, **attrs()}],  # repeated
    [{"index": 0, **attrs()}, {"index": 5, **attrs()}],  # out of range
])
def test_every_crop_must_be_described_exactly_once(garments):
    with pytest.raises(ValueError):
        parse_garments(json.dumps({"garments": garments}), expected=2)


def test_schema_requires_every_field_and_allows_null_brand():
    item = response_schema(with_index=True)["schema"]["properties"]["garments"]["items"]
    assert item["additionalProperties"] is False and set(item["required"]) == set(item["properties"])
    assert item["properties"]["visible_brand"]["type"] == ["string", "null"]
    assert item["properties"]["category"]["enum"] == ["top", "jacket", "pants", "shoes", "dress", "skirt"]


def test_describe_outfit_lists_garments_from_one_photo():
    subject, calls = describer(json.dumps({"garments": [attrs(), attrs("pants", "navy"), attrs("shoes", "white")]}))
    result = run(subject.describe_outfit(Image.new("RGB", (300, 600), "white")))
    assert [a.category for a in result] == ["jacket", "pants", "shoes"]
    assert "index" not in json.dumps(calls.calls[0]["response_format"])


@pytest.mark.parametrize("error, code", [
    (openai.APITimeoutError(request=REQUEST), "provider_timeout"),
    (openai.APIConnectionError(request=REQUEST), "provider_unreachable"),
    (openai.AuthenticationError("bad key", response=httpx.Response(401, request=REQUEST), body=None), "provider_auth"),
    (openai.NotFoundError("no model", response=httpx.Response(404, request=REQUEST), body=None), "provider_model"),
    (openai.RateLimitError("slow down", response=httpx.Response(429, request=REQUEST), body=None), "provider_busy"),
])
def test_openai_errors_become_readable_step_failures(error, code):
    subject, _ = describer(error)
    with pytest.raises(StepFailure) as failure:
        run(subject.describe(crops(1), [None]))
    assert failure.value.code == code


def test_refusal_is_reported():
    subject, _ = describer(Message(None, refusal="no"))
    with pytest.raises(StepFailure) as failure:
        run(subject.describe(crops(1), [None]))
    assert failure.value.code == "provider_refused"


# MARK: SerpAPI Google Shopping

def shopping_result(n, link=True, price="$49.99", extracted=49.99, source="Northwind Apparel"):
    result = {"position": n, "title": f"Olive Nylon Bomber Jacket {n}", "source": source,
              "thumbnail": f"https://serpapi.example/thumb/{n}.jpg", "price": price, "extracted_price": extracted}
    if link:
        result["link"] = f"https://shop.example/item/{n}?utm_source=google"
    return result


class FakeSerpApi:
    def __init__(self, body=None, status=200):
        self.body, self.status, self.requests = body, status, []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        return httpx.Response(self.status, json=self.body if self.body is not None else {})


def shopping(fake, top_k=10, country="us") -> ShoppingSearch:
    return ShoppingSearch(SerpApiClient("serp-key", country=country, transport=httpx.MockTransport(fake)), top_k=top_k)


def online_request(query="olive nylon bomber jacket") -> OnlineRequest:
    return OnlineRequest(crop=crops(1)[0], crop_jpeg=b"", embedding=None, attributes=None, category="jacket",
                         query=query, key="a/0")


def test_shopping_maps_results_in_google_order():
    fake = FakeSerpApi({"shopping_results": [shopping_result(1), shopping_result(2, price="CA$80.00", extracted=80)]})
    result = run(shopping(fake).search(online_request(), Timer("t")))
    first, second = result.matches
    assert first.title == "Olive Nylon Bomber Jacket 1" and first.retailer == "Northwind Apparel"
    assert first.price.model_dump() == {"value": "49.99", "currency": "USD"}
    assert second.price.model_dump() == {"value": "80.00", "currency": "CAD"}
    assert first.url == "https://shop.example/item/1?utm_source=google" and first.source == "shopping"
    assert first.score > second.score
    params = fake.requests[0].url.params
    assert params["engine"] == "google_shopping" and params["q"] == "olive nylon bomber jacket"
    assert params["api_key"] == "serp-key" and params["gl"] == "us"


def test_shopping_drops_results_without_links_and_duplicates():
    duplicate = shopping_result(3)
    duplicate["link"] = "https://www.SHOP.example/item/1/?srsltid=abc"
    fake = FakeSerpApi({"shopping_results": [shopping_result(1), shopping_result(2, link=False), duplicate, shopping_result(4)]})
    matches = run(shopping(fake).search(online_request(), Timer("t"))).matches
    assert [m.title for m in matches] == ["Olive Nylon Bomber Jacket 1", "Olive Nylon Bomber Jacket 4"]


def test_shopping_uses_product_link_when_there_is_no_direct_link():
    result = shopping_result(1, link=False)
    result["product_link"] = "https://www.google.com/shopping/product/123"
    matches = run(shopping(FakeSerpApi({"shopping_results": [result]})).search(online_request(), Timer("t"))).matches
    assert matches[0].url == "https://www.google.com/shopping/product/123"


def test_shopping_keeps_top_k():
    fake = FakeSerpApi({"shopping_results": [shopping_result(n) for n in range(1, 30)]})
    assert len(run(shopping(fake, top_k=10).search(online_request(), Timer("t"))).matches) == 10


def test_no_results_is_an_empty_answer_not_an_error():
    fake = FakeSerpApi({"error": "Google hasn't returned any results for this query."})
    assert run(shopping(fake).search(online_request(), Timer("t"))).matches == []


@pytest.mark.parametrize("status, body, code", [
    (401, {"error": "Invalid API key."}, "provider_auth"),
    (429, {"error": "Your account has run out of searches."}, "provider_busy"),
    (500, {}, "provider_error"),
    (200, {"error": "Something else went wrong."}, "provider_error"),
])
def test_serpapi_errors_become_step_failures(status, body, code):
    with pytest.raises(StepFailure) as failure:
        run(shopping(FakeSerpApi(body, status)).search(online_request(), Timer("t")))
    assert failure.value.code == code


def test_unreachable_serpapi():
    def offline(request):
        raise httpx.ConnectError("offline", request=request)
    with pytest.raises(StepFailure) as failure:
        run(shopping(offline).search(online_request(), Timer("t")))
    assert failure.value.code == "provider_unreachable"


@pytest.mark.parametrize("text, extracted, country, expected", [
    ("$29.99", 29.99, "us", ("29.99", "USD")),
    ("$29.99", 29.99, "ca", ("29.99", "CAD")),
    ("€1,299.00", None, "us", ("1299.00", "EUR")),
    ("£40", 40, "us", ("40.00", "GBP")),
])
def test_prices_keep_their_currency(text, extracted, country, expected):
    price = parse_price(text, extracted, country)
    assert (price.value, price.currency) == expected


@pytest.mark.parametrize("text", [None, "", "Free", "40 kr"])
def test_unclear_prices_are_left_out(text):
    assert parse_price(text, None, "us") is None


def test_normalize_url_ignores_tracking_and_case():
    assert normalize_url("https://WWW.Shop.example/a/?utm_source=x&b=2&a=1#top") == normalize_url("https://shop.example/a?a=1&b=2")
    assert normalize_url("https://shop.example/a?id=1") != normalize_url("https://shop.example/a?id=2")


# MARK: Pipeline and app with real-shaped components

def test_build_pipeline_uses_the_keys_present():
    assert build_pipeline(Settings()) is None
    both = build_pipeline(Settings(openai_api_key="k", serpapi_key="s", segmentation=False, embeddings=False))
    assert both.components() == {"segmenter": None, "describer": "openai", "embedder": None, "catalog": None,
                                 "online_search": "serpapi-shopping"}
    only_openai = build_pipeline(Settings(openai_api_key="k", segmentation=False, embeddings=False))
    assert only_openai.online is None and only_openai.describer is not None


def test_photo_without_segmenter_is_described_as_a_whole():
    pipeline = Pipeline(None, MockDescriber(), None, None, None)
    client = TestClient(create_app(Settings(), pipeline=pipeline))
    body = client.post("/analyze", files={"image": ("p.jpg", jpeg(), "image/jpeg")}).json()
    assert [g["category"] for g in body["garments"]] == ["top", "pants"]
    assert all(g["source_label"] == WHOLE_PHOTO and g["catalog_matches"] == [] and g["errors"] == [] for g in body["garments"])
    assert "segment" not in body["timings_ms"] and "embed" not in body["timings_ms"]
    # Without online search configured, /search says so instead of failing.
    search = client.post("/search", json={"analysis_id": body["analysis_id"], "garment_index": 0})
    assert search.status_code == 503 and search.json()["error"]["code"] == "not_configured"


def test_end_to_end_crops_to_shopping_links():
    answer = json.dumps({"garments": [{"index": 0, **attrs(search_query="olive nylon bomber jacket")}]})
    subject, _ = describer(answer)
    fake = FakeSerpApi({"shopping_results": [shopping_result(1), shopping_result(2)]})
    pipeline = Pipeline(None, subject, None, None, shopping(fake))
    client = TestClient(create_app(Settings(), pipeline=pipeline))
    body = client.post("/analyze", files=[("crops", ("j.png", png_crop((95, 100, 50)), "image/png"))],
                       data={"categories": "jacket"}).json()
    garment = body["garments"][0]
    assert garment["attributes"]["search_query"] == "olive nylon bomber jacket" and garment["errors"] == []
    assert fake.requests == []  # /analyze spends no searches
    search = client.post("/search", json={"analysis_id": body["analysis_id"], "garment_index": 0}).json()
    assert search["query"] == "olive nylon bomber jacket" and len(search["online_matches"]) == 2
    assert search["online_matches"][0]["image"] == "https://serpapi.example/thumb/1.jpg"
    assert "shopping" in search["timings_ms"]
    refine = client.post("/refine", json={"analysis_id": body["analysis_id"], "garment_index": 0, "brand": "Alpha Industries"}).json()
    assert fake.requests[-1].url.params["q"] == "Alpha Industries olive nylon bomber jacket"
    assert refine["query"] == "Alpha Industries olive nylon bomber jacket"


def test_shopping_outage_still_returns_the_analysis():
    answer = json.dumps({"garments": [{"index": 0, **attrs()}]})
    subject, _ = describer(answer)
    pipeline = Pipeline(None, subject, None, None, shopping(FakeSerpApi({}, status=500)))
    client = TestClient(create_app(Settings(), pipeline=pipeline))
    body = client.post("/analyze", files=[("crops", ("j.png", png_crop((95, 100, 50)), "image/png"))]).json()
    assert body["garments"][0]["attributes"]["category"] == "jacket"
    search = client.post("/search", json={"analysis_id": body["analysis_id"], "garment_index": 0})
    assert search.status_code == 200
    assert search.json()["online_matches"] == [] and search.json()["errors"][0]["code"] == "provider_error"
