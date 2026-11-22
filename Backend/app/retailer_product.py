"""Verify discovered listings and prepare retailer photos for visual comparison."""

import asyncio
import io
import ipaddress
import json
import re
import socket
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from html import unescape
from urllib.parse import urljoin

import httpx
from PIL import Image, ImageOps, UnidentifiedImageError

from .listing import _first, _products

CURRENCY = "CAD"
MAX_PAGE = 2_500_000
MAX_PHOTO = 4_000_000
IPV6_TRANSLATION = tuple(map(ipaddress.ip_network, ("64:ff9b::/96", "64:ff9b:1::/48", "2002::/16", "2001::/32")))


def price(value) -> Decimal | None:
    try:
        amount = Decimal(str(value))
        return amount if amount.is_finite() and 0 < amount <= 100000 and amount == amount.quantize(Decimal(".01")) else None
    except InvalidOperation:
        return None


def product_codes(words) -> set[str]:
    return {clean for word in words if re.fullmatch(r"[a-zA-Z0-9-]{6,32}", word)
            and (clean := word.replace("-", "").upper()) and len(clean) >= 6
            and (clean.isdigit() and len(clean) in (8, 12, 13, 14)
                 or any(c.isalpha() for c in clean) and any(c.isdigit() for c in clean))}


def public_https(value) -> httpx.URL | None:
    if not isinstance(value, str) or len(value) > 2048:
        return None
    try:
        url = httpx.URL(value)
    except (httpx.InvalidURL, ValueError):
        return None
    if (url.scheme != "https" or not url.host or url.port not in (None, 443) or url.userinfo
            or "." not in url.host):
        return None
    return url.copy_with(fragment=None)


def _resolve_url(base: str, value: str) -> httpx.URL | None:
    try:
        return public_https(urljoin(base, value))
    except ValueError:
        return None


def public_addresses(host: str) -> list[str]:
    addresses = {ipaddress.ip_address(row[4][0]) for row in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)}
    if any(not ip.is_global or ip.is_multicast or ip.is_reserved or
           (ip.version == 6 and (ip.ipv4_mapped is not None or any(ip in net for net in IPV6_TRANSLATION)))
           for ip in addresses):
        return []
    return [str(ip) for ip in sorted(addresses, key=lambda ip: (ip.version, int(ip)))]


class PublicRetailerHTTP:
    def __init__(self, http=None, resolve=public_addresses):
        self.http = http or httpx.AsyncClient(trust_env=False, timeout=httpx.Timeout(4, connect=2.5),
                                              limits=httpx.Limits(max_connections=16, max_keepalive_connections=0))
        self.resolve = resolve
        self.slots = asyncio.Semaphore(16)

    async def get(self, value: str, mime: str, limit: int) -> tuple[str, bytes] | None:
        # Pin the verified DNS result while retaining the merchant hostname for HTTP and TLS.
        # Redirects are followed manually so every destination gets the same checks.
        url = public_https(value)
        try:
            async with self.slots, asyncio.timeout(9):
                for _ in range(4):
                    if url is None:
                        return None
                    ips = await asyncio.to_thread(self.resolve, url.host)
                    if not ips:
                        return None
                    target = url.copy_with(host=ips[0])
                    request = httpx.Request("GET", target, headers={
                        "Host": url.raw_host.decode("ascii"), "Accept": mime + "*" if mime.endswith("/") else mime,
                        "User-Agent": "FitMixListingReader/1.0",
                    }, extensions={"sni_hostname": url.raw_host.decode("ascii")})
                    response = await self.http.send(request, stream=True)
                    try:
                        if response.status_code in (301, 302, 303, 307, 308):
                            location = response.headers.get("location")
                            url = public_https(urljoin(str(url), location)) if location else None
                            continue
                        if response.status_code != 200 or not response.headers.get("content-type", "").lower().startswith(mime):
                            return None
                        data = bytearray()
                        async for chunk in response.aiter_bytes(chunk_size=65536):
                            if len(data) + len(chunk) > limit:
                                return None
                            data.extend(chunk)
                        return str(url), bytes(data)
                    finally:
                        await response.aclose()
        except (TimeoutError, httpx.HTTPError, OSError, ValueError):
            return None
        return None


@dataclass(frozen=True)
class Listing:
    title: str
    retailer: str
    brand: str | None
    url: str
    image_url: str
    amount: Decimal
    currency: str
    exact: bool

    def result(self, score: int) -> dict:
        return {
            "id": self.url, "title": self.title, "retailer": self.retailer, "brand": self.brand,
            "url": self.url, "image_url": self.image_url,
            "price": {"value": str(self.amount), "currency": self.currency},
            "match": "exact" if self.exact else "similar", "visual_score": score,
            "provider": "trendtrack",
            "evidence": ["A code visible on the garment matches the retailer’s in-stock product."] if self.exact else [],
        }


def _string(value, limit: int = 180) -> str:
    return value.strip()[:limit] if isinstance(value, str) else ""


def _in_stock_offer(offer):
    if not isinstance(offer, dict):
        return None
    availability = _string(offer.get("availability")).rstrip("/").rsplit("/", 1)[-1]
    if availability not in ("InStock", "LimitedAvailability"):
        return None
    spec = offer.get("priceSpecification")
    spec = spec if isinstance(spec, dict) else {}
    amount = price(offer.get("price", spec.get("price")))
    currency = _string(offer.get("priceCurrency", spec.get("priceCurrency")))
    if amount is None or not re.fullmatch(r"[A-Z]{3}", currency):
        return None
    return amount, currency


def verified_offers(html: str, page_url: str, store_name: str, codes: set[str]) -> list[Listing]:
    page = public_https(page_url)
    if page is None:
        return []
    retailer = _string(store_name) or page.host
    offers = []
    for block in re.findall(r"<script[^>]+application/ld\+json[^>]*>(.*?)</script>", html, re.S | re.I):
        try:
            products = list(_products(json.loads(block.strip())))
        except (ValueError, RecursionError):
            try:
                products = list(_products(json.loads(unescape(block.strip()))))
            except (ValueError, RecursionError):
                continue
        for product in products:
            kinds = product.get("@type")
            if kinds != "Product" and not (isinstance(kinds, list) and "Product" in kinds):
                continue
            title, image = _string(product.get("name")), _string(_first(product.get("image")), 2048)
            if not title or not image:
                continue
            photo = _resolve_url(page_url, image)
            if photo is None:
                continue
            raw_product_url = _string(_first(product.get("url")), 2048)
            product_url = _resolve_url(page_url, raw_product_url) if raw_product_url else page
            if product_url is None or product_url.host != page.host or product_url.path != page.path:
                continue
            product_offers = product.get("offers")
            for offer in product_offers if isinstance(product_offers, list) else [product_offers]:
                verified = _in_stock_offer(offer)
                if verified is None:
                    continue
                amount, currency = verified
                raw_url = _string(_first(offer.get("url")), 2048)
                link = _resolve_url(page_url, raw_url) if raw_url else product_url
                if link is None or link.host != page.host or link.path != page.path:
                    continue
                independent_codes = product_codes(
                    str(record.get(key) or "") for record in (offer, product)
                    for key in ("sku", "mpn", "gtin", "gtin8", "gtin12", "gtin13", "gtin14")
                )
                offers.append(Listing(title, retailer, _string(_first(product.get("brand"))) or None,
                                      str(link), str(photo), amount, currency, bool(codes & independent_codes)))
    offers.sort(key=lambda offer: (not offer.exact, offer.currency != CURRENCY, offer.currency, offer.amount))
    return offers


def comparison_jpeg(data: bytes) -> bytes | None:
    try:
        with Image.open(io.BytesIO(data), formats=["JPEG", "PNG", "WEBP", "GIF"]) as original:
            if original.width * original.height > 16_000_000:
                return None
            original.thumbnail((512, 512))
            image = ImageOps.exif_transpose(original).convert("RGB")
            output = io.BytesIO()
            image.save(output, format="JPEG", quality=85)
            return output.getvalue()
    except (Image.DecompressionBombError, UnidentifiedImageError, OSError, ValueError):
        return None


class RetailerVerifier:
    def __init__(self, http=None):
        self.http = http or PublicRetailerHTTP()

    async def verify(self, url: str, domain: str, name: str, codes: set[str], cap: Decimal | None):
        page = await self.http.get(url, "text/html", MAX_PAGE)
        if page is None:
            return None
        page_url, data = page
        final_host = httpx.URL(page_url).host.removeprefix("www.")
        # If a search hit redirected to a different retailer, display the verified domain.
        store = name if final_host == domain.lower().removeprefix("www.") else final_host
        offers = verified_offers(data.decode(errors="replace"), page_url, store, codes)
        seen_photos = set()
        for offer in offers:
            if cap is not None and (offer.currency != CURRENCY or offer.amount > cap):
                continue
            if offer.image_url in seen_photos:
                continue
            seen_photos.add(offer.image_url)
            photo = await self.http.get(offer.image_url, "image/", MAX_PHOTO)
            if photo and (jpeg := await asyncio.to_thread(comparison_jpeg, photo[1])):
                return offer, jpeg
            if len(seen_photos) >= 2:
                break
        return None
