# Camera → garments handoff

The Camera doesn't take photos. Garments are detected live and tapped one at a time, then Studio opens on that
frame and searches retailers for the tapped garment. See [LiveGarmentMatch.md](LiveGarmentMatch.md).

The earlier still-photo flow (Camera → Use Photo → on-device garment isolation → Outfit Review) has been
removed: `CaptureHandoff`, `GarmentIsolator` and the photo analysis in `StudioStore` are no longer in the code.
They are in the Git history from before the live scanner.

## Outfit Review

Outfit Review (`OutfitReviewView`) is still in the app, but only Debug builds reach it. A debug sample or
fixture scan goes from the Camera to `StudioStore.review(_:)`, the user picks pieces, and **Try Full Look** opens
Studio. See [TryOnHandoff.md](TryOnHandoff.md).

## Guarantees

- Closing Camera or Outfit Review leaves Studio's current look unchanged.

## Debug testing

- `FM_DEBUG_CAPTURE_PHOTO=/path/photo.jpg` adds **Analyze Test Photo as Live Frame**: the photo is analyzed like
  a live camera frame (see LiveGarmentMatch.md).
- `FM_DEBUG_SCAN_FIXTURE` and `FM_DEBUG_SAMPLE_SCANS=1` add **Finish with…** buttons that open a ready-made scan
  in Outfit Review. The scans are labeled as fixture or sample data.
