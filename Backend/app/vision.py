"""Retailer matching through the FitMix vision service (vision-service/): Google Lens + Google Shopping, re-ranked.

Selected with FITMIX_MATCH_PROVIDER=vision. The app's request is unchanged: it sends only the tapped garment's
crop and category. This matcher forwards the crop to the vision service (`POST /analyze` with the crop, then
`POST /search` for it) and returns its best online matches as listings. Titles, prices, pictures and links
are the shops' own. Results are "similar" matches: image search is no evidence of the exact product.
"""

import hashlib
import logging
from urllib.parse import urlsplit

import httpx

from .retail import MAX_RESULTS, Listing, MatchError

log = logging.getLogger("fitmix")

UNREACHABLE = "The vision service isn't running or can't be reached. Start vision-service/run.sh and try again."


class VisionMatcher:
    name = "vision"

    def __init__(self, base_url: str, token: str = "", timeout_seconds: float = 60.0,
                 transport: httpx.AsyncBaseTransport | None = None):
        self.base_url = base_url.rstrip("/")
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        self.http = httpx.AsyncClient(timeout=timeout_seconds, headers=headers, transport=transport)
        # True when the vision service answers with MOCK_MODE data, so the app labels it as test data.
        self.fixture = False

    async def search(self, category: str, image: bytes, color: str | None, brand_hints: list[str]) -> list[Listing]:
        analysis = await self._post("/analyze", files={"crops": ("garment.jpg", image, "image/jpeg")},
                                    data={"categories": category})
        self.fixture = bool(analysis.get("mock"))
        if not analysis.get("garments"):
            raise MatchError(502, "provider_error", _first_message(analysis.get("errors"))
                             or "The vision service couldn't read this garment. Try again.")
        found = await self._post("/search", json={"analysis_id": analysis["analysis_id"], "garment_index": 0})
        self.fixture = bool(found.get("mock"))
        matches = found.get("online_matches") or []
        if not matches and found.get("errors"):
            raise MatchError(503, "provider_busy", _first_message(found["errors"]) or "Product search failed. Try again.")
        listings = [listing for listing in map(listing_from_match, matches) if listing is not None]
        return listings[:MAX_RESULTS]

    async def _post(self, path: str, **kwargs) -> dict:
        try:
            response = await self.http.post(f"{self.base_url}{path}", **kwargs)
        except httpx.TimeoutException:
            raise MatchError(504, "provider_timeout", "The product search took too long. Try again.")
        except httpx.HTTPError:
            raise MatchError(502, "provider_unreachable", UNREACHABLE)
        try:
            body = response.json()
        except ValueError:
            body = {}
        if response.status_code == 200:
            return body
        error = (body.get("error") or {}) if isinstance(body, dict) else {}
        code, message = error.get("code"), error.get("message")
        log.info("vision service %s: HTTP %s (%s)", path, response.status_code, code)
        if response.status_code == 401:
            raise MatchError(502, "provider_auth", "The vision service refused the backend (check VISION_APP_TOKEN in both .env files).")
        if code == "not_configured":
            raise MatchError(503, "not_configured", message or "The vision service isn't set up yet.")
        raise MatchError(502, "provider_error", message or "The vision service had a problem. Try again.")


def listing_from_match(match: dict) -> Listing | None:
    url, title = match.get("url"), (match.get("title") or "").strip()
    if not url or not title:
        return None
    price = match.get("price")
    retailer = match.get("retailer") or urlsplit(url).netloc.removeprefix("www.") or "Online shop"
    return Listing(id=hashlib.sha256(url.encode()).hexdigest()[:16], title=title, retailer=retailer, seller=None,
                   image_url=match.get("image"), url=url,
                   price={"value": price["value"], "currency": price["currency"]} if price else None)


def _first_message(errors) -> str | None:
    for error in errors or []:
        if isinstance(error, dict) and error.get("message"):
            return error["message"]
    return None
