"""The demo catalog: products a user can match against (and later try on), ranked by FashionCLIP similarity.

`catalog/catalog.json` is a list of products:

    {"id": "demo-jacket-01", "title": "Olive Nylon Bomber Jacket", "category": "jacket",
     "price": {"value": "89.00", "currency": "USD"}, "image": "images/demo-jacket-01.png",
     "retailer_url": "https://…", "retailer": "…", "sample": true}

- `category` is one of top, jacket, pants, shoes, dress, skirt. `price` may be null, and `retailer`,
  `retailer_url` and `sample` are optional.
- `image` is a path inside `catalog/` or an https URL.
- `sample: true` marks fictional demo products.

Entries that don't fit this shape are skipped with a warning. Image embeddings are computed once and cached in
`catalog/embeddings.npz`. They're keyed by model, plus the file's contents for local images or the URL for
remote ones, so only new or changed products are embedded at startup.
"""

import hashlib
import io
import json
import logging
import time
from pathlib import Path
from typing import Callable

import httpx
import numpy as np
from PIL import Image
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .models import Category, CatalogMatch, Price
from .pipeline import Embedder

log = logging.getLogger("vision")


class CatalogItem(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: str = Field(min_length=1)
    title: str = Field(min_length=1)
    category: Category
    price: Price | None = None
    image: str = Field(min_length=1)
    retailer_url: str | None = None
    retailer: str | None = None
    sample: bool = False

    @property
    def is_remote(self) -> bool:
        return self.image.startswith(("http://", "https://"))


def fetch_url(url: str) -> bytes:
    response = httpx.get(url, timeout=15, follow_redirects=True, headers={"User-Agent": "FitMix-vision/1.0"})
    response.raise_for_status()
    return response.content


def load_items(path: Path) -> list[CatalogItem]:
    entries = json.loads(path.read_text())
    if not isinstance(entries, list):
        raise ValueError(f"{path} must contain a JSON list of products")
    items, seen = [], set()
    for number, entry in enumerate(entries):
        try:
            item = CatalogItem(**entry)
        except (TypeError, ValidationError) as error:
            log.warning("catalog entry %d skipped: %s", number, str(error).splitlines()[0])
            continue
        if item.id in seen:
            log.warning("catalog entry %d skipped: repeated id %s", number, item.id)
            continue
        seen.add(item.id)
        items.append(item)
    return items


class Catalog:
    def __init__(self, path: Path, embedder: Embedder, model_id: str, fetch: Callable[[str], bytes] = fetch_url):
        started = time.perf_counter()
        self.path, self.root = path, path.parent
        self.name = f"catalog ({path.name})"
        self.cache_path = self.root / "embeddings.npz"
        cache = self._read_cache()
        items, vectors, missing = [], [], []
        for item in load_items(path):
            try:
                key, content = self._key(item, model_id)
                picture = None if key in cache else _open(content if content is not None else fetch(item.image))
            except Exception as error:
                log.warning("catalog %s skipped: its image couldn't be loaded (%s)", item.id, type(error).__name__)
                continue
            if picture is None:
                vectors.append(cache[key])
            else:
                missing.append((len(items), key, picture))
                vectors.append(None)
            items.append(item)
        if missing:
            computed = embedder.embed([picture for _, _, picture in missing])
            for (position, key, _), vector in zip(missing, computed):
                vectors[position] = vector
                cache[key] = vector
            self._write_cache(cache)
        self.items = items
        self.vectors = np.vstack(vectors).astype(np.float32) if vectors else np.zeros((0, 1), dtype=np.float32)
        log.info("catalog: %d product(s) (%d newly embedded) in %.1fs", len(items), len(missing), time.perf_counter() - started)

    def __len__(self) -> int:
        return len(self.items)

    def match(self, category: str | None, vector: np.ndarray, k: int) -> list[CatalogMatch]:
        indices = [i for i, item in enumerate(self.items) if category is None or item.category == category]
        if not indices:
            return []
        scores = self.vectors[indices] @ vector.astype(np.float32)
        order = np.argsort(-scores)[:k]
        return [self._match(self.items[indices[i]], float(scores[i])) for i in order]

    @staticmethod
    def _match(item: CatalogItem, score: float) -> CatalogMatch:
        image = item.image if item.is_remote else f"catalog-images/{item.image.removeprefix('images/')}"
        return CatalogMatch(id=item.id, title=item.title, price=item.price, image=image, retailer_url=item.retailer_url,
                            retailer=item.retailer, sample=item.sample, score=round(score, 4))

    def _key(self, item: CatalogItem, model_id: str) -> tuple[str, bytes | None]:
        """Cache key for the item's image, and the image file's bytes when it's local (remote ones aren't fetched
        unless they need embedding)."""
        if item.is_remote:
            return hashlib.sha256(f"{model_id}|{item.image}".encode()).hexdigest(), None
        file = (self.root / item.image).resolve()
        if self.root.resolve() not in file.parents:
            raise ValueError("image path is outside the catalog folder")
        content = file.read_bytes()
        return hashlib.sha256(model_id.encode() + b"|" + content).hexdigest(), content

    def _read_cache(self) -> dict[str, np.ndarray]:
        if not self.cache_path.exists():
            return {}
        try:
            with np.load(self.cache_path) as stored:
                return dict(zip(stored["keys"].tolist(), stored["vectors"]))
        except Exception:
            log.warning("catalog: embedding cache unreadable, recomputing")
            return {}

    def _write_cache(self, cache: dict[str, np.ndarray]) -> None:
        keys = list(cache)
        try:
            np.savez(self.cache_path, keys=np.array(keys), vectors=np.vstack([cache[k] for k in keys]))
        except Exception as error:
            log.warning("catalog: couldn't save the embedding cache (%s)", error)


def _open(data: bytes) -> Image.Image:
    with Image.open(io.BytesIO(data)) as picture:
        return picture.convert("RGB")
