"""Retailer matching for one garment the user selected in the live camera.

The app sends only that garment's crop (never the full outfit frame), its category (jacket, tshirt, pants or
shoes), and attributes read on the phone (dominant colour, words printed on the garment). This module asks a
product-search provider for real listings and keeps only those in the selected category.

Provider today: eBay Browse API `item_summary/search_by_image` (official, authorized; free developer account).
Its keys live only in this server's environment. Every name, price, currency, image and link returned comes
from the listing itself; nothing is estimated. Results are "similar" matches: image search alone is no
evidence that a listing is the exact same product.
"""

import asyncio
import base64
import logging
import re
import time
from dataclasses import asdict, dataclass
from typing import Protocol

import httpx

log = logging.getLogger("fitmix")

CATEGORIES = ("jacket", "tshirt", "pants", "shoes")

# eBay US category tree. search_by_image accepts one category per request, so the men's and women's
# category for each garment are searched side by side. If eBay renumbers a category, the category-path check
# below drops its results (they show as "no match"), so a wrong ID can't put another category on the card.
EBAY_CATEGORY_IDS = {
    "jacket": ("57988", "63862"),  # Men's Coats, Jackets & Vests · Women's Coats, Jackets & Vests
    "tshirt": ("15687", "53159"),  # Men's T-Shirts · Women's Tops
    "pants": ("57989", "63863"),  # Men's Pants · Women's Pants
    "shoes": ("93427", "3034"),  # Men's Shoes · Women's Shoes
}

# A listing is kept only if one of its eBay categories contains one of these words...
CATEGORY_WORDS = {
    "jacket": ("coat", "jacket"),
    "tshirt": ("t-shirt", "tops"),
    "pants": ("pants", "jeans", "trousers"),
    "shoes": ("shoes", "sneakers", "boots", "sandals", "heels", "flats", "loafers", "athletic"),
}
# ...and, where the category is broad (Women's Tops), its title says what it is.
TITLE_WORDS = {"tshirt": ("t-shirt", "t shirt", "tshirt", "tee")}

COLOR_SYNONYMS = {"gray": ("gray", "grey"), "beige": ("beige", "tan", "cream", "khaki"), "navy": ("navy",),
                  "burgundy": ("burgundy", "maroon", "wine"), "olive": ("olive", "khaki")}

MAX_RESULTS = 5


class MatchError(Exception):
    """A provider failure the app can show. `code` decides whether the app offers Retry."""

    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


@dataclass
class Listing:
    id: str
    title: str
    retailer: str
    seller: str | None
    image_url: str | None
    url: str | None
    price: dict | None  # {"value": "48.00", "currency": "USD"} exactly as listed, or None
    match: str = "similar"

    def to_json(self) -> dict:
        return asdict(self)


class Matcher(Protocol):
    name: str
    fixture: bool

    async def search(self, category: str, image: bytes, color: str | None, brand_hints: list[str]) -> list[Listing]: ...


def keep(category: str, item: dict) -> bool:
    """True when an eBay item summary is in the selected garment category."""
    names = " ".join(c.get("categoryName", "") for c in item.get("categories") or []).lower()
    if not any(word in names for word in CATEGORY_WORDS[category]):
        return False
    title_words = TITLE_WORDS.get(category)
    if title_words and "t-shirts" not in names:
        return any(word in (item.get("title") or "").lower() for word in title_words)
    return True


def rank(candidates: list[tuple[int, Listing]], color: str | None, brand_hints: list[str]) -> list[Listing]:
    """Provider order first (it is visual similarity), nudged by the colour and any brand read on the garment."""
    colors = COLOR_SYNONYMS.get(color or "", (color,) if color else ())
    hints = [h for h in brand_hints if len(h) >= 3]

    def score(entry: tuple[int, Listing]) -> float:
        position, listing = entry
        title = listing.title.lower()
        value = 1.0 / (1 + position)
        if any(re.search(rf"\b{re.escape(c)}\b", title) for c in colors):
            value += 0.35
        if any(re.search(rf"\b{re.escape(h)}\b", title) for h in hints):
            value += 0.5
        return value

    return [listing for _, listing in sorted(candidates, key=score, reverse=True)]


def listing_from_ebay(item: dict) -> Listing | None:
    title, item_id = item.get("title"), item.get("itemId")
    if not title or not item_id:
        return None
    image = (item.get("image") or {}).get("imageUrl") or next(
        (i.get("imageUrl") for i in item.get("thumbnailImages") or [] if i.get("imageUrl")), None)
    price = item.get("price") or {}
    listed = {"value": str(price["value"]), "currency": str(price["currency"])} if price.get("value") and price.get("currency") else None
    return Listing(id=item_id, title=title, retailer="eBay", seller=(item.get("seller") or {}).get("username"),
                   image_url=image, url=item.get("itemWebUrl"), price=listed)


class EbayMatcher:
    name = "ebay"
    fixture = False
    api = "https://api.ebay.com"
    scope = "https://api.ebay.com/oauth/api_scope"

    def __init__(self, client_id: str, client_secret: str, marketplace: str = "EBAY_US",
                 http: httpx.AsyncClient | None = None):
        self.client_id, self.client_secret, self.marketplace = client_id, client_secret, marketplace
        self.http = http or httpx.AsyncClient(timeout=httpx.Timeout(15.0, connect=5.0))
        self._token: tuple[str, float] | None = None
        self._lock = asyncio.Lock()

    async def _access_token(self, refresh: bool = False) -> str:
        async with self._lock:
            if not refresh and self._token and self._token[1] > time.monotonic() + 60:
                return self._token[0]
            basic = base64.b64encode(f"{self.client_id}:{self.client_secret}".encode()).decode()
            try:
                response = await self.http.post(f"{self.api}/identity/v1/oauth2/token",
                                                headers={"Authorization": f"Basic {basic}",
                                                         "Content-Type": "application/x-www-form-urlencoded"},
                                                data={"grant_type": "client_credentials", "scope": self.scope})
            except httpx.TimeoutException:
                raise MatchError(504, "provider_timeout", "The product search took too long. Try again.")
            except httpx.HTTPError:
                raise MatchError(502, "provider_unreachable", "The server couldn't reach eBay. Try again in a moment.")
            if response.status_code in (400, 401, 403):
                raise MatchError(502, "provider_auth", "eBay refused the server's API keys. Check EBAY_CLIENT_ID and EBAY_CLIENT_SECRET.")
            if response.status_code != 200:
                raise MatchError(502, "provider_error", "eBay had a problem. Try again.")
            body = response.json()
            self._token = (body["access_token"], time.monotonic() + float(body.get("expires_in", 7200)))
            return self._token[0]

    async def _search_category(self, category_id: str, encoded: str) -> list[dict]:
        for attempt in (0, 1):
            token = await self._access_token(refresh=attempt == 1)
            try:
                response = await self.http.post(
                    f"{self.api}/buy/browse/v1/item_summary/search_by_image",
                    # Fixed-price listings only, so the price shown is what the listing sells for (not a bid).
                    params={"category_ids": category_id, "limit": "25", "filter": "buyingOptions:{FIXED_PRICE}"},
                    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                             "X-EBAY-C-MARKETPLACE-ID": self.marketplace},
                    json={"image": encoded})
            except httpx.TimeoutException:
                raise MatchError(504, "provider_timeout", "The product search took too long. Try again.")
            except httpx.HTTPError:
                raise MatchError(502, "provider_unreachable", "The server couldn't reach eBay. Try again in a moment.")
            if response.status_code == 401 and attempt == 0:
                continue  # token expired early: get a new one once
            if response.status_code in (401, 403):
                raise MatchError(502, "provider_auth", "eBay refused the server's access to image search.")
            if response.status_code == 429:
                raise MatchError(503, "provider_busy", "eBay's product search is busy. Try again in a minute.")
            if response.status_code >= 500:
                raise MatchError(502, "provider_error", "eBay had a problem. Try again.")
            if response.status_code != 200:
                codes = [e.get("errorId") for e in (response.json().get("errors") or [])] if response.content else []
                log.warning("eBay rejected an image search: HTTP %s %s", response.status_code, codes)
                raise MatchError(502, "provider_rejected", "eBay couldn't search with this image. Try scanning the garment again.")
            return response.json().get("itemSummaries") or []
        return []

    async def search(self, category: str, image: bytes, color: str | None, brand_hints: list[str]) -> list[Listing]:
        encoded = base64.b64encode(image).decode()
        pages = await asyncio.gather(*(self._search_category(cid, encoded) for cid in EBAY_CATEGORY_IDS[category]))
        seen: set[str] = set()
        candidates: list[tuple[int, Listing]] = []
        for page in pages:
            for position, item in enumerate(page):
                if not keep(category, item):
                    continue
                listing = listing_from_ebay(item)
                if listing and listing.id not in seen:
                    seen.add(listing.id)
                    candidates.append((position, listing))
        return rank(candidates, color, brand_hints)[:MAX_RESULTS]


class FixtureMatcher:
    """FITMIX_MATCH_PROVIDER=fixture: development data, clearly marked, nothing sent anywhere."""

    name = "fixture"
    fixture = True

    async def search(self, category: str, image: bytes, color: str | None, brand_hints: list[str]) -> list[Listing]:
        await asyncio.sleep(1)
        label = {"tshirt": "T-shirt"}.get(category, category.capitalize())
        return [Listing(id=f"fixture-{category}", title=f"Test fixture {label.lower()} (not a real listing)",
                        retailer="FitMix test fixture", seller=None, image_url=None, url=None,
                        price={"value": "42.00", "currency": "USD"})]
