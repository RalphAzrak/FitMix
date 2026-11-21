# Live garment detection and retailer match

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
6. **Search** (`RetailerSearch.swift` → `POST /v1/garment-match` on the FitMix backend). The phone sends only the
   selected garment's crop (JPEG, long edge ≤ 640 px, no metadata), its category, its colour, and up to three
   words printed on it (read on-device). The backend holds the retailer credentials.

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

## Retailer match

- **Provider:** eBay Browse API `item_summary/search_by_image`, an official, authorized API. See
  `Backend/README.md` for setup. The backend searches the men's and women's eBay category for the selected
  garment (one category per request). It keeps fixed-price listings only, so the price shown is what the item
  sells for, not a bid. It then drops any listing whose eBay category isn't that garment, and ranks by eBay's
  visual order, nudged by the colour and any brand word read on the garment.
- **Card contents:** the listing's own product image, title, retailer ("eBay · seller"), listed price and
  currency, and **View listing**, all taken from the listing. A missing price reads **Price unavailable**.
  Results are always **Similar match**, because image search alone isn't evidence of the exact product.
- **States:** loading on the card; **No match found** when the provider answered but nothing in that category
  came back; **Search failed** with **Retry** for network, timeout or busy errors; and **Search unavailable**
  (no retry) when the backend has no keys or eBay refuses them.

## Debug and test hooks (Debug builds only)

| Variable | What it does |
| --- | --- |
| `FM_DEBUG_MATCH_FIXTURE=match\|nomatch\|error\|slow` | Replaces the backend with labeled fixtures ("Test fixture … (not a real listing)"). |
| `FM_DEBUG_SCREEN=live-sample-<jacket\|tshirt\|pants\|shoes>` | Opens Studio as if that garment of Sample Scan A had been tapped live. |
| `FM_DEBUG_THEN_SELECT=<category>` | With the above, selects another garment 1 s later (checks that an older search can't overwrite it). |
| `FM_DEBUG_CAPTURE_PHOTO=/path.jpg` | Adds **Analyze Test Photo as Live Frame** to the Camera. `FM_DEBUG_AUTO_ANALYZE=1` runs it on open. |
| `FM_DEBUG_REPLAY=shoes:x,y,w,h;…` | With the above, replays detections recorded on a Mac, because the simulator can't run body pose. |
| `FM_DEBUG_AUTO_SELECT=<category>` | Selects that live target through the same path as a tap, once it is ready. |
| `FITMIX_MATCH_PROVIDER=fixture` (backend) | The backend returns a labeled fixture without calling eBay. |

## What still needs an iPhone

- Live detection on the camera feed: frame rate, responsiveness, stable targets while moving, and stale
  targets clearing when a garment leaves view.
- Physical taps on targets (in the simulator, selection is checked through the same `select` path a tap uses).
- A real listing in Studio, which also needs eBay keys on the backend.
