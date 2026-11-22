# Live garment detection and product match

Camera → tap a garment in the live preview (or select it manually) → Studio opens on that frame and searches for
the visible garments.

## The flow

1. **Camera**. The analyzer reads native rear-camera buffers in portrait on a serial queue. While nothing is
   tappable it analyzes up to 15 frames per second; once targets are shown, up to 8. A garment awaiting
   confirmation gets one earlier check. AVFoundation drops callbacks that arrive while analysis is busy.
   Vision's models are loaded while the camera starts, so the first person isn't slowed by them.
2. **Detection**. Vision pose locks onto one subject and matches their landmarks across frames. A missing or
   ambiguous match keeps the lock for 0.6 s. Within 2 s, a person found where the subject was last seen
   resumes the same lock (a pose dropout, not a new person). Anyone else becomes a new subject, which resets
   the garment tracks.
3. **Stable targets**. Two matching detections make a garment tappable. Smoothing and a movement
   threshold suppress jitter. The analyzer copies a full frame when a target appears, moves, or needs
   a fresher source.
   - A garment missed while the same person is still tracked stays tappable for up to 1 s after its last
     detection, and comes back without a second confirmation.
   - When the tracked person isn't matched for 0.45 s (they left), or 0.25 s while someone else is in view
     (the scanner switched subjects), all targets are cleared at once.
   - A new framing hint must hold for 3 analyzed frames before it replaces the one shown.
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

Skin is the reference for telling garments from bare body. It is sampled on the cheek, or on the back of a hand
when something covers the face, and only used if it falls in a plausible skin-colour range. Without a
reference, skin-coloured samples count as bare.

- **Jacket and T-shirt.** The image classifier and torso colour samples identify likely jackets, short
  sleeves, and contrasting inner layers. An inner shirt under an open jacket gets its own narrower target.
  A clear top is also tappable when both torso side panels are the same fabric and neither they nor the chest
  look like skin, so long sleeves and faces out of frame still work. Close framing that cuts off the hips
  estimates them from the shoulders (1.45 shoulder widths down) while the chest is in view. A torso that looks
  bare is never a T-shirt, however the arms read.
- **Pants.** Hip, knee, and ankle landmarks set the region. With the ankles out of frame, hips and a knee are
  enough (waist-to-knee): the box runs to the bottom of the frame. Thigh, above-knee and shin samples must not
  look like skin, so shorts and bare legs are rejected. The classifier ("jeans") is asked only when colour
  can't tell: the leg isn't one garment, a gray leg has no skin to compare with (it needs 0.5), or only one
  thigh is visible without a skin reference.
- **Shoes.** Ankles and leg length set the region. Vision's labels are hierarchical ("footwear" covers socks),
  so only shoe labels count (shoes, sneaker, boot, high heel, sandal, loafer), at 0.1 or more. When the tight
  crop scores sock but no shoe, a wider crop with the lower legs is classified, because dark shoes under dark
  trousers read as socks when cropped tight. Feet whose colour is skin are rejected unless a shoe label
  reaches 0.3 (sandals). When the feet run off the bottom of the frame, the Camera says **Feet are cut off.
  Step back or tilt down to include the shoes.**
- **Optional Core ML detector.** When `GarmentDetector.mlmodelc` is bundled, it can refine boxes for
  the locked pose. A box shared with another pose is discarded. The project ships without this model.

Low-confidence frames show a framing or lighting hint. Category thresholds are heuristic and
benefit from real-world checks across clothing, lighting, and partial poses. Known gaps: tan, beige or pink
garments can read as skin (warm light makes white look beige), and a frame with no pose at all (a waist-down
crop, legs only) finds nothing. Manual selection covers both.

## Manual selection

The crop button at the bottom right of the Camera (and, after 4 s with nothing tappable, a **Not finding it?
Select manually** prompt) freezes the next frame. **Select a Garment** shows it with a crop box. The user
picks Jacket, T-shirt, Pants or Shoes, then drags the box or its corners; VoiceOver users get Move and
Larger/Smaller actions on the box. The box starts on the scanner's own box for that garment if it found one,
otherwise where that garment usually sits on the person found, otherwise in the usual place in the frame.
It starts on the first category the scanner didn't find. **Use This Crop** hands Studio a
`LiveGarmentSelection` exactly like a tap: the frozen frame, the chosen garment cut with the box shown, and the
other garments detected in that frame. The camera is paused while the screen is open and resumes on close.

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

## Detection check (22 Nov 2026, Mac, no iPhone)

The detector and analyzer source files were compiled into a Mac harness. The harness fed 1080×1920 portrait frames,
built from openly licensed photos and crops of them, through `LiveGarmentAnalyzer` at 30 fps. Frames arrived as
landscape sensor buffers with the app's `.right` orientation, and frames arriving while analysis was busy were
dropped. "Slight movement" was synthetic: ±3 % sway, ±1.2 % shake and ±2 % zoom, with a 1.2 s empty frame
between scenes. Times run from the person's first frame to the target being tappable. "Drops" counts a visible
target disappearing and coming back within the 3 s scene. Each row is one run, before (`origin/main`) and
after.

| Scene | Before | After |
| --- | --- | --- |
| Full body, white tee, green pants, white sneakers | all three 0.53 s, no drops | all three 0.17 s, no drops |
| Closer shirt view (hips visible) | T-shirt 0.10 s, 2 drops | T-shirt 0.17 s, no drops |
| Closer still (hips out of frame) | nothing | T-shirt 0.50 s, no drops |
| Waist to knee, ankles out of frame | T-shirt 0.83 s, Pants 1.80 s, 1 drop each | both 0.17 s, no drops |
| Full body, ankles cut off | T-shirt only; Pants never | T-shirt and Pants 0.17 s, no drops |
| Dark trousers and dark shoes, face hidden by a camera | Pants 0.17 s, Shoes 0.44 s, no shirt | all three 0.17 s, no drops |
| Same, ankles cut off | Pants 2.17 s | T-shirt and Pants 0.24 s, no drops |
| Dark jacket, jeans, dark shoes, seen from above (small) | Shoes 0.13 s, 1 drop (3 runs: 2 drops each) | Shoes 0.90 s, 1 drop (3 runs: 0.13 s, 1 drop) |
| Sandals | Shoes 0.20 s | Shoes 0.14 s, no drops |
| **False detections** | | |
| Shorts with bare legs and feet | Pants (false) | none |
| Shirtless, gray sweatpants | T-shirt (false), 1 drop | none |
| Bare feet, denim shorts, grayscale | Pants (false in stills) | none |
| Back view, white tank, plaid shorts | — | T-shirt for the tank; no Pants |

Tracking (same harness):

- A 0.3 s pose dropout kept every target the whole time.
- A 0.8 s dropout cleared them after 0.40 s. They came back 0.13 s after the person returned, with no
  second confirmation.
- The person leaving cleared targets after 0.43 s.
- A direct switch to another person cleared the old targets after 0.17 s. The new person's targets were
  tappable at 0.64 s.

Frame cost was 6–9 ms on the Mac. Not checked: an iPhone camera, real motion blur, low light, socks without
shoes (no suitable photo was found), and several people in view.

## Product match

Studio sends the clearest eligible crop for each garment using up to four recent snapshots. Each
crop goes to `POST /v1/outfit-match` independently. OpenAI invokes Trendtrack’s image search with the actual
crop, then compares the crop against the retailer photos. The score uses color, cut, pattern and distinctive
details. A verified retailer code matching a visible code earns **Exact match**. Otherwise Studio shows the
highest-scoring credible listing as **Similar match**. **More matches** opens the alternatives. Changing the listing also updates
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
| `FM_DEBUG_MANUAL=<category>` | Opens manual selection on that category 1.5 s after the camera (or test photo) is ready. |
| `FM_DEBUG_MANUAL_CONFIRM=1` | With the above, presses **Use This Crop** 1.5 s later. |

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
