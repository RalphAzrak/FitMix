"""In-memory store of recent analyses, so /search, /refine and crop URLs can reuse /analyze's work.

Least-recently-used entries are dropped past `size`, and entries expire after `ttl_seconds`. Nothing is written
to disk, and a restart forgets everything.
"""

import time
from collections import OrderedDict
from typing import Generic, TypeVar

T = TypeVar("T")


class TTLCache(Generic[T]):
    def __init__(self, size: int = 64, ttl_seconds: float = 3600, clock=time.monotonic):
        self.size, self.ttl, self.clock = size, ttl_seconds, clock
        self._items: OrderedDict[str, tuple[float, T]] = OrderedDict()

    def get(self, key: str) -> T | None:
        entry = self._items.get(key)
        if entry is None:
            return None
        stored, value = entry
        if self.clock() - stored > self.ttl:
            del self._items[key]
            return None
        self._items.move_to_end(key)
        return value

    def put(self, key: str, value: T) -> None:
        self._items[key] = (self.clock(), value)
        self._items.move_to_end(key)
        while len(self._items) > self.size:
            self._items.popitem(last=False)

    def __len__(self) -> int:
        return len(self._items)
