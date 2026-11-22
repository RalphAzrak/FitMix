"""Writes the fictional demo products into catalog/catalog.json, with drawn pictures in catalog/images/.

    .venv/bin/python scripts/make_sample_catalog.py

The products and drawings are FitMix's own (the same ones MOCK_MODE uses), so they can be committed and shown
freely. They're marked "sample": true. Entries that aren't samples (for example ones added by
seed_catalog_ebay.py) are kept.
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.mock import DEMO_PRODUCTS, product_picture  # noqa: E402

CATALOG = ROOT / "catalog" / "catalog.json"


def main() -> None:
    images = CATALOG.parent / "images"
    images.mkdir(parents=True, exist_ok=True)
    existing = json.loads(CATALOG.read_text()) if CATALOG.exists() else []
    kept = [entry for entry in existing if not entry.get("sample")]
    samples = []
    for number, (category, color, title, price) in enumerate(DEMO_PRODUCTS, start=1):
        product_id = f"demo-{category}-{number:02d}"
        product_picture(category, color, size=384).save(images / f"{product_id}.png", optimize=True)
        samples.append({"id": product_id, "title": title, "category": category,
                        "price": {"value": price, "currency": "USD"}, "image": f"images/{product_id}.png",
                        "retailer": "FitMix demo", "retailer_url": None, "sample": True})
    CATALOG.write_text(json.dumps(samples + kept, indent=2) + "\n")
    print(f"{CATALOG}: {len(samples)} sample product(s), {len(kept)} other product(s) kept")


if __name__ == "__main__":
    main()
