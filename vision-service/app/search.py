"""Online product search through SerpAPI.

Stage 2: Google Shopping with the garment's text query. Results keep their title, price, shop, picture and
link exactly as returned. Duplicate links are merged. Until image re-ranking exists (stage 5), the score
reflects Google's own order: 1.0 for the first result, falling evenly.
"""

import logging
import re
from decimal import Decimal, InvalidOperation
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import httpx

from .models import OnlineMatch, Price
from .pipeline import OnlineRequest, OnlineResult, StepFailure, Timer

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
