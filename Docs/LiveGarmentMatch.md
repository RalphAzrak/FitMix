# Live garment detection and product match

Camera → tap a garment in the live preview → Studio opens on that frame and searches for the visible garments.

## The flow

1. **Camera**. The analyzer reads native rear-camera buffers in portrait on a serial queue. It usually
   analyzes at most 8 frames per second. A garment awaiting confirmation gets one earlier check.
   AVFoundation drops callbacks that arrive while analysis is busy.
2. **Detection**. Vision pose locks onto one subject and matches their landmarks across frames. The
   lock can recover from a brief interruption. Acquiring a new subject resets the garment tracks.
3. **Stable targets**. Two matching detections make a garment tappable. Smoothing and a movement
   threshold suppress jitter. The analyzer copies a full frame when a target appears, moves, or needs
   a fresher source. Targets expire 0.6 seconds after their source frame.
4. **Tap**. Studio uses the target’s exact source image and highlight rectangle. The preview crop
   matches that rectangle. For product search, the analyzer can choose a sharper crop of the same
   garment from earlier, unexpired snapshots of the tracked subject.
5. **Studio**. The tapped garment is selected. Each visible garment starts its own lookup and updates
   as results arrive. Opening a new scan cancels the old searches.
6. **Search**. `POST /v1/outfit-match` takes one garment crop per request as JPEG up to 640 px on
   the long edge, with its category and text read on the phone. The full outfit frame and avatar
   stay on the phone during product search.

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

Studio sends the clearest eligible crop for each garment using up to four recent snapshots. Each
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

## iPhone verification

- Real time-to-tappable and frame cost (`FM_DEBUG_PERF_HUD=1`), and stable targets while moving.
- Physical taps on targets (in the simulator, selection is checked through the same `select` path a tap uses).
- Live OpenAI and retailer matching with a configured backend and a garment-only scan.

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
