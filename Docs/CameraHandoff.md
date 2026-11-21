# Camera → garments handoff

The flow is Camera → Use Photo → Outfit Review (garments found, **Tap to Isolate**, choose pieces)
→ Try Full Look → Studio.

## Garment isolation (on-device)

When the user taps Use Photo, `StudioStore.review(_ capture:)` opens Outfit Review with the photo.
It then runs `CaptureHandoff.analyze`, which calls `GarmentIsolator`, in the background. When
analysis finishes, it replaces `pendingScan` with the same photo plus its garments.

- `GarmentIsolator` (`FitMix/Services/GarmentIsolator.swift`) uses only Vision. It needs no
  network and sends nothing off the device. It runs a per-person mask, which it refines with
  `.accurate` person segmentation and reduces to the connected area around the torso. It then
  uses body pose to split the person into a **Top** (shoulders to hips, arms included) and
  **Bottoms** (hips to ankles, within the width of the legs).
- Each `DetectedGarment` has `bounds` normalized to `OutfitScan.image`, plus a transparent
  `cutout` and a rectangular `crop` cut from that same image. `HeroFrame.convert` maps the bounds
  into Studio's and Outfit Review's cropped view, so outlines and cutouts line up when the view
  is cropped or scaled.
- Known limits:
  - Bare skin inside a region becomes part of that cutout.
  - The split falls at the hip joint, so long coats and high-waisted bottoms are cut there.
  - If more than one person is in the photo, the largest one is used.
  - The top needs both shoulders and hips in frame. Bottoms need the hips and the knees or ankles.
  - Pose joints need a confidence above 0.3, so tightly cropped photos are often rejected.
- When nothing usable is found, Outfit Review explains why and offers **Retake Photo**.
- The iOS **simulator can't run body pose** ("Unable to setup request"), so analysis there shows
  "couldn't run on this device". Test the analysis on an iPhone.

To replace the heuristic with a clothing-parsing model, keep `GarmentIsolator.Output` and
change `analyze`. Nothing in Camera, Outfit Review, or Studio needs to change.

## Live tracking (not built)

| What | Where |
| --- | --- |
| Live frames for people tracking | `CameraSession.configureIfNeeded()`, at the `HANDOFF (issue 07)` comment: add an `AVCaptureVideoDataOutput` on the session queue. |
| Tracking overlay / tap-to-select in the viewfinder | `CameraView.viewfinder`, in the `.live` case. The preview uses `.resizeAspect`; convert boxes with `layerRectConverted(fromMetadataOutputRect:)`. |
| Product matching | `CaptureHandoff.analyze`, at the `HANDOFF` comment: fill `label` and `matches`. |

## Guarantees

- `ConfirmedCapture.image` is upright, has a long edge of at most 3000 px, and is the exact still
  the user reviewed.
- Closing or retaking in Camera or Outfit Review leaves Studio's current look unchanged.

## Debug testing

- `FM_DEBUG_CAPTURE_PHOTO=/path/photo.jpg` adds a **Capture Test Photo** button to the simulator's
  "Camera unavailable" screen. The photo goes through review → Use Photo → analysis exactly like
  a capture. In the simulator, analysis stops at the body-pose step.
- `FM_DEBUG_SCAN_FIXTURE` and `FM_DEBUG_SAMPLE_SCANS=1` still work. They're labeled as fixture or
  sample data.
