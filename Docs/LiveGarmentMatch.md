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
4. **Tap** (`CameraController.select`). Studio keeps the tapped target's full frame as the outfit reference.
   The analyzer compares recent crops from each stable garment track and takes its clearest one.
5. **Studio** (`StudioStore.openLive`). Layers & Garments shows all captured tracks with the tapped garment
   selected. Each card starts its own lookup and updates as the results arrive. A replacement scan cancels
   the old work and rejects late responses.
6. **Search** (`RetailerSearch.swift` → `POST /v1/outfit-match`). The phone sends one JPEG crop per garment
   (long edge ≤ 640 px, no metadata), its category and text for product-code verification. The full outfit
   frame stays on the phone. Provider credentials stay on the backend.

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

Studio chooses the clearest crop for each stable garment from up to four recent detections. Each
crop goes to `POST /v1/outfit-match` independently. OpenAI describes the garment, then scores a batch
of Canadian retailer listings on color, cut, pattern, and distinctive details. A verified retailer
SKU or barcode matching a visible code earns **Exact match**. Otherwise Studio shows the highest-scoring
listing as **Closest match**. **More matches** opens the alternatives. Changing the listing also updates
the selected-product summary and shopping review.

**Budget** sets one cap in CAD. Studio maximizes the number of included garments and then total
visual similarity. When necessary it searches for lower-priced alternatives using the original
garment descriptions. An over-budget swap is blocked before it changes the look.

See [backend setup and iPhone test](../Backend/README.md#studio-outfit-matching) for endpoint and
deployment details. The Xcode console category `OutfitMatching` reports first card and settled times.

## Debug and test hooks (Debug builds only)

| Variable | What it does |
| --- | --- |
| `FM_DEBUG_MATCH_FIXTURE=match\|branded\|nomatch\|error\|slow\|budget` | Replaces the backend with labeled fixtures ("Test fixture … (not a real listing)"); `branded` returns one of each label. |
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
- Live OpenAI and retailer matching with a configured backend and a garment-only scan.
