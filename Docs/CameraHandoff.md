# Camera → garments handoff

> **The Camera no longer takes photos.** Garments are detected live and tapped one at a time, then Studio
> opens on that frame and searches retailers for the tapped garment. See [LiveGarmentMatch.md](LiveGarmentMatch.md).
> The still-photo path below (`CaptureHandoff`, `GarmentIsolator`, Outfit Review) is still in the code and is
> reached from the debug sample scans. The Camera no longer feeds it.

The still-photo flow was Camera → Use Photo → Outfit Review (garments found, **Tap to Isolate**, choose pieces)
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

## Live detection

Live frames, the tap targets, and retailer matching are built. See [LiveGarmentMatch.md](LiveGarmentMatch.md).

## Guarantees

- Closing Camera or Outfit Review leaves Studio's current look unchanged.

## Debug testing

- `FM_DEBUG_CAPTURE_PHOTO=/path/photo.jpg` now adds **Analyze Test Photo as Live Frame**: the photo
  is analyzed like a live camera frame (see LiveGarmentMatch.md).
- `FM_DEBUG_SCAN_FIXTURE` and `FM_DEBUG_SAMPLE_SCANS=1` still work. They're labeled as fixture or
  sample data.
