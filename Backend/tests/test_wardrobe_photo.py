import asyncio
import base64
from types import SimpleNamespace

from fastapi.testclient import TestClient

from app.image_results import ImageResult, ImageResults
from app.main import ApiError, Settings, create_app
from app.outfit_match import OpenAIVisualSearch, OutfitMatcher, WardrobeIdentification

from .test_avatar import JPEG, PNG, Recorder


class Detector:
    def __init__(self, category, clear_subject=True):
        self.result = WardrobeIdentification(category=category, clear_subject=clear_subject)
        self.calls = []

    async def identify_wardrobe_item(self, photo, media):
        self.calls.append((photo, media))
        return self.result


def post(detector, generator):
    client = TestClient(create_app(Settings(), generator=generator, wardrobe_analysis=detector))
    return client.post("/v1/wardrobe-photo", files={"photo": ("phone.jpg", JPEG, "image/jpeg")})


def test_identifies_outerwear_from_the_original_and_requests_a_straightened_catalog_photo():
    detector, generator = Detector("outerwear"), Recorder()
    response = post(detector, generator)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == {"category": "outerwear", "image": base64.b64encode(PNG).decode(), "message": None}
    assert detector.calls == [(JPEG, "image/jpeg")]
    images, prompt = generator.calls[0]
    assert images == [("garment.jpeg", JPEG, "image/jpeg")]
    assert all(text in prompt for text in ("sleeves extended", "align and close it", "visible logos", "pure white"))


def test_unclear_photo_does_not_spend_an_image_generation():
    generator = Recorder()
    result = post(Detector(None, clear_subject=False), generator).json()
    assert result["category"] is None and result["image"] is None
    assert "single item or one pair of shoes" in result["message"]
    assert not generator.calls


def test_category_can_be_confirmed_when_the_image_edit_fails():
    class Failure:
        async def generate(self, images, prompt):
            raise ApiError(502, "upstream_quota", "Provider unavailable.")

    result = post(Detector("shoes"), Failure()).json()
    assert result["category"] == "shoes" and result["image"] is None
    assert "Try again" in result["message"]


def test_unknown_category_of_clear_item_keeps_manual_selection():
    result = post(Detector(None), Recorder()).json()
    assert result["category"] is None and result["image"] is not None


def test_wardrobe_photo_uses_openai_when_retailer_discovery_is_unconfigured():
    async def parse(**request):
        assert request["text_format"] is WardrobeIdentification
        assert request["store"] is False
        assert request["input"][0]["content"][0]["image_url"].startswith("data:image/jpeg;base64,")
        return SimpleNamespace(output_parsed=WardrobeIdentification(category="outerwear", clear_subject=True))

    analysis = OpenAIVisualSearch("", "fixture", SimpleNamespace(responses=SimpleNamespace(parse=parse)))
    outfit = OutfitMatcher(analysis, discovery=None)
    client = TestClient(create_app(Settings(), generator=Recorder(), outfit=outfit))
    assert client.get("/health").json()["outfit_match"]["ready"] is False
    response = client.post("/v1/wardrobe-photo", files={"photo": ("phone.jpg", JPEG, "image/jpeg")})
    assert response.status_code == 200
    assert response.json()["category"] == "outerwear"
    assert response.json()["image"] is not None


def test_identical_shots_reuse_result_and_regenerate_requests_a_new_one():
    detector, generator = Detector("outerwear"), Recorder()
    client = TestClient(create_app(Settings(), generator=generator, wardrobe_analysis=detector))
    photo = {"photo": ("phone.jpg", JPEG, "image/jpeg")}
    first = client.post("/v1/wardrobe-photo", files=photo, headers={"Accept": "image/*"})
    second = client.post("/v1/wardrobe-photo", files=photo)
    assert first.content == PNG
    assert first.headers["X-FitMix-Wardrobe-Category"] == "outerwear"
    assert first.headers["X-FitMix-Result"] == "generated"
    assert second.headers["X-FitMix-Result"] == "cached"
    assert len(detector.calls) == len(generator.calls) == 1
    third = client.post("/v1/wardrobe-photo", files=photo, data={"regenerate": "true"})
    assert third.headers["X-FitMix-Result"] == "generated"
    assert len(detector.calls) == len(generator.calls) == 2
    scoped = client.post("/v1/wardrobe-photo", files=photo, headers={"X-FitMix-Image-Scope": "other-account"})
    assert scoped.headers["X-FitMix-Result"] == "generated"


def test_revisiting_a_screen_can_join_a_request_after_the_first_caller_leaves():
    async def exercise():
        results = ImageResults()
        started, release = asyncio.Event(), asyncio.Event()
        calls = 0

        async def generate():
            nonlocal calls
            calls += 1
            started.set()
            await release.wait()
            return ImageResult(PNG)

        caller = asyncio.create_task(results.get(b"portrait-and-outfit", generate, regenerate=False))
        await started.wait()
        caller.cancel()
        await asyncio.gather(caller, return_exceptions=True)

        another_caller = asyncio.create_task(results.get(b"portrait-and-outfit", generate, regenerate=False))
        await asyncio.sleep(0)
        release.set()
        assert await another_caller == (ImageResult(PNG), "joined")
        assert await results.get(b"portrait-and-outfit", generate, regenerate=False) == (ImageResult(PNG), "cached")
        assert calls == 1

    asyncio.run(exercise())
