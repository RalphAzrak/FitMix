# Try-on handoff

Flow: **Camera → Outfit Review → Try Full Look → Studio**.

| Step | Where | What it does today |
| --- | --- | --- |
| Camera confirms a scan | `HomeView` `CameraView(confirm:)` | `studio.review(scan)`, opens Outfit Review. Studio's current look is unchanged. |
| Outfit Review | `FitMix/Views/Studio/OutfitReviewView.swift` | User picks which detected garments to try (all on by default). |
| Try Full Look | same file, `tryFullLook()` | Uses `AvatarStore.bodyPhoto` if saved; otherwise `TryOnPhotoSheet` asks for one (camera or Photos, on-device full-body check, saved with `saveBodyPhoto`). Then `studio.open(scan, selected:, tryOnSource:)`. |
| Studio preview | `StudioStore.refreshPreview()`, `TryOnHero` | Builds a `TryOnRequest` from the **original** photo and the full current selection, on open and after every swap. Older results are dropped by `signature`. |

## What's missing: the renderer

`TryOnRenderers.current` (in `FitMix/Models/TryOn.swift`) is `nil`, so Studio shows the user's
photo labeled **YOUR PHOTO · NOT A TRY-ON** with "Try-on isn't available yet". To generate the
composite, implement `TryOnRenderer` and assign it at launch:

```swift
struct MyRenderer: TryOnRenderer {
    var producesTryOn: Bool { true }
    func render(_ request: TryOnRequest) async throws -> UIImage { … }
}
// e.g. in MyApp.init: TryOnRenderers.current = MyRenderer()
```

The renderer must:

1. Start from `request.person` every time (never a previous render).
2. Apply only `request.garments`; every other slot keeps what the user is wearing in the photo.
   Each garment has its `category` (the slot), the best garment image (`image`: replacement product
   image, else detected cutout, else crop), `productID` when it's a catalog item, and `sourceBounds`
   in the street capture.
3. Return the user wearing those garments, or throw. Studio shows the thrown error with Try Again.
4. Report `producesTryOn = true` only if the output really shows the clothes on the user; Studio
   labels the image **TRY-ON** only then.

Practical options: an on-device or server virtual try-on model (person image + garment image per
slot → composite, typically one garment per pass, chained across slots), behind a small API the
renderer calls. Garment cutouts from the Camera's segmentation (issue 09) give much better results
than crops. Catalog product images are used for swapped pieces; remote product images (`.remote`
URLs) are currently passed as `image = nil`, so the renderer should download `productID`'s image
itself or the catalog should provide local images.

## Debugging without a renderer

`FM_DEBUG_TRYON_STUB=1` (debug builds) installs `DebugStandInRenderer`: it stamps the requested
garments on the user's photo, reports `producesTryOn = false`, and Studio labels it
**STAND-IN · NOT A TRY-ON**. Use it to check that swaps re-render the full selection.
