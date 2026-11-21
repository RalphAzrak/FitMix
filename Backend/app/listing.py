"""Reads a product listing page for the facts FitMix shows: photo, price, currency, brand and product codes.

Values come only from the page's own structured data (schema.org Product JSON-LD, then OpenGraph/product meta
tags). Nothing is inferred: if a page has no price, the listing keeps "no price" and the app says
"Price unavailable". Only public http(s) pages are fetched; private, loopback and link-local addresses are
refused so a listing URL can't reach internal services. Nothing about the user is sent.
"""

import asyncio
import ipaddress
import json
import logging
import re
import socket
from dataclasses import replace
from html import unescape
from urllib.parse import urljoin, urlparse

import httpx

from .visual_search import Candidate

log = logging.getLogger("fitmix")

MAX_BYTES = 1_500_000
CURRENCY_CODE = re.compile(r"^[A-Z]{3}$")


def _public_host(host: str) -> bool:
    try:
        infos = socket.getaddrinfo(host, None)
    except OSError:
        return False
    for info in infos:
        address = ipaddress.ip_address(info[4][0])
        if address.is_private or address.is_loopback or address.is_link_local or address.is_reserved or address.is_multicast:
            return False
    return True


def _products(node):
    """Every schema.org Product in a JSON-LD tree (handles @graph and lists)."""
    if isinstance(node, list):
        for item in node:
            yield from _products(item)
    elif isinstance(node, dict):
        kind = node.get("@type")
        kinds = kind if isinstance(kind, list) else [kind]
        if "Product" in kinds or "ProductGroup" in kinds:
            yield node
        for key in ("@graph", "mainEntity", "hasVariant"):
            if key in node:
                yield from _products(node[key])


def _first(value):
    if isinstance(value, list):
        return _first(value[0]) if value else None
    if isinstance(value, dict):
        return value.get("url") or value.get("contentUrl") or value.get("name")
    return value


def _offer_price(offers) -> dict | None:
    for offer in offers if isinstance(offers, list) else [offers]:
        if not isinstance(offer, dict):
            continue
        value = offer.get("price") or offer.get("lowPrice")
        spec = offer.get("priceSpecification")
        currency = offer.get("priceCurrency") or (spec.get("priceCurrency") if isinstance(spec, dict) else None)
        if value is None and isinstance(spec, dict):
            value = spec.get("price")
        try:
            amount = float(str(value).replace(",", ""))
        except (TypeError, ValueError):
            continue
        if currency and CURRENCY_CODE.match(str(currency)) and amount > 0:
            return {"value": f"{amount:.2f}", "currency": str(currency)}
    return None


def parse_listing(html: str, base_url: str) -> dict:
    """{"title", "image_url", "price", "brand", "codes"} from a page; missing values are None/[]."""
    found: dict = {"title": None, "image_url": None, "price": None, "brand": None, "codes": []}
    for block in re.findall(r"<script[^>]+application/ld\+json[^>]*>(.*?)</script>", html, re.S | re.I):
        try:
            data = json.loads(unescape(block.strip()))
        except ValueError:
            continue
        for product in _products(data):
            found["title"] = found["title"] or product.get("name")
            image = _first(product.get("image"))
            found["image_url"] = found["image_url"] or (urljoin(base_url, image) if isinstance(image, str) else None)
            found["price"] = found["price"] or _offer_price(product.get("offers"))
            brand = product.get("brand")
            found["brand"] = found["brand"] or (_first(brand) if brand else None)
            for key in ("sku", "mpn", "gtin", "gtin8", "gtin12", "gtin13", "gtin14", "productID", "model"):
                value = product.get(key)
                if isinstance(value, (str, int)) and str(value).strip():
                    found["codes"].append(str(value).strip())

    def meta(name: str) -> str | None:
        match = re.search(rf"<meta[^>]+(?:property|name)=[\"']{re.escape(name)}[\"'][^>]+content=[\"']([^\"']+)", html, re.I) \
            or re.search(rf"<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+(?:property|name)=[\"']{re.escape(name)}[\"']", html, re.I)
        return unescape(match.group(1)).strip() if match else None

    found["image_url"] = found["image_url"] or (urljoin(base_url, meta("og:image")) if meta("og:image") else None)
    found["title"] = found["title"] or meta("og:title")
    if not found["price"]:
        amount = meta("product:price:amount") or meta("og:price:amount")
        currency = meta("product:price:currency") or meta("og:price:currency")
        if amount and currency and CURRENCY_CODE.match(currency):
            try:
                found["price"] = {"value": f"{float(amount.replace(',', '')):.2f}", "currency": currency}
            except ValueError:
                pass
    found["brand"] = found["brand"] or meta("product:brand") or meta("og:brand")
    return found


class ListingEnricher:
    """Fills a candidate's photo, price, brand and codes from its listing page, keeping provider values when the
    page has none."""

    def __init__(self, http: httpx.AsyncClient | None = None, timeout: float = 6.0, check_host=_public_host):
        self.check_host = check_host

        async def every_hop(request: httpx.Request):
            # Checked on each request, redirects included, so a public page can't bounce to an internal host.
            if not await asyncio.to_thread(self.check_host, request.url.host or ""):
                raise httpx.RequestError("listing host isn't public", request=request)

        self.http = http or httpx.AsyncClient(timeout=httpx.Timeout(timeout, connect=3.0), follow_redirects=True,
                                              max_redirects=4, event_hooks={"request": [every_hop]},
                                              headers={"User-Agent": "Mozilla/5.0 (compatible; FitMixListingReader/1.0)",
                                                       "Accept": "text/html,application/xhtml+xml"})

    async def enrich(self, candidate: Candidate) -> Candidate:
        url = candidate.url
        if not url or urlparse(url).scheme not in ("http", "https") or candidate.fixture:
            return candidate
        if not await asyncio.to_thread(self.check_host, urlparse(url).hostname or ""):
            return candidate
        try:
            async with self.http.stream("GET", url) as response:
                if response.status_code != 200 or "html" not in response.headers.get("content-type", ""):
                    return candidate
                chunks, size = [], 0
                async for chunk in response.aiter_bytes():
                    chunks.append(chunk)
                    size += len(chunk)
                    if size > MAX_BYTES:
                        break
                html = b"".join(chunks).decode(response.encoding or "utf-8", errors="replace")
                final_url = str(response.url)
        except httpx.HTTPError:
            return candidate
        page = parse_listing(html, final_url)
        return replace(candidate,
                       image_url=page["image_url"] or candidate.image_url,
                       price=page["price"] or candidate.price,
                       brand=page["brand"] or candidate.brand,
                       codes=list(dict.fromkeys(candidate.codes + page["codes"])))
