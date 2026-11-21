"""Adds real eBay listings to catalog/catalog.json through the official eBay Browse API (item_summary/search).

    .venv/bin/python scripts/seed_catalog_ebay.py                 # 10 listings per category
    .venv/bin/python scripts/seed_catalog_ebay.py --per-category 5

Keys: EBAY_CLIENT_ID and EBAY_CLIENT_SECRET from the environment, vision-service/.env, or Backend/.env (the
same production keyset the backend uses). Each run replaces the previous eBay entries and keeps everything
else, including the samples. Only fixed-price listings with a picture and a price are kept; the title, price,
picture and link are the listing's own. Listings end over time, so re-run the script before a demo.
"""

import argparse
import base64
import json
import os
import sys
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "catalog" / "catalog.json"
API = "https://api.ebay.com"

# eBay US categories per catalog category (men's and women's where both exist), with a query that keeps
# results on-topic inside broad categories. The jacket, top, pants and shoes ids match Backend/app/retail.py.
SEARCHES: dict[str, list[tuple[str, str]]] = {
    "jacket": [("57988", "jacket"), ("63862", "jacket")],
    "top": [("15687", "t-shirt"), ("53159", "t-shirt")],
    "pants": [("57989", "pants"), ("63863", "pants")],
    "shoes": [("93427", "sneakers"), ("3034", "sneakers")],
    "dress": [("63861", "dress")],
    "skirt": [("63864", "skirt")],
}


def read_keys() -> tuple[str, str]:
    values = {name: os.environ.get(name, "") for name in ("EBAY_CLIENT_ID", "EBAY_CLIENT_SECRET")}
    for env_file in (ROOT / ".env", ROOT.parent / "Backend" / ".env"):
        if all(values.values()) or not env_file.exists():
            continue
        for line in env_file.read_text().splitlines():
            name, _, value = line.partition("=")
            if name.strip() in values and not values[name.strip()]:
                values[name.strip()] = value.strip()
    if not all(values.values()):
        sys.exit("Set EBAY_CLIENT_ID and EBAY_CLIENT_SECRET (in vision-service/.env or Backend/.env) first.")
    return values["EBAY_CLIENT_ID"], values["EBAY_CLIENT_SECRET"]


def token(http: httpx.Client, client_id: str, secret: str) -> str:
    basic = base64.b64encode(f"{client_id}:{secret}".encode()).decode()
    response = http.post(f"{API}/identity/v1/oauth2/token",
                         headers={"Authorization": f"Basic {basic}", "Content-Type": "application/x-www-form-urlencoded"},
                         data={"grant_type": "client_credentials", "scope": "https://api.ebay.com/oauth/api_scope"})
    if response.status_code != 200:
        sys.exit(f"eBay refused the keys (HTTP {response.status_code}). Check EBAY_CLIENT_ID and EBAY_CLIENT_SECRET.")
    return response.json()["access_token"]


def listings_to_entries(category: str, summaries: list[dict]) -> list[dict]:
    """Catalog entries for eBay item summaries; listings without a picture, price or link are left out."""
    entries = []
    for item in summaries:
        image = (item.get("image") or {}).get("imageUrl")
        price = item.get("price") or {}
        if not (item.get("itemId") and item.get("title") and image and item.get("itemWebUrl") and price.get("value")):
            continue
        seller = (item.get("seller") or {}).get("username")
        entries.append({"id": f"ebay-{item['itemId']}", "title": item["title"], "category": category,
                        "price": {"value": str(price["value"]), "currency": price.get("currency", "USD")},
                        "image": image, "retailer": f"eBay · {seller}" if seller else "eBay",
                        "retailer_url": item["itemWebUrl"], "sample": False})
    return entries


def search(http: httpx.Client, access_token: str, marketplace: str, category_id: str, query: str, limit: int) -> list[dict]:
    response = http.get(f"{API}/buy/browse/v1/item_summary/search",
                        params={"q": query, "category_ids": category_id, "limit": str(limit),
                                "filter": "buyingOptions:{FIXED_PRICE}"},
                        headers={"Authorization": f"Bearer {access_token}", "X-EBAY-C-MARKETPLACE-ID": marketplace})
    if response.status_code != 200:
        print(f"  category {category_id}: eBay answered HTTP {response.status_code}, skipped")
        return []
    return response.json().get("itemSummaries") or []


def merge(existing: list[dict], fresh: list[dict]) -> list[dict]:
    """Everything that isn't from eBay, then the new eBay entries (one per listing)."""
    kept = [entry for entry in existing if not str(entry.get("id", "")).startswith("ebay-")]
    unique = list({entry["id"]: entry for entry in fresh}.values())
    return kept + unique


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--per-category", type=int, default=10)
    parser.add_argument("--marketplace", default=os.environ.get("EBAY_MARKETPLACE_ID", "EBAY_US"))
    args = parser.parse_args()
    client_id, secret = read_keys()
    with httpx.Client(timeout=20) as http:
        access_token = token(http, client_id, secret)
        fresh = []
        for category, searches in SEARCHES.items():
            per_search = max(1, -(-args.per_category // len(searches)))
            found = []
            for category_id, query in searches:
                found += listings_to_entries(category, search(http, access_token, args.marketplace, category_id, query, per_search))
            print(f"{category}: {len(found[:args.per_category])} listing(s)")
            fresh += found[:args.per_category]
    existing = json.loads(CATALOG.read_text()) if CATALOG.exists() else []
    catalog = merge(existing, fresh)
    CATALOG.parent.mkdir(parents=True, exist_ok=True)
    CATALOG.write_text(json.dumps(catalog, indent=2) + "\n")
    print(f"{CATALOG}: {len(fresh)} eBay listing(s), {len(catalog) - len(fresh)} other product(s). "
          "Restart the service to embed the new ones.")


if __name__ == "__main__":
    main()
