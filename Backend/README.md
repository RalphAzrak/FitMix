# FitMix backend

A small server between the iPhone app and OpenAI. The app sends the user's full-body photo, optional selfie,
height and weight; the server adds the drawing instruction and calls OpenAI's Image Edits API, then returns the
finished portrait. The OpenAI key lives only here, in an environment variable. It is never in the app or in Git.

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

## What happens to the photos

The server keeps each photo in memory only while its request runs. It writes nothing to disk and logs only the
number and size of the pictures, how long the request took, and whether it worked. OpenAI receives the photos
and the instruction; how long OpenAI keeps them is governed by OpenAI's own API data policy.

## Tests

    .venv/bin/pip install -r requirements-dev.txt
    .venv/bin/python -m pytest

The tests replace OpenAI with a stand-in, so they need no key and send nothing.

## Before putting this on the internet

It is built to run on your own Mac for now. Before hosting it publicly:

- Serve it over HTTPS and set the app's production address in `FitMix/Services/BackendConfig.swift`.
- Replace the shared secret with a check of the signed-in user's Supabase session, so only FitMix accounts can
  request avatars. A secret shipped inside an app can be extracted.
- Keep the per-device hourly limit, and set a spending limit on the OpenAI key.
