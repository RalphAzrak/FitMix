"""Cross-retailer visual product search for one garment the user tapped in the live camera.

Pipeline for one request:
  1. Every enabled provider (eBay, Google Lens via Scrappa, fixtures) is asked in parallel with the garment crop
     and the clues read on the phone. A provider that fails doesn't sink the others.
  2. Candidates are de-duplicated by listing URL and limited to the selected category.
  3. The best few are enriched from the listing page itself (schema.org Product data): photo, price, currency,
     brand and product codes come from the retailer, never from a guess.
  4. Each candidate gets a tier from the evidence that supports it:
       - "exact":   a product code / SKU on the garment matches the listing, or the brand AND model name AND
                    colour read on the garment all match, or the provider found the very same image AND the
                    brand is supported.
       - "brand":   only the brand is supported ("Likely from Nike"): read on the garment, or (when nothing can
                    be read, e.g. a curved logo patch) most of the top visual matches agree on it.
       - "similar": the closest real alternative.
     and a score (tier first, then provider rank and the clues it shares). The app adds its own on-device
     photo similarity within each tier.

Only the garment crop is ever handed to a provider. Full frames, profile photos and avatar images never reach
this module.
"""

import asyncio
import logging
import re
from dataclasses import dataclass, field
from typing import Protocol
from urllib.parse import parse_qs, urlparse, urlunparse

log = logging.getLogger("fitmix")

CATEGORIES = ("jacket", "tshirt", "pants", "shoes")

# Words that put a listing in a category. A listing naming another category's words (and none of its own)
# is dropped: a shoe search never shows a T-shirt.
CATEGORY_WORDS = {
    "jacket": ("jacket", "coat", "parka", "blazer", "bomber", "windbreaker", "anorak", "puffer", "hoodie", "shacket",
               "overshirt", "gilet", "trucker"),
    # Not "top": shoes are "high top" / "low top".
    "tshirt": ("t-shirt", "t shirt", "tshirt", "tee", "tees", "jersey", "crewneck", "crew neck"),
    "pants": ("pants", "pant", "trousers", "trouser", "jeans", "jean", "chinos", "chino", "joggers", "jogger",
              "slacks", "cargos", "sweatpants", "leggings"),
    "shoes": ("shoe", "shoes", "sneaker", "sneakers", "trainer", "trainers", "boot", "boots", "loafer", "loafers",
              "sandal", "sandals", "heel", "heels", "runner", "runners", "clog", "clogs", "mule", "mules", "slip-on",
              "flats", "oxford", "derby"),
}

KNOWN_BRANDS = (
    "nike", "adidas", "puma", "reebok", "new balance", "asics", "converse", "vans", "jordan", "under armour",
    "hanes", "gildan", "fruit of the loom", "comfort colors", "new era",
    "levi's", "levis", "wrangler", "lee", "diesel", "carhartt", "dickies", "patagonia", "the north face",
    "north face", "columbia", "arc'teryx", "uniqlo", "zara", "h&m", "gap", "old navy", "ralph lauren",
    "polo ralph lauren", "tommy hilfiger", "calvin klein", "lacoste", "fila", "champion", "supreme", "stussy",
    "gucci", "prada", "balenciaga", "dr. martens", "dr martens", "timberland", "birkenstock", "crocs", "salomon",
    "hoka", "on running", "lululemon", "aritzia", "everlane", "j.crew", "banana republic", "guess", "hollister",
    "abercrombie", "american eagle", "superdry", "fred perry", "stone island", "moncler", "canada goose",
)

# Pages that show clothes but don't sell them: never offered as a match.
NON_RETAIL = ("instagram.com", "pinterest.", "facebook.com", "tiktok.com", "reddit.com", "youtube.com", "x.com",
              "twitter.com", "wikipedia.org", "wikimedia.org", "tumblr.com", "flickr.com", "lookbook.nu")

TIER_WEIGHT = {"exact": 3.0, "brand": 2.0, "similar": 1.0}
MAX_RESULTS = 10
ENRICH_TOP = 6


@dataclass
class Clues:
    """What the phone read on the garment crop. All optional except the category."""

    category: str
    color: str | None = None
    brand_hints: list[str] = field(default_factory=list)
    # Every word or code read on the garment, e.g. ["air", "force", "dd8959-100"].
    text: list[str] = field(default_factory=list)
    pattern: str | None = None  # "polka dots", "leopard", "text print"
    style: str | None = None  # "sneaker", "boot", "hoodie", "jeans", ...

    @property
    def codes(self) -> list[str]:
        """Tokens that look like product codes / style numbers (letters and digits, 5+ characters)."""
        return [t for t in self.text if len(t) >= 5 and re.search(r"\d", t) and re.search(r"[a-z]", t, re.I)
                or re.fullmatch(r"\d{6,}", t)]

    @property
    def brands(self) -> list[str]:
        """Known brands spelled out in the text or hints."""
        words = " ".join(self.brand_hints + self.text).lower()
        return [b for b in KNOWN_BRANDS if re.search(rf"(?<![a-z]){re.escape(b)}(?![a-z])", words)]


@dataclass
class Candidate:
    """A listing a provider returned, as close to the provider's data as possible."""

    id: str
    title: str
    url: str | None
    retailer: str
    provider: str
    rank: int  # 0-based position in that provider's own results
    image_url: str | None = None
    price: dict | None = None  # {"value": "48.00", "currency": "USD"} or None
    brand: str | None = None
    codes: list[str] = field(default_factory=list)  # SKU / MPN / GTIN / style codes from the listing
    seller: str | None = None
    same_image: bool = False  # the provider says it found this very image (e.g. Lens exact_matches)
    fixture: bool = False


@dataclass
class Ranked:
    candidate: Candidate
    tier: str
    brand: str | None
    evidence: list[str]
    score: float

    def to_json(self) -> dict:
        c = self.candidate
        return {"id": c.id, "title": c.title, "retailer": c.retailer, "seller": c.seller, "image_url": c.image_url,
                "url": c.url, "price": c.price, "match": self.tier, "brand": self.brand, "evidence": self.evidence,
                "provider": c.provider, "fixture": c.fixture, "score": round(self.score, 3)}


class ProviderError(Exception):
    def __init__(self, code: str, message: str, retryable: bool = True):
        super().__init__(message)
        self.code, self.message, self.retryable = code, message, retryable


class VisualProvider(Protocol):
    name: str
    fixture: bool

    async def search(self, crop: bytes, clues: Clues) -> list[Candidate]: ...


class Enricher(Protocol):
    async def enrich(self, candidate: Candidate) -> Candidate: ...


# MARK: - Evidence


def _contains(text: str, phrase: str) -> bool:
    return re.search(rf"(?<![a-z0-9]){re.escape(phrase.lower())}(?![a-z0-9])", text.lower()) is not None


def _norm_code(code: str) -> str:
    return re.sub(r"[^a-z0-9]", "", code.lower())


def in_category(category: str, title: str) -> bool:
    own = any(_contains(title, w) for w in CATEGORY_WORDS[category])
    other = any(_contains(title, w) for c, words in CATEGORY_WORDS.items() if c != category for w in words)
    # Keep listings that name the category, or that name no category at all (provider already filtered).
    return own or not other


@dataclass
class Consensus:
    """A brand most of the top visual matches agree on."""

    brand: str
    count: int
    of: int


def visual_consensus(candidates: list[Candidate], top: int = 6) -> Consensus | None:
    """At least 4 of the top 6 and two thirds of them: popular basics (plain tees) come back from many brands,
    so a looser rule would credit whichever brand is most common rather than the one on the garment."""
    leading = sorted(candidates, key=lambda c: c.rank)[:top]
    if len(leading) < 4:
        return None
    best = None
    for brand in KNOWN_BRANDS:
        count = sum(1 for c in leading if _contains(" ".join(filter(None, [c.title, c.brand])), brand))
        if count >= 4 and count * 3 >= len(leading) * 2 and (best is None or count > best.count):
            best = Consensus(brand, count, len(leading))
    return best


def is_retail(candidate: Candidate) -> bool:
    host = urlparse(canonical(candidate.url) or "").netloc
    return not any(marker in host or marker in candidate.retailer.lower() for marker in NON_RETAIL)


def assess(candidate: Candidate, clues: Clues, consensus: Consensus | None = None) -> Ranked:
    title = candidate.title
    haystack = " ".join(filter(None, [title, candidate.brand, candidate.url]))
    evidence: list[str] = []

    clue_codes = {_norm_code(c) for c in clues.codes}
    listing_codes = {_norm_code(c) for c in candidate.codes} | {_norm_code(w) for w in re.findall(r"[A-Za-z0-9-]{5,}", haystack)}
    code_match = sorted(c for c in clue_codes if c and c in listing_codes)
    if code_match:
        evidence.append(f"product code {code_match[0].upper()} on the garment matches the listing")

    brand = next((b for b in clues.brands if _contains(haystack, b)), None)
    read_brand = brand is not None
    if brand:
        evidence.append(f"brand {brand.title()} read on the garment matches the listing")
    elif consensus and _contains(haystack, consensus.brand):
        brand = consensus.brand
        evidence.append(f"{consensus.count} of the top {consensus.of} visual matches are {consensus.brand.title()}")
    listing_brand = candidate.brand or brand

    # Model name: two or more consecutive non-brand words read on the garment that also appear in the title.
    words = [w for w in clues.text if w.isalpha() and len(w) >= 3 and w not in (brand or "")]
    model = next((" ".join(words[i:i + 2]) for i in range(len(words) - 1) if _contains(title, " ".join(words[i:i + 2]))), None)
    if model:
        evidence.append(f"model name \"{model}\" matches")
    color = clues.color and any(_contains(title, c) for c in _color_words(clues.color))
    if color:
        evidence.append(f"colour {clues.color} matches")
    if clues.pattern and _contains(title, clues.pattern.split()[0]):
        evidence.append(f"pattern {clues.pattern} matches")
    if clues.style and _contains(title, clues.style.replace("_", " ")):
        evidence.append(f"style {clues.style.replace('_', ' ')} matches")
    if candidate.same_image:
        evidence.append(f"{candidate.provider} found this same image")

    if code_match or (read_brand and model and color) or (candidate.same_image and brand):
        tier = "exact"
    elif brand:
        tier = "brand"
    else:
        tier = "similar"

    score = TIER_WEIGHT[tier] + 1.0 / (2 + candidate.rank)
    # Provider order is already visual similarity (colour included), so a colour word in the title only nudges:
    # more than that and a "Black" low-top would outrank the right high-top that its title just doesn't call black.
    score += 0.1 * bool(color) + 0.25 * bool(model) + 0.15 * bool(candidate.same_image)
    score += 0.1 * bool(clues.pattern and any("pattern" in e for e in evidence))
    score += 0.1 * bool(clues.style and any("style" in e for e in evidence))
    score += 0.05 * bool(candidate.price) + 0.05 * bool(candidate.image_url)
    return Ranked(candidate, tier, (listing_brand or "").title() or None, evidence, score)


def _color_words(color: str) -> tuple[str, ...]:
    return {"gray": ("gray", "grey"), "beige": ("beige", "tan", "cream", "khaki", "sand"),
            "navy": ("navy",), "burgundy": ("burgundy", "maroon", "wine"), "olive": ("olive", "khaki"),
            "white": ("white", "off-white", "ivory")}.get(color, (color,))


def canonical(url: str | None) -> str | None:
    if not url:
        return None
    parsed = urlparse(url)
    # Google redirect links carry the real listing in ?url=.
    if parsed.netloc.endswith("google.com") and parsed.path in ("/goto", "/url"):
        target = parse_qs(parsed.query).get("url") or parse_qs(parsed.query).get("q")
        if target:
            parsed = urlparse(target[0])
    keep = "&".join(p for p in parsed.query.split("&") if p and not p.lower().startswith(("utm_", "gclid", "srsltid")))
    return urlunparse((parsed.scheme, parsed.netloc.lower(), parsed.path.rstrip("/"), "", keep, ""))


# MARK: - Aggregation


@dataclass
class SearchOutcome:
    results: list[Ranked]
    providers: list[dict]  # [{"name", "status": "ok"|"error", "count", "message"?}]


async def search_all(providers: list[VisualProvider], crop: bytes, clues: Clues,
                     enricher: Enricher | None = None, timeout: float = 40.0) -> SearchOutcome:
    async def run(provider: VisualProvider):
        try:
            return await asyncio.wait_for(provider.search(crop, clues), timeout)
        except asyncio.TimeoutError:
            return ProviderError("provider_timeout", f"{provider.name} took too long.")
        except ProviderError as error:
            return error
        except Exception as error:  # a broken provider must not take the others down
            log.warning("provider %s failed: %s", provider.name, type(error).__name__)
            return ProviderError("provider_error", f"{provider.name} had a problem.")

    answers = await asyncio.gather(*(run(p) for p in providers))
    report, candidates, errors = [], [], []
    for provider, answer in zip(providers, answers):
        if isinstance(answer, ProviderError):
            errors.append(answer)
            report.append({"name": provider.name, "status": "error", "count": 0, "message": answer.message})
        else:
            report.append({"name": provider.name, "status": "ok", "count": len(answer)})
            candidates.extend(answer)
    if errors and len(errors) == len(providers):
        raise errors[0] if len(errors) == 1 else ProviderError(
            "provider_error" if any(e.retryable for e in errors) else errors[0].code,
            "Product search failed. Try again.", any(e.retryable for e in errors))

    candidates = [c for c in candidates if c.fixture or is_retail(c)]
    consensus = visual_consensus([c for c in candidates if in_category(clues.category, c.title)])
    seen: set[str] = set()
    unique: list[Candidate] = []
    for c in sorted(candidates, key=lambda c: c.rank):
        key = canonical(c.url) or f"{c.provider}:{c.id}"
        if key in seen or not in_category(clues.category, c.title):
            continue
        seen.add(key)
        unique.append(c)

    ranked = sorted((assess(c, clues, consensus) for c in unique), key=lambda r: r.score, reverse=True)
    if enricher:
        top = ranked[:ENRICH_TOP]
        enriched = await asyncio.gather(*(enricher.enrich(r.candidate) for r in top), return_exceptions=True)
        refreshed = [assess(e, clues, consensus) if isinstance(e, Candidate) else r for r, e in zip(top, enriched)]
        ranked = sorted(refreshed + ranked[ENRICH_TOP:], key=lambda r: r.score, reverse=True)
    return SearchOutcome(ranked[:MAX_RESULTS], report)
