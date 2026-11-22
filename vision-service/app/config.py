"""Settings, read once from the environment (vision-service/.env via run.sh). Keys are never logged."""

import os
from dataclasses import dataclass, field


def _flag(value: str | None) -> bool:
    return (value or "").strip().lower() in ("1", "true", "yes", "on")


def _float(env: dict, name: str, default: float) -> float:
    raw = env.get(name, "").strip()
    return float(raw) if raw else default


def _int(env: dict, name: str, default: int) -> int:
    raw = env.get(name, "").strip()
    return int(raw) if raw else default


@dataclass(frozen=True)
class Settings:
    # MOCK_MODE=1: realistic fake data, no model downloads, no paid API calls, nothing leaves this machine.
    mock: bool = False
    # Optional shared secret. When set, /analyze, /search and /refine need `Authorization: Bearer <token>`.
    app_token: str = field(default="", repr=False)

    openai_api_key: str = field(default="", repr=False)
    openai_vision_model: str = "gpt-5-mini"
    openai_timeout_seconds: float = 60.0
    # low, high or auto: how closely the model looks at each picture. high reads small logos better, costs more.
    openai_image_detail: str = "auto"

    serpapi_key: str = field(default="", repr=False)
    # Google country and language for Shopping and Lens results (prices come back in that country's currency).
    serpapi_country: str = "us"
    serpapi_language: str = "en"

    supabase_url: str = ""
    supabase_service_role_key: str = field(default="", repr=False)
    supabase_crop_bucket: str = "vision-crops"
    signed_url_seconds: int = 300

    # Online re-ranking: score = image_weight * cosine + attr_weight * attribute_match.
    rerank_image_weight: float = 0.8
    rerank_attr_weight: float = 0.2
    # Garments covering less than this fraction of the photo are dropped (e.g. shoes cut off at the edge).
    min_garment_area: float = 0.01
    catalog_top_k: int = 5
    online_top_k: int = 10

    # In-memory analysis cache (crops, attributes, embeddings) used by /search and /refine.
    cache_size: int = 64
    cache_ttl_seconds: int = 3600

    max_image_bytes: int = 8 * 1024 * 1024
    max_crop_bytes: int = 4 * 1024 * 1024
    max_crops: int = 8

    @staticmethod
    def from_environment(env: dict | None = None) -> "Settings":
        env = dict(os.environ if env is None else env)
        d = Settings
        return Settings(
            mock=_flag(env.get("MOCK_MODE")),
            app_token=env.get("VISION_APP_TOKEN", "").strip(),
            openai_api_key=env.get("OPENAI_API_KEY", "").strip(),
            openai_vision_model=env.get("OPENAI_VISION_MODEL", "").strip() or d.openai_vision_model,
            openai_timeout_seconds=_float(env, "OPENAI_TIMEOUT_SECONDS", d.openai_timeout_seconds),
            openai_image_detail=env.get("OPENAI_IMAGE_DETAIL", "").strip().lower() or d.openai_image_detail,
            serpapi_key=env.get("SERPAPI_KEY", "").strip(),
            serpapi_country=env.get("SERPAPI_COUNTRY", "").strip().lower() or d.serpapi_country,
            serpapi_language=env.get("SERPAPI_LANGUAGE", "").strip().lower() or d.serpapi_language,
            supabase_url=env.get("SUPABASE_URL", "").strip().rstrip("/"),
            supabase_service_role_key=env.get("SUPABASE_SERVICE_ROLE_KEY", "").strip(),
            supabase_crop_bucket=env.get("SUPABASE_CROP_BUCKET", "").strip() or d.supabase_crop_bucket,
            signed_url_seconds=_int(env, "SIGNED_URL_SECONDS", d.signed_url_seconds),
            rerank_image_weight=_float(env, "RERANK_IMAGE_WEIGHT", d.rerank_image_weight),
            rerank_attr_weight=_float(env, "RERANK_ATTR_WEIGHT", d.rerank_attr_weight),
            min_garment_area=_float(env, "MIN_GARMENT_AREA", d.min_garment_area),
            catalog_top_k=_int(env, "CATALOG_TOP_K", d.catalog_top_k),
            online_top_k=_int(env, "ONLINE_TOP_K", d.online_top_k),
            cache_size=_int(env, "CACHE_SIZE", d.cache_size),
            cache_ttl_seconds=_int(env, "CACHE_TTL_SECONDS", d.cache_ttl_seconds),
        )
