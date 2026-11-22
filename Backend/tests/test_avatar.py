import base64
from types import SimpleNamespace

import httpx
import openai
import pytest
from fastapi.testclient import TestClient

from app.main import OpenAIGenerator, Settings, create_app
from app.mock import placeholder_png
from app.prompt import build_prompt

JPEG = b"\xff\xd8\xff\xe0" + b"0" * 64
PNG = placeholder_png()


class Recorder:
    def __init__(self, result=PNG):
        self.calls, self.result = [], result

    async def generate(self, images, prompt):
        self.calls.append((images, prompt))
        return self.result


def client(generator=None, **settings):
    return TestClient(create_app(Settings(**settings), generator))


def post(c, selfie=True, height="178", weight="74.3", headers=None, body=JPEG):
    files = {"body_photo": ("b.jpg", body, "image/jpeg")}
    if selfie:
        files["selfie"] = ("s.png", PNG, "image/png")
    return c.post("/v1/avatar", files=files, data={"height_cm": height, "weight_kg": weight}, headers=headers or {})


def test_sends_body_photo_first_then_selfie_with_measurements_in_the_prompt():
    recorder = Recorder()
    response = post(client(recorder))
    assert response.status_code == 200 and response.headers["content-type"] == "image/png" and response.content == PNG
    images, prompt = recorder.calls[0]
    assert [i[0] for i in images] == ["body.jpeg", "selfie.png"] and images[0][1] == JPEG
    assert "178 cm" in prompt and "74.3 kg" in prompt and "second is a selfie" in prompt


def test_works_without_a_selfie():
    recorder = Recorder()
    assert post(client(recorder), selfie=False).status_code == 200
    images, prompt = recorder.calls[0]
    assert len(images) == 1 and "Only the full-body photo is provided" in prompt and "selfie" not in prompt


def test_prompt_targets_entered_measurements_and_uses_the_photo_for_individual_proportions():
    prompt = build_prompt(165, 82, has_selfie=False)
    assert "entered height of 165 cm and weight of 82 kg as the targets" in prompt
    assert "head-to-body and torso-to-leg proportions" in prompt
    assert "Reflect weight relative to height in the silhouette" in prompt
    assert "Adjust that baseline where needed to reflect the entered measurements" in prompt
    assert "Match the person's age, face shape, and distinguishing features" in prompt and "head to shoes" in prompt


def test_changed_measurements_generate_a_new_portrait_with_the_same_photo():
    recorder = Recorder()
    with client(recorder) as c:
        for height, weight in (("178", "74.3"), ("183", "74.3"), ("183", "90"), ("183", "90")):
            assert post(c, selfie=False, height=height, weight=weight).status_code == 200
    assert len(recorder.calls) == 3
    for (images, prompt), measurements in zip(recorder.calls, ("178 cm and weight of 74.3 kg",
                                                                "183 cm and weight of 74.3 kg",
                                                                "183 cm and weight of 90 kg"), strict=True):
        assert images[0][1] == JPEG and measurements in prompt


@pytest.mark.parametrize("height,weight", [("40", "70"), ("170", "900"), ("abc", "70")])
def test_rejects_measurements_out_of_range(height, weight):
    response = post(client(Recorder()), height=height, weight=weight)
    assert response.status_code == 400 and response.json()["error"]["code"] in ("invalid_measurements", "invalid_request")


def test_rejects_files_that_are_not_pictures_and_pictures_that_are_too_large():
    assert post(client(Recorder()), body=b"not a picture").json()["error"]["code"] == "invalid_image"
    assert post(client(Recorder()), body=JPEG + b"0" * (8 * 1024 * 1024)).status_code == 413


def test_requires_the_app_token_when_one_is_set():
    c = client(Recorder(), app_token="secret")
    assert post(c).status_code == 401
    assert post(c, headers={"Authorization": "Bearer wrong"}).status_code == 401
    assert post(c, headers={"Authorization": "Bearer secret"}).status_code == 200


def test_says_so_when_no_key_is_configured_and_never_reports_the_key():
    c = client()
    assert post(c).json()["error"]["code"] == "not_configured"
    c = client(api_key="sk-test-123")
    assert "sk-test-123" not in c.get("/health").text and c.get("/health").json()["ready"] is True


def test_limits_how_many_avatars_one_client_can_make_per_hour():
    c = client(Recorder(), rate_limit_per_hour=2)
    assert [post(c).status_code for _ in range(3)] == [200, 200, 429]


def test_mock_mode_returns_a_picture_without_a_key(monkeypatch):
    async def no_wait(_):
        return None
    monkeypatch.setattr("app.main.asyncio.sleep", no_wait)
    response = post(client(mock=True))
    assert response.status_code == 200 and response.content[:8] == b"\x89PNG\r\n\x1a\n"


class FakeImages:
    def __init__(self, outcomes):
        self.outcomes, self.calls = list(outcomes), []

    async def edit(self, **kwargs):
        self.calls.append(kwargs)
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


def status_error(kind, status, code=None):
    request = httpx.Request("POST", "https://api.openai.com/v1/images/edits")
    return kind("message", response=httpx.Response(status, request=request), body={"code": code} if code else None)


def openai_generator(outcomes, **settings):
    images = FakeImages(outcomes)
    return OpenAIGenerator(Settings(api_key="k", **settings), client=SimpleNamespace(images=images)), images


def picture():
    return SimpleNamespace(data=[SimpleNamespace(b64_json=base64.b64encode(PNG).decode())])


def test_openai_call_uses_the_configured_model_portrait_size_and_all_images():
    generator, images = openai_generator([picture()], model="gpt-image-2", quality="high")
    response = post(client(generator))
    assert response.status_code == 200 and response.content == PNG
    call = images.calls[0]
    assert call["model"] == "gpt-image-2" and call["size"] == "1024x1536" and call["quality"] == "high" and call["n"] == 1
    assert len(call["image"]) == 2 and "input_fidelity" not in call


def test_falls_back_when_the_configured_model_is_not_available():
    generator, images = openai_generator([status_error(openai.NotFoundError, 404), picture()], model="gpt-image-2.6-sunburst")
    assert post(client(generator)).status_code == 200
    assert [c["model"] for c in images.calls] == ["gpt-image-2.6-sunburst", "gpt-image-2"]


@pytest.mark.parametrize("error,status,code", [
    (status_error(openai.BadRequestError, 400, "moderation_blocked"), 422, "blocked"),
    (status_error(openai.BadRequestError, 400), 502, "upstream_rejected"),
    (status_error(openai.RateLimitError, 429), 429, "busy"),
    (status_error(openai.RateLimitError, 429, "insufficient_quota"), 502, "upstream_quota"),
    (status_error(openai.AuthenticationError, 401), 502, "upstream_auth"),
    (status_error(openai.InternalServerError, 500), 502, "upstream_error"),
    (openai.APITimeoutError(httpx.Request("POST", "https://api.openai.com")), 504, "timeout"),
])
def test_openai_failures_become_errors_the_app_can_show(error, status, code):
    generator, _ = openai_generator([error], model="gpt-image-2")
    response = post(client(generator))
    assert response.status_code == status and response.json()["error"]["code"] == code


def test_the_real_openai_client_sends_both_pictures_and_reads_the_result():
    """Runs the real OpenAI SDK against a stand-in for api.openai.com, to check the request it builds."""
    seen = {}

    def openai_api(request: httpx.Request) -> httpx.Response:
        body = request.read()
        seen.update(path=request.url.path, auth=request.headers["authorization"], body=body)
        return httpx.Response(200, json={"created": 1, "data": [{"b64_json": base64.b64encode(PNG).decode()}]})

    sdk = openai.AsyncOpenAI(api_key="sk-test", http_client=httpx.AsyncClient(transport=httpx.MockTransport(openai_api)))
    generator = OpenAIGenerator(Settings(api_key="sk-test", model="gpt-image-2", quality="medium"), client=sdk)
    response = post(client(generator))
    assert response.status_code == 200 and response.content == PNG
    assert seen["path"].endswith("/images/edits") and seen["auth"] == "Bearer sk-test"
    body = seen["body"]
    assert body.count(b'name="image[]"') == 2 and body.index(b'filename="body.jpeg"') < body.index(b'filename="selfie.png"')
    assert JPEG in body and b'name="model"' in body and b"gpt-image-2" in body and b"1024x1536" in body
    assert b"178 cm" in body and b"74.3 kg" in body
    assert b"photorealistic, full-body studio photograph" in body
    assert b"realistic skin texture" in body and b"3D animated-style" not in body
