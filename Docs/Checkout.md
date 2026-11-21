# In-app retailer checkout (proof of concept)

Studio Fit listing → Shop This Look → **Choose Size & Add** (the exact store variant) → **View Cart** →
**Checkout at <store>**. Each Shopify store's own checkout opens in a sheet inside FitMix (Shopify Checkout
Kit). The cart is grouped by store, and every store checks out separately.

| Piece | Where |
| --- | --- |
| Listing URL → store + product handle, variants from `/products/<handle>.js` | `FitMix/Services/ShopifyProducts.swift` |
| Size / colour / quantity picker | `FitMix/Views/Checkout/VariantPickerSheet.swift` |
| Exact variant on a cart line (`ShopifyLine`) | `FitMix/Models/Cart.swift` |
| Retailer groups, clear-only-what-this-store-sold | `FitMix/Services/CartStore.swift` |
| Cart permalink, completion → receipt, lifecycle log | `FitMix/Services/RetailerCheckout.swift` |
| Per-store checkout button and Checkout Kit sheet | `FitMix/Views/Checkout/CartView.swift` |
| Launch-argument script for the simulator | `FitMix/Services/DebugCheckoutScript.swift` |

Package: [Shopify/checkout-kit](https://github.com/Shopify/checkout-kit) 4.2.0, products `ShopifyCheckoutKit`
and `EmbeddedCheckoutProtocol` (the v4 SDK; the older `checkout-sheet-kit-swift` v3 is in maintenance until
May 2027).

## How it works

1. **Is it Shopify?** `ShopifyProductLink` reads `https://<store>/…/products/<handle>[?variant=<id>]` from the
   listing (Google Lens `google.com/goto?url=` links are unwrapped). `ShopifyProducts.load` fetches
   `https://<store>/products/<handle>.js`, which every Shopify online store serves publicly. Anything that
   isn't that JSON is treated as "not Shopify" and keeps **View at retailer**.
2. **Exact variant.** The picker offers only option values that a real variant has, crosses out sold-out
   ones, and resolves one numeric variant ID. Two real cases:
   - **Kotn** lists `Color`, `Colour` and `Size`, and its option lists include colours this product doesn't
     have (each colour is a separate product). Only Black exists here, so colour is fixed and the shopper
     picks Size.
   - **Frank And Oak** has only `Size`; each colour is its own product (`YGroup_…` tag). The listing's URL
     fixes the colour, and the cart says "Colour as pictured".
3. **Cart.** A Shopify line stores the store domain, handle, numeric variant ID, the store's variant title
   and every option. Lines group by store domain.
4. **Checkout.** `https://<store>/cart/<variant>:<qty>,<variant>:<qty>` (Shopify's cart permalink; no
   Storefront API token) is opened with `ShopifyCheckout(checkout:)` in a sheet.
5. **Outcome.**
   - Closed without buying (close button, swipe down, or the app closing it): the cart is unchanged and
     says so.
   - `onComplete`: FitMix reads the order ID/label and line items from the event, removes exactly those
     variants and quantities from **that store's** lines, and shows a receipt. Other stores' lines stay. If
     the event's line items don't match what was sent, it falls back to what FitMix sent for that store.
   - `onFail`: the cart is unchanged and the error is shown.

The prices shown in FitMix are the listing's; each store's checkout prices the order, tax and shipping.

## Debug launch arguments (Debug builds only)

| Variable | What it does |
| --- | --- |
| `FM_DEBUG_MATCH_FIXTURE=shopify` | Studio Fit's search returns **two hand-picked real listings**: Kotn's Women's Shrunken Tee in Black for the T-shirt, Frank And Oak's Essential Slim Chino Pant for the pants. Everything after the search is the real path. |
| `FM_DEBUG_CHECKOUT_PICKS=tshirt=Size:M*1;pants=Size:32X32*2` | Selects each garment in Studio, waits for its match, opens Shop This Look, and adds each through the variant picker. |
| `FM_DEBUG_CHECKOUT_OPEN=kotn.com` | The cart then opens that store's checkout. |
| `FM_DEBUG_CHECKOUT_CLOSE_AFTER=40` | Closes that checkout after 40 s without buying. |
| `FM_DEBUG_CHECKOUT_SIMULATE_COMPLETE=1` | **Simulated**: no order exists. Feeds a completion event built from the lines FitMix sent through the real completion handler, to check cart clearing only. The receipt says "simulated". |
| `FM_DEBUG_CHECKOUT_PREFILL=montreal` | Pre-fills Montréal City Hall (275 Rue Notre-Dame Est, H2Y 1C6) and `fitmix-checkout-test@example.com` (a reserved, undeliverable domain). Never the user's details. |

With `FM_DEBUG_SCREEN=live-sample-tshirt`, these run the whole flow without a camera. Every checkout event is
printed as `[checkout] …` and saved as JSON in the app's `Documents/checkout-events/`.

## Observed on 21 Nov 2026 (iPhone 17 simulator, iOS 27.2)

| Store | Variant sent | What checkout reported (Checkout Kit `start`/`update` events) |
| --- | --- | --- |
| Kotn (`kotn.com`) | `53281327513968` (Black / M) × 1 | Same variant × 1, CAD 48.00. With the Montréal test address: "Ground (Up to 7 Business Days)" $8.00, tax $8.39 (Québec GST + QST rate). Needs a phone number to continue. |
| Frank And Oak (`www.frankandoak.com`) | `47362189885618` (32X32) × 2, and × 4 in a later run | Same variant and quantity, CAD 81.75 each. With the Montréal test address: "Free standard delivery" $0, tax $48.97 on $327.00 (Québec GST + QST rate). Needs a phone number to continue. |

- Both `/cart/<variant>:<qty>` permalinks worked on the stores' own domains, without any token.
- Closing a checkout without buying kept the cart exactly as it was.
- A **simulated** completion for Kotn removed only Kotn's line; Frank And Oak's stayed.
- No order was placed and no payment details were entered. Both are live stores.

## Not done yet

- **A real Studio Fit result** needs eBay keys or the approved Scrappa setup on the backend. The hand-picked
  listings stand in for that.
- **A test order** needs a Shopify development store (free, from a Shopify Partner account) with the
  Bogus Gateway or Shopify Payments test mode on, and a product. Point `FM_DEBUG_MATCH_FIXTURE=shopify`
  listings (or a real listing) at that store, check out with card `1`, and confirm the order in its admin.
- **Order details on completion**: buyer details are redacted unless the merchant grants
  `read_checkout_kit_enhanced_buyer_events`.
- **Wallets**: Apple Pay inside checkout needs an Apple Pay-capable device; Shop Pay and bank or wallet apps
  can leave FitMix (see the report for what was observed).
