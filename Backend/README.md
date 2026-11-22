# FitMix backend

A small server between the iPhone app and the services it uses. Provider keys live only here, in environment
variables. They are never in the app or in Git.

- **Avatars:** the app sends the user's full-body photo, optional selfie, height and weight. The server adds the
  instruction for a photorealistic portrait, calls OpenAI's Image Edits API, and returns the finished image.
- **Avatar styling:** the app sends the accepted portrait and selected wardrobe garments after the user confirms.
  The server returns one styled image. See [Avatar outfit previews](#avatar-outfit-previews).
- **3D avatars:** the app sends the accepted portrait. The server builds a rotatable model on this computer.
  See [3D avatars](#3d-avatars).
- **Outfit match:** the app sends one crop per garment. OpenAI searches the web for it from the photo and a
  description, and compares the crop with the product photos on the pages found.
  See [Studio outfit matching](#studio-outfit-matching).

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
| `height_cm`, `weight_kg` | Required. Guide the portrait's apparent stature and build, alongside the person's proportions in the full-body photo. |

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

## Studio outfit matching

Set `OPENAI_API_KEY` in the ignored `Backend/.env`. `OPENAI_SEARCH_MODEL` defaults to
`gpt-6.2-sol` for image description and web search. `OPENAI_MATCH_MODEL` defaults to
`gpt-4.1-mini` for product photo comparison. Start the server with `./run.sh` and check
`/health` for `outfit_match.ready` and `outfit_match.discovery: openai_web_search`.
The legacy Scrappa, eBay and Google Lens routes and configuration have been removed.

Studio sends only the selected garment crop, shopping department, and on-device OCR hints to
`POST /v1/outfit-match`. The full outfit photo stays on the phone. Shopping department applies
to retailer matching.

1. **Describe the garment.** OpenAI identifies visible garment type, color, pattern, cut, closure and lettering.
2. **Find direct listings.** The same crop and its structured description go to the OpenAI
   [web search request](https://developers.openai.com/api/docs/guides/tools-web-search). The model
   uses the image to resolve visible details and issues text queries to retrieve listings.
   A broader query can relax details while keeping garment construction and department.
   Listings found this way appear as Similar options.
3. **Verify listings.** FitMix reads the retailer page to confirm the product, variant photo,
   department and any stated price and currency. It drops pages and photos it cannot verify.
   Men's and Women's also include verified Unisex products. An explicit brand requires
   matching brand evidence on the page.
4. **Compare garment photos.** The ranker sees the original crop and verified product photos.
   A close match requires at least 65 and no clear conflict. Similar options still need
   the right construction, including quarter-zip and shorts when visible.
5. **Return up to five distinct options**, with close matches first and the photo used for comparison
   included as a JPEG thumbnail.

The multipart form accepts `crop`, `category`, optional `text` (OCR), optional `brand`, and
`department` (`men`, `women`, `unisex`, or `any`, the default).
`mode` defaults to `combined`. Use `photo` for the photo search only or `description` for
the description search and scoring only. Description mode derives its text from the same crop, then
ranks product photos against the text. The response returns `description` and an optional
`garment_label` from the crop. The `results` array contains close matches. The `alternatives` array contains
similar options and can be populated when `status` is `no_match`. Only a close match can be marked
`best_match`. A result's `price` is `null`
when its page doesn't state one.

Search time and result counts depend on live retailer coverage and any broadened queries.
Some retailers restrict automated product page or photo access. The app's request timeout is 85 seconds.
The outfit budget uses CAD prices only. A budget follow-up has no additional page to fetch.
Crops are held in memory during combined searches.

For an iPhone test, run the backend on the same Wi-Fi, then build this worktree in Xcode.
Disable `FM_DEBUG_MATCH_FIXTURE` and camera replay settings. Open **Scan Fits** and tap a
garment target. In **Layers & Garments**, check the shop link, photo and match label. Try **Refine Search**,
adjust the crop or set and clear a brand. Try an alternative. The Xcode console category `OutfitMatching`
shows first-card and settled timings.

## What happens to the photos

The server keeps each photo in memory only while its request runs. It writes nothing to disk and logs only the
number and size of the pictures, how long the request took, and whether it worked. OpenAI receives the avatar
photos and the instruction; how long OpenAI keeps them is governed by OpenAI's own API data policy. For Studio
outfit matching, OpenAI receives the garment crop, and its web search runs queries OpenAI writes from it. The
stores get an ordinary request for a product photo or page, and never the crop. No other service receives it.

## Tests

    .venv/bin/pip install -r requirements-dev.txt
    .venv/bin/python -m pytest

The tests replace OpenAI and retailer requests with fixtures. They run without API keys or external requests.

## Before putting this on the internet

It is built to run on your own Mac for now. Before hosting it publicly:

- Serve it over HTTPS and set the app's production address in `FitMix/Services/BackendConfig.swift`.
- Replace the shared secret with a check of the signed-in user's Supabase session, so only FitMix accounts can
  request avatars. A secret shipped inside an app can be extracted.
- Keep the per-device hourly limits, and set a spending limit on the OpenAI key.
