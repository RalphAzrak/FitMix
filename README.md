# FitMix

Built for McGill CodeJam 16.

FitMix is a SwiftUI iPhone app for recreating outfits you spot in real life. Capture a look, pick out the pieces you like, and preview the full outfit on a photo of yourself before deciding what to shop for.

## What works today

| Branch | What you can try |
| --- | --- |
| `main` | Create an AI-generated full-body portrait in **My Avatar** from your photo, height and weight, then build a 3D model of it that you can turn (the backend builds it on your Mac, see `Backend/README.md`). Open **Account** to sign up, sign in, or reset your password with Supabase Auth. Avatar captures stay on your device. |
| [`studio-fit`](https://github.com/RalphAzrak/FitMix/tree/studio-fit) | Open a sample outfit in **Studio**, inspect individual garments, swap in sample catalog items, and review sizes and retailer links. Sample scans demonstrate how an outfit goes from Camera to Studio. |

## The outfit flow we're building

1. **Scan a look.** Use the camera to capture an outfit you want to recreate.
2. **Isolate a garment.** Tap a piece in Studio to see it against a contrasting background, browse similar items, and choose what to keep.
3. **Try the full look.** Take a photo of yourself and see all selected garments together on that photo. Studio keeps the original outfit visible as a reference.

**Live garment match** (branch `feature/live-garment-retailer-match`): point the Camera at an outfit and tap the jacket, T-shirt, pants or shoes. There's no shutter. Studio opens on that frame and finds a similar retailer listing for that one garment, showing its photo, price and a link. Detection runs on the iPhone; only the selected garment's crop is sent for search. Retailer search needs eBay API keys on the backend ([setup](Backend/README.md#retailer-search-setup)). Details are in [Docs/LiveGarmentMatch.md](Docs/LiveGarmentMatch.md). Photo-based try-on is still planned.

## Run locally

1. Clone this repository and open [`FitMix.xcodeproj`](FitMix.xcodeproj) in Xcode. The project on `main` targets iOS **27.2**. Use an Xcode version and run destination that support it.
2. Let Xcode resolve the Swift packages, select an iPhone simulator, and press **⌘R**. The app opens on **My Avatar**.
3. For camera capture, run on a physical iPhone, configure signing if prompted, and grant camera access.
4. To test email authentication, open **Account**. The app includes the team's Supabase client configuration. To use a different Supabase project, update `SupabaseConfig` in [`AuthSession.swift`](FitMix/Services/AuthSession.swift) and add `fitmix://confirm-email`, `fitmix://reset-password` and `fitmix://email-change` to the project's allowed auth redirect URLs. See [Docs/EmailConfirmation.md](Docs/EmailConfirmation.md) for the dashboard settings and how to test confirmation links.

### Preview Studio with a sample scan

On `studio-fit`, open **Product → Scheme → Edit Scheme → Run → Arguments** in Xcode. Under **Environment Variables**, add `FM_DEBUG_SAMPLE_SCANS` with the value `1` and run the Debug build. From **My Avatar**, choose **Open Camera to Scan Fits**, then select **Finish with Sample Scan A** or **Finish with Sample Scan B**.
