# FitMix

Built for McGill CodeJam 16.

FitMix is a SwiftUI iPhone app for recreating outfits you spot in real life. The idea is to capture a look, pick out the clothes you like, and see the full outfit on a photo of yourself before deciding what to shop for.

## What runs today

| Where | What you can try |
| --- | --- |
| `main` | Create a 3D preview in **My Avatar** using your measurements and photos, with a face scan on a compatible iPhone. Open **Account** to sign up, sign in, or reset your password using Supabase Auth. Avatar captures are stored on the device. |
| [`studio-fit`](https://github.com/RalphAzrak/FitMix/tree/studio-fit) | Open an outfit in **Studio**, inspect individual garments, swap in sample catalog items, and review sizes and retailer links. The branch uses sample scans to demonstrate the Camera → Studio handoff. |

## The outfit flow we're building

1. **Scan a look.** Capture a person wearing an outfit you want to recreate.
2. **Isolate a garment.** Tap a piece in Studio to inspect it on a contrasting background, then browse similar items and choose which ones to keep.
3. **Try the full look.** Take a photo of yourself and preview all selected garments together on that photo. The scanned outfit is the reference in Studio, and your own photo is the canvas for the try-on.

Live garment detection, automated product matching, and photo-based virtual try-on are planned. The Studio prototype links to retailers for shopping.

## Run locally

1. Clone this repository and open [`FitMix.xcodeproj`](FitMix.xcodeproj) in Xcode. On `main`, the project sets the iOS deployment target to **27.2**, so use an Xcode installation and run destination that support it.
2. Let Xcode resolve the Swift packages, select an iPhone simulator, and press **⌘R**. The app opens on **My Avatar**. To test camera capture or face scanning, select a physical iPhone, configure signing if prompted, and grant camera access. Face scanning requires a TrueDepth camera.
3. To test email authentication, open **Account** from **My Avatar**. The app already includes the project's Supabase client configuration. If you use your own Supabase project, update `SupabaseConfig` in [`AuthSession.swift`](FitMix/Services/AuthSession.swift) and allow `fitmix://reset-password` in the project's auth redirect settings.

### Preview Studio with a sample scan

On `studio-fit`, open **Product → Scheme → Edit Scheme → Run → Arguments** in Xcode. Add `FM_DEBUG_SAMPLE_SCANS` with value `1` under **Environment Variables** and run the Debug build. From **My Avatar**, choose **Open Camera to Scan Fits**, then **Finish with Sample Scan A** or **Finish with Sample Scan B**.
