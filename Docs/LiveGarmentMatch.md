# Live garment detection and product match

Camera → tap one garment in the live preview → Studio opens on that frame and searches retailers for that
garment only. There is no shutter.

## The flow

1. **Camera** (`CameraView`, `CameraController`). The rear camera's video output delivers upright 1080p frames,
   rotated like the preview, to `LiveGarmentAnalyzer` on its own queue. It analyzes at most ~8 frames a
   second. AVFoundation drops the frames that arrive while a frame is being analyzed, so the preview never waits.
2. **Detection** (`LiveGarmentDetector`). This finds **Jacket, T-shirt, Pants and Shoes** on the most prominent
   person. It runs on the iPhone, and frames never leave it.
3. **Stable targets** (`GarmentTracker`). A garment becomes tappable after it has been seen in two analyzed
   frames. It is smoothed between frames and cleared once it has been out of view for 0.6 s. Frames much
   blurrier than recent ones don't replace the detections, so a tap always uses a recent sharp frame.
   **Tap to Isolate** shows when at least one target is ready.
4. **Tap** (`CameraController.select`). The tapped garment is cut from **the exact frame it was detected in**,
   along with every other garment detected in that frame. The camera stops and Studio opens
   (`StudioStore.openLive`).
5. **Studio**. The large image is that whole frame, with the tapped garment outlined. Layers & Garments shows
   the garments from that frame with the tapped one selected, and its card starts a retailer search right
   away. Tapping another card searches for that garment instead. Any search still running is cancelled, and
   its result is dropped even if it arrives late (each search has a token).
6. **Search**, only after the tap (`RetailerSearch.swift` → `POST /v1/garment-match`). The phone sends only the
   selected garment's crop (JPEG, long edge ≤ 640 px, no metadata), its category, and the clues it read on-device
   (`GarmentClues`). Full frames, profile photos and avatar images are never sent. The backend holds every
   provider credential.

## Overlays and taps

- The preview is aspect-fit, and frames are rotated to match the preview's rotation. A box normalized to the
  frame therefore maps onto the screen through the same `AVMakeRect` fit at any view size.
- The iPhone UI is portrait-only. If the phone is turned sideways, the preview and frames rotate together, so
  boxes still line up (people then appear sideways to the detector).
- Boxes are drawn largest first, so an inner T-shirt sits above the Jacket around it. A tap on the T-shirt strip
  selects the T-shirt, and a tap on the jacket's sides or sleeves selects the Jacket.
- Each garment also has its own labeled chip button, drawn above every box. Chips sit in separate places
  (Jacket above its box, T-shirt in the middle, Pants beside, Shoes below), so small or overlapping garments
  each keep one unambiguous control. The chip is also what VoiceOver reads.

## Detection: what runs today and its limits

Vision has no clothing detector. Two engines produce the same output:

- **Garment model (preferred, not included).** If the app bundle contains `GarmentDetector.mlmodelc`, a Core ML
  object detector exported with NMS (for example YOLO), its boxes are used directly. Labels are mapped by
  `LiveGarmentDetector.modelCategory(for:)`: jacket/coat/outerwear, t-shirt/tee/top, pants/trousers/jeans,
  shoes/footwear/boots/sneakers. Drop a compiled model into `FitMix/` and nothing else needs to change.
  Datasets with these classes (ModaNet, DeepFashion2) have their own licences; check them before shipping.
- **Vision fallback (what runs now).** Regions come from body pose and person segmentation. A garment is only
  reported when there is evidence for its category; otherwise it gets no target:
  - **Shoes:** a box from the ankles down, trimmed to the person mask, confirmed by Vision's built-in image
    classifier (shoes / footwear / sneaker / boot).
  - **Pants:** hips to the lowest ankle, where the shin matches the thigh and isn't bare skin. Shorts and bare
    legs get no Pants target.
  - **Jacket over T-shirt:** the centre of the torso differs from both side panels from chest to hem. The
    classifier's jacket/hoodie score lowers how much contrast is needed. The T-shirt is the inner strip only.
  - **Jacket alone:** the classifier says jacket, hoodie or suit (≥ 0.2), and the sleeves aren't short.
  - **T-shirt alone:** short sleeves (a bare forearm matching the face's skin tone).
  - Known limits: long-sleeve tops that aren't jackets get no target. A shirt, hoodie or sweater worn under an
    open jacket is labeled T-shirt. Jackets need both shoulders and hips in frame, and Shoes need the feet in
    frame (the Camera then says "Step back to include the shoes"). Thresholds were set on a handful of photos
    and need checking on an iPhone across lighting and outfits.

**The simulator can't run Vision body pose.** There, the Camera shows "Live garment detection needs an iPhone".

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

Studio asks the backend for listings, then shows the best one on the garment's card with its label:

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
| Google Lens via Scrappa | Implemented and tested with fixtures; **off until approved** (it would receive garment crops). |
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

## What still needs an iPhone

- Real time-to-tappable and frame cost (`FM_DEBUG_PERF_HUD=1`), and stable targets while moving.
- Physical taps on targets (in the simulator, selection is checked through the same `select` path a tap uses).
- On-device clues and photo comparison: in the simulator, Vision's classifier and foreground mask return nothing, so
  clues came back empty there and the re-ranker kept the backend order. Both were checked on a Mac.
- A live provider result, which needs eBay keys or an approved Scrappa setup.
