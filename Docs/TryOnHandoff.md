# Try-on handoff

Flows: **Camera (Scan Fits) → tap a garment → Studio Fit → Your Try-On**, and **Camera → Outfit Review →
Try Full Look → Studio Fit**. Both end with a generated photo of the user wearing the scanned outfit.

| Step | Where | What it does |
| --- | --- | --- |
| Live scan → Studio | `AppShell` → `CameraView` select callback | `studio.openLive(selection, tryOnSource: AvatarStore.bodyPhoto)`: the saved try-on photo (Profile → My Try-On Photo). |
| Outfit Review | `FitMix/Views/Studio/OutfitReviewView.swift` | The user picks which detected garments to try (all on by default). **Try Full Look** uses `AvatarStore.bodyPhoto`, or asks for it first with `TryOnPhotoSheet`, then calls `studio.open(scan, selected:, tryOnSource:)`. |
| Studio request | `StudioStore.currentRequest` | One `TryOnRequest` for **every selected piece**. Each garment image is the scanned garment by default: the cutout, the crop, or for live scans the clearest search crop. A retailer match is never needed. A piece the user explicitly **swapped** uses that product's photo (local, cached, or its URL, downloaded by the renderer). The signature covers the photo and every piece, so a result for an older photo or outfit is never shown. |
| When it renders | `StudioStore.refreshPreview()`, `setTryOnVisible(_:)` | Only while **Your Try-On** is on screen. A live look opens on Street Look and renders when the user switches over. Swapping a piece or changing the photo cancels the running render and starts a new one. Wardrobe Try-On renders as soon as it opens. |
| Renderer | `BackendOutfitTryOnRenderer` (`FitMix/Services/OutfitTryOnRenderer.swift`), `TryOnRenderers.current` | Sends the request the Outfit builder uses (`BackendAvatarGenerator.style`). |
| Backend | `POST /v1/avatar-outfit` (`Backend/app/main.py`) | One OpenAI image edit: image 1 is the person, then one image per slot (`tshirt`, `pants`, `shoes`, `outerwear`), with `build_outfit_prompt`. The model, quality and size come from `OPENAI_IMAGE_MODEL`, `OPENAI_IMAGE_QUALITY` and `OPENAI_IMAGE_SIZE`. |
| Preview | `TryOnHero` | **Putting the look on you…** while rendering. The result is labeled **Try-On**. A failure says what went wrong and offers **Try Again**. With no photo it shows **Add Your Photo**, which asks for a full-body photo and continues with the same look. |

`TryOnRenderers.current` is the backend renderer whenever `BackendConfig.current` exists: Debug builds with
`Backend.local.json` (made by `Backend/run.sh`) or `FITMIX_BACKEND_URL`, and Release builds with
`FitMixBackendURL`. Without a backend it's nil, and Studio says try-on isn't available, as before.

### Garment slots

The backend renders one garment per slot. Jacket → `outerwear`; T-shirt or top → `tshirt`; pants, bottoms,
shorts or skirt → `pants`; shoes → `shoes`. If two pieces share a slot, the first one in the look is used.
Bags, hats, accessories and dresses have no slot. A request with nothing renderable shows **Try-on isn't
available yet** instead of trying and failing. That's what Studio's Wardrobe Try-On shows for an
accessory, as it did before.

### Wardrobe

- **Wardrobe → Add to Outfit** (shirts, pants, shoes, outerwear) opens the Outfit builder. It dresses the
  avatar portrait through the same `BackendAvatarGenerator.style` → `/v1/avatar-outfit`. That code is unchanged.
- **Wardrobe → Try On in Studio** (accessories) opens Studio's Wardrobe Try-On with `avatarImage ?? bodyPhoto`.
  It goes through the same renderer.

## Try on my avatar (listing handoff)

On a live garment's card, once a listing is chosen, **Try on my avatar** makes `AvatarStore.avatarImage` the
source and requests that one listing (`AvatarTryOn`). With the backend renderer this is a render too, of the
avatar with that listing's product photo.

## Mix with your wardrobe

Studio's **On your avatar** board (live looks) shows the avatar's four slots head to toe: Jacket, Shirt, Pants,
Shoes. A slot holds the scanned listing (**SCAN**), a wardrobe piece (**YOURS**), or nothing. Tapping a slot
offers the scanned garment for that slot or **Choose from Wardrobe** (`WardrobeMixPicker`).

- `StudioStore.wardrobeMix` holds one `WardrobeMixPiece` per `AvatarOutfitSlot`. `addToMix` / `removeFromMix`.
- The avatar request is the scanned listing (`avatarTryOn`) plus every wardrobe piece in another slot, sent
  together to `/v1/avatar-outfit`. No backend change: the endpoint already takes one image per slot.
- One piece per slot, last choice wins: trying a scanned shirt takes a wardrobe shirt off, and vice versa.
  Only one scanned listing is on the avatar at a time.
- Wardrobe photos load with `tryOnPath` (the cleaned cutout when there is one). Accessories have no slot.
- The mix is cleared when a new look opens and when the account changes.

### Keeping track of the try-on

The preview sits above the garment cards, so every action that dresses the avatar (card, board, wardrobe)
scrolls Studio back to it. While the preview is out of view, `TryOnProgressPill` floats above the footer
(**Dressing your avatar…**, then **Your try-on is ready**) and scrolls up when tapped. A finished render
plays a success haptic and a VoiceOver announcement. The card's button turns into **On your avatar ↑**.

### Garment categories

`GarmentCategoryStyle.swift` gives each family one color and glyph used everywhere in Studio: jacket
(terracotta), shirt (teal), pants (plum, drawn glyph since SF Symbols has none), shoes (ochre). The Scanned
Outfit photo outlines each garment in its color, cards carry a color stripe and badge, and a chip row jumps
to each garment's card. Cobalt stays for selection and actions.

| Variable | What it does |
| --- | --- |
| `FM_DEBUG_WARDROBE_MIX=/path.png` | Puts that image on the avatar as a wardrobe piece after a look opens (`FM_DEBUG_WARDROBE_MIX_CATEGORY`, default `pants`; `FM_DEBUG_WARDROBE_MIX_DELAY`, default 4 s). |
| `FM_DEBUG_STUDIO_NO_AUTOSCROLL=1` | Leaves the page where it is when something goes on the avatar, to check the progress pill. |

## Privacy

The try-on photo leaves the phone only when a render runs, to the FitMix backend, which passes it to OpenAI and
keeps nothing. Profile → Privacy & Data says so.

## Debugging without OpenAI

| Variable | What it does |
| --- | --- |
| `FM_DEBUG_TRYON_STUB=1` | `DebugStandInRenderer`: returns the try-on photo stamped **DEBUG STAND-IN · NOT A TRY-ON** with each garment's id, and the garment images it received along the bottom. It reports `producesTryOn = false`, so Studio labels it **Stand-in · Not a Try-On**. |
| `FM_DEBUG_TRYON_STUB_DELAY=<s>` | Makes the stand-in slower, to change the outfit or photo while a render runs. |
| `FM_DEBUG_SCREEN=wardrobe-tryon` | Opens Studio's Wardrobe Try-On on `FM_DEBUG_WARDROBE_GARMENT` (`FM_DEBUG_WARDROBE_CATEGORY`, default `accessory`). Needs `FM_DEBUG_ACCOUNT_ID`. |

Each render logs `Try-on render: …` (category `TryOn`, subsystem `app.fitmix`) with the person size and each
garment's source: `scanned` or the product id, with the image size, `url`, or `no-image`. Debug builds also
print `[tryon] …` lines.

UI tests: `FitMixUITests/ScanTryOnUITests.swift`. They take their photos from `TEST_RUNNER_FM_TRYON_PERSON`,
`TEST_RUNNER_FM_TRYON_SCAN`, `TEST_RUNNER_FM_TRYON_REPLAY` and `TEST_RUNNER_FM_TRYON_GARMENT`, and skip when
those aren't set. The no-photo test also needs a photo in the simulator's library (`xcrun simctl addmedia`).
