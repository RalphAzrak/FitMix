"""Short-lived, in-memory results shared by identical image requests."""

import asyncio
import hashlib
import time
from collections import OrderedDict
from collections.abc import Awaitable, Callable
from dataclasses import dataclass


@dataclass(frozen=True)
class ImageResult:
    image: bytes | None
    category: str | None = None
    message: str | None = None
    generation_ms: float = 0
    classification_ms: float | None = None

    def headers(self, disposition: str) -> dict[str, str]:
        timing = f"result;desc={disposition}"
        if disposition == "generated":
            timing += f", generation;dur={self.generation_ms:.1f}"
            if self.classification_ms is not None:
                timing += f", classification;dur={self.classification_ms:.1f}"
        return {"Cache-Control": "no-store", "Server-Timing": timing, "X-FitMix-Result": disposition}


def image_key(scope: str, operation: str, prompt: str, images: list[tuple[str, bytes, str]]) -> bytes:
    digest = hashlib.sha256()
    for part in (scope.encode(), operation.encode(), prompt.encode()):
        digest.update(len(part).to_bytes(8, "big"))
        digest.update(part)
    for name, image, media in images:
        for part in (name.encode(), image, media.encode()):
            digest.update(len(part).to_bytes(8, "big"))
            digest.update(part)
    return digest.digest()


class ImageResults:
    def __init__(self, ttl: float = 600, max_bytes: int = 24 * 1024 * 1024):
        self.ttl = ttl
        self.max_bytes = max_bytes
        self.bytes_used = 0
        self.completed: OrderedDict[bytes, tuple[float, ImageResult]] = OrderedDict()
        self.running: dict[bytes, asyncio.Task[ImageResult]] = {}

    def _remove(self, key: bytes) -> None:
        _, result = self.completed.pop(key)
        self.bytes_used -= len(result.image or b"")

    def _expire(self) -> None:
        now = time.monotonic()
        for key, (expiry, _) in tuple(self.completed.items()):
            if expiry <= now:
                self._remove(key)

    async def get(self, key: bytes, produce: Callable[[], Awaitable[ImageResult]], *, regenerate: bool
                  ) -> tuple[ImageResult, str]:
        self._expire()
        if task := self.running.get(key):
            return await asyncio.shield(task), "joined"
        if not regenerate and key in self.completed:
            self.completed.move_to_end(key)
            return self.completed[key][1], "cached"
        task = asyncio.create_task(self._produce(key, produce))
        # A cancelled upload can leave the provider running for a future retry.
        task.add_done_callback(self._observe_finish)
        self.running[key] = task
        return await asyncio.shield(task), "generated"

    @staticmethod
    def _observe_finish(task: asyncio.Task[ImageResult]) -> None:
        if not task.cancelled():
            task.exception()

    def _remove_if_current(self, key: bytes, expiry: float) -> None:
        if key in self.completed and self.completed[key][0] == expiry:
            self._remove(key)

    async def _produce(self, key: bytes, produce: Callable[[], Awaitable[ImageResult]]) -> ImageResult:
        try:
            result = await produce()
            if result.image and len(result.image) <= self.max_bytes:
                if key in self.completed:
                    self._remove(key)
                expiry = time.monotonic() + self.ttl
                self.completed[key] = (expiry, result)
                self.bytes_used += len(result.image)
                asyncio.get_running_loop().call_later(self.ttl, self._remove_if_current, key, expiry)
                while self.bytes_used > self.max_bytes or len(self.completed) > 32:
                    self._remove(next(iter(self.completed)))
            return result
        finally:
            self.running.pop(key, None)
