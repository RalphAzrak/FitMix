# Try-on handoff

Flow: **Camera → Outfit Review → Try Full Look → Studio**.

| Step | Where | What it does today |
| --- | --- | --- |
| Camera confirms a scan | `HomeView` `CameraView(confirm:)` | `studio.review(scan)`, opens Outfit Review. Studio's current look is unchanged. |
| Outfit Review | `FitMix/Views/Studio/OutfitReviewView.swift` | User picks which detected garments to try (all on by default). |
| Try Full Look | same file, `tryFullLook()` | Uses `AvatarStore.bodyPhoto` if saved; otherwise `TryOnPhotoSheet` asks for one (camera or Photos, on-device full-body check, saved with `saveBodyPhoto`). Then `studio.open(scan, selected:, tryOnSource:)`. |
| Studio preview | `StudioStore.refreshPreview()`, `TryOnHero` | Builds a `TryOnRequest` from the **original** photo and the full current selection, on open and after every swap. Older results are dropped by `signature`. |

## Try on my avatar (listing handoff)

On a live garment's card, once a listing is chosen, **Try on my avatar** calls
`StudioStore.tryOnAvatar(pieceID:avatar:)` with `AvatarStore.avatarImage`, the full-body portrait from My Avatar.
It records an `AvatarTryOn` (listing ID, category, product name, product image URL and the listing photo), makes the
avatar the try-on source, and builds a `TryOnRequest` with exactly one garment:
`TryOnGarment(category:, productID: <listing ID>, image: <listing photo>, productImageURL:)`. Nothing from the
street capture is applied. Studio switches to **Your Try-On**, shows the avatar labeled
**YOUR AVATAR · NOT A TRY-ON** with the listing's photo and name, and says try-on can't be generated yet. With no
avatar, Studio asks the user to create one in My Avatar first. Choosing a different listing clears the handoff.

Verified in the simulator with `FM_DEBUG_TRYON_STUB=1`: the stand-in renderer received the avatar and stamped
"Shoes: <listing ID>" on it.

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

### Generation work that remains

1. **A try-on model.** Its inputs are a person image (the avatar portrait) and a garment product image; its output is
   the person wearing that garment, with everything else unchanged. Options include a hosted VTON model, or an
   image-edit model given both images. Either belongs behind the FitMix backend, like `/v1/avatar`, so its keys stay
   server-side.
2. **A backend endpoint**, e.g. `POST /v1/try-on`, taking the avatar image, the category and the listing's product
   image (or its URL, fetched server-side through the same public-host check as listing pages), and returning a PNG.
   It should be rate limited, and should log and store nothing, like `/v1/avatar`.
3. **A `TryOnRenderer`** that calls it, reports `producesTryOn = true` only for real try-ons, and is assigned in
   `TryOnRenderers.current` at launch.
4. **Consent copy.** The avatar (derived from the user's photos) would go to the try-on provider. That is separate from
   product search, which never receives it.

## Debugging without a renderer

`FM_DEBUG_TRYON_STUB=1` (debug builds) installs `DebugStandInRenderer`: it stamps the requested
garments on the user's photo, reports `producesTryOn = false`, and Studio labels it
**STAND-IN · NOT A TRY-ON**. Use it to check that swaps re-render the full selection.
