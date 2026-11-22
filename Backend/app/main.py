"""FitMix backend: avatar portraits, and retailer matches for a garment selected in the live camera.

- `POST /v1/avatar`: the app posts the user's photos; this server adds the instruction and calls OpenAI's Image
  Edits API.
- `POST /v1/garment-match`: the app posts one garment's crop and category; this server searches a retailer
  catalog (eBay Browse API) and returns real listings in that category, or, with FITMIX_MATCH_PROVIDER=vision,
  forwards the crop to the FitMix vision service (Google Lens + Google Shopping, re-ranked).

Provider keys live only in this process's environment. Images are held in memory for the length of one request:
they are never written to disk and never logged.
"""

import asyncio
import base64
import hmac
import logging
import os
import time
import uuid
from collections import defaultdict, deque
from dataclasses import dataclass, field
from typing import Protocol

import openai
from fastapi import Depends, FastAPI, File, Form, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response

from .mock import placeholder_png
from .prompt import build_prompt
from .retail import CATEGORIES, EbayMatcher, FixtureMatcher, Matcher, MatchError
from .vision import VisionMatcher

log = logging.getLogger("fitmix")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_CROP_BYTES = 2 * 1024 * 1024
HEIGHT_RANGE_CM = (100.0, 250.0)
WEIGHT_RANGE_KG = (30.0, 300.0)
# Used when the configured model is not available to this OpenAI account.
FALLBACK_MODEL = "gpt-image-2"


@dataclass(frozen=True)
class Settings:
    api_key: str = field(default="", repr=False)
    model: str = "gpt-image-2.6-sunburst"
    quality: str = "medium"
    size: str = "1024x1536"
    timeout_seconds: float = 240.0
    app_token: str = field(default="", repr=False)
    mock: bool = False
    rate_limit_per_hour: int = 20
    ebay_client_id: str = field(default="", repr=False)
    ebay_client_secret: str = field(default="", repr=False)
    ebay_marketplace: str = "EBAY_US"
    # "ebay" (real listings, needs the keys above), "fixture" (labeled test data, no keys, nothing sent), or
    # "vision" (Google Lens + Shopping through the FitMix vision service in vision-service/).
    match_provider: str = "ebay"
    vision_service_url: str = "http://localhost:8790"
    vision_app_token: str = field(default="", repr=False)
    match_rate_limit_per_hour: int = 120

    @staticmethod
    def from_environment() -> "Settings":
        env = os.environ
        return Settings(
            api_key=env.get("OPENAI_API_KEY", "").strip(),
            model=env.get("OPENAI_IMAGE_MODEL", "").strip() or Settings.model,
            quality=env.get("OPENAI_IMAGE_QUALITY", "").strip() or Settings.quality,
            size=env.get("OPENAI_IMAGE_SIZE", "").strip() or Settings.size,
            timeout_seconds=float(env.get("OPENAI_TIMEOUT_SECONDS", "") or Settings.timeout_seconds),
            app_token=env.get("FITMIX_APP_TOKEN", "").strip(),
            mock=env.get("FITMIX_MOCK", "").strip().lower() in ("1", "true", "yes"),
            rate_limit_per_hour=int(env.get("FITMIX_RATE_LIMIT_PER_HOUR", "") or Settings.rate_limit_per_hour),
            ebay_client_id=env.get("EBAY_CLIENT_ID", "").strip(),
            ebay_client_secret=env.get("EBAY_CLIENT_SECRET", "").strip(),
            ebay_marketplace=env.get("EBAY_MARKETPLACE_ID", "").strip() or Settings.ebay_marketplace,
            match_provider=env.get("FITMIX_MATCH_PROVIDER", "").strip().lower() or Settings.match_provider,
            match_rate_limit_per_hour=int(env.get("FITMIX_MATCH_RATE_LIMIT_PER_HOUR", "") or Settings.match_rate_limit_per_hour),
            vision_service_url=env.get("VISION_SERVICE_URL", "").strip() or Settings.vision_service_url,
            vision_app_token=env.get("VISION_APP_TOKEN", "").strip(),
        )


class ApiError(Exception):
    """An error the app can show. `code` is stable; `message` is written for the person using the app."""

    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


ImageFile = tuple[str, bytes, str]  # file name, contents, media type


class Generator(Protocol):
    async def generate(self, images: list[ImageFile], prompt: str) -> bytes: ...


class MockGenerator:
    """Returns a placeholder picture after a short pause. Nothing leaves this machine."""

    async def generate(self, images: list[ImageFile], prompt: str) -> bytes:
        await asyncio.sleep(2)
        return placeholder_png()


class OpenAIGenerator:
    def __init__(self, settings: Settings, client: openai.AsyncOpenAI | None = None):
        self.settings = settings
        self.client = client or openai.AsyncOpenAI(api_key=settings.api_key, timeout=settings.timeout_seconds, max_retries=1)

    async def generate(self, images: list[ImageFile], prompt: str) -> bytes:
        try:
            try:
                result = await self._edit(self.settings.model, images, prompt)
            except openai.NotFoundError:
                if self.settings.model == FALLBACK_MODEL:
                    raise
                log.warning("model %s is not available to this account; using %s", self.settings.model, FALLBACK_MODEL)
                result = await self._edit(FALLBACK_MODEL, images, prompt)
        except openai.APITimeoutError:
            raise ApiError(504, "timeout", "Creating the avatar took too long. Try again.")
        except openai.APIConnectionError:
            raise ApiError(502, "upstream_unreachable", "The server couldn't reach OpenAI. Try again in a moment.")
        except openai.RateLimitError as error:
            if getattr(error, "code", None) == "insufficient_quota":
                raise ApiError(502, "upstream_quota", "The OpenAI account behind FitMix is out of credit.")
            raise ApiError(429, "busy", "The avatar service is busy. Try again in a minute.")
        except (openai.AuthenticationError, openai.PermissionDeniedError):
            raise ApiError(502, "upstream_auth", "OpenAI refused the server's key, or the account isn't verified for image models.")
        except openai.BadRequestError as error:
            if getattr(error, "code", None) == "moderation_blocked":
                raise ApiError(422, "blocked", "OpenAI declined to create an image from these photos. Try different photos.")
            log.warning("OpenAI rejected the request: %s", getattr(error, "code", None) or type(error).__name__)
            raise ApiError(502, "upstream_rejected", "OpenAI couldn't use these photos. Try different photos.")
        except openai.APIStatusError as error:
            log.warning("OpenAI error %s", error.status_code)
            raise ApiError(502, "upstream_error", "OpenAI had a problem creating the avatar. Try again.")
        encoded = result.data[0].b64_json if result.data else None
        if not encoded:
            raise ApiError(502, "upstream_empty", "OpenAI returned no image. Try again.")
        return base64.b64decode(encoded)

    async def _edit(self, model: str, images: list[ImageFile], prompt: str):
        options = {}
        if model.startswith("gpt-image-1.5"):
            options["input_fidelity"] = "high"  # keeps faces closer to the reference; newer models do this themselves
        return await self.client.images.edit(model=model, image=images, prompt=prompt, size=self.settings.size,
                                             quality=self.settings.quality, n=1, **options)


def default_matcher(settings: Settings) -> Matcher | None:
    if settings.match_provider == "fixture":
        return FixtureMatcher()
    if settings.match_provider == "vision":
        return VisionMatcher(settings.vision_service_url, settings.vision_app_token)
    if settings.match_provider == "ebay" and settings.ebay_client_id and settings.ebay_client_secret:
        return EbayMatcher(settings.ebay_client_id, settings.ebay_client_secret, settings.ebay_marketplace)
    return None


def create_app(settings: Settings | None = None, generator: Generator | None = None,
               matcher: Matcher | None = None) -> FastAPI:
    settings = settings or Settings.from_environment()
    if generator is None:
        if settings.mock:
            generator = MockGenerator()
        elif settings.api_key:
            generator = OpenAIGenerator(settings)
    if matcher is None:
        matcher = default_matcher(settings)
    app = FastAPI(title="FitMix backend", docs_url=None, redoc_url=None, openapi_url=None)
    recent: dict[tuple[str, str], deque[float]] = defaultdict(deque)

    @app.exception_handler(ApiError)
    async def api_error(_: Request, error: ApiError):
        return JSONResponse(status_code=error.status, content={"error": {"code": error.code, "message": error.message}})

    @app.exception_handler(RequestValidationError)
    async def invalid(_: Request, error: RequestValidationError):
        return JSONResponse(status_code=400, content={"error": {"code": "invalid_request", "message": "The request was incomplete."}})

    def limiter(bucket: str, limit: int, service: str, too_many: str):
        def authorize(request: Request) -> str:
            if settings.app_token:
                sent = request.headers.get("authorization", "")
                if not hmac.compare_digest(sent, f"Bearer {settings.app_token}"):
                    raise ApiError(401, "unauthorized", f"This copy of FitMix isn't allowed to use the {service}.")
            client = request.client.host if request.client else "unknown"
            now = time.monotonic()
            window = recent[(bucket, client)]
            while window and now - window[0] > 3600:
                window.popleft()
            if len(window) >= limit:
                raise ApiError(429, "rate_limited", too_many)
            window.append(now)
            return client
        return authorize

    authorize = limiter("avatar", settings.rate_limit_per_hour, "avatar service",
                        "You've made a lot of avatars in the last hour. Try again later.")
    authorize_match = limiter("match", settings.match_rate_limit_per_hour, "product search",
                              "You've searched a lot in the last hour. Try again later.")

    @app.get("/health")
    async def health():
        return {"status": "ok", "ready": generator is not None, "mock": settings.mock,
                "match_ready": matcher is not None, "match_provider": matcher.name if matcher else None}

    @app.post("/v1/garment-match")
    async def garment_match(
        crop: UploadFile = File(...),
        category: str = Form(...),
        color: str | None = Form(None),
        brand_hints: str | None = Form(None),
        _: str = Depends(authorize_match),
    ):
        if category not in CATEGORIES:
            raise ApiError(400, "invalid_category", "FitMix can search for a jacket, T-shirt, pants or shoes.")
        if matcher is None:
            raise ApiError(503, "not_configured",
                           "Retailer search isn't set up yet: the server has no eBay API keys (EBAY_CLIENT_ID, EBAY_CLIENT_SECRET).")
        data = await crop.read(MAX_CROP_BYTES + 1)
        if len(data) > MAX_CROP_BYTES:
            raise ApiError(413, "image_too_large", "The garment image is too large to send.")
        if _media_type(data) is None:
            raise ApiError(400, "invalid_image", "The garment image isn't a JPEG, PNG or WebP picture.")
        hints = [h.strip().lower() for h in (brand_hints or "").split(",") if h.strip()][:3]
        color = (color or "").strip().lower()[:20] or None

        started = time.monotonic()
        try:
            results = await matcher.search(category, data, color, hints)
        except MatchError as error:
            log.info("match %s: failed (%s) after %.1fs", category, error.code, time.monotonic() - started)
            raise ApiError(error.status, error.code, error.message)
        log.info("match %s: %d KB crop, %d result(s) in %.1fs", category, len(data) // 1024, len(results),
                 time.monotonic() - started)
        return JSONResponse({"status": "matched" if results else "no_match", "category": category,
                             "provider": matcher.name, "fixture": matcher.fixture,
                             "results": [r.to_json() for r in results]}, headers={"Cache-Control": "no-store"})

    @app.post("/v1/avatar")
    async def create_avatar(
        body_photo: UploadFile = File(...),
        selfie: UploadFile | None = File(None),
        height_cm: float = Form(...),
        weight_kg: float = Form(...),
        _: str = Depends(authorize),
    ):
        if generator is None:
            raise ApiError(503, "not_configured", "The avatar service isn't set up yet: the server has no OpenAI key.")
        if not HEIGHT_RANGE_CM[0] <= height_cm <= HEIGHT_RANGE_CM[1] or not WEIGHT_RANGE_KG[0] <= weight_kg <= WEIGHT_RANGE_KG[1]:
            raise ApiError(400, "invalid_measurements", "Height or weight is outside the range FitMix supports.")
        # The full-body photo goes first: it is the main reference.
        images = [await _read_image(body_photo, "full-body photo", "body")]
        if selfie is not None:
            images.append(await _read_image(selfie, "selfie", "selfie"))
        prompt = build_prompt(height_cm, weight_kg, has_selfie=len(images) > 1)

        request_id = uuid.uuid4().hex[:8]
        started = time.monotonic()
        log.info("avatar %s: %d image(s), %d KB", request_id, len(images), sum(len(i[1]) for i in images) // 1024)
        try:
            picture = await generator.generate(images, prompt)
        except ApiError as error:
            log.info("avatar %s: failed (%s) after %.1fs", request_id, error.code, time.monotonic() - started)
            raise
        log.info("avatar %s: done in %.1fs", request_id, time.monotonic() - started)
        return Response(content=picture, media_type=_media_type(picture) or "image/png", headers={"Cache-Control": "no-store"})

    return app


def _media_type(data: bytes) -> str | None:
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


async def _read_image(upload: UploadFile, label: str, name: str) -> ImageFile:
    data = await upload.read(MAX_IMAGE_BYTES + 1)
    if len(data) > MAX_IMAGE_BYTES:
        raise ApiError(413, "image_too_large", f"The {label} is too large to send.")
    media_type = _media_type(data)
    if media_type is None:
        raise ApiError(400, "invalid_image", f"The {label} isn't a JPEG, PNG or WebP picture.")
    return (f"{name}.{media_type.split('/')[1]}", data, media_type)


app = create_app()
