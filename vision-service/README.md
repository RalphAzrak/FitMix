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
| 2 | Real OpenAI description + Google Shopping links | planned |
| 3 | SegFormer segmentation (per-garment crops) | planned |
| 4 | FashionCLIP catalog matching + demo catalog | planned |
| 5 | Google Lens (via Supabase signed links) + re-ranking | planned |
| 6 | `/refine` on real search + image-hash cache | planned |

Until a stage is done, only `MOCK_MODE=1` has a working pipeline. Without it, `/analyze` answers
`503 not_configured`.

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
   | `SUPABASE_CROP_BUCKET` | stage 5 | Create a **private** bucket with this name (default `vision-crops`) under Storage. |
   | `EBAY_CLIENT_ID` / `EBAY_CLIENT_SECRET` | stage 4, optional | Only for the catalog seed script; the same keys as `Backend/.env`. |
   | `VISION_APP_TOKEN` | optional | Any random string. When set, callers must send `Authorization: Bearer <token>`. |

4. **Run it:**
   ```bash
   ./run.sh                 # uses .env
   MOCK_MODE=1 ./run.sh     # demo data, whatever .env says
   ```
   The first run creates a private Python environment in `.venv` and installs the requirements. From stage 3
   on, the first real run also downloads about 1 GB of models into `~/.cache/huggingface`. Keep the window open:
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
                         "retailer_url": "https://example.com/products/demo-top-08", "score": 0.7671}],
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

## Re-ranking (stage 5)

Each online result's thumbnail is compared with the garment crop:

    score = RERANK_IMAGE_WEIGHT · cos(crop, thumbnail) + RERANK_ATTR_WEIGHT · attribute_match

`cos` is the cosine similarity of the two FashionCLIP vectors. `attribute_match` is the fraction of the
garment's category, colour and pattern found in the result's title. The weights default to 0.8 and 0.2 and
are set in `.env`.

## Mock mode

`MOCK_MODE=1` gives realistic data without models or keys. The mock still reacts to the photo:
- crops are real regions of it (upper and lower body)
- colours are measured from its pixels
- catalog scores are real cosine similarities over a small colour fingerprint

Every product is fictional. Links go to `example.com`, and product pictures are drawings served by
`/mock-images/…`. Responses say `"mock": true`.

## Privacy

- **`image` input sends the whole photo of a person to this service.** From stage 2 on, its garment crops go
  to OpenAI (description), and from stage 5 on also to Supabase Storage and Google via SerpAPI (online
  search). That's a change from the iPhone app's current guarantee that the full camera frame never leaves the
  phone (see `Docs/LiveGarmentMatch.md`).
- **`crops` input keeps that guarantee:** the app cuts out garments on the phone and sends only those.
- Photos and crops are kept **in memory only**, for the cache lifetime (`CACHE_TTL_SECONDS`, 1 hour by
  default), and nothing is written to disk. Logs contain step names, counts and timings, never images or keys.
- Crops uploaded for Google Lens (stage 5) go to a private bucket, and Lens gets a signed link that expires
  after `SIGNED_URL_SECONDS` (5 minutes by default).

## Tests

```bash
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest
```

The tests use the mock components and stand-ins, so they download no models, need no keys and send nothing.
