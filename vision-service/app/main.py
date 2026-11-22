"""FitMix vision service: garment recognition and similar-product search.

- `POST /analyze`  a person photo (`image`) or garment crops from the app (`crops`) → per garment: crop, LLM
  description and attributes, and demo-catalog matches. No online search here, so it costs no SerpAPI credit.
- `POST /search`   online matches (Google Lens + Google Shopping via SerpAPI, re-ranked) for one garment.
- `POST /refine`   the same search with a brand added to the query; reuses everything else.
- `GET /crops/{analysis_id}/{index}.jpg`, `GET /health`

Errors use the same shape as Backend/: {"error": {"code", "message"}}. A step that fails inside a request is
reported in that garment's `errors` and the rest of the result is still returned.
"""

import hmac
import logging

from fastapi import Depends, FastAPI, File, Form, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response

from .config import Settings
from .images import decode, media_type
from .models import (APP_CATEGORY, HINT_CATEGORY, AnalyzeResponse, GarmentResult, OnlineMatch, RefineRequest,
                     SearchRequest, SearchResponse)
from .pipeline import Analysis, Pipeline
from .store import TTLCache

log = logging.getLogger("vision")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


class ApiError(Exception):
    """An error the app can show. `code` is stable; `message` is written for the person using the app."""

    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def build_pipeline(settings: Settings) -> Pipeline | None:
    """The pipeline for these settings: every step mocked in MOCK_MODE, otherwise each step whose key or model
    is available. None when nothing is configured."""
    if settings.mock:
        from .mock import MockCatalog, MockDescriber, MockEmbedder, MockOnlineSearch, MockSegmenter

        embedder = MockEmbedder()
        return Pipeline(MockSegmenter(), MockDescriber(), embedder, MockCatalog(embedder),
                        MockOnlineSearch(top_k=settings.online_top_k), catalog_top_k=settings.catalog_top_k)

    describer = online = None
    if settings.openai_api_key:
        from .describe import OpenAIDescriber

        describer = OpenAIDescriber(settings.openai_api_key, settings.openai_vision_model,
                                    settings.openai_timeout_seconds, settings.openai_image_detail)
    if settings.serpapi_key:
        from .search import SerpApiClient, ShoppingSearch

        client = SerpApiClient(settings.serpapi_key, settings.serpapi_country, settings.serpapi_language)
        online = ShoppingSearch(client, top_k=settings.online_top_k)
    if describer is None and online is None:
        return None
    segmenter = load_segmenter(settings) if describer is not None else None
    # Embeddings and the catalog (stage 4) aren't built yet.
    return Pipeline(segmenter, describer, None, None, online, catalog_top_k=settings.catalog_top_k)


def load_segmenter(settings: Settings):
    """The SegFormer segmenter, loaded once at startup. If it can't load, photos are described as a whole."""
    if not settings.segmentation:
        return None
    try:
        from .segment import SegFormerSegmenter

        return SegFormerSegmenter(settings.segmentation_model, settings.min_garment_area)
    except Exception as error:
        log.error("segmentation is off: the model %s couldn't load (%s: %s). Photos will be described as a whole.",
                  settings.segmentation_model, type(error).__name__, error)
        return None


def create_app(settings: Settings | None = None, pipeline: Pipeline | None = None) -> FastAPI:
    settings = settings or Settings.from_environment()
    if pipeline is None:
        pipeline = build_pipeline(settings)
    analyses: TTLCache[Analysis] = TTLCache(settings.cache_size, settings.cache_ttl_seconds)
    app = FastAPI(title="FitMix vision service", docs_url=None, redoc_url=None, openapi_url=None)

    @app.exception_handler(ApiError)
    async def api_error(_: Request, error: ApiError):
        return JSONResponse(status_code=error.status, content={"error": {"code": error.code, "message": error.message}})

    @app.exception_handler(RequestValidationError)
    async def invalid(_: Request, error: RequestValidationError):
        return JSONResponse(status_code=400, content={"error": {"code": "invalid_request", "message": "The request was incomplete or malformed."}})

    def authorize(request: Request):
        if settings.app_token:
            sent = request.headers.get("authorization", "")
            if not hmac.compare_digest(sent, f"Bearer {settings.app_token}"):
                raise ApiError(401, "unauthorized", "This app isn't allowed to use the vision service.")

    def require_pipeline() -> Pipeline:
        if pipeline is None:
            raise ApiError(503, "not_configured",
                           "The vision service has no models configured yet. Start it with MOCK_MODE=1 for demo data.")
        return pipeline

    async def read_image(upload: UploadFile, limit: int, label: str):
        data = await upload.read(limit + 1)
        if len(data) > limit:
            raise ApiError(413, "image_too_large", f"The {label} is too large (limit {limit // (1024 * 1024)} MB).")
        if media_type(data) is None:
            raise ApiError(400, "invalid_image", f"The {label} isn't a JPEG, PNG or WebP picture.")
        try:
            return decode(data)
        except Exception:
            raise ApiError(400, "invalid_image", f"The {label} couldn't be opened.")

    def base_url(request: Request) -> str:
        return str(request.base_url).rstrip("/")

    def absolute(url: str | None, base: str) -> str | None:
        if url is None or url.startswith(("http://", "https://")):
            return url
        return f"{base}/{url.lstrip('/')}"

    def online_json(matches: list[OnlineMatch], base: str) -> list[OnlineMatch]:
        return [m.model_copy(update={"image": absolute(m.image, base)}) for m in matches]

    def analysis_json(analysis: Analysis, base: str, cached: bool) -> AnalyzeResponse:
        garments = []
        for g in analysis.garments:
            garments.append(GarmentResult(
                index=g.index, category=g.category, app_category=APP_CATEGORY.get(g.category or ""),
                source_label=g.hint, crop_url=f"{base}/crops/{analysis.id}/{g.index}.jpg",
                description=g.attributes.description if g.attributes else None, attributes=g.attributes,
                catalog_matches=[m.model_copy(update={"image": absolute(m.image, base)}) for m in g.catalog_matches],
                online_matches=[], errors=g.errors))
        return AnalyzeResponse(analysis_id=analysis.id, input=analysis.input, mock=settings.mock, cached=cached,
                               garments=garments, errors=analysis.errors, timings_ms=analysis.timings_ms)

    @app.get("/health")
    async def health():
        return {"status": "ok", "ready": pipeline is not None, "mock": settings.mock,
                "components": pipeline.components() if pipeline else None,
                "keys": {"openai": bool(settings.openai_api_key), "serpapi": bool(settings.serpapi_key),
                         "supabase": bool(settings.supabase_url and settings.supabase_service_role_key)},
                "cached_analyses": len(analyses)}

    @app.post("/analyze", response_model=AnalyzeResponse, dependencies=[Depends(authorize)])
    async def analyze(
        request: Request,
        image: UploadFile | None = File(None),
        crops: list[UploadFile] | None = File(None),
        categories: str | None = Form(None),
    ):
        active = require_pipeline()
        crops = crops or []
        if (image is None) == (not crops):
            raise ApiError(400, "invalid_request", "Send either one `image` (a person photo) or one or more `crops`, not both.")
        if image is not None:
            photo = await read_image(image, settings.max_image_bytes, "photo")
            analysis = await active.analyze(image=photo)
        else:
            if len(crops) > settings.max_crops:
                raise ApiError(400, "too_many_crops", f"Send at most {settings.max_crops} garment crops at once.")
            hints: list[str | None] = [None] * len(crops)
            if categories:
                hints = [c.strip().lower() or None for c in categories.split(",")]
                if len(hints) != len(crops) or any(h is not None and h not in HINT_CATEGORY for h in hints):
                    raise ApiError(400, "invalid_categories",
                                   "`categories` needs one entry per crop, each one of: " + ", ".join(sorted(HINT_CATEGORY)) + ".")
            pictures = [await read_image(c, settings.max_crop_bytes, f"garment crop {i + 1}") for i, c in enumerate(crops)]
            analysis = await active.analyze(crops=pictures, hints=hints)
        analyses.put(analysis.id, analysis)
        return analysis_json(analysis, base_url(request), cached=False)

    async def run_search(request: Request, body: SearchRequest, brand: str | None) -> SearchResponse:
        active = require_pipeline()
        if active.online is None:
            raise ApiError(503, "not_configured", "Online search isn't set up on this service yet (SERPAPI_KEY).")
        analysis = analyses.get(body.analysis_id)
        if analysis is None:
            raise ApiError(404, "analysis_not_found", "This analysis has expired or doesn't exist. Analyze the photo again.")
        if body.garment_index >= len(analysis.garments):
            raise ApiError(404, "garment_not_found", "This analysis has no garment with that index.")
        _, result, query, cached, timings = await active.search(analysis, body.garment_index, brand)
        return SearchResponse(analysis_id=analysis.id, garment_index=body.garment_index, query=query, brand=brand,
                              mock=settings.mock, cached=cached, online_matches=online_json(result.matches, base_url(request)),
                              errors=result.errors, timings_ms=timings)

    @app.post("/search", response_model=SearchResponse, dependencies=[Depends(authorize)])
    async def search(request: Request, body: SearchRequest):
        return await run_search(request, body, brand=None)

    @app.post("/refine", response_model=SearchResponse, dependencies=[Depends(authorize)])
    async def refine(request: Request, body: RefineRequest):
        return await run_search(request, body, brand=body.brand.strip())

    @app.get("/crops/{analysis_id}/{filename}")
    async def crop(analysis_id: str, filename: str):
        # Unguessable ids (128-bit random) act as the access check, so the app can load these in an image view.
        analysis = analyses.get(analysis_id)
        index = filename.removesuffix(".jpg")
        if analysis is None or not filename.endswith(".jpg") or not index.isdigit() or int(index) >= len(analysis.garments):
            raise ApiError(404, "crop_not_found", "This crop has expired or doesn't exist.")
        return Response(analysis.garments[int(index)].crop_jpeg, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=3600"})

    if settings.mock:
        from .mock import product_image_jpeg

        @app.get("/mock-images/{name}")
        async def mock_image(name: str):
            data = product_image_jpeg(name)
            if data is None:
                raise ApiError(404, "not_found", "No such mock image.")
            return Response(data, media_type="image/jpeg", headers={"Cache-Control": "public, max-age=86400"})

    return app


app = create_app()
