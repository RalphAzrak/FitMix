"""Google Lens product search for a garment the user scanned (FitMix's primary product search).

`POST /v1/lens-search`: for one garment crop it

  1. answers from the cache when the same crop was searched for the same category before (no provider call);
  2. joins a search already running for the same crop instead of starting another;
  3. otherwise checks the guards: SCRAPPA_API_KEY and an https FITMIX_PUBLIC_BASE_URL are set, the monthly call
     cap (kept under Scrappa's free 500 credits) has room, the account isn't out of credits, the key wasn't
     refused, and the provider isn't cooling down after rate limiting or repeated failures;
  4. publishes the crop at a short-lived, unguessable https URL (`CropHost`) and asks Scrappa's Google Lens
     endpoint for visual matches (GET https://scrappa.co/api/google/lens?type=visual_matches);
  5. keeps only credible retail listings for the selected category, with a product link and a usable photo,
     reads the top few listing pages for the retailer's own product photo, and returns the best one, labeled
     "similar".

Only the crop is ever sent, and only through that URL. The key stays in this process's environment and is never
logged. The cache and the usage counter are kept in a small JSON file (no images, no user data).
"""

import asyncio
import hashlib
import json
import logging
import time
from dataclasses import asdict, dataclass, field, replace
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

from .visual_search import (CATEGORY_WORDS, Candidate, Clues, Enricher, ProviderError, VisualProvider, _contains,
                            assess, canonical, is_retail)

log = logging.getLogger("fitmix")

# Listing pages read per search for the retailer's own photo and price.
ENRICH_TOP = 4


def _month() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m")


def _usable_url(url: str | None, schemes=("https",)) -> bool:
    if not url:
        return False
    parsed = urlparse(url)
    return parsed.scheme in schemes and bool(parsed.netloc)


def _is_google(url: str) -> bool:
    host = urlparse(url).netloc.lower()
    return host.endswith(("google.com", "gstatic.com", "googleusercontent.com", "googleapis.com")) or ".google." in host


def credible(candidate: Candidate, category: str) -> bool:
    """A real listing for the selected category that FitMix can show: an http(s) product link off Google, on a
    page that sells things, with a photo, whose title names this category (or, once its page was read, carries
    a price) and names no other category."""
    if not candidate.title or not _usable_url(candidate.url, ("https", "http")) or _is_google(candidate.url):
        return False
    if not is_retail(candidate) or not _usable_url(candidate.image_url):
        return False
    own = any(_contains(candidate.title, w) for w in CATEGORY_WORDS[category])
    other = any(_contains(candidate.title, w) for c, words in CATEGORY_WORDS.items() if c != category for w in words)
    return not other and (own or candidate.price is not None)


@dataclass
class LensState:
    """What survives a restart: the usage counter, the quota flag, and cached answers. No images."""

    month: str = field(default_factory=_month)
    calls: int = 0
    exhausted_month: str | None = None
    # cache key -> {"at": unix time, "category": ..., "result": listing json or None}
    cache: dict[str, dict] = field(default_factory=dict)


class LensUnavailable(Exception):
    """The search can't run right now, and the provider was not called."""

    def __init__(self, code: str, message: str, status: int = 503, retryable: bool = True):
        super().__init__(message)
        self.code, self.message, self.status, self.retryable = code, message, status, retryable


@dataclass
class LensAnswer:
    result: dict | None  # the best listing as JSON, or None for "no close match"
    cached: bool


class LensSearch:
    def __init__(self, provider: VisualProvider | None, enricher: Enricher | None = None, *,
                 not_configured: str | None = None, monthly_limit: int = 100, cache_ttl: float = 7 * 24 * 3600,
                 cache_size: int = 500, state_path: Path | None = None, cooldown: float = 60.0,
                 failure_threshold: int = 3, clock=time.time):
        self.provider, self.enricher = provider, enricher
        self.not_configured = not_configured
        self.monthly_limit, self.cache_ttl, self.cache_size = monthly_limit, cache_ttl, cache_size
        self.state_path, self.cooldown, self.failure_threshold, self.clock = state_path, cooldown, failure_threshold, clock
        self.state = self._load()
        self._auth_refused = False
        self._cooldown_until = 0.0
        self._failures = 0
        self._inflight: dict[str, asyncio.Future] = {}

    @property
    def ready(self) -> bool:
        return self.provider is not None

    def status(self) -> dict:
        self._roll_month()
        return {"ready": self.ready, "message": self.not_configured, "calls_this_month": self.state.calls,
                "monthly_limit": self.monthly_limit, "quota_exhausted": self.state.exhausted_month == self.state.month,
                "cached_searches": len(self.state.cache)}

    @staticmethod
    def key(crop: bytes, category: str) -> str:
        return hashlib.sha256(category.encode() + b"\0" + crop).hexdigest()

    async def search(self, crop: bytes, clues: Clues) -> LensAnswer:
        key = self.key(crop, clues.category)
        hit = self._cached(key)
        if hit is not None:
            return LensAnswer(hit["result"], cached=True)
        # The same crop asked twice at once makes one provider call.
        if key in self._inflight:
            result = await asyncio.shield(self._inflight[key])
            return LensAnswer(result, cached=True)
        self._guard()
        future = asyncio.get_running_loop().create_future()
        self._inflight[key] = future
        try:
            result = await self._search_provider(crop, clues)
        except BaseException as error:
            future.set_exception(error)
            future.exception()  # mark retrieved: waiters re-raise it, nobody else needs to
            raise
        else:
            future.set_result(result)
            self._store(key, clues.category, result)
            return LensAnswer(result, cached=False)
        finally:
            self._inflight.pop(key, None)

    # MARK: Guards

    def _guard(self) -> None:
        if self.provider is None:
            raise LensUnavailable("not_configured", f"Google Lens search isn't set up ({self.not_configured}).",
                                  retryable=False)
        if self._auth_refused:
            raise LensUnavailable("provider_auth", "Scrappa refused the server's API key.", retryable=False)
        self._roll_month()
        if self.state.exhausted_month == self.state.month:
            raise LensUnavailable("provider_quota", "The Google Lens allowance is used up for this month.", retryable=False)
        if self.state.calls >= self.monthly_limit:
            raise LensUnavailable("budget_exhausted",
                                  f"FitMix's Google Lens budget ({self.monthly_limit} searches this month) is used up.",
                                  retryable=False)
        if self.clock() < self._cooldown_until:
            raise LensUnavailable("provider_cooling_down", "Google Lens is busy. Try again in a minute.")

    def _roll_month(self) -> None:
        if self.state.month != _month():
            self.state.month, self.state.calls = _month(), 0
            self._save()

    # MARK: Provider

    async def _search_provider(self, crop: bytes, clues: Clues) -> dict | None:
        self.state.calls += 1  # counted before the call: a call Scrappa bills must never go uncounted
        self._save()
        try:
            candidates = await self.provider.search(crop, clues)
        except ProviderError as error:
            self._note_failure(error)
            raise
        self._failures = 0
        return await self._best(candidates, clues)

    def _note_failure(self, error: ProviderError) -> None:
        if error.code == "provider_auth":
            self._auth_refused = True
        elif error.code == "provider_quota":
            self.state.exhausted_month = self.state.month
            self._save()
        elif error.code.lower() in ("rate_limited", "provider_busy") or "rate" in error.code.lower():
            self._cooldown_until = self.clock() + self.cooldown
        else:
            self._failures += 1
            if self._failures >= self.failure_threshold:
                self._cooldown_until, self._failures = self.clock() + self.cooldown, 0
        log.info("lens search: provider failed (%s)", error.code)

    async def _best(self, candidates: list[Candidate], clues: Clues) -> dict | None:
        category = clues.category
        seen, pool = set(), []
        for c in sorted(candidates, key=lambda c: c.rank):
            key = canonical(c.url)
            if not key or key in seen:
                continue
            seen.add(key)
            # Before reading pages, drop what can never qualify: no link, Google pages, social sites, other categories.
            if (c.title and _usable_url(c.url, ("https", "http")) and not _is_google(c.url) and is_retail(c)
                    and not any(_contains(c.title, w) for k, ws in CATEGORY_WORDS.items() if k != category for w in ws)):
                pool.append(c)
        top = pool[:ENRICH_TOP]
        if self.enricher and top:
            pages = await asyncio.gather(*(self.enricher.enrich(c) for c in top), return_exceptions=True)
            top = [page if isinstance(page, Candidate) else c for c, page in zip(top, pages)]
        # The retailer's own photo when its page names one; otherwise Lens's thumbnail of that listing.
        shown = []
        for original, c in zip(pool[:ENRICH_TOP], top):
            source = "listing_page" if c.image_url and c.image_url != original.image_url else "lens_thumbnail"
            shown.append((c, source))
        shown += [(c, "lens_thumbnail") for c in pool[ENRICH_TOP:]]
        ranked = sorted(((assess(c, clues), source) for c, source in shown if credible(c, category)),
                        key=lambda pair: pair[0].score, reverse=True)
        if not ranked:
            return None
        best, image_source = ranked[0]
        # A Lens visual match is never claimed as the same item: it is always "Similar match".
        listing = replace(best, tier="similar").to_json()
        listing["image_source"] = image_source
        return listing

    # MARK: Cache and persistence

    def _cached(self, key: str) -> dict | None:
        entry = self.state.cache.get(key)
        if entry is None:
            return None
        if self.clock() - entry["at"] > self.cache_ttl:
            self.state.cache.pop(key, None)
            return None
        return entry

    def _store(self, key: str, category: str, result: dict | None) -> None:
        self.state.cache[key] = {"at": self.clock(), "category": category, "result": result}
        while len(self.state.cache) > self.cache_size:
            oldest = min(self.state.cache, key=lambda k: self.state.cache[k]["at"])
            self.state.cache.pop(oldest)
        self._save()

    def _load(self) -> LensState:
        if not self.state_path or not self.state_path.exists():
            return LensState()
        try:
            data = json.loads(self.state_path.read_text())
            return LensState(month=data.get("month") or _month(), calls=int(data.get("calls", 0)),
                             exhausted_month=data.get("exhausted_month"), cache=dict(data.get("cache") or {}))
        except (ValueError, TypeError, OSError):
            log.warning("lens search: couldn't read %s; starting a fresh counter", self.state_path.name)
            return LensState()

    def _save(self) -> None:
        if not self.state_path:
            return
        try:
            self.state_path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.state_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(asdict(self.state)))
            temporary.replace(self.state_path)
        except OSError:
            log.warning("lens search: couldn't save %s", self.state_path.name)
