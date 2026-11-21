# FitMix vision service

Recognises the garments in an outfit and finds similar products. It's a separate Python service from
`Backend/` because its ML libraries (PyTorch, Transformers, the models) add a few GB that the main backend
doesn't need.

```
POST /analyze   photo or crops ─► 1 segment (photo only) ─► 2 describe (OpenAI) ∥ embed (FashionCLIP)
                                                         ─► 3 demo-catalog matches (top 5 per garment)
POST /search    one garment    ─► Supabase signed link ─► Google Lens ∥ Google Shopping (SerpAPI)
                                                         ─► merge, dedupe ─► re-rank (top 10)
POST /refine    one garment + brand ─► the /search step again, with the brand in the query
```

`/analyze` never calls SerpAPI. Online search runs only when the user taps a garment, and each
garment-and-brand pair is searched once and then cached, so credits are only spent on what someone looks at.

## Build status

| Stage | What | Status |
|---|---|---|
| 1 | Skeleton, `MOCK_MODE`, `/health`, all endpoints with mock data | ✅ done |
| 2 | Real OpenAI description + Google Shopping links | ✅ done |
| 3 | SegFormer segmentation (per-garment crops) | ✅ done |
| 4 | FashionCLIP catalog matching + demo catalog | ✅ done |
| 5 | Google Lens (via Supabase signed links) + re-ranking | ✅ done |
| 6 | `/refine` on real search + image-hash cache | ✅ done |

Without `MOCK_MODE=1`, each step runs when its key is present, and steps that aren't built or configured yet
are skipped (they're `null` in `/health` → `components`). With neither `OPENAI_API_KEY` nor `SERPAPI_KEY`,
`/analyze` answers `503 not_configured`.

**What runs today (all stages done):**
- **A photo** (`image`) is segmented by SegFormer into upper clothes, dress, skirt, pants and shoes. Each
  garment is cut out onto white, and pieces under `MIN_GARMENT_AREA` of the photo are dropped (shoes need half
  that). All the crops are then described in one OpenAI call. The model merges a jacket and the top under it
  into "upper clothes", so the LLM decides between `top` and `jacket` and sets `layered_over_top`.
- **Crops** (`crops`) skip segmentation and are described the same way.
- If the segmentation model can't load, or `SEGMENTATION=0`, photos are described as a whole instead: the LLM
  lists the garments, and each `crop_url` shows the whole photo (`source_label: "whole_photo"`). The log says why.
- **`/search`** runs **Google Lens** with the garment crop and **Google Shopping** with its `search_query`, side
  by side (2 SerpAPI searches). The results are merged, so a link both found is one result
  (`source: "lens+shopping"`). Then the **top 10 come back re-ranked** by how alike their thumbnails look (see
  [Re-ranking](#re-ranking)).
  - Lens needs the Supabase settings: it downloads the crop through a signed link, and the crop is deleted from
    the bucket right after. Without those settings, Lens is skipped and the log says so.
  - If FashionCLIP isn't available, `/search` falls back to Shopping alone, in Google's order.
  - **`/refine`** reuses the garment's Lens results (the picture hasn't changed), so only Shopping runs again, with
    the brand in the query. It costs 1 search.
- **Catalog matches:** each garment is embedded with FashionCLIP and compared with the demo catalog's products
  of the same category. The 5 most similar come back as `catalog_matches`, best first. If FashionCLIP can't
  load or `EMBEDDINGS=0`, `catalog_matches` stays empty and the log says why.

## Setup on Mac

For the Mac that runs the service (Apple Silicon recommended: the models then run on the GPU through Metal).

1. **Install Python 3.12** if `python3 --version` shows something older than 3.10:
   `brew install python@3.12`
2. **Create your settings file:**
   ```bash
   cd vision-service
   cp .env.example .env
   ```
3. **Put your keys in `vision-service/.env`.** `.env` is ignored by Git, so never commit it.

   | Setting | Needed from | Where to get it |
   |---|---|---|
   | `MOCK_MODE=1` | now | Use this until you have keys. Fake data, nothing sent anywhere. |
   | `OPENAI_API_KEY` | stage 2 | [platform.openai.com/api-keys](https://platform.openai.com/api-keys). Can be the same key as `Backend/.env`. |
   | `OPENAI_VISION_MODEL` | stage 2 | Any vision-capable model your account has (default `gpt-5-mini`). |
   | `SERPAPI_KEY` | stage 2 | [serpapi.com/manage-api-key](https://serpapi.com/manage-api-key). The free plan has a small monthly search quota. |
   | `SUPABASE_URL` | stage 5 | Already filled in with FitMix's project. |
   | `SUPABASE_SERVICE_ROLE_KEY` | stage 5 | Supabase dashboard → Project Settings → API → `service_role` key. **A master key**: keep it only in this file. |
   | `SUPABASE_CROP_BUCKET` | stage 5 | Supabase dashboard → Storage → **New bucket**, named `vision-crops` (or your choice), with **Public bucket turned off**. No policies needed: the service role key can use it. |
   | `EBAY_CLIENT_ID` / `EBAY_CLIENT_SECRET` | stage 4, optional | Only for the catalog seed script; the same keys as `Backend/.env`. |
   | `VISION_APP_TOKEN` | optional | Any random string. When set, callers must send `Authorization: Bearer <token>`. |

4. **Run it:**
   ```bash
   ./run.sh                 # uses .env
   MOCK_MODE=1 ./run.sh     # demo data, whatever .env says
   ```
   The first run creates a private Python environment in `.venv` and installs the requirements. From stage 3
   on, the first real run also downloads the models into `~/.cache/huggingface`: about 110 MB for segmentation
   (stage 3), plus about 600 MB for FashionCLIP (stage 4). Startup then takes several seconds while they load,
   and `/health` shows where they run (`"segmenter": "segformer (mps)"` on an Apple Silicon Mac). Keep the window open:
   the service runs at `http://localhost:8790` and logs how long each step takes.
5. **Check that it works.** In a second Terminal window:
   ```bash
   curl localhost:8790/health
   # → {"status":"ok","ready":true,"mock":true,...}

   curl -F image=@/path/to/person.jpg localhost:8790/analyze
   # → {"analysis_id":"…","garments":[{"category":"top","crop_url":"…","catalog_matches":[…]},…]}
   ```
   Copy the `analysis_id` and search online for the first garment:
   ```bash
   curl -X POST localhost:8790/search -H 'Content-Type: application/json' \
        -d '{"analysis_id":"PASTE_ID","garment_index":0}'
   ```

## API

All errors look like `{"error": {"code": "…", "message": "…"}}`, and the message is written for a person.
A step that fails *inside* a request (for example SerpAPI is down) doesn't fail the request: the response
still has everything that worked, and the failure is listed in that garment's `errors`.

### `POST /analyze` (multipart)

Send **either**:
- `image`: one photo of a person (JPEG, PNG or WebP, up to 8 MB). The service segments it into garments.
- **or** `crops`: one or more garment images the app already cut out (repeat the field, up to 8, 4 MB each).
  Transparent areas become white. Segmentation is skipped. Optional `categories` is a comma-separated hint
  per crop (`jacket`, `tshirt`, `top`, `pants`, `shoes`, `dress`, `skirt`).

```bash
curl -F image=@person.jpg localhost:8790/analyze
curl -F crops=@jacket.png -F crops=@shoes.png -F categories=jacket,shoes localhost:8790/analyze
```

```json
{
  "analysis_id": "bbe72050ed2e45888b7bbceaa7eaba4e",
  "input": "image",
  "mock": true,
  "cached": false,
  "garments": [{
    "index": 0,
    "category": "top",
    "app_category": "tshirt",
    "source_label": "upper_clothes",
    "crop_url": "http://localhost:8790/crops/bbe72050…/0.jpg",
    "description": "A olive casual crew-neck t-shirt in cotton.",
    "attributes": {"category": "top", "color": "olive", "pattern": "solid", "material": "cotton",
                   "style": "casual crew-neck t-shirt", "visible_brand": null, "description": "…",
                   "search_query": "olive cotton crew neck t-shirt", "layered_over_top": false},
    "catalog_matches": [{"id": "demo-top-08", "title": "Black Heavyweight Pocket Tee",
                         "price": {"value": "29.00", "currency": "USD"}, "image": "…",
                         "retailer_url": "https://example.com/products/demo-top-08",
                         "retailer": null, "sample": false, "score": 0.7671}],
    "online_matches": [],
    "errors": []
  }],
  "errors": [],
  "timings_ms": {"segment": 4, "describe": 12, "embed": 4, "catalog": 1, "total": 25}
}
```

- `category` is the LLM's category (`top`, `jacket`, `pants`, `shoes`, `dress`, `skirt`). `app_category` is the
  matching iPhone-app category (`jacket`, `tshirt`, `pants`, `shoes`), or `null` when the app has none yet.
- `layered_over_top` is true when an upper-body crop shows a jacket over another top. Segmentation can't
  separate the two, so the LLM says so.
- `online_matches` is always empty here. Call `/search`.
- Crop links work for as long as the analysis is cached (1 hour by default). The id in the link is the access
  check.

### `POST /search` (JSON)

```bash
curl -X POST localhost:8790/search -H 'Content-Type: application/json' \
     -d '{"analysis_id":"bbe72050ed2e45888b7bbceaa7eaba4e","garment_index":0}'
```

Returns `{analysis_id, garment_index, query, brand, mock, cached, online_matches, errors, timings_ms}`. Each
online match is `{title, price: {value, currency} | null, retailer, url, image, score, source}`, best first.
`source` is `lens`, `shopping`, or `lens+shopping`. A search that worked is cached, so asking again returns
`"cached": true` and spends nothing. A failed one isn't cached, so it can be retried.

The same input sent to `/analyze` again also returns `"cached": true`, with the earlier `analysis_id` (see
[Caching](#caching)).

### `POST /refine` (JSON)

```bash
curl -X POST localhost:8790/refine -H 'Content-Type: application/json' \
     -d '{"analysis_id":"bbe72050ed2e45888b7bbceaa7eaba4e","garment_index":1,"brand":"Levi'"'"'s"}'
```

This is the same as `/search`, with the brand put in front of the garment's search query (for example
`Levi's navy straight leg jeans`). The crop, description and embedding are reused from `/analyze`.

### `GET /health`

Reports whether a pipeline is ready, mock mode, which component runs each step, which keys are present
(true/false only, never the keys) and how many analyses are cached.

## Demo catalog

`catalog/catalog.json` lists the products `/analyze` can match against. These are the ones the user can try
on the avatar. Each entry looks like this:

```json
{"id": "demo-jacket-01", "title": "Olive Nylon Bomber Jacket", "category": "jacket",
 "price": {"value": "89.00", "currency": "USD"}, "image": "images/demo-jacket-01.png",
 "retailer": "FitMix demo", "retailer_url": null, "sample": true}
```

- `category` is one of `top`, `jacket`, `pants`, `shoes`, `dress`, `skirt`.
- `image` is a file in `catalog/images/` or an `https://` link.
- `price` can be `null`.
- Entries that don't fit are skipped, with a warning in the log.

Two scripts fill it:
- **`scripts/make_sample_catalog.py`** writes 32 fictional products with drawn pictures (`"sample": true`).
  They're in the repo already. Run it again only to restore them.
- **`scripts/seed_catalog_ebay.py`** adds real eBay listings (10 per category by default) through eBay's
  official Browse API. It reads `EBAY_CLIENT_ID` and `EBAY_CLIENT_SECRET` from `vision-service/.env` or
  `Backend/.env`, and each run replaces the previous eBay entries. Listings end over time, so re-run it before
  a demo.
  ```bash
  .venv/bin/python scripts/seed_catalog_ebay.py
  ```

Each run keeps the other script's entries and any you added by hand. FashionCLIP embeddings are computed at
startup only for new or changed products and cached in `catalog/embeddings.npz`, which Git ignores. Restart the
service after changing the catalog. Matches from local images point at `/catalog-images/<file>`, served by
this service.

## Caching

Everything is kept in memory, and a restart forgets it.

- **Repeated inputs** (stage 6): `/analyze` hashes its input with sha256 (the kind, every file's bytes in order,
  and the category hints).
  - **The same photo again** returns the earlier analysis instantly, with the same `analysis_id`,
    `"cached": true` and `timings_ms: {"cache", "total"}`. Its searches stay cached too.
  - **Only clean analyses are reused:** if any step failed, the next request runs again, so an outage can be
    retried.
  - **Identical requests that arrive together** share one run.
- **Searches:** a `/search` or `/refine` that worked is kept per garment and brand, so asking again returns
  `"cached": true` and spends no SerpAPI credit. A garment's Lens results are also reused by its `/refine`.
- **Limits:** up to `CACHE_SIZE` analyses (64) for `CACHE_TTL_SECONDS` (1 hour). The least recently used go first.

## Re-ranking

Each online result's thumbnail is downloaded and compared with the garment crop:

    score = RERANK_IMAGE_WEIGHT · cos(crop, thumbnail) + RERANK_ATTR_WEIGHT · attribute_match

- `cos` is the cosine similarity of the two FashionCLIP vectors, from −1 to 1; higher looks more alike. A
  result whose thumbnail couldn't be downloaded gets 0 for this part, because nothing shows that it looks alike.
- `attribute_match` is the fraction of the garment's category, colour and pattern found in the result's title,
  from 0 to 1. Common synonyms count ("tee" for a top, "gray" for grey, "army green" for olive). A solid pattern
  is left out, because shops rarely write "solid". On `/refine` the brand counts too.
- The weights default to 0.8 and 0.2, and are set in `.env`. Up to `RERANK_MAX_CANDIDATES` (40) merged results
  are scored, and the best `ONLINE_TOP_K` (10) are returned. Equal scores keep the providers' order.

## Mock mode

`MOCK_MODE=1` gives realistic data without models or keys. The mock still reacts to the photo:
- crops are real regions of it (upper and lower body)
- colours are measured from its pixels
- catalog scores are real cosine similarities over a small colour fingerprint

Every product is fictional. Links go to `example.com`, and product pictures are drawings served by
`/mock-images/…`. Responses say `"mock": true`.

## Privacy

- **`image` input sends the whole photo of a person to this service.** In stage 2, with no segmentation yet,
  the **whole photo** goes to OpenAI for the description. From stage 3 on, only its garment crops go to
  OpenAI, and from stage 5 on, the crop of a garment someone searches also goes to Supabase Storage and Google
  via SerpAPI (online search). That's a change from the iPhone app's current guarantee that the full camera
  frame never leaves the phone (see `Docs/LiveGarmentMatch.md`).
- **`crops` input keeps that guarantee:** the app cuts out garments on the phone and sends only those.
- Photos and crops are kept **in memory only**, for the cache lifetime (`CACHE_TTL_SECONDS`, 1 hour by
  default), and nothing is written to disk. Logs contain step names, counts and timings, never images or keys.
- Crops uploaded for Google Lens go to a private bucket, and Lens gets a signed link that expires after
  `SIGNED_URL_SECONDS` (5 minutes by default). The crop is deleted as soon as the Lens search is done. If a
  delete fails, it's logged; leftovers can be cleared from the dashboard.

## Tests

```bash
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest
```

The tests use the mock components and stand-ins, so they download no models, need no keys and send nothing.
