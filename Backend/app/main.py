"""FitMix backend: avatar portraits, 3D avatars, and retailer matches for a garment selected in the live camera.

- `POST /v1/avatar`: the app posts the user's photos; this server adds the instruction and calls OpenAI's Image
  Edits API.
- `POST /v1/avatar-3d`: the app posts the accepted portrait; this server builds a 3D model from it on this
  computer (see avatar3d.py) and the app collects it when it is ready.
- `POST /v1/garment-match`: the app posts one garment's crop, category and the clues read on the phone; this
  server asks every enabled visual search provider, reads the listing pages, and returns ranked real listings
  labeled "exact", "brand" or "similar" (see visual_search.py).
- `POST /v1/outfit-match`: Studio's product search. OpenAI searches the web from the garment's photo and
  description, and this server reads the pages it finds and ranks them by their photos (see outfit_match.py).
- `POST /v1/lens-search`: legacy compatibility route for older app builds. This server asks Google
  Lens (via Scrappa) for visual matches and returns the best credible retailer listing, labeled "similar"
  (see lens_search.py). Cached, de-duplicated and capped per month.

Provider keys live only in this process's environment. Images are held in memory for the length of one request
and never logged. The one exception is a 3D avatar build, whose tools read files: the portrait sits in a private
temporary folder until that build ends.
"""

import asyncio
import base64
import hmac
import logging
import os
import time
import uuid
from pathlib import Path
from collections import defaultdict, deque
from dataclasses import dataclass, field, replace
from typing import Protocol

import openai
from fastapi import Depends, FastAPI, File, Form, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response

from . import avatar3d
from .mock import placeholder_png
from .image_results import ImageResult, ImageResults, image_key
from .outfit_match import (MAX_PER_STORE, OpenAIVisualSearch, OpenAIWebSearch, OutfitMatcher, SearchMode,
                           WardrobeIdentification, brand_key)
from .retailer_product import CURRENCY, Department, price
from .prompt import build_catalog_prompt, build_outfit_prompt, build_prompt
from .lens_search import LensSearch, LensUnavailable
from .listing import ListingEnricher
from .providers import CropHost, EbayProvider, FixtureProvider, ScrappaLensProvider
from .retail import EbayMatcher
from .visual_search import CATEGORIES, Clues, Enricher, ProviderError, VisualProvider, search_all

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "visual.json"
# Lens usage counter and cached answers (no images). Ignored by Git.
LENS_STATE_PATH = Path(__file__).parent.parent / ".cache" / "lens_search.json"

log = logging.getLogger("fitmix")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
# Storefront query URLs can include codes read from garments.
logging.getLogger("httpx").setLevel(logging.WARNING)

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
    preview_model: str = "gpt-image-2.6-flare"
    matching_model: str = "gpt-4.1-mini"
    quality: str = "medium"
    preview_quality: str = "low"
    size: str = "1024x1536"
    timeout_seconds: float = 240.0
    app_token: str = field(default="", repr=False)
    mock: bool = False
    rate_limit_per_hour: int = 20
    ebay_client_id: str = field(default="", repr=False)
    ebay_client_secret: str = field(default="", repr=False)
    ebay_marketplace: str = "EBAY_US"
    # Which providers receive garment crops, in FITMIX_VISUAL_PROVIDERS (comma-separated): ebay, google_lens,
    # fixture. Default: eBay when its keys are set. google_lens (Scrappa) is never on unless listed here.
    visual_providers: tuple[str, ...] = ("ebay",)
    scrappa_api_key: str = field(default="", repr=False)
    # An https address of this server that Scrappa can reach, to fetch the crop it is asked about.
    public_base_url: str = ""
    # Read listing pages for photo, price, currency, brand and codes.
    listing_enrichment: bool = True
    match_rate_limit_per_hour: int = 120
    # Most Google Lens calls per calendar month (UTC). Scrappa's free tier is 500 credits a month.
    lens_monthly_limit: int = 100
    # How long a Lens answer for the same crop is reused, in hours.
    lens_cache_hours: float = 168.0
    # A 3D avatar takes minutes of this computer's GPU, so fewer are allowed per hour than portraits.
    avatar3d_rate_limit_per_hour: int = 6

    @staticmethod
    def from_environment() -> "Settings":
        env = os.environ
        return Settings(
            api_key=env.get("OPENAI_API_KEY", "").strip(),
            model=env.get("OPENAI_IMAGE_MODEL", "").strip() or Settings.model,
            preview_model=env.get("FITMIX_PREVIEW_IMAGE_MODEL", "").strip() or Settings.preview_model,
            matching_model=env.get("OPENAI_MATCH_MODEL", "").strip() or Settings.matching_model,
            quality=env.get("OPENAI_IMAGE_QUALITY", "").strip() or Settings.quality,
            preview_quality=env.get("FITMIX_PREVIEW_IMAGE_QUALITY", "").strip() or Settings.preview_quality,
            size=env.get("OPENAI_IMAGE_SIZE", "").strip() or Settings.size,
            timeout_seconds=float(env.get("OPENAI_TIMEOUT_SECONDS", "") or Settings.timeout_seconds),
            app_token=env.get("FITMIX_APP_TOKEN", "").strip(),
            mock=env.get("FITMIX_MOCK", "").strip().lower() in ("1", "true", "yes"),
            rate_limit_per_hour=int(env.get("FITMIX_RATE_LIMIT_PER_HOUR", "") or Settings.rate_limit_per_hour),
            ebay_client_id=env.get("EBAY_CLIENT_ID", "").strip(),
            ebay_client_secret=env.get("EBAY_CLIENT_SECRET", "").strip(),
            ebay_marketplace=env.get("EBAY_MARKETPLACE_ID", "").strip() or Settings.ebay_marketplace,
            visual_providers=_provider_list(env),
            scrappa_api_key=env.get("SCRAPPA_API_KEY", "").strip(),
            public_base_url=env.get("FITMIX_PUBLIC_BASE_URL", "").strip(),
            listing_enrichment=env.get("FITMIX_LISTING_ENRICHMENT", "1").strip().lower() not in ("0", "false", "no"),
            match_rate_limit_per_hour=int(env.get("FITMIX_MATCH_RATE_LIMIT_PER_HOUR", "") or Settings.match_rate_limit_per_hour),
            lens_monthly_limit=int(env.get("FITMIX_LENS_MONTHLY_LIMIT", "") or Settings.lens_monthly_limit),
            lens_cache_hours=float(env.get("FITMIX_LENS_CACHE_HOURS", "") or Settings.lens_cache_hours),
            avatar3d_rate_limit_per_hour=int(env.get("FITMIX_AVATAR3D_RATE_LIMIT_PER_HOUR", "") or Settings.avatar3d_rate_limit_per_hour),
        )


class ApiError(Exception):
    """An error the app can show. `code` is stable; `message` is written for the person using the app."""

    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


ImageFile = tuple[str, bytes, str]  # file name, contents, media type


class Generator(Protocol):
    async def generate(self, images: list[ImageFile], prompt: str) -> bytes: ...


class WardrobeAnalyzing(Protocol):
    async def identify_wardrobe_item(self, photo: bytes, media: str) -> WardrobeIdentification: ...


class MockGenerator:
    """Returns a placeholder picture after a short pause. Nothing leaves this machine."""

    async def generate(self, images: list[ImageFile], prompt: str) -> bytes:
        await asyncio.sleep(2)
        return placeholder_png()


class OpenAIGenerator:
    def __init__(self, settings: Settings, client: openai.AsyncOpenAI | None = None, *, jpeg: bool = False):
        self.settings = settings
        self.jpeg = jpeg
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
        options = {"output_format": "jpeg", "output_compression": 90} if self.jpeg else {}
        if model.startswith("gpt-image-1.5"):
            options["input_fidelity"] = "high"  # keeps faces closer to the reference; newer models do this themselves
        return await self.client.images.edit(model=model, image=images, prompt=prompt, size=self.settings.size,
                                             quality=self.settings.quality, n=1, **options)


def _provider_list(env) -> tuple[str, ...]:
    listed = env.get("FITMIX_VISUAL_PROVIDERS", "").strip()
    if not listed:  # older setting: FITMIX_MATCH_PROVIDER=ebay|fixture
        listed = env.get("FITMIX_MATCH_PROVIDER", "").strip() or "ebay"
    return tuple(p.strip().lower() for p in listed.split(",") if p.strip())


def default_providers(settings: Settings, crop_host: CropHost) -> tuple[list[VisualProvider], list[dict]]:
    """The providers that can run, plus why any listed one can't."""
    ready, skipped = [], []
    for name in settings.visual_providers:
        if name == "fixture":
            ready.append(FixtureProvider(FIXTURE_PATH))
        elif name == "ebay":
            if settings.ebay_client_id and settings.ebay_client_secret:
                ready.append(EbayProvider(EbayMatcher(settings.ebay_client_id, settings.ebay_client_secret, settings.ebay_marketplace)))
            else:
                skipped.append({"name": "ebay", "status": "skipped", "message": "EBAY_CLIENT_ID / EBAY_CLIENT_SECRET not set"})
        elif name in ("google_lens", "scrappa"):
            if not settings.scrappa_api_key:
                skipped.append({"name": "google_lens", "status": "skipped", "message": "SCRAPPA_API_KEY not set"})
            elif not settings.public_base_url.startswith("https://"):
                skipped.append({"name": "google_lens", "status": "skipped",
                                "message": "FITMIX_PUBLIC_BASE_URL must be an https address Scrappa can reach"})
            else:
                ready.append(ScrappaLensProvider(settings.scrappa_api_key, settings.public_base_url, crop_host))
        else:
            skipped.append({"name": name, "status": "skipped", "message": "unknown provider"})
    return ready, skipped


def default_lens_search(settings: Settings, crop_host: CropHost, enricher: Enricher | None,
                          state_path: Path | None = LENS_STATE_PATH) -> LensSearch:
    """Google Lens product search. Independent of FITMIX_VISUAL_PROVIDERS: it only needs the key and an https
    address Scrappa can fetch the crop from."""
    missing = None
    if not settings.scrappa_api_key:
        missing = "SCRAPPA_API_KEY not set"
    elif not settings.public_base_url.startswith("https://"):
        missing = "FITMIX_PUBLIC_BASE_URL must be an https address Scrappa can reach"
    provider = None if missing else ScrappaLensProvider(settings.scrappa_api_key, settings.public_base_url, crop_host,
                                                        search_type="visual_matches")
    return LensSearch(provider, enricher, not_configured=missing, monthly_limit=settings.lens_monthly_limit,
                        cache_ttl=settings.lens_cache_hours * 3600, state_path=state_path)


def create_app(settings: Settings | None = None, generator: Generator | None = None,
               providers: list[VisualProvider] | None = None, enricher: Enricher | None = None,
               crop_host: CropHost | None = None, lens: LensSearch | None = None,
               builder: avatar3d.Builder | None = None, outfit: OutfitMatcher | None = None,
               wardrobe_analysis: WardrobeAnalyzing | None = None) -> FastAPI:
    settings = settings or Settings.from_environment()
    if builder is None:
        builder = avatar3d.MockBuilder() if settings.mock else avatar3d.ScriptBuilder()
    builds = avatar3d.Jobs(builder)
    if generator is None:
        if settings.mock:
            generator = MockGenerator()
        elif settings.api_key:
            generator = OpenAIGenerator(settings)
    crop_host = crop_host or CropHost()
    skipped: list[dict] = []
    if providers is None:
        providers, skipped = default_providers(settings, crop_host)
    if enricher is None and settings.listing_enrichment:
        enricher = ListingEnricher()
    lens = lens or default_lens_search(settings, crop_host, enricher)
    if outfit is None:
        analysis = OpenAIVisualSearch(settings.api_key, settings.matching_model) if settings.api_key else None
        outfit = OutfitMatcher(analysis, OpenAIWebSearch(analysis) if analysis else None, per_store=MAX_PER_STORE)
    if wardrobe_analysis is None and not settings.mock and isinstance(outfit.analysis, OpenAIVisualSearch):
        wardrobe_analysis = outfit.analysis
    if isinstance(generator, OpenAIGenerator):
        preview_settings = replace(settings, model=settings.preview_model, quality=settings.preview_quality)
        preview_generator = OpenAIGenerator(preview_settings, client=generator.client, jpeg=True)
        catalog_generator = OpenAIGenerator(replace(preview_settings, size="1024x1024"), client=generator.client, jpeg=True)
    else:
        preview_generator = catalog_generator = generator
    image_results = ImageResults()

    def scoped_image_key(request: Request, operation: str, prompt: str, images: list[ImageFile]) -> bytes:
        client = request.client.host if request.client else "unknown"
        scope = request.headers.get("X-FitMix-Image-Scope", "")[:128] or client
        return image_key(scope, operation, prompt, images)

    async def render_image(generator: Generator, images: list[ImageFile], prompt: str) -> ImageResult:
        start = time.perf_counter()
        picture = await generator.generate(images, prompt)
        return ImageResult(picture, generation_ms=(time.perf_counter() - start) * 1000)

    app = FastAPI(title="FitMix backend", docs_url=None, redoc_url=None, openapi_url=None)
    recent: dict[tuple[str, str], deque[float]] = defaultdict(deque)

    @app.exception_handler(ApiError)
    async def api_error(_: Request, error: ApiError):
        return JSONResponse(status_code=error.status, content={"error": {"code": error.code, "message": error.message}})

    @app.exception_handler(RequestValidationError)
    async def invalid(_: Request, error: RequestValidationError):
        return JSONResponse(status_code=400, content={"error": {"code": "invalid_request", "message": "The request was incomplete."}})

    def known_app(request: Request, service: str) -> str:
        if settings.app_token:
            sent = request.headers.get("authorization", "")
            if not hmac.compare_digest(sent, f"Bearer {settings.app_token}"):
                raise ApiError(401, "unauthorized", f"This copy of FitMix isn't allowed to use the {service}.")
        return request.client.host if request.client else "unknown"

    def limiter(bucket: str, limit: int, service: str, too_many: str):
        def authorize(request: Request) -> str:
            client = known_app(request, service)
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
    authorize_build = limiter("avatar3d", settings.avatar3d_rate_limit_per_hour, "3D avatar service",
                              "You've built a lot of 3D avatars in the last hour. Try again later.")

    def follow_build(request: Request) -> str:
        """Checking on a build is not rate limited, only starting one."""
        return known_app(request, "3D avatar service")

    @app.get("/health")
    async def health():
        return {"status": "ok", "ready": generator is not None, "mock": settings.mock,
                "avatar3d_ready": builder.ready,
                "match_ready": bool(providers), "match_providers": [p.name for p in providers],
                "match_skipped": skipped, "lens_search": lens.status(),
                "outfit_match": {"ready": outfit.ready, "currency": CURRENCY, "discovery": "openai_web_search"}}

    @app.get("/v1/crops/{token}.jpg")
    async def crop_for_provider(token: str):
        """A garment crop published for an image-URL provider (Scrappa). Unguessable, short-lived, few fetches."""
        data = crop_host.fetch(token)
        if data is None:
            return Response(status_code=404)
        return Response(content=data, media_type=_media_type(data) or "image/jpeg", headers={"Cache-Control": "no-store"})

    @app.post("/v1/garment-match")
    async def garment_match(
        crop: UploadFile = File(...),
        category: str = Form(...),
        color: str | None = Form(None),
        brand_hints: str | None = Form(None),
        text: str | None = Form(None),
        pattern: str | None = Form(None),
        style: str | None = Form(None),
        _: str = Depends(authorize_match),
    ):
        if category not in CATEGORIES:
            raise ApiError(400, "invalid_category", "FitMix can search for a jacket, T-shirt, pants or shoes.")
        if not providers:
            reasons = "; ".join(f"{s['name']}: {s['message']}" for s in skipped) or "no provider is enabled"
            raise ApiError(503, "not_configured", f"Retailer search isn't set up yet ({reasons}).")
        data = await crop.read(MAX_CROP_BYTES + 1)
        if len(data) > MAX_CROP_BYTES:
            raise ApiError(413, "image_too_large", "The garment image is too large to send.")
        if _media_type(data) is None:
            raise ApiError(400, "invalid_image", "The garment image isn't a JPEG, PNG or WebP picture.")

        def words(value: str | None, limit: int) -> list[str]:
            return [w.strip().lower()[:40] for w in (value or "").split(",") if w.strip()][:limit]

        clues = Clues(category=category, color=(color or "").strip().lower()[:20] or None,
                      brand_hints=words(brand_hints, 3), text=words(text, 12),
                      pattern=(pattern or "").strip().lower()[:30] or None, style=(style or "").strip().lower()[:30] or None)
        started = time.monotonic()
        try:
            outcome = await search_all(providers, data, clues, enricher)
        except ProviderError as error:
            log.info("match %s: failed (%s) after %.1fs", category, error.code, time.monotonic() - started)
            status = 504 if error.code == "provider_timeout" else 503 if error.code == "provider_busy" else 502
            raise ApiError(status, error.code if not error.retryable or error.code.startswith("provider_") else "provider_error",
                           error.message)
        tiers = [r.tier for r in outcome.results]
        log.info("match %s: %d KB crop, %d result(s) %s in %.1fs", category, len(data) // 1024, len(tiers),
                 {t: tiers.count(t) for t in set(tiers)}, time.monotonic() - started)
        return JSONResponse({"status": "matched" if outcome.results else "no_match", "category": category,
                             "fixture": any(r.candidate.fixture for r in outcome.results),
                             "providers": outcome.providers + skipped,
                             "results": [r.to_json() for r in outcome.results]}, headers={"Cache-Control": "no-store"})

    @app.post("/v1/lens-search")
    async def lens_search(
        crop: UploadFile = File(...),
        category: str = Form(...),
        color: str | None = Form(None),
        text: str | None = Form(None),
        pattern: str | None = Form(None),
        style: str | None = Form(None),
        _: str = Depends(authorize_match),
    ):
        if category not in CATEGORIES:
            raise ApiError(400, "invalid_category", "FitMix can search for a jacket, T-shirt, pants or shoes.")
        data = await crop.read(MAX_CROP_BYTES + 1)
        if len(data) > MAX_CROP_BYTES:
            raise ApiError(413, "image_too_large", "The garment image is too large to send.")
        if _media_type(data) is None:
            raise ApiError(400, "invalid_image", "The garment image isn't a JPEG, PNG or WebP picture.")
        clues = Clues(category=category, color=(color or "").strip().lower()[:20] or None,
                      text=[w.strip().lower()[:40] for w in (text or "").split(",") if w.strip()][:12],
                      pattern=(pattern or "").strip().lower()[:30] or None, style=(style or "").strip().lower()[:30] or None)
        started = time.monotonic()
        try:
            answer = await lens.search(data, clues)
        except LensUnavailable as error:
            log.info("lens %s: not called (%s)", category, error.code)
            raise ApiError(error.status, error.code, error.message)
        except ProviderError as error:
            log.info("lens %s: failed (%s) after %.1fs", category, error.code, time.monotonic() - started)
            status = 504 if error.code == "provider_timeout" else 503 if error.code in ("provider_quota", "provider_auth") else 502
            raise ApiError(status, error.code if error.code in ("provider_timeout", "provider_quota", "provider_auth")
                           else "provider_error", error.message)
        log.info("lens %s: %d KB crop, %s%s in %.1fs", category, len(data) // 1024,
                 "match" if answer.result else "no close match", " (cached)" if answer.cached else "", time.monotonic() - started)
        return JSONResponse({"status": "matched" if answer.result else "no_match", "category": category,
                             "source": "google_lens", "cached": answer.cached, "result": answer.result},
                            headers={"Cache-Control": "no-store"})

    @app.post("/v1/outfit-match")
    async def outfit_match(
        category: str = Form(...), crop: UploadFile | None = File(None), text: str = Form(""),
        search_id: str | None = Form(None), max_price: str | None = Form(None),
        brand: str = Form(""), mode: SearchMode = Form("combined"), department: Department = Form("any"),
        _: str = Depends(authorize_match),
    ):
        if category not in CATEGORIES:
            raise ApiError(400, "invalid_category", "Choose a jacket, T-shirt, pants or shoes.")
        cap = price(max_price)
        brand = brand.strip()
        if len(brand) > 80 or (brand and not brand_key(brand)):
            raise ApiError(400, "invalid_brand", "Enter a brand name of up to 80 characters.")
        if bool(crop) == bool(search_id) or (search_id and (len(search_id) != 32 or cap is None)):
            raise ApiError(400, "invalid_request", "Send a garment crop or a valid budget search.")
        data = await crop.read(MAX_CROP_BYTES + 1) if crop else b""
        media = _media_type(data) if crop else None
        if len(data) > MAX_CROP_BYTES:
            raise ApiError(413, "image_too_large", "This garment photo is too large.")
        if crop and media is None:
            raise ApiError(400, "invalid_image", "This garment image couldn't be read.")
        started = time.monotonic()
        try:
            async with asyncio.timeout(60):
                search_id, results, description = await outfit.match(
                    category, data, media, text[:500].split(",")[:12], search_id, cap, mode=mode, brand=brand,
                    department=department,
                )
        except TimeoutError:
            raise ApiError(504, "provider_timeout", "Garment matching took too long. Try again.") from None
        except ProviderError as error:
            status = {"search_expired": 410, "provider_timeout": 504, "not_configured": 503}.get(error.code, 502)
            log.info("outfit %s: failed (%s)", category, error.code)
            raise ApiError(status, error.code, error.message) from None
        log.info("outfit %s: %d listings in %.2fs", category, len(results), time.monotonic() - started)
        close = [row for row in results if row["match"] != "alternative"]
        alternatives = [row for row in results if row["match"] == "alternative"]
        return JSONResponse({"status": "matched" if close else "no_match", "currency": CURRENCY,
                             "search_id": search_id, "description": description.summary() if description else None,
                             "garment_label": description.label() if description else None,
                             "results": close, "alternatives": alternatives}, headers={"Cache-Control": "no-store"})

    @app.post("/v1/avatar")
    async def create_avatar(
        request: Request,
        body_photo: UploadFile = File(...),
        selfie: UploadFile | None = File(None),
        height_cm: float = Form(...),
        weight_kg: float = Form(...),
        regenerate: bool = Form(False),
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
            rendered, disposition = await image_results.get(
                scoped_image_key(request, "avatar", prompt, images),
                lambda: render_image(generator, images, prompt), regenerate=regenerate,
            )
        except ApiError as error:
            log.info("avatar %s: failed (%s) after %.1fs", request_id, error.code, time.monotonic() - started)
            raise
        log.info("avatar %s: done in %.1fs", request_id, time.monotonic() - started)
        return Response(content=rendered.image, media_type=_media_type(rendered.image) or "image/png",
                        headers=rendered.headers(disposition))

    @app.post("/v1/avatar-outfit")
    async def style_avatar(
        request: Request,
        portrait: UploadFile = File(...),
        tshirt: UploadFile | None = File(None),
        pants: UploadFile | None = File(None),
        shoes: UploadFile | None = File(None),
        outerwear: UploadFile | None = File(None),
        regenerate: bool = Form(False),
        _: str = Depends(authorize),
    ):
        if preview_generator is None:
            raise ApiError(503, "not_configured", "Outfit previews aren't configured on the FitMix server.")
        selected = [(slot, upload) for slot, upload in (
            ("tshirt", tshirt), ("pants", pants), ("shoes", shoes), ("outerwear", outerwear)
        ) if upload is not None]
        if not selected:
            raise ApiError(400, "empty_outfit", "Add at least one garment to preview the outfit.")
        images = [await _read_image(portrait, "avatar portrait", "portrait")]
        images.extend([await _read_image(upload, slot, slot) for slot, upload in selected])
        prompt = build_outfit_prompt([slot for slot, _ in selected])
        rendered, disposition = await image_results.get(
            scoped_image_key(request, "outfit", prompt, images),
            lambda: render_image(preview_generator, images, prompt), regenerate=regenerate,
        )
        headers = rendered.headers(disposition)
        headers["X-FitMix-Mock"] = "1" if settings.mock else "0"
        return Response(content=rendered.image, media_type=_media_type(rendered.image) or "image/png", headers=headers)

    @app.post("/v1/wardrobe-photo")
    async def wardrobe_photo(request: Request, photo: UploadFile = File(...), regenerate: bool = Form(False),
                             _: str = Depends(authorize)):
        if wardrobe_analysis is None or catalog_generator is None:
            raise ApiError(503, "not_configured", "Photo polishing isn't set up on this FitMix server.")
        image = await _read_image(photo, "clothing photo", "garment")

        async def prepare_catalog() -> ImageResult:
            started = time.perf_counter()
            try:
                identified = await wardrobe_analysis.identify_wardrobe_item(image[1], image[2])
            except ProviderError as error:
                raise ApiError(504 if error.code == "provider_timeout" else 502, error.code,
                               "FitMix couldn't identify the garment. Choose its category or try again.") from None
            classification_ms = (time.perf_counter() - started) * 1000
            if not identified.clear_subject:
                return ImageResult(None, message="Try a photo with a single item or one pair of shoes.",
                                   classification_ms=classification_ms)
            try:
                rendered = await render_image(catalog_generator, [image], build_catalog_prompt(identified.category))
                if _media_type(rendered.image) is None:
                    raise ApiError(502, "upstream_empty", "The service didn't return a usable photo.")
                return replace(rendered, category=identified.category, classification_ms=classification_ms)
            except ApiError as error:
                log.info("wardrobe photo polish failed (%s)", error.code)
                return ImageResult(None, category=identified.category,
                                   message="Couldn't polish this photo. Try again or use your original.",
                                   classification_ms=classification_ms)

        result, disposition = await image_results.get(
            scoped_image_key(request, "catalog", "", [image]), prepare_catalog, regenerate=regenerate,
        )
        headers = result.headers(disposition)
        if result.image and request.headers.get("accept") == "image/*":
            if result.category:
                headers["X-FitMix-Wardrobe-Category"] = result.category
            return Response(content=result.image, media_type=_media_type(result.image), headers=headers)
        return JSONResponse({"category": result.category,
                             "image": base64.b64encode(result.image).decode("ascii") if result.image else None,
                             "message": result.message}, headers=headers)

    def build_state(job: avatar3d.Job) -> dict:
        return {"job": job.id, "status": job.status, "stage": job.stage, "progress": job.progress,
                "position": builds.position(job),
                "face_sharpened": job.built.face_sharpened if job.built else None,
                "error": {"code": job.error.code, "message": job.error.message} if job.error else None}

    def find_build(job_id: str, client: str) -> avatar3d.Job:
        job = builds.get(job_id)
        if job is None or job.owner != client:
            raise ApiError(404, "not_found", "That 3D avatar build has expired. Start it again.")
        return job

    @app.post("/v1/avatar-3d", status_code=202)
    async def start_avatar_3d(portrait: UploadFile = File(...), client: str = Depends(authorize_build)):
        if not builder.ready:
            raise ApiError(503, "not_configured",
                           "The 3D avatar builder isn't set up on this server yet (run Backend/avatar3d/setup.sh).")
        _, data, _ = await _read_image(portrait, "avatar portrait", "portrait")
        try:
            job = builds.submit(data, client)
        except avatar3d.QueueFull:
            raise ApiError(503, "busy", "The 3D avatar builder is busy. Try again in a few minutes.")
        log.info("avatar-3d %s: started, %d KB portrait", job.id[:8], len(data) // 1024)
        return JSONResponse(build_state(job), status_code=202, headers={"Cache-Control": "no-store"})

    @app.get("/v1/avatar-3d/{job_id}")
    async def avatar_3d_progress(job_id: str, client: str = Depends(follow_build)):
        return JSONResponse(build_state(find_build(job_id, client)), headers={"Cache-Control": "no-store"})

    @app.get("/v1/avatar-3d/{job_id}/model")
    async def avatar_3d_model(job_id: str, client: str = Depends(follow_build)):
        job = find_build(job_id, client)
        if job.built is None:
            raise ApiError(409, "not_ready", "The 3D avatar isn't finished yet.")
        log.info("avatar-3d %s: collected, %d KB model, built in %.0fs, face %s", job.id[:8], len(job.built.model) // 1024,
                 (job.finished or time.monotonic()) - job.started,
                 "sharpened" if job.built.face_sharpened else f"not sharpened ({job.built.face_note or 'no reason given'})")
        return Response(content=job.built.model, media_type="model/vnd.usdz+zip", headers={"Cache-Control": "no-store"})

    @app.delete("/v1/avatar-3d/{job_id}", status_code=204)
    async def cancel_avatar_3d(job_id: str, client: str = Depends(follow_build)):
        """Stops a build the user cancelled, or forgets a finished one."""
        builds.cancel(find_build(job_id, client))
        return Response(status_code=204)

    return app


def _media_type(data: bytes | None) -> str | None:
    if not data:
        return None
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
