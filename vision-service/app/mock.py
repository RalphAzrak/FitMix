"""MOCK_MODE: realistic fake data for every step, so the app can integrate before the real models and keys exist.

Nothing here downloads a model or calls a paid API, and nothing leaves this machine. The mocks still react to
the photo: crops are real regions of it, colours are measured from its pixels, and catalog scores are real
cosine similarities over a tiny colour embedding. All products are fictional: links point to example.com and
pictures are drawn by `product_image`.
"""

import hashlib
import io

import numpy as np
from PIL import Image, ImageDraw

from .images import pad_on_white
from .models import CatalogMatch, GarmentAttributes, HINT_CATEGORY, OnlineMatch, Price
from .pipeline import OnlineRequest, OnlineResult, Segment, StepFailure, Timer

PALETTE: dict[str, tuple[int, int, int]] = {
    "black": (25, 25, 28), "white": (240, 240, 236), "grey": (128, 128, 128), "navy": (28, 38, 80),
    "blue": (50, 100, 190), "light blue": (150, 185, 225), "olive": (95, 100, 50), "green": (40, 130, 70),
    "beige": (215, 195, 160), "brown": (110, 70, 40), "tan": (190, 150, 100), "red": (180, 35, 40),
    "burgundy": (110, 25, 40), "pink": (230, 160, 180), "yellow": (230, 200, 60), "cream": (240, 230, 205),
}


def color_name(image: Image.Image) -> str:
    """Nearest palette colour to the centre of the garment, ignoring the white padding."""
    w, h = image.size
    centre = np.asarray(image.crop((w // 4, h // 4, 3 * w // 4, 3 * h // 4)).convert("RGB"), dtype=float).reshape(-1, 3)
    garment = centre[centre.min(axis=1) < 235]  # drop near-white background pixels
    mean = (garment if len(garment) else centre).mean(axis=0)
    return min(PALETTE, key=lambda name: float(np.sum((np.array(PALETTE[name]) - mean) ** 2)))


# MARK: Steps

class MockSegmenter:
    """Upper and lower body as fixed bands of the photo. Stands in for SegFormer."""

    name = "mock"

    def segment(self, image: Image.Image) -> list[Segment]:
        w, h = image.size
        bands = [("upper_clothes", (0.18, 0.15, 0.82, 0.52)), ("pants", (0.25, 0.50, 0.75, 0.92))]
        segments = []
        for label, (x0, y0, x1, y1) in bands:
            crop = image.crop((int(x0 * w), int(y0 * h), int(x1 * w), int(y1 * h)))
            segments.append(Segment(label=label, crop=pad_on_white(crop), area=(x1 - x0) * (y1 - y0)))
        return segments


TEMPLATES: dict[str, dict[str, str]] = {
    "top": {"material": "cotton", "style": "casual crew-neck t-shirt", "query": "{color} cotton crew neck t-shirt"},
    "jacket": {"material": "nylon", "style": "bomber jacket", "query": "{color} nylon bomber jacket"},
    "pants": {"material": "denim", "style": "straight-leg jeans", "query": "{color} straight leg jeans"},
    "shoes": {"material": "leather", "style": "low-top sneakers", "query": "{color} leather low top sneakers"},
    "dress": {"material": "viscose", "style": "midi dress", "query": "{color} midi dress"},
    "skirt": {"material": "cotton", "style": "a-line midi skirt", "query": "{color} a-line midi skirt"},
}


class MockDescriber:
    """Category from the hint, colour measured on the crop, the rest from templates. Stands in for the LLM."""

    name = "mock"

    async def describe(self, crops: list[Image.Image], hints: list[str | None]) -> list[GarmentAttributes]:
        described = []
        for crop, hint in zip(crops, hints):
            category = HINT_CATEGORY.get(hint or "", "top")
            color = color_name(crop)
            template = TEMPLATES[category]
            described.append(GarmentAttributes(
                category=category, color=color, pattern="solid", material=template["material"], style=template["style"],
                visible_brand=None, description=f"A {color} {template['style']} in {template['material']}.",
                search_query=template["query"].format(color=color), layered_over_top=False))
        return described


class MockEmbedder:
    """A 48-number colour layout (4×4 grid × RGB), centred and L2-normalised. Stands in for FashionCLIP."""

    name = "mock"

    def embed(self, images: list[Image.Image]) -> np.ndarray:
        rows = []
        for image in images:
            grid = np.asarray(image.convert("RGB").resize((4, 4), Image.Resampling.BILINEAR), dtype=float) / 255.0
            vector = grid.reshape(-1) - 0.5
            norm = np.linalg.norm(vector)
            rows.append(vector / norm if norm else vector)
        return np.vstack(rows) if rows else np.zeros((0, 48))


# Fictional demo products: (category, colour, title, price in USD).
DEMO_PRODUCTS: list[tuple[str, str, str, str]] = [
    ("jacket", "olive", "Olive Nylon Bomber Jacket", "89.00"),
    ("jacket", "black", "Black Faux-Leather Moto Jacket", "120.00"),
    ("jacket", "blue", "Classic Denim Trucker Jacket", "74.50"),
    ("jacket", "beige", "Beige Double-Breasted Trench Coat", "149.00"),
    ("jacket", "navy", "Navy Quilted Puffer Jacket", "110.00"),
    ("jacket", "grey", "Grey Wool-Blend Overcoat", "189.00"),
    ("top", "white", "White Organic Cotton Crew Tee", "24.00"),
    ("top", "black", "Black Heavyweight Pocket Tee", "29.00"),
    ("top", "navy", "Navy Breton Stripe Long-Sleeve Top", "39.00"),
    ("top", "grey", "Heather Grey Pullover Hoodie", "55.00"),
    ("top", "red", "Red Check Flannel Shirt", "48.00"),
    ("top", "cream", "Cream Cable-Knit Sweater", "68.00"),
    ("pants", "navy", "Dark Wash Straight-Leg Jeans", "79.00"),
    ("pants", "light blue", "Light Wash Relaxed Jeans", "69.00"),
    ("pants", "tan", "Khaki Slim Chinos", "58.00"),
    ("pants", "black", "Black Utility Cargo Pants", "72.00"),
    ("pants", "grey", "Grey Fleece Joggers", "45.00"),
    ("pants", "olive", "Olive Ripstop Cargo Pants", "66.00"),
    ("shoes", "white", "White Leather Low-Top Sneakers", "95.00"),
    ("shoes", "black", "Black Leather Chelsea Boots", "160.00"),
    ("shoes", "brown", "Brown Suede Penny Loafers", "130.00"),
    ("shoes", "grey", "Grey Mesh Running Shoes", "110.00"),
    ("shoes", "cream", "Cream Canvas High-Tops", "60.00"),
    ("shoes", "tan", "Tan Suede Desert Boots", "125.00"),
    ("dress", "black", "Black Satin Slip Dress", "85.00"),
    ("dress", "pink", "Pink Floral Midi Dress", "92.00"),
    ("dress", "red", "Red Wrap Midi Dress", "88.00"),
    ("dress", "navy", "Navy Cotton Shirt Dress", "76.00"),
    ("skirt", "blue", "Denim A-Line Mini Skirt", "42.00"),
    ("skirt", "black", "Black Pleated Midi Skirt", "58.00"),
    ("skirt", "beige", "Beige Satin Midi Skirt", "64.00"),
    ("skirt", "green", "Green Ribbed Knit Skirt", "49.00"),
]


def _mock_image_path(category: str, color: str, key: str) -> str:
    return f"mock-images/{category}__{color.replace(' ', '-')}__{key}.jpg"


class MockCatalog:
    """The demo products above, ranked by real cosine similarity of the mock embedding."""

    name = "mock"

    def __init__(self, embedder: MockEmbedder):
        self.products = []
        for number, (category, color, title, price) in enumerate(DEMO_PRODUCTS, start=1):
            product_id = f"demo-{category}-{number:02d}"
            self.products.append({"id": product_id, "category": category, "title": title, "price": price,
                                  "image": _mock_image_path(category, color, product_id),
                                  "retailer_url": f"https://example.com/products/{product_id}",
                                  "picture": product_picture(category, color)})
        self.vectors = embedder.embed([p["picture"] for p in self.products])

    def match(self, category: str | None, vector: np.ndarray, k: int) -> list[CatalogMatch]:
        indices = [i for i, p in enumerate(self.products) if category is None or p["category"] == category]
        scores = self.vectors[indices] @ vector if indices else np.array([])
        ranked = sorted(zip(indices, scores), key=lambda pair: -pair[1])[:k]
        return [CatalogMatch(id=self.products[i]["id"], title=self.products[i]["title"],
                             price=Price(value=self.products[i]["price"], currency="USD"),
                             image=self.products[i]["image"], retailer_url=self.products[i]["retailer_url"],
                             score=round(float(score), 4))
                for i, score in ranked]


RETAILERS = ["Northwind Apparel", "Fabrikam Outfitters", "Contoso Closet", "Tailspin Threads", "Litware Wear"]
SOURCES = ["lens", "shopping", "lens+shopping"]


class MockOnlineSearch:
    """Fictional listings built from the query, in descending score. Stands in for Lens + Shopping + re-rank.
    `fail="all"` makes it fail, for testing partial results."""

    name = "mock"

    def __init__(self, top_k: int = 10, fail: str | None = None):
        self.top_k, self.fail = top_k, fail

    async def search(self, request: OnlineRequest, timer: Timer) -> OnlineResult:
        if self.fail == "all":
            raise StepFailure("provider_unreachable", "Online search couldn't reach the search provider. Try again.")
        with timer.step("online_search"):
            category = request.category or "top"
            color = request.attributes.color if request.attributes else "grey"
            seed = int(hashlib.sha256(request.query.encode()).hexdigest()[:8], 16)
            matches = []
            for i in range(self.top_k):
                retailer = RETAILERS[(seed + i) % len(RETAILERS)]
                slug = f"{seed % 10000}-{i + 1}"
                price = 30 + (seed + 17 * i) % 140
                matches.append(OnlineMatch(
                    title=f"{request.query.title()} – Style {i + 1}", price=Price(value=f"{price}.00", currency="USD"),
                    retailer=retailer, url=f"https://example.com/listing/{slug}",
                    image=_mock_image_path(category, color, slug), score=round(0.93 - 0.035 * i, 4),
                    source=SOURCES[(seed + i) % len(SOURCES)]))
        return OnlineResult(matches=matches)


# MARK: Pictures

def product_picture(category: str, color: str, size: int = 256) -> Image.Image:
    """A flat drawing of a garment in `color` on white: enough for layout and for the mock embedding."""
    fill = PALETTE.get(color.replace("-", " "), PALETTE["grey"])
    image = Image.new("RGB", (size, size), (255, 255, 255))
    draw = ImageDraw.Draw(image)
    s = size / 256
    box = lambda *xy: [round(v * s) for v in xy]  # noqa: E731
    if category in ("top", "jacket"):
        draw.rectangle(box(78, 60, 178, 210), fill=fill)
        draw.polygon(box(78, 60, 30, 120, 52, 140, 78, 105), fill=fill)
        draw.polygon(box(178, 60, 226, 120, 204, 140, 178, 105), fill=fill)
        if category == "jacket":
            draw.line(box(128, 62, 128, 210), fill=(235, 235, 235), width=max(1, round(3 * s)))
    elif category == "pants":
        draw.rectangle(box(80, 40, 176, 80), fill=fill)
        draw.polygon(box(80, 80, 124, 80, 118, 225, 84, 225), fill=fill)
        draw.polygon(box(132, 80, 176, 80, 172, 225, 138, 225), fill=fill)
    elif category == "shoes":
        draw.ellipse(box(30, 120, 125, 175), fill=fill)
        draw.ellipse(box(131, 120, 226, 175), fill=fill)
    elif category == "dress":
        draw.polygon(box(100, 40, 156, 40, 200, 225, 56, 225), fill=fill)
    else:  # skirt
        draw.polygon(box(96, 70, 160, 70, 196, 190, 60, 190), fill=fill)
    return image


def product_image_jpeg(name: str) -> bytes | None:
    """JPEG for a `mock-images/<category>__<color>__<key>.jpg` path, or None if the name isn't one."""
    parts = name.removesuffix(".jpg").split("__")
    if len(parts) != 3 or parts[0] not in TEMPLATES:
        return None
    buffer = io.BytesIO()
    product_picture(parts[0], parts[1]).save(buffer, format="JPEG", quality=85)
    return buffer.getvalue()
