# Live garment detection and product match

Camera → tap one garment in the live preview → Studio opens on that frame and searches retailers for that
garment only. There is no shutter.

## The flow

1. **Camera** (`CameraView`, `CameraController`). The preview uses the rear camera in portrait.
   The analyzer reads native camera buffers with a portrait orientation and runs on a serial queue.
   Analysis usually runs at most 8 times per second. A garment awaiting confirmation gets one earlier
   check. AVFoundation drops callbacks that arrive while the analysis queue is busy.
2. **Detection** (`LiveGarmentDetector`). Vision body pose locks onto a subject and matches its
   landmarks across frames. If the match is lost or ambiguous, the lock can recover for up to 0.6 s.
   A new subject starts a fresh set of garment tracks.
3. **Stable targets** (`GarmentTracker`). Each garment needs two matching detections. Smoothing and
   a small movement threshold suppress jitter. The analyzer copies the full frame when a selectable
   target first appears, moves enough, or needs a fresher source frame. Each highlight expires 0.6 s
   after its source frame, including when the camera stops delivering frames.
4. **Tap** (`CameraController.select`). Each target carries its source image and crop bounds. A tap
   opens Studio on that image with the exact highlight rectangle and other garments detected in
   the same frame. Cropping uses the rectangle edges rounded out to whole pixels.
5. **Studio**. The large image is that whole frame, with the tapped garment outlined. Layers & Garments shows
   the garments from that frame with the tapped one selected, and its card starts a retailer search right
   away. Tapping another card searches for that garment instead. Any search still running is cancelled, and
   its result is dropped even if it arrives late (each search has a token).
6. **Search**, only after the tap (`LensSearch.swift` → `POST /v1/lens-search`). The phone sends only the
   selected garment's crop (JPEG, long edge ≤ 640 px, no metadata), its category, and the clues it read on-device
   (`GarmentClues`). Full frames, profile photos and avatar images are never sent. The backend holds every
   provider credential.

## Overlays and taps

- The rear preview is aspect-fit, portrait, and unmirrored. Vision and the copied frame use the same
  portrait orientation. Top-left normalized bounds map onto the displayed image using `AVMakeRect`.
- FitMix targets iPhone with a portrait-only interface. Test phone tilt and rear zoom presets on
  hardware. Vision should be used with the phone held upright.
- Boxes are drawn largest first, so an inner T-shirt sits above the Jacket around it. A tap on the T-shirt strip
  selects the T-shirt, and a tap on the jacket's sides or sleeves selects the Jacket.
- Each garment also has its own labeled chip button, drawn above every box. Chips sit in separate places
  (Jacket above its box, T-shirt in the middle, Pants beside, Shoes below), so small or overlapping garments
  each keep one unambiguous control. The chip is also what VoiceOver reads.

## Detection: what runs today and its limits

Vision pose uses confident shoulder, hip, knee, and ankle landmarks to place garment regions.
A person-instance mask refines them when most of the subject's pose probes agree on one label.
If another pose shares the label, the mask is discarded and pose bounds still work. Mask requests
are paced, with brief reuse when the visible joints stay aligned.

- **Jacket and T-shirt.** The image classifier and torso colour samples identify likely jackets,
  short sleeves, and contrasting inner layers. An inner shirt under an open jacket gets its own
  narrower target.
- **Pants.** Hip, knee, and ankle landmarks set the region. Colour continuity and the classifier help
  distinguish covered legs from shorts or bare shins.
- **Shoes.** Ankles and leg length set the region, and the classifier confirms footwear.
- **Optional Core ML detector.** When `GarmentDetector.mlmodelc` is bundled, it can refine boxes for
  the locked pose. A box shared with another pose is discarded. The project ships without this model.

Low-confidence frames show a framing or lighting hint. Category thresholds are heuristic and
benefit from real-world checks across clothing, lighting, and partial poses.

## Camera speed

Product search never runs in the camera loop: only detection does, and search starts after the tap.

Measured on an M4 Mac with camera-shaped 1080×1920 frames (no iPhone was available; numbers on an iPhone will differ,
so use the overlay below to measure there):

| Stage (per analyzed frame) | Before | Now |
| --- | --- | --- |
| Body pose | 9.1 ms (from a copied CGImage) | 5.6 ms (straight from the camera's pixel buffer) |
| Person segmentation | 13.3 ms (`.balanced`) | 4.2 ms (`.fast`; same detections on all 7 test frames) |
| Image classifier, per body area | 7.8 ms × up to 3, cached 0.5 s | unchanged |
| Whole frame | 22–60 ms | 9–35 ms |
| **Time until T-shirt / pants are tappable** (person in view at 30 fps) | **153–176 ms** | **43–89 ms, median 43–47 ms** |

The bottleneck was the Vision work per frame (segmentation quality, then the CGImage path) plus stabilization: a
garment had to wait 0.12 s for its confirming frame. Now a garment seen once is confirmed on the very next frame, so it
is tappable as soon as two frames agree. The floor is now the camera's 33 ms frame interval.

The same change also fixed detection on camera-shaped frames. Pants with shading down the leg are now recognised by
matching chroma, and a dark T-shirt under a black jacket is still separated, by averaging the centre/panel contrast.

**To measure on an iPhone:** run with `FM_DEBUG_PERF_HUD=1`. The Camera shows the last frame's cost
(vision / classify) and how long each garment took to become tappable after the person appeared. The same numbers are
`app.fitmix` signposts ("analyze frame", "tappable") in Instruments.

## Product match

**Google Lens via Scrappa is the product search** (Debug and Release). When Studio Fit opens after a scan, every
garment with a usable crop (jacket, T-shirt, pants or shoes, at least 48 px a side) gets its own
`POST /v1/lens-search`, all side by side (`StudioStore.openLive` → `findMatch`, `LensRetailerSearch`). Each card:

- shows that garment's original crop with a **Finding a match…** badge while its search runs;
- then the best credible listing: the retailer's product photo (with the crop kept as a small inset), name, retailer,
  price or **Price unavailable**, **View listing** (opens the listing), labeled **Similar match**;
- or **No close match found** when Lens returns nothing usable for that category;
- or **Couldn't search. Try again.** with **Retry** when the request fails (Debug builds also show the server's code);
- or **Search limit reached** when the server's monthly cap or Scrappa's credits are used up (no Retry).

One garment's failure doesn't affect the others, and a garment already answered isn't searched again for that look.
The server caches answers per crop, joins duplicate in-flight requests and caps monthly calls (see Backend/README.md),
so reopening Studio or retrying doesn't spend extra credits. Release builds find the backend through Info.plist
`FitMixBackendURL` (and optional `FitMixBackendToken`); Debug builds use `FITMIX_BACKEND_URL` or the
`Backend.local.json` that `Backend/run.sh` writes.

The labels below come from the older `/v1/garment-match` search (eBay and others), which the app no longer calls:

- **Exact match**: corroborated. A product code read on the garment matches the listing, or the brand, model name and
  colour read on the garment all match, or the visual search found the same image on the listing and the brand is
  supported.
- **Likely from [brand]**: only the brand is supported, read on the garment or agreed on by at least 4 of the top 6
  visual matches.
- **Similar match**: the closest real alternative.

Every photo, price, currency and link comes from the listing (provider data, then the listing page's own schema.org
data). A missing price reads **Price unavailable**. **More matches (N)** lists every ranked listing with the evidence
behind its label, and choosing one makes it the card's listing.

The backend orders listings by label, then provider rank and shared clues. On the phone, `VisualReranker` downloads the
top 6 listing photos, lifts the subject out of each and out of the crop (Vision foreground mask), and nudges the order
within a label by subject colour and feature-print likeness. On the test photos this correctly put a white tee above
black and green tees. It could not tell Converse models apart, so it's kept as a small nudge, never a label.

What the phone reads (`GarmentClues`): words and codes printed on the garment, colour (measured on the person's pixels
when the garment was detected), pattern (polka dots, leopard, or text print) and style (sneaker, boot, heel, loafer,
sandal, hoodie, suit, jeans). Limits: Vision can't read curved or stylised logo text (the Converse patch read nothing),
and it has no stripes, plaid or logo detection. Those depend on the visual search provider.

### Providers

| Provider | State |
| --- | --- |
| eBay Browse API (official) | As before; one provider among several. Needs keys. |
| Google Lens via Scrappa | **The app's product search** (`/v1/lens-search`). Needs `SCRAPPA_API_KEY` and an https `FITMIX_PUBLIC_BASE_URL` on the backend. |
| Fixtures | Labeled test data for development. |

**Scrappa evaluation.** Sources: scrappa.co Lens API page, pricing, privacy policy and terms, read 21 Nov 2026.
- **Upload contract:** `GET https://scrappa.co/api/google/lens?url=<public https image URL>&type=all|products|exact_matches|visual_matches`,
  with an `X-API-KEY` header. The page also lists a POST upload, but its FAQ says "No. The endpoint accepts a public
  HTTPS image URL", and the upload docs couldn't be read. So FitMix publishes the crop at a short-lived, unguessable URL
  on its own server (90 s, 3 fetches, revoked after the search).
- **Response:** `visual_matches`, `exact_matches`, `related_content`. Items have `title`, `link` (a google.com/goto
  redirect), `source`, `thumbnail`, `price` (display text only, no currency field) and `position`.
- **Price coverage:** "only filled when Google Lens displays them". A bare "$" is ambiguous, so FitMix takes prices
  with a clear currency marker only, and otherwise reads the listing page.
- **Data handling:** not stated for API inputs. There's no retention period for submitted images or URLs, no GDPR or
  data-processing terms, and nothing on what goes to Google. The controller is Marin Solutions UG, Berlin.
- **Cost:** $0.20 per 1,000 requests, 500 free credits a month, and a 45 s client timeout advised.

Before enabling it, get Scrappa to confirm in writing (hello@marin.sh) how long it keeps submitted image URLs and
fetched images, and whether images are passed to Google or others.

## Debug and test hooks (Debug builds only)

| Variable | What it does |
| --- | --- |
| `FM_DEBUG_MATCH_FIXTURE=match\|branded\|nomatch\|error\|slow` | Replaces the backend with labeled fixtures ("Test fixture … (not a real listing)"); `branded` returns one of each label. |
| `FM_DEBUG_PERF_HUD=1` | Camera shows per-frame cost and time-to-tappable per garment. |
| `FM_DEBUG_AUTO_TRYON=1` | Studio presses **Try on my avatar** once the selected garment's match arrives. |
| `FM_DEBUG_SCREEN=live-sample-<jacket\|tshirt\|pants\|shoes>` | Opens Studio as if that garment of Sample Scan A had been tapped live. |
| `FM_DEBUG_THEN_SELECT=<category>` | With the above, selects another garment 1 s later (checks that an older search can't overwrite it). |
| `FM_DEBUG_CAPTURE_PHOTO=/path.jpg` | Adds **Analyze Test Photo as Live Frame** to the Camera. `FM_DEBUG_AUTO_ANALYZE=1` runs it on open. |
| `FM_DEBUG_REPLAY=shoes:x,y,w,h;…` | With the above, replays detections recorded on a Mac, because the simulator can't run body pose. |
| `FM_DEBUG_AUTO_SELECT=<category>` | Selects that live target through the same path as a tap, once it is ready. |
| `FITMIX_VISUAL_PROVIDERS=fixture` (backend) | The backend returns labeled fixtures without calling any provider. |

## iPhone verification

- Real time-to-tappable and frame cost (`FM_DEBUG_PERF_HUD=1`), and stable targets while moving.
- Physical taps on targets (in the simulator, selection is checked through the same `select` path a tap uses).
- On-device clues and photo comparison: in the simulator, Vision's classifier and foreground mask return nothing, so
  clues came back empty there and the re-ranker kept the backend order. Both were checked on a Mac.
- A live Scrappa result: needs `SCRAPPA_API_KEY`, an https `FITMIX_PUBLIC_BASE_URL` that reaches the backend, and
  an approved garment-only photo.

Run the baseline and updated build on the same iPhone. Record the screen with the same subject,
outfit, lighting, and starting distance. Compare these scenarios.

| Scenario | What to check |
| --- | --- |
| Still subject | Time from framing the subject to the first tappable highlight. Compare edge movement while the phone and subject hold still. |
| Walking subject | Highlights follow the right garment and settle when the subject stops. |
| Person walking behind | The original subject keeps the highlights. Brief occlusion can recover. After a longer loss, confirm that the old highlights clear before the next subject is selectable. |
| Partial framing | Crop the feet, then the shoulders or hips out of frame. Confirm the hint and check which remaining garments are tappable. |
| Quick tap while panning | Tap an outline and its chip in separate takes. Compare the highlighted garment with the selected outline in Studio, especially where the jacket and T-shirt overlap. |
| Rear camera modes | Repeat with each available zoom stop, torch on and off, and after backgrounding and resuming. Tilt the iPhone within its portrait interface and check alignment. |

In Instruments, use Points of Interest for `app.fitmix / LiveGarmentScanner`. **Analyze frame**
includes timings for pose, mask, model, and classifier. **Copy selectable frame** measures the
full-resolution copy. **First usable target** measures elapsed time from the first analyzed frame
that acquired the subject to the first selectable snapshot. A screen recording measures what the
user actually sees, including preview startup and display latency.
