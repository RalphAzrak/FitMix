"""Read product pages found on the web and prepare their photos for visual comparison."""

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
MAX_COLORWAYS = 3
VARIANT_PARAMS = frozenset({"variant", "variantid", "option_values", "color", "colour", "colorid", "colourid",
                            "colorway", "size", "pattern", "style", "material", "sku"})
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


def variant_selector(url: httpx.URL) -> tuple[tuple[str, str], ...]:
    return tuple(sorted((key.casefold(), value) for key, value in url.params.multi_items()
                        if key.casefold() in VARIANT_PARAMS and value))


def listing_key(value: str) -> str:
    url = httpx.URL(value)
    selector = httpx.QueryParams(variant_selector(url))
    return url.host.removeprefix("www.") + url.path.rstrip("/") + (f"?{selector}" if selector else "")


def _same_product(a: httpx.URL, b: httpx.URL) -> bool:
    return a.host == b.host and a.path.rstrip("/") == b.path.rstrip("/")


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
    # None when the page doesn't state a price.
    amount: Decimal | None
    currency: str | None
    exact: bool
    color: str | None = None
    pattern: str | None = None

    @property
    def variant_attributes(self) -> dict[str, str]:
        return {key: value for key, value in (("color", self.color), ("pattern", self.pattern)) if value}

    def result(self, score: int) -> dict:
        return {
            "id": self.url, "title": self.title, "retailer": self.retailer, "brand": self.brand,
            "url": self.url, "image_url": self.image_url,
            "price": {"value": str(self.amount), "currency": self.currency} if self.amount is not None else None,
            "match": "exact" if self.exact else "similar", "visual_score": score,
            "provider": "web",
            "variant_color": self.color,
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


def _product_records(html: str):
    records = []
    for block in re.findall(r"<script[^>]+application/ld\+json[^>]*>(.*?)</script>", html, re.S | re.I):
        try:
            records.extend(list(_products(json.loads(block.strip()))))
        except (ValueError, RecursionError):
            try:
                records.extend(list(_products(json.loads(unescape(block.strip())))))
            except (ValueError, RecursionError):
                continue
    groups = [record for record in records if _is_type(record, "ProductGroup")]
    groups_by_id = {group[key]: group for group in groups for key in ("@id", "productGroupID")
                    if isinstance(group.get(key), str)}
    membership = {}
    references = {}
    for group in groups:
        children = group.get("hasVariant")
        for child in children if isinstance(children, list) else [children]:
            if isinstance(child, dict):
                membership[id(child)] = group
                if isinstance(child.get("@id"), str):
                    references[child["@id"]] = group
    for product in records:
        if _is_type(product, "Product") and not _is_type(product, "ProductGroup"):
            parent = product.get("isVariantOf")
            parent_id = parent.get("@id") if isinstance(parent, dict) else parent
            group = membership.get(id(product)) or references.get(_property(product, "@id", 2048))
            if group is None:
                group = groups_by_id.get(parent_id if isinstance(parent_id, str) else None)
                group = group or groups_by_id.get(_property(product, "inProductGroupWithID"))
            yield product, group or {}


def _is_type(record, name: str) -> bool:
    kinds = record.get("@type")
    return kinds == name or isinstance(kinds, list) and name in kinds


def _property(record, name: str, limit: int = 180) -> str | None:
    return _string(_first(record.get(name)), limit) or None


def _image_url(page_url: str, value) -> httpx.URL | None:
    raw = _string(_first(value), 2048)
    return _resolve_url(page_url, raw) if raw else None


def verified_offers(html: str, page_url: str, store_name: str, codes: set[str], *,
                    selected: tuple[tuple[str, str], ...] = ()) -> list[Listing]:
    page = public_https(page_url)
    if page is None:
        return []
    retailer = _string(store_name) or page.host
    selected = set(selected or variant_selector(page))
    offers = []
    for product, group in _product_records(html):
        title = _property(product, "name") or _property(group, "name")
        explicit_product_url = _property(product, "url", 2048)
        product_url = _resolve_url(page_url, explicit_product_url) if explicit_product_url else page.copy_with(query=None)
        if not title or product_url is None or not _same_product(product_url, page):
            continue
        product_selection = set(variant_selector(product_url))
        offered = product.get("offers")
        offered = offered if isinstance(offered, list) else [offered]
        group_color = _property(group, "color")
        group_pattern = _property(group, "pattern")
        group_url = _property(group, "url", 2048)
        group_page = _resolve_url(page_url, group_url) if group_url else None
        varies_by = group.get("variesBy")
        varies_by = varies_by if isinstance(varies_by, list) else [varies_by]
        varies_by = {str(value).rsplit("/", 1)[-1].casefold() for value in varies_by}
        for offer in offered:
            verified = _in_stock_offer(offer)
            if not verified:
                continue
            amount, currency = verified
            raw_url = _property(offer, "url", 2048)
            link = _resolve_url(page_url, raw_url) if raw_url else product_url
            if link is None or not _same_product(link, page):
                continue
            selectors = set(variant_selector(link))
            own_page = bool((raw_url or explicit_product_url) and group_page and not _same_product(group_page, link))
            if ((selected and not selected <= selectors)
                    or (product_selection and not product_selection <= selectors)
                    or (group and not selectors and not own_page)):
                continue
            # A generic Product hero does not identify offers for different colorways.
            tied_product = (not selectors or bool(product_selection and product_selection <= selectors)
                            or bool(group and len(offered) == 1))
            photo = _image_url(page_url, offer.get("image"))
            if photo is None and tied_product:
                photo = _image_url(page_url, product.get("image"))
            if photo is None:
                continue
            color = _property(offer, "color")
            pattern = _property(offer, "pattern")
            if tied_product:
                color = color or _property(product, "color")
                pattern = pattern or _property(product, "pattern")
            color = color or (group_color if "color" not in varies_by else None)
            pattern = pattern or (group_pattern if "pattern" not in varies_by else None)
            records = (offer, product) if tied_product else (offer,)
            independent_codes = product_codes(
                str(record.get(key) or "") for record in records
                for key in ("sku", "mpn", "gtin", "gtin8", "gtin12", "gtin13", "gtin14", "barcode")
            )
            brand = _property(product, "brand") or _property(group, "brand")
            offers.append(Listing(title, retailer, brand, str(link), str(photo), amount, currency,
                                  bool(codes & independent_codes), color, pattern))
    offers.sort(key=lambda offer: (not offer.exact, offer.currency != CURRENCY, offer.currency, offer.amount))
    return offers


META_TAG = re.compile(r"<meta\b[^>]*>", re.I)
META_ATTRIBUTE = re.compile(r"""([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')""")
SOLD_OUT = frozenset({"OutOfStock", "SoldOut", "Discontinued"})


def _page_meta(html: str) -> dict[str, str]:
    found = {}
    for tag in META_TAG.findall(html[:500_000])[:400]:
        attributes = {key.casefold(): unescape(double or single).strip()
                      for key, double, single in META_ATTRIBUTE.findall(tag)}
        key = (attributes.get("property") or attributes.get("name") or "").casefold()
        if key and attributes.get("content"):
            found.setdefault(key, attributes["content"])
    return found


def _stated_price(offer: dict) -> tuple[Decimal, str] | None:
    spec = offer.get("priceSpecification")
    spec = spec if isinstance(spec, dict) else {}
    amount = price(offer.get("price", spec.get("price")))
    currency = _string(offer.get("priceCurrency", spec.get("priceCurrency"))).upper()
    return (amount, currency) if amount is not None and re.fullmatch(r"[A-Z]{3}", currency) else None


def page_listing(html: str, page_url: str, store_name: str, *,
                 selected: tuple[tuple[str, str], ...] = ()) -> Listing | None:
    """A product page with no structured in-stock offer: the title and photo the page gives for itself, and
    its price when it states one. A page that says the product is sold out, or that isn't about one product,
    gives nothing."""
    page = public_https(page_url)
    if page is None:
        return None
    selected = set(selected or variant_selector(page))
    meta = _page_meta(html)
    products = [product for product, _ in _product_records(html)]
    own: list[tuple[dict, httpx.URL]] = []
    for product in products:
        link = _property(product, "url", 2048)
        target = _resolve_url(page_url, link) if link else None
        if target and _same_product(target, page):
            selectors = set(variant_selector(target))
            if selected <= selectors and (selected or not selectors):
                own.append((product, target))
        elif not link and not selected and len(products) == 1:
            own.append((product, page))
    if selected and len(own) != 1:
        return None
    record, product_url = own[0] if len(own) == 1 else ({}, page)
    offered = record.get("offers")
    offers = [offer for offer in (offered if isinstance(offered, list) else [offered]) if isinstance(offer, dict)]
    if selected:
        offers = [offer for offer in offers if not (link := _property(offer, "url", 2048))
                  or ((target := _resolve_url(page_url, link)) and _same_product(target, page)
                      and selected <= set(variant_selector(target)))]
    stock = {_string(offer.get("availability")).rstrip("/").rsplit("/", 1)[-1] for offer in offers} - {""}
    if stock and stock <= SOLD_OUT:
        return None
    stated = (_string(meta.get("product:price:amount") or meta.get("og:price:amount")),
              _string(meta.get("product:price:currency") or meta.get("og:price:currency")))
    if not record and not meta.get("og:type", "").casefold().startswith("product") and not stated[0]:
        return None
    title = _property(record, "name") or _string(meta.get("og:title")) or _string(meta.get("twitter:title"))
    photo = _image_url(page_url, record.get("image"))
    if not selected:
        for key in ("og:image:secure_url", "og:image", "twitter:image"):
            if photo is None and meta.get(key):
                photo = _resolve_url(page_url, meta[key])
    if not title or photo is None:
        return None
    # Offers that disagree are different variants, and the page doesn't say which one the photo shows.
    prices = {found for offer in offers if (found := _stated_price(offer))}
    cost = next(iter(prices)) if len(prices) == 1 else None
    if not prices and not selected:
        cost = _stated_price({"price": stated[0], "priceCurrency": stated[1]})
    amount, currency = cost or (None, None)
    return Listing(title, _string(store_name) or page.host, _property(record, "brand"), str(product_url), str(photo),
                   amount, currency, False, _property(record, "color"), _property(record, "pattern"))


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
    """Reads one found page. A structured in-stock offer is used when the page has one; otherwise the page's
    own title and photo. Each store page is read once."""

    def __init__(self, http=None):
        self.http = http or PublicRetailerHTTP()

    async def verify(self, url: str, domain: str, name: str, codes: set[str],
                     cap: Decimal | None) -> list[tuple[Listing, bytes]]:
        page = await self.http.get(url, "text/html", MAX_PAGE)
        if page is None:
            return []
        page_url, data = page
        final_url = httpx.URL(page_url)
        final_host = final_url.host.removeprefix("www.")
        # If a search hit redirected to a different retailer, display the verified domain.
        store = name if final_host == domain.lower().removeprefix("www.") else final_host
        html = data.decode(errors="replace")
        selected = variant_selector(httpx.URL(url)) or variant_selector(final_url)
        offers = verified_offers(html, page_url, store, codes, selected=selected)
        if not offers and (listing := page_listing(html, page_url, store, selected=selected)):
            offers = [listing]
        colorways = {}
        for offer in offers:
            # A budget can only use listings priced in its currency.
            if cap is not None and (offer.amount is None or offer.currency != CURRENCY or offer.amount > cap):
                continue
            colorways.setdefault((offer.image_url, offer.color, offer.pattern), offer)
            if len(colorways) >= MAX_COLORWAYS:
                break
        results = await asyncio.gather(*(self._photo(offer) for offer in colorways.values()))
        return [result for result in results if result is not None]

    async def _photo(self, offer: Listing) -> tuple[Listing, bytes] | None:
        photo = await self.http.get(offer.image_url, "image/", MAX_PHOTO)
        if photo and (jpeg := await asyncio.to_thread(comparison_jpeg, photo[1])):
            return offer, jpeg
        return None
