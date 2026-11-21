"""Visual search providers. Each turns its source's own data into `Candidate`s; none of them ranks or labels.

- `EbayProvider`: eBay Browse API image search (official API; keys in EBAY_CLIENT_ID / EBAY_CLIENT_SECRET).
- `ScrappaLensProvider`: Google Lens results through Scrappa (scrappa.co). Off unless explicitly listed in
  FITMIX_VISUAL_PROVIDERS. Scrappa's documented Lens search takes a *public image URL*, so this provider
  publishes the crop at a short-lived, unguessable URL on this server (`CropHost`) for Scrappa to fetch, then
  revokes it. That needs FITMIX_PUBLIC_BASE_URL (an https address Scrappa can reach).
- `FixtureProvider`: labeled development data loaded from JSON. Never contacts anyone.
"""

import json
import re
import secrets
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import httpx

from .retail import EBAY_CATEGORY_IDS, EbayMatcher, MatchError, keep, listing_from_ebay
from .visual_search import Candidate, Clues, ProviderError

# MARK: - eBay


class EbayProvider:
    name = "ebay"
    fixture = False

    def __init__(self, matcher: EbayMatcher):
        self.matcher = matcher

    async def search(self, crop: bytes, clues: Clues) -> list[Candidate]:
        import asyncio
        import base64

        encoded = base64.b64encode(crop).decode()
        try:
            pages = await asyncio.gather(*(self.matcher._search_category(cid, encoded) for cid in EBAY_CATEGORY_IDS[clues.category]))
        except MatchError as error:
            raise ProviderError(error.code, error.message, retryable=error.code != "provider_auth")
        found = []
        for page in pages:
            for position, item in enumerate(page):
                if not keep(clues.category, item):
                    continue
                listing = listing_from_ebay(item)
                if listing:
                    found.append(Candidate(id=listing.id, title=listing.title, url=listing.url, retailer="eBay",
                                           seller=listing.seller, provider=self.name, rank=position,
                                           image_url=listing.image_url, price=listing.price,
                                           brand=(item.get("brand") or None)))
        return found


# MARK: - Scrappa (Google Lens)


class CropHost:
    """Holds a crop in memory under a random token for a few seconds so an image-URL provider can fetch it.
    Each token can be fetched a limited number of times and expires on its own; nothing touches disk."""

    def __init__(self, lifetime: float = 90.0, max_fetches: int = 3):
        self.lifetime, self.max_fetches = lifetime, max_fetches
        self._items: dict[str, list] = {}

    def publish(self, data: bytes) -> str:
        self._sweep()
        token = secrets.token_urlsafe(32)
        self._items[token] = [data, time.monotonic() + self.lifetime, self.max_fetches]
        return token

    def fetch(self, token: str) -> bytes | None:
        self._sweep()
        item = self._items.get(token)
        if not item:
            return None
        item[2] -= 1
        if item[2] <= 0:
            self._items.pop(token, None)
        return item[0]

    def revoke(self, token: str) -> None:
        self._items.pop(token, None)

    def _sweep(self) -> None:
        now = time.monotonic()
        for token in [t for t, item in self._items.items() if item[1] < now]:
            self._items.pop(token, None)


# Only unambiguous currency markers. A bare "$" could be USD, CAD, AUD... so it yields no currency and the price
# is left for the listing page to supply (or shown as "Price unavailable").
_CURRENCY_MARKERS = [("US$", "USD"), ("USD", "USD"), ("CA$", "CAD"), ("C$", "CAD"), ("CAD", "CAD"), ("A$", "AUD"),
                     ("AU$", "AUD"), ("AUD", "AUD"), ("€", "EUR"), ("EUR", "EUR"), ("£", "GBP"), ("GBP", "GBP"),
                     ("CHF", "CHF"), ("₹", "INR")]


def parse_price_text(text: str | None) -> dict | None:
    if not text:
        return None
    currency = next((code for marker, code in _CURRENCY_MARKERS if marker in text), None)
    number = re.search(r"\d[\d.,]*", text)
    if not currency or not number:
        return None
    raw = number.group(0)
    if "," in raw and "." in raw:
        raw = raw.replace(",", "") if raw.rfind(".") > raw.rfind(",") else raw.replace(".", "").replace(",", ".")
    elif "," in raw:
        raw = raw.replace(",", ".") if re.search(r",\d{2}$", raw) else raw.replace(",", "")
    try:
        return {"value": f"{float(raw):.2f}", "currency": currency}
    except ValueError:
        return None


def unwrap_link(link: str | None) -> str | None:
    if not link:
        return None
    parsed = urlparse(link)
    if parsed.netloc.endswith("google.com") and parsed.path in ("/goto", "/url"):
        target = parse_qs(parsed.query).get("url") or parse_qs(parsed.query).get("q")
        return target[0] if target else link
    return link


class ScrappaLensProvider:
    name = "google_lens"
    fixture = False
    endpoint = "https://scrappa.co/api/google/lens"

    def __init__(self, api_key: str, public_base_url: str, crop_host: CropHost, http: httpx.AsyncClient | None = None):
        self.api_key, self.public_base_url, self.crop_host = api_key, public_base_url.rstrip("/"), crop_host
        # Scrappa says a visual search "can take several seconds, so use a client timeout of at least 45 seconds".
        self.http = http or httpx.AsyncClient(timeout=httpx.Timeout(45.0, connect=5.0))

    async def search(self, crop: bytes, clues: Clues) -> list[Candidate]:
        token = self.crop_host.publish(crop)
        image_url = f"{self.public_base_url}/v1/crops/{token}.jpg"
        try:
            response = await self.http.get(self.endpoint, params={"url": image_url, "type": "all"},
                                           headers={"X-API-KEY": self.api_key, "Accept": "application/json"})
        except httpx.TimeoutException:
            raise ProviderError("provider_timeout", "Google Lens took too long. Try again.")
        except httpx.HTTPError:
            raise ProviderError("provider_unreachable", "The server couldn't reach Google Lens. Try again.")
        finally:
            self.crop_host.revoke(token)
        if response.status_code in (401, 403):
            raise ProviderError("provider_auth", "Scrappa refused the server's API key.", retryable=False)
        if response.status_code != 200:
            body = response.json() if response.content and "json" in response.headers.get("content-type", "") else {}
            raise ProviderError(str(body.get("error_code") or "provider_error"), "Google Lens search failed.",
                                retryable=bool(body.get("retryable", response.status_code >= 500 or response.status_code == 429)))
        return self.parse(response.json())

    def parse(self, body: dict) -> list[Candidate]:
        found = []
        for group, same_image in (("exact_matches", True), ("visual_matches", False)):
            for index, item in enumerate(body.get(group) or []):
                title, link = item.get("title"), unwrap_link(item.get("link"))
                if not title or not link:
                    continue
                position = item.get("position")
                rank = (int(position) - 1) if isinstance(position, int) and position > 0 else index
                found.append(Candidate(id=f"lens:{link}", title=title, url=link, retailer=item.get("source") or urlparse(link).netloc,
                                       provider=self.name, rank=rank, image_url=item.get("thumbnail"),
                                       price=parse_price_text(item.get("price")), same_image=same_image))
        return found


# MARK: - Fixtures


class FixtureProvider:
    """Serves labeled candidates from a JSON file: {"<category>": [candidate, ...], ...}. Development only."""

    name = "fixture"
    fixture = True

    def __init__(self, path: Path):
        self.data = json.loads(Path(path).read_text())

    async def search(self, crop: bytes, clues: Clues) -> list[Candidate]:
        return [Candidate(id=item["id"], title=item["title"], url=item.get("url"), retailer=item["retailer"],
                          provider=self.name, rank=index, image_url=item.get("image_url"), price=item.get("price"),
                          brand=item.get("brand"), codes=item.get("codes", []), same_image=item.get("same_image", False),
                          fixture=True)
                for index, item in enumerate(self.data.get(clues.category, []))]
