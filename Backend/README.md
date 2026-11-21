# FitMix backend

A small server between the iPhone app and the services it uses. Provider keys live only here, in environment
variables. They are never in the app or in Git.

- **Avatars:** the app sends the user's full-body photo, optional selfie, height and weight. The server adds the
  drawing instruction, calls OpenAI's Image Edits API, and returns the finished portrait.
- **Retailer match:** the app sends the crop of one garment the user tapped in the live camera, with its
  category. The server searches eBay's catalog and returns real listings in that category. See
  [Retailer search setup](#retailer-search-setup).

## Run it on your Mac

1. `cp .env.example .env` and put your key after `OPENAI_API_KEY=`.
2. `./run.sh`
3. Build and run FitMix from Xcode. Your iPhone must be on the same Wi-Fi as this Mac, and the first time it
   will ask to connect to devices on your local network: allow it.

`run.sh` creates a private Python environment in `.venv`, makes a shared secret, and writes
`FitMix/Resources/Backend.local.json` so debug builds know this Mac's address and the secret. That file and
`.env` are ignored by Git. Rebuild the app after the first run so it picks the file up.

To try the app without a key or any cost: `FITMIX_MOCK=1 ./run.sh` returns a placeholder figure instead of
calling OpenAI.

## The endpoint

`POST /v1/avatar` (multipart form)

| Field | |
|---|---|
| `body_photo` | Required. JPEG, PNG or WebP, up to 8 MB. Sent to OpenAI first, as the main reference. |
| `selfie` | Optional. Same formats. Sent second, for facial detail. |
| `height_cm`, `weight_kg` | Required. Written into the instruction as supporting cues for build. |

Header: `Authorization: Bearer <FITMIX_APP_TOKEN>` when a token is set.

Returns the portrait as `image/png`, or `{"error": {"code", "message"}}`. The message is written for the person
using the app. `GET /health` says whether the server is ready.

The instruction sent with the photos is in `app/prompt.py`. Model, quality and limits are set in `.env`
(see `.env.example`).

`POST /v1/garment-match` (multipart form)

| Field | |
|---|---|
| `crop` | Required. JPEG, PNG or WebP of the selected garment only, up to 2 MB. The full outfit frame is never sent. |
| `category` | Required. `jacket`, `tshirt`, `pants` or `shoes`. Only this category is searched. |
| `color` | Optional, e.g. `navy`. Measured on the phone. |
| `brand_hints` | Optional, comma-separated words read on the garment on the phone (at most three are used). |

Returns `{"status": "matched" | "no_match", "category", "provider", "fixture", "results": [...]}`. Each result has
`id`, `title`, `retailer`, `seller`, `image_url`, `url`, `price` (`{"value", "currency"}` exactly as listed, or
`null`) and `match` (always `"similar"`; image search is no evidence of the exact product). Errors use the same
`{"error": {"code", "message"}}` shape. `not_configured` and `provider_auth` aren't worth retrying. The other
codes (`provider_busy`, `provider_timeout`, `provider_unreachable`, `provider_error`, `provider_rejected`) are.

## Retailer search setup

The provider is the **eBay Browse API** (`item_summary/search_by_image`), eBay's official, authorized API for
finding listings by image. It returns each listing's image, title, price, currency and link.

1. Create a free account at [developer.eBay.com](https://developer.ebay.com/) and create a **Production** keyset.
   eBay asks every production keyset to handle *Marketplace Account Deletion* notifications, or to apply for
   an exemption. FitMix stores no eBay user data, so the exemption applies.
2. In `Backend/.env`, set `EBAY_CLIENT_ID` (the keyset's App ID) and `EBAY_CLIENT_SECRET` (its Cert ID).
   Optionally set `EBAY_MARKETPLACE_ID` (default `EBAY_US`; prices come back in that site's currency).
3. Restart `./run.sh`. `GET /health` should say `"match_ready": true, "match_provider": "ebay"`.

Cost: the API is free. eBay applies a daily call limit per keyset, shown on the developer portal. Each FitMix
search makes two calls (men's and women's category), plus a token request about every two hours.

To try the app without keys: `FITMIX_MATCH_PROVIDER=fixture ./run.sh` returns one listing marked as a fixture
("Test fixture … (not a real listing)", no link) without contacting eBay.

The eBay category IDs searched for each garment are in `app/retail.py` (`EBAY_CATEGORY_IDS`). Any listing whose
eBay category doesn't name that garment is dropped. If eBay renumbers a category, searches for it show
"No match found" rather than listings from another category.

## Google Lens matches through the vision service

With `FITMIX_MATCH_PROVIDER=vision`, `/v1/garment-match` forwards the garment crop to the FitMix vision service
([`vision-service/`](../vision-service/README.md)). There, it's described by OpenAI and searched with
**Google Lens and Google Shopping**, then re-ranked by how alike the products look. The best 5 come back in
the same response shape, so **the app needs no change or rebuild**. As before, only the tapped garment's
crop leaves the phone.

1. Set up and start the vision service: see its README, "Setup on Mac". Leave that window open.
2. In `Backend/.env`:
   ```
   FITMIX_MATCH_PROVIDER=vision
   VISION_SERVICE_URL=http://localhost:8790
   VISION_APP_TOKEN=            # only if you set one in vision-service/.env
   ```
3. Restart `./run.sh`. `GET /health` should say `"match_ready": true, "match_provider": "vision"`.

- **Cost:** each garment the user taps costs one OpenAI description and two SerpAPI searches. The vision
  service caches repeats of the same crop.
- **Errors:** if the vision service isn't running, the app shows **Search failed** with **Retry**.
- **Mock data:** with the vision service in `MOCK_MODE`, results are labelled as test data in the app. Its
  mock product pictures are served by the vision service itself, so for them to load on an iPhone, set
  `VISION_SERVICE_URL=http://<your-mac>.local:8790` instead of `localhost`. Real Lens and Shopping pictures
  are ordinary web links and load either way.

## What happens to the photos

The server keeps each photo in memory only while its request runs. It writes nothing to disk and logs only the
number and size of the pictures, how long the request took, and whether it worked. OpenAI receives the avatar
photos and the instruction; how long OpenAI keeps them is governed by OpenAI's own API data policy. For retailer
search, eBay receives only the garment crop; its API terms govern what eBay does with it. With the `vision`
provider, the crop goes to the vision service instead, which sends it to OpenAI, Supabase Storage (deleted
after the search) and Google via SerpAPI.

## Tests

    .venv/bin/pip install -r requirements-dev.txt
    .venv/bin/python -m pytest

The tests replace OpenAI and eBay with stand-ins (eBay answers are shaped like its documented `ItemSummary`
schema, not real listings), so they need no keys and send nothing.

## Before putting this on the internet

It is built to run on your own Mac for now. Before hosting it publicly:

- Serve it over HTTPS and set the app's production address in `FitMix/Services/BackendConfig.swift`.
- Replace the shared secret with a check of the signed-in user's Supabase session, so only FitMix accounts can
  request avatars. A secret shipped inside an app can be extracted.
- Keep the per-device hourly limits, and set a spending limit on the OpenAI key.
