"""eBay Browse API client used by `providers.EbayProvider`: OAuth app token, `item_summary/search_by_image`, the
category check for its results, and turning an item summary into listing fields. Ranking and match labels live in
`visual_search.py`; eBay is one provider among several.
"""

import asyncio
import base64
import logging
import re
import time
from dataclasses import asdict, dataclass

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


def keep(category: str, item: dict) -> bool:
    """True when an eBay item summary is in the selected garment category."""
    names = " ".join(c.get("categoryName", "") for c in item.get("categories") or []).lower()
    if not any(word in names for word in CATEGORY_WORDS[category]):
        return False
    title_words = TITLE_WORDS.get(category)
    if title_words and "t-shirts" not in names:
        return any(word in (item.get("title") or "").lower() for word in title_words)
    return True


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
