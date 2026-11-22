# FitMix backend

A small server between the iPhone app and the services it uses. Provider keys live only here, in environment
variables. They are never in the app or in Git.

- **Avatars:** the app sends the user's full-body photo, optional selfie, height and weight. The server adds the
  instruction for a photorealistic portrait, calls OpenAI's Image Edits API, and returns the finished image.
- **Avatar styling:** the app sends the accepted portrait and selected wardrobe garments after the user confirms.
  The server returns one styled image. See [Avatar outfit previews](#avatar-outfit-previews).
- **3D avatars:** the app sends the accepted portrait. The server builds a rotatable model on this computer.
  See [3D avatars](#3d-avatars).
- **Outfit match:** the app sends one crop per garment. OpenAI invokes image-based discovery and compares
  the crop with verified retailer photos. See [Studio outfit matching](#studio-outfit-matching).

## Run it on your Mac

1. If `.env` is missing, copy `.env.example` to `.env`. Put your key after `OPENAI_API_KEY=`.
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

## Avatar outfit previews

`POST /v1/avatar-outfit` accepts a required `portrait` and at least one of `tshirt`, `pants`, `shoes`, and
`outerwear` as multipart images. The accepted portrait is the primary reference for one edit. A
shirt and outerwear are layered in the same preview. Requests and results use the existing avatar
service settings. The app asks for confirmation before sending the portrait and garment images.

## 3D avatars

`avatar3d/build.sh portrait.png out.usdz` turns one full-body portrait into a 3D avatar, in about 5 minutes on an
Apple-silicon Mac:

1. **Cutout:** the person is cut out of the portrait (Apple Vision).
2. **Shape:** TRELLIS.2, run locally by [trellis.cpp](https://github.com/pwilkin/trellis.cpp), turns that one
   picture into a textured mesh. It takes a single image, so no other angles are generated or asked for; the
   sides and back are the model's estimate. The seed is fixed, so the same portrait always gives the same avatar.
3. **Face:** the generated texture is coarse and its colours drift from the portrait's, so the portrait
   (enlarged 4x with Real-ESRGAN, no face restoration) is used for everything the camera saw:
   - It is laid over the model's front view, outline to outline, and becomes the texture of the whole front:
     clothes, arms, hands, shoes.
   - Wherever the two show the same point, the pair says how the generator changed that colour. That correction
     is applied to the whole texture, so skin, hair and clothes are the same colour all the way round.
   - The head is done again at higher detail. It is placed by the landmarks found on the model's own texture,
     or by the mesh's nose when no face can be read there, and checked against the mesh: the model's nose tip
     must sit inside the portrait's nose.

   The mesh is not changed, so shapes (the hair, the hands) are still the generator's, and the sides and back
   keep its texture, recoloured. A part that can't be placed with confidence is skipped and the server log says why.
4. **Package:** a self-contained USDZ, upright, 1.75 m tall, feet on the floor.

Set it up once with `avatar3d/setup.sh`. It installs everything into `avatar3d/.tools` (ignored by Git, about
6 GB, mostly the TRELLIS.2 weights) and needs Xcode's command-line tools, Blender 5, cmake and ninja. Until then
`GET /health` reports `"avatar3d_ready": false` and the app's **Build 3D Avatar** says the builder isn't set up.
Check the licences of the TRELLIS.2 and DINOv3 weights before shipping avatars made with them commercially.

| Request | |
|---|---|
| `POST /v1/avatar-3d` (multipart, `portrait`) | Starts a build. Returns `202` with the build's state. |
| `GET /v1/avatar-3d/{job}` | `{"job", "status": "queued" \| "running" \| "done" \| "failed", "stage", "progress", "position", "face_sharpened", "error"}`. `stage` is `cutout`, `shape`, `face` or `package`; `progress` is 0 to 100, counted from the generator's own steps. |
| `GET /v1/avatar-3d/{job}/model` | The finished USDZ (`model/vnd.usdz+zip`). |
| `DELETE /v1/avatar-3d/{job}` | Stops a build that is no longer wanted. |

One build runs at a time and others wait their turn. The portrait is written to a private temporary folder for the
length of its build and deleted with it; a finished model is kept in memory for 30 minutes. With `FITMIX_MOCK=1`
a plain placeholder figure is returned after a few seconds, with no tools needed.

`POST /v1/garment-match` (multipart form)

| Field | |
|---|---|
| `crop` | Required. JPEG, PNG or WebP of the selected garment only, up to 2 MB. Full camera frames, profile photos and avatar images are never sent. |
| `category` | Required. `jacket`, `tshirt`, `pants` or `shoes`. Only this category is returned. |
| `color`, `pattern`, `style` | Optional clues read on the phone, e.g. `black`, `polka dots`, `sneaker`. |
| `brand_hints`, `text` | Optional, comma-separated words and codes printed on the garment (Vision text recognition on the phone). |

Returns `{"status": "matched" | "no_match", "category", "fixture", "providers": [...], "results": [...]}`. Each result has
`id`, `title`, `retailer`, `seller`, `image_url`, `url`, `price` (`{"value", "currency"}` exactly as listed, or `null`),
`match`, `brand`, `evidence` (why it got its label, in words), `provider`, `fixture` and `score`. `providers` says which
provider answered, failed, or was skipped and why.

How results are labeled (`app/visual_search.py`):

- `exact`: a product code read on the garment matches the listing (title, URL, or the page's SKU/MPN/GTIN); or the
  brand, a two-word model name and the colour read on the garment all match; or the provider found the same image on
  the listing *and* the brand is supported. The app shows **Exact match**.
- `brand`: only the brand is supported, either read on the garment or agreed on by at least 4 of the top 6 visual
  matches. The app shows **Likely from [brand]**.
- `similar`: the closest real alternative. The app shows **Similar match**.

Social and media pages (Instagram, Pinterest, …) and listings that name another garment category are dropped. Results
are ordered by label, then provider rank and shared clues; the app reorders within each label by photo likeness.

Errors use `{"error": {"code", "message"}}`. `not_configured` and `provider_auth` aren't worth retrying; the other
codes are. When one provider fails, the others' results are still returned.

## Studio outfit matching

Add `OPENAI_API_KEY` and `TRENDTRACK_API_KEY` to this worktree's ignored `Backend/.env`.
`OPENAI_MATCH_MODEL` defaults to `gpt-4.1-mini`. Start the server with `./run.sh`.
Check `/health` for `outfit_match.ready` and `outfit_match.discovery`. Readiness indicates that
both keys are configured. Trendtrack requires API access to its image search endpoint.

FitMix sends one garment JPEG per garment to `POST /v1/outfit-match`. OpenAI invokes the
backend's `discover_products_by_image` function. That function sends the unchanged crop as
the multipart image to [Trendtrack product image search](https://docs.trendtrack.io/en/docs/guides/image-search).
Discovery covers Trendtrack's indexed stores. FitMix has no store allowlist. It resolves each
hit to its retailer page, requires a structured in-stock offer with a price and currency,
and downloads the retailer's product photo. The OpenAI ranking call sees only the crop,
product photos and category. It compares color (35), cut (30), pattern (20) and details (15).
A visible product code must match a retailer SKU, MPN or GTIN for an **Exact match**.
Otherwise Studio shows a credible **Similar match**, or no result if verification fails.

The app shows the merchant's currency. The existing outfit budget uses CAD listings only
and compares item prices before tax and shipping. Budget follow-ups page the same image
search without re-uploading to Trendtrack. The backend retains the original crop in memory
for up to 10 minutes when more pages are available, with a 16 MiB server-wide cap. Crops
are never written to disk. Each initial result or budget fetch can examine at most two
pages of 12 hits. Trendtrack charges API credits per returned row and for detail lookups
when needed.

For an iPhone test, run the backend on the same Wi-Fi, then build this worktree in Xcode.
Disable `FM_DEBUG_MATCH_FIXTURE` and camera replay settings. Open **Scan Fits** and tap a
garment target. In **Layers & Garments**, check the shop link, photo, currency and visual
score. Try an alternative, open **Shop This Look**, and set a CAD budget. The Xcode console
category `OutfitMatching` shows first-card and settled timings.

## Legacy product search: `POST /v1/lens-search`

Older clients send each garment’s crop as multipart `crop` (JPEG, PNG or WebP, at most 2 MB) plus `category` (`jacket`, `tshirt`, `pants`, `shoes`) and the
optional on-device clues `color`, `text`, `pattern`, `style`. The server asks Google Lens through Scrappa
(`GET https://scrappa.co/api/google/lens?url=<crop URL>&type=visual_matches`, `X-API-KEY` header, from Scrappa's
OpenAPI spec) and answers:

    {"status": "matched", "source": "google_lens", "cached": false,
     "result": {"title", "url", "image_url", "image_source", "retailer", "price", "match": "similar", ...}}
    {"status": "no_match", "source": "google_lens", "cached": false, "result": null}

`result` is the single best credible listing: a retail page (not Google, social or image sites) whose title fits the
category (or whose page carries a price) and names no other category, with an http(s) product link and an https
photo. The top 4 listing pages are read for the retailer's own product photo (`image_source: "listing_page"`);
otherwise Lens's thumbnail of that listing is used (`"lens_thumbnail"`). It is always labeled `similar`.

Spending guards, all server-side:

- **Cache**: the same crop and category get the stored answer (match or no match) for `FITMIX_LENS_CACHE_HOURS`
  (default 7 days), across restarts. Failures aren't cached.
- **In-flight de-duplication**: identical requests at the same time share one Scrappa call.
- **Monthly cap**: at most `FITMIX_LENS_MONTHLY_LIMIT` calls (default 100) per UTC month; Scrappa's free tier is
  500 credits. Over the cap: `503 budget_exhausted`, no call.
- **Quota**: Scrappa `402` (out of credits) → `503 provider_quota`, and no more calls this month.
- **Refused key** (`401/403`) → `503 provider_auth`, no more calls until restart. **Rate limited** → 60 s cooldown
  (`provider_cooling_down`). Three failures in a row → 60 s cooldown. **Timeout** → `504 provider_timeout`.
- **Not configured** (no `SCRAPPA_API_KEY`, or `FITMIX_PUBLIC_BASE_URL` isn't https) → `503 not_configured`, no call.

The counter and cache live in `Backend/.cache/lens_search.json` (ignored by Git): hashes and listing JSON, no images.
`GET /health` reports `lens_search` readiness, calls this month and the cap, never the key.

## Retailer search setup (`/v1/garment-match`, not used by the app any more)

Providers receive only the selected garment crop, and only those listed in `FITMIX_VISUAL_PROVIDERS` run.

| Provider | Status | What it needs |
|---|---|---|
| `ebay`: eBay Browse API `search_by_image` | Official API, free. On by default once keys are set. | `EBAY_CLIENT_ID`, `EBAY_CLIENT_SECRET` from a Production keyset at [developer.ebay.com](https://developer.ebay.com/) (eBay asks for Marketplace Account Deletion handling or an exemption; FitMix stores no eBay user data). |
| `google_lens`: Google Lens via [Scrappa](https://scrappa.co/apis/google-lens-api) | Built and tested with fixtures. **Off until you decide to send garment photos to Scrappa.** | `SCRAPPA_API_KEY`, and `FITMIX_PUBLIC_BASE_URL`: an https address of this server Scrappa can reach. |
| `fixture` | Labeled development data. Sends nothing. | Nothing. |

Scrappa's documented Lens search is `GET /api/google/lens?url=<public image URL>&type=…` with an `X-API-KEY` header.
FitMix therefore publishes the crop at `/v1/crops/<random token>.jpg` for at most 90 seconds and 3 fetches, sends that
URL, and revokes it when the search returns. Scrappa's page also lists an upload endpoint, but its own FAQ says
uploads aren't supported and the upload docs couldn't be read, so FitMix doesn't use it. Lens results carry `title`,
`link`, `source`, `thumbnail`, `price` (display text, no currency field) and `position`. A price whose currency isn't
unambiguous (a bare "$") is dropped and taken from the listing page instead, or shown as "Price unavailable".

Listing pages: with `FITMIX_LISTING_ENRICHMENT=1` (default) the server reads the top 6 listings' pages for the
schema.org Product photo, price, currency, brand and codes. Only public http(s) hosts are fetched (private, loopback and
link-local addresses are refused, on every redirect too), and nothing about the user is sent.

To try the app without keys: `FITMIX_VISUAL_PROVIDERS=fixture ./run.sh`. The older `FITMIX_MATCH_PROVIDER=ebay|fixture`
still works when `FITMIX_VISUAL_PROVIDERS` isn't set.

## What happens to the photos

The server keeps each photo in memory only while its request runs. It writes nothing to disk and logs only the
number and size of the pictures, how long the request took, and whether it worked. OpenAI receives the avatar
photos and the instruction; how long OpenAI keeps them is governed by OpenAI's own API data policy. For retailer
search, each enabled provider receives only the garment crop; that provider's terms govern what it does with it.
Crops published for Scrappa live only in this server's memory, under an unguessable token, for at most 90 seconds.

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
