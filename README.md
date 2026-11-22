# FitMix

**Scan an outfit. Try it on. Shop the pieces you want.**

Built for **McGill CodeJam 16**, FitMix is a SwiftUI iPhone app for recreating outfits you spot in real life. Point the camera at a look, find similar pieces from different retailers, and see how they look on you alongside clothes you already own.

Recreating an outfit usually means guessing search terms, opening a tab for every store, and deciding whether new pieces will go with what’s already in your closet. FitMix brings discovery, styling, and shopping into one flow so you can decide what’s worth buying.

## The CodeJam demo

1. **Scan an outfit.** Open **Scan Fits**, point the camera at a look, and tap a detected garment to open **Studio Fit**. The scanner recognizes outerwear, tops, bottoms, and shoes. Manual selection lets you crop a piece when the live scan misses it.
2. **Find similar pieces.** Studio shows retailer photos, store names, listed prices, and links. Compare alternatives or refine the search with a tighter crop or a brand. The outfit budget uses CAD prices. Matches are based on visual similarity, so a listing can be a close match without being the original item.
3. **See the look on yourself.** Switch from **Street Look** to **Your Try-On** to preview selected garments on your full-body photo. Try on the pieces from the scan or swap in a retailer listing. To style your generated avatar, choose **Try on my avatar** on a listing, then use **Add from Wardrobe** to mix it with your own clothes.
4. **Shop the look.** Choose sizes and add selected pieces to one cart, even when they come from different retailers. The demo takes you through **Order Review → Demo Payment → Order Summary**. It simulates payment locally without charging a card or placing retailer orders. The summary includes an order number and stays available in **Order History** after the app relaunches.

## Your avatar, wardrobe, and saved looks

- **My Avatar** generates a full-body portrait from your photo, height, and weight, with an optional selfie for facial detail. An optional Apple-silicon Mac setup creates a rotatable 3D avatar from the portrait.
- **Wardrobe** lets signed-in users photograph, crop, categorize, and save clothing they already own. Build an outfit from your wardrobe, or mix its pieces with a retailer find. Avatar outfits support one piece per slot for outerwear, top, bottoms, and shoes.
- **Saved Looks** keeps styled previews on this iPhone for later. **Profile** lets you manage your try-on photo, preferred sizes, and shipping addresses. Account sign-in and password reset use Supabase Auth.

## How it works

| Component | What it does |
| --- | --- |
| **SwiftUI, AVFoundation, Apple Vision, and Core ML** | The iPhone runs live garment detection and produces garment crops and text hints for search. Wardrobe photo cleanup also runs on-device. |
| **Python and FastAPI** | The backend uses OpenAI to describe garment crops, search for product listings, and compare verified listing photos with the crop. It also uses image editing to generate portraits and try-on previews. |
| **Supabase** | Auth handles accounts. Postgres and private Storage hold wardrobe items and photos with per-user access policies. |
| **TRELLIS.2 and USDZ** | The optional Mac pipeline builds a textured 3D model that can be rotated in the app. |
| **Checkout** | Debug uses a local, multi-retailer demo checkout. Release uses Shopify Checkout Kit for eligible Shopify variants, one store at a time. |

The full scan frame stays on the phone during retailer search. The backend and OpenAI process the garment crop for matching and the relevant photo or avatar and garment references for image generation. Try-on is a generated styling preview. Retailer sizing and availability depend on the listing.

## Run locally

1. Clone this repository on a Mac and open [FitMix.xcodeproj](FitMix.xcodeproj). Use an Xcode version and run destination that support the project’s **iOS 27.2** target.
2. For live search and generated images, start the backend from the repository root. Add your OpenAI API key to the ignored `Backend/.env` after copying the template.

   ```sh
   cd Backend
   cp -n .env.example .env
   # Set OPENAI_API_KEY in .env before starting the server.
   ./run.sh
   ```

3. Build and run the **FitMix** scheme in Debug. The backend script writes the local connection settings before you build. Use a physical iPhone for the live scanner, configure signing if prompted, connect it to the same Wi-Fi as the Mac, and allow camera and local network access.
4. The shared Debug scheme opens sign-in. To start on Home instead, turn off `FM_DEBUG_SCREEN` under **Product → Scheme → Edit Scheme → Run → Arguments**. If you use your own Supabase project, update [`SupabaseConfig`](FitMix/Services/AuthSession.swift), configure the [auth redirects](Docs/EmailConfirmation.md), and apply the [wardrobe migrations](supabase/migrations).

### Try it in the simulator

Under the Run scheme’s **Environment Variables**, set `FM_DEBUG_SAMPLE_SCANS=1` and `FM_DEBUG_MATCH_FIXTURE=mixed`. From Home, open **Scan Outfit** and choose **Finish with Sample Scan A** or **Finish with Sample Scan B**. Set `FM_DEBUG_TRYON_STUB=1` for a stand-in try-on without calling OpenAI. For placeholder avatar generation, start the backend with `FITMIX_MOCK=1 ./run.sh` from `Backend`.

To go straight to demo checkout, set `FM_DEBUG_SCREEN=cart` and `FM_DEBUG_CART_SEED=twostores` in the same scheme settings. The seed replaces the active cart with sample items.

## Project docs

- [Backend setup, endpoints, photo handling, and optional 3D setup](Backend/README.md)
- [Live camera and sample scans](Docs/CameraHandoff.md)
- [Photo try-on and wardrobe mixing](Docs/TryOnHandoff.md)
- [Cart, demo payment, Shopify checkout, and UI tests](Docs/Checkout.md)
