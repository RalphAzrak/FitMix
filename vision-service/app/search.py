"""Online product search through SerpAPI: Google Lens with the garment crop and Google Shopping with its text
query, run side by side, merged, and re-ranked by how alike the thumbnails look (see rerank.py).

Results keep their title, price, shop, picture and link exactly as returned. The same link found by both is
one result (source "lens+shopping"). `ShoppingSearch` alone (no Lens, no re-ranking, scores in Google's
order) is kept for setups without image embeddings.
"""

import asyncio
import io
import logging
import re
import time
from decimal import Decimal, InvalidOperation
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import httpx
import numpy as np
from PIL import Image

from .models import OnlineMatch, Price, StepError
from .pipeline import OnlineRequest, OnlineResult, StepFailure, Timer, step_error
from .rerank import rerank

log = logging.getLogger("vision")

SERPAPI_URL = "https://serpapi.com/search.json"
# Query parameters that only track the click; dropping them lets the same product link compare equal.
TRACKING_PARAMS = re.compile(r"^(utm_|gclid$|gclsrc$|srsltid$|fbclid$|mc_|ref$|ref_)")

CURRENCY_SYMBOLS = {"CA$": "CAD", "C$": "CAD", "A$": "AUD", "US$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR"}
DOLLAR_BY_COUNTRY = {"us": "USD", "ca": "CAD", "au": "AUD", "nz": "NZD"}


def normalize_url(url: str) -> str:
    """Lower-case host, no fragment, no trailing slash, no tracking parameters, sorted query."""
    parts = urlsplit(url.strip())
    query = sorted((k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if not TRACKING_PARAMS.match(k))
    path = parts.path.rstrip("/") or "/"
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower().removeprefix("www."), path, urlencode(query), ""))


def parse_price(text: str | None, extracted: float | int | None, country: str) -> Price | None:
    """The listed price, with its currency read from the symbol. None when there's no price or the currency is unclear."""
    if not text:
        return None
    text = text.strip()
    currency = next((code for symbol, code in CURRENCY_SYMBOLS.items() if text.startswith(symbol)), None)
    if currency is None and text.startswith("$"):
        currency = DOLLAR_BY_COUNTRY.get(country, "USD")
    if currency is None:
        return None
    if extracted is not None:
        value = Decimal(str(extracted))
    else:
        digits = re.search(r"[\d.,]+", text)
        try:
            value = Decimal(digits.group().replace(",", "")) if digits else None
        except InvalidOperation:
            value = None
    return Price(value=f"{value:.2f}", currency=currency) if value is not None else None


def position_scores(count: int) -> list[float]:
    return [round(1 - i / max(count, 1), 4) for i in range(count)]


class SerpApiClient:
    def __init__(self, api_key: str, country: str = "us", language: str = "en", timeout_seconds: float = 20.0,
                 transport: httpx.AsyncBaseTransport | None = None):
        self.api_key, self.country, self.language = api_key, country, language
        self.http = httpx.AsyncClient(timeout=timeout_seconds, transport=transport)

    async def get(self, engine: str, **params) -> dict:
        query = {"engine": engine, "api_key": self.api_key, "gl": self.country, "hl": self.language, **params}
        try:
            response = await self.http.get(SERPAPI_URL, params=query)
        except httpx.TimeoutException:
            raise StepFailure("provider_timeout", "The product search took too long. Try again.")
        except httpx.HTTPError:
            raise StepFailure("provider_unreachable", "The service couldn't reach the product search. Try again in a moment.")
        if response.status_code == 401:
            raise StepFailure("provider_auth", "SerpAPI refused the service's key (check SERPAPI_KEY).")
        if response.status_code == 429:
            raise StepFailure("provider_busy", "The product search is out of searches or busy. Try again later.")
        try:
            body = response.json()
        except ValueError:
            body = {}
        error = body.get("error") if isinstance(body, dict) else None
        if error and "hasn't returned any results" in error:
            return {}  # a search that worked but found nothing
        if response.status_code >= 400 or error:
            log.warning("serpapi %s: HTTP %s", engine, response.status_code)
            raise StepFailure("provider_error", "The product search had a problem. Try again.")
        return body


class ShoppingSearch:
    """Google Shopping results for the garment's search query."""

    name = "serpapi-shopping"

    def __init__(self, client: SerpApiClient, top_k: int = 10):
        self.client, self.top_k = client, top_k

    async def search(self, request: OnlineRequest, timer: Timer) -> OnlineResult:
        with timer.step("shopping"):
            body = await self.client.get("google_shopping", q=request.query, num=40)
        matches = shopping_matches(body, self.client.country)[: self.top_k]
        for match, score in zip(matches, position_scores(len(matches))):
            match.score = score
        return OnlineResult(matches=matches)


def shopping_matches(body: dict, country: str) -> list[OnlineMatch]:
    """Google Shopping results as matches, in Google's order, without results that have no link or repeat one."""
    seen: set[str] = set()
    matches = []
    for result in body.get("shopping_results") or []:
        url = result.get("link") or result.get("product_link")
        title = (result.get("title") or "").strip()
        if not url or not title:
            continue
        key = normalize_url(url)
        if key in seen:
            continue
        seen.add(key)
        matches.append(OnlineMatch(
            title=title, price=parse_price(result.get("price"), result.get("extracted_price"), country),
            retailer=result.get("source"), url=url, image=result.get("thumbnail"), score=0.0, source="shopping"))
    return matches


def lens_matches(body: dict, country: str) -> list[OnlineMatch]:
    """Google Lens visual matches as matches, in Google's order, without results that have no link or repeat one."""
    seen: set[str] = set()
    matches = []
    for result in body.get("visual_matches") or []:
        url, title = result.get("link"), (result.get("title") or "").strip()
        if not url or not title or normalize_url(url) in seen:
            continue
        seen.add(normalize_url(url))
        price = result.get("price") or {}
        matches.append(OnlineMatch(
            title=title, price=parse_price(price.get("value"), price.get("extracted_value"), country),
            retailer=result.get("source"), url=url, image=result.get("thumbnail") or result.get("image"),
            score=0.0, source="lens"))
    return matches


def merge_matches(*lists: list[OnlineMatch]) -> list[OnlineMatch]:
    """One result per link, in the order given. A link found by several sources keeps the first one's details,
    fills in a missing price or picture from the others, and lists every source."""
    merged: dict[str, OnlineMatch] = {}
    for matches in lists:
        for match in matches:
            key = normalize_url(match.url)
            if key not in merged:
                merged[key] = match.model_copy()
                continue
            kept = merged[key]
            sources = kept.source.split("+")
            if match.source not in sources:
                kept.source = "+".join(sorted(sources + [match.source]))
            kept.price = kept.price or match.price
            kept.image = kept.image or match.image
    return list(merged.values())


class ThumbnailFetcher:
    """Downloads result thumbnails for re-ranking, several at a time. A failed download gives None."""

    def __init__(self, timeout_seconds: float = 8.0, max_bytes: int = 2 * 1024 * 1024, concurrency: int = 8,
                 transport: httpx.AsyncBaseTransport | None = None):
        self.max_bytes = max_bytes
        self.limit = asyncio.Semaphore(concurrency)
        self.http = httpx.AsyncClient(timeout=timeout_seconds, follow_redirects=True, transport=transport,
                                      headers={"User-Agent": "FitMix-vision/1.0"})

    async def fetch_all(self, urls: list[str | None]) -> list[bytes | None]:
        return await asyncio.gather(*(self.fetch(url) for url in urls))

    async def fetch(self, url: str | None) -> bytes | None:
        if not url or not url.startswith(("http://", "https://")):
            return None
        async with self.limit:
            try:
                response = await self.http.get(url)
            except httpx.HTTPError:
                return None
        if response.status_code != 200 or len(response.content) > self.max_bytes:
            return None
        return response.content


class OnlineSearch:
    """Lens (when a crop store is configured) and Shopping in parallel, merged, then re-ranked with the embedder.

    /refine reuses the garment's Lens results (the picture hasn't changed), so a refine costs one search."""

    def __init__(self, client: SerpApiClient, embedder, storage=None, fetcher: ThumbnailFetcher | None = None,
                 image_weight: float = 0.8, attr_weight: float = 0.2, top_k: int = 10, max_candidates: int = 40,
                 lens_cache_seconds: float = 3600):
        self.client, self.embedder, self.storage = client, embedder, storage
        self.fetcher = fetcher or ThumbnailFetcher()
        self.image_weight, self.attr_weight = image_weight, attr_weight
        self.top_k, self.max_candidates = top_k, max_candidates
        self.lens_cache_seconds = lens_cache_seconds
        self._lens: dict[str, tuple[float, list[OnlineMatch]]] = {}
        self.name = "serpapi-" + ("lens+shopping" if storage else "shopping") + "+rerank"

    async def search(self, request: OnlineRequest, timer: Timer) -> OnlineResult:
        errors: list[StepError] = []

        async def guarded(step: str, work):
            try:
                with timer.step(step):
                    return await work
            except Exception as error:
                errors.append(step_error(step, error))
                return []

        lens, shopping = await asyncio.gather(guarded("lens", self._lens_matches(request, timer)),
                                              guarded("shopping", self._shopping_matches(request)))
        candidates = merge_matches(shopping, lens)[: self.max_candidates]
        if not candidates:
            return OnlineResult(matches=[], errors=errors)
        with timer.step("thumbnails"):
            pictures = await self.fetcher.fetch_all([m.image for m in candidates])
        with timer.step("rerank"):
            vectors = await asyncio.to_thread(self._embed_thumbnails, pictures)
            ranked = rerank(candidates, request.embedding, vectors, request.attributes, request.category, request.brand,
                            self.image_weight, self.attr_weight, self.top_k)
        log.info("online search: %d lens + %d shopping → %d candidates, %d thumbnails embedded",
                 len(lens), len(shopping), len(candidates), sum(v is not None for v in vectors))
        return OnlineResult(matches=ranked, errors=errors)

    async def _shopping_matches(self, request: OnlineRequest) -> list[OnlineMatch]:
        body = await self.client.get("google_shopping", q=request.query, num=40)
        return shopping_matches(body, self.client.country)

    async def _lens_matches(self, request: OnlineRequest, timer: Timer) -> list[OnlineMatch]:
        if self.storage is None:
            return []
        cached = self._lens.get(request.key)
        if cached and time.monotonic() - cached[0] < self.lens_cache_seconds:
            return cached[1]
        path = f"crops/{request.key}.jpg"
        link = await self.storage.signed_link(path, request.crop_jpeg)
        try:
            body = await self.client.get("google_lens", url=link, country=self.client.country)
        finally:
            await self.storage.remove(path)  # Lens has fetched it (or failed); don't keep the crop around
        matches = lens_matches(body, self.client.country)
        self._lens[request.key] = (time.monotonic(), matches)
        return matches

    def _embed_thumbnails(self, pictures: list[bytes | None]) -> list[np.ndarray | None]:
        opened: list[tuple[int, Image.Image]] = []
        for index, data in enumerate(pictures):
            if data is None:
                continue
            try:
                with Image.open(io.BytesIO(data)) as picture:
                    opened.append((index, picture.convert("RGB")))
            except Exception:
                continue
        vectors: list[np.ndarray | None] = [None] * len(pictures)
        if opened and self.embedder is not None:
            for (index, _), vector in zip(opened, self.embedder.embed([p for _, p in opened])):
                vectors[index] = vector
        return vectors
