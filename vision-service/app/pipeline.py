"""The analysis pipeline, independent of which models and providers sit behind each step.

/analyze:  segment (photo only) → describe ∥ embed → catalog match
/search:   online search for one garment (Lens + Shopping + re-rank), on demand, cached per brand

Each step is a small interface (Protocol) with a real and a mock implementation. A failing step is recorded on
the garment as a StepError and the rest still runs, so callers always get whatever worked.
"""

import asyncio
import logging
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from typing import Literal, Protocol

import numpy as np
from PIL import Image

from .images import pad_on_white, to_jpeg
from .models import HINT_CATEGORY, CatalogMatch, GarmentAttributes, OnlineMatch, StepError

log = logging.getLogger("vision")


class StepFailure(Exception):
    """A step failed in a way worth telling the caller. `message` is readable by a person."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def step_error(step: str, error: Exception) -> StepError:
    if isinstance(error, StepFailure):
        return StepError(step=step, code=error.code, message=error.message)
    log.exception("%s failed unexpectedly", step)
    return StepError(step=step, code="internal", message=f"The {step} step failed unexpectedly.")


class Timer:
    """Measures each step, logs it, and keeps the numbers for the response's `timings_ms`."""

    def __init__(self, label: str):
        self.label = label
        self.ms: dict[str, int] = {}

    @contextmanager
    def step(self, name: str):
        started = time.perf_counter()
        try:
            yield
        finally:
            self.ms[name] = round((time.perf_counter() - started) * 1000)
            log.info("%s %s: %d ms", self.label, name, self.ms[name])


# MARK: Step interfaces

@dataclass
class Segment:
    label: str  # SegFormer label, e.g. "upper_clothes"
    crop: Image.Image  # garment on white
    area: float  # fraction of the photo the garment covers


class Segmenter(Protocol):
    name: str

    def segment(self, image: Image.Image) -> list[Segment]: ...


class Describer(Protocol):
    name: str

    async def describe(self, crops: list[Image.Image], hints: list[str | None]) -> list[GarmentAttributes]: ...


class Embedder(Protocol):
    name: str

    def embed(self, images: list[Image.Image]) -> np.ndarray:
        """One L2-normalised row per image."""
        ...


class Catalog(Protocol):
    name: str

    def match(self, category: str | None, vector: np.ndarray, k: int) -> list[CatalogMatch]: ...


@dataclass
class OnlineRequest:
    crop: Image.Image
    crop_jpeg: bytes
    embedding: np.ndarray | None
    attributes: GarmentAttributes | None
    category: str | None
    query: str
    key: str  # stable name for uploads, e.g. "<analysis_id>/<index>"


@dataclass
class OnlineResult:
    matches: list[OnlineMatch]
    errors: list[StepError] = field(default_factory=list)


class OnlineSearch(Protocol):
    name: str

    async def search(self, request: OnlineRequest, timer: Timer) -> OnlineResult: ...


# MARK: State kept between /analyze and /search

@dataclass
class Garment:
    index: int
    crop: Image.Image
    crop_jpeg: bytes
    hint: str | None
    attributes: GarmentAttributes | None = None
    embedding: np.ndarray | None = None
    catalog_matches: list[CatalogMatch] = field(default_factory=list)
    errors: list[StepError] = field(default_factory=list)
    # Online results per lower-cased brand ("" = no brand), so repeat taps cost no searches.
    searches: dict[str, OnlineResult] = field(default_factory=dict)

    @property
    def category(self) -> str | None:
        if self.attributes:
            return self.attributes.category
        return HINT_CATEGORY.get(self.hint or "")

    def query(self, brand: str | None = None) -> str:
        if self.attributes:
            base = self.attributes.search_query
        else:
            base = (self.category or "clothing").replace("top", "shirt")
        if brand and brand.lower() not in base.lower():
            return f"{brand} {base}"
        return base


@dataclass
class Analysis:
    id: str
    input: Literal["image", "crops"]
    garments: list[Garment]
    errors: list[StepError]
    timings_ms: dict[str, int]


# MARK: Orchestration

class Pipeline:
    def __init__(self, segmenter: Segmenter, describer: Describer, embedder: Embedder, catalog: Catalog,
                 online: OnlineSearch, catalog_top_k: int = 5):
        self.segmenter, self.describer, self.embedder = segmenter, describer, embedder
        self.catalog, self.online = catalog, online
        self.catalog_top_k = catalog_top_k

    def components(self) -> dict[str, str]:
        return {"segmenter": self.segmenter.name, "describer": self.describer.name, "embedder": self.embedder.name,
                "catalog": self.catalog.name, "online_search": self.online.name}

    async def analyze(self, image: Image.Image | None = None, crops: list[Image.Image] | None = None,
                      hints: list[str | None] | None = None) -> Analysis:
        analysis_id = uuid.uuid4().hex
        timer = Timer(f"analysis {analysis_id[:8]}")
        errors: list[StepError] = []
        started = time.perf_counter()

        if image is not None:
            pieces: list[tuple[str | None, Image.Image]] = []
            try:
                with timer.step("segment"):
                    segments = await asyncio.to_thread(self.segmenter.segment, image)
                pieces = [(s.label, s.crop) for s in segments]
                if not pieces:
                    errors.append(StepError(step="segment", code="no_garments",
                                            message="No garments were found in this photo. Try a photo that shows the whole outfit."))
            except Exception as error:
                errors.append(step_error("segment", error))
        else:
            crops = crops or []
            hints = hints or [None] * len(crops)
            pieces = [(hint, pad_on_white(crop)) for crop, hint in zip(crops, hints)]

        garments = [Garment(index=i, crop=crop, crop_jpeg=to_jpeg(crop), hint=hint) for i, (hint, crop) in enumerate(pieces)]
        if garments:
            await asyncio.gather(self._describe(garments, timer), self._embed(garments, timer))
            await self._match_catalog(garments, timer)

        timer.ms["total"] = round((time.perf_counter() - started) * 1000)
        log.info("analysis %s: %d garment(s) in %d ms", analysis_id[:8], len(garments), timer.ms["total"])
        return Analysis(id=analysis_id, input="image" if image is not None else "crops", garments=garments,
                        errors=errors, timings_ms=timer.ms)

    async def _describe(self, garments: list[Garment], timer: Timer):
        try:
            with timer.step("describe"):
                described = await self.describer.describe([g.crop for g in garments], [g.hint for g in garments])
            if len(described) != len(garments):
                raise StepFailure("describe_mismatch", "The garment description didn't cover every garment.")
            for garment, attributes in zip(garments, described):
                garment.attributes = attributes
        except Exception as error:
            failure = step_error("describe", error)
            for garment in garments:
                garment.errors.append(failure)

    async def _embed(self, garments: list[Garment], timer: Timer):
        try:
            with timer.step("embed"):
                vectors = await asyncio.to_thread(self.embedder.embed, [g.crop for g in garments])
            for garment, vector in zip(garments, vectors):
                garment.embedding = vector
        except Exception as error:
            failure = step_error("embed", error)
            for garment in garments:
                garment.errors.append(failure)

    async def _match_catalog(self, garments: list[Garment], timer: Timer):
        with timer.step("catalog"):
            for garment in garments:
                if garment.embedding is None:
                    garment.errors.append(StepError(step="catalog", code="no_embedding",
                                                    message="Catalog matching needs the garment's image embedding, which failed."))
                    continue
                try:
                    garment.catalog_matches = self.catalog.match(garment.category, garment.embedding, self.catalog_top_k)
                except Exception as error:
                    garment.errors.append(step_error("catalog", error))

    async def search(self, analysis: Analysis, index: int, brand: str | None = None) -> tuple[Garment, OnlineResult, str, bool, dict]:
        """Online matches for one garment. Returns (garment, result, query, cached, timings)."""
        garment = analysis.garments[index]
        key = (brand or "").strip().lower()
        query = garment.query(brand)
        if key in garment.searches:
            return garment, garment.searches[key], query, True, {}
        timer = Timer(f"search {analysis.id[:8]}#{index}")
        started = time.perf_counter()
        request = OnlineRequest(crop=garment.crop, crop_jpeg=garment.crop_jpeg, embedding=garment.embedding,
                                attributes=garment.attributes, category=garment.category, query=query,
                                key=f"{analysis.id}/{index}")
        try:
            result = await self.online.search(request, timer)
        except Exception as error:
            result = OnlineResult(matches=[], errors=[step_error("online_search", error)])
        timer.ms["total"] = round((time.perf_counter() - started) * 1000)
        # Only cache searches that worked, so a provider outage can be retried.
        if not result.errors:
            garment.searches[key] = result
        return garment, result, query, False, timer.ms
