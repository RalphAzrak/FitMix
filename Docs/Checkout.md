# Checkout across stores

Studio Fit → Shop This Look → **Add to Cart** (a Shopify listing first opens the size picker) → **View Cart** →
**Checkout**. One FitMix cart can hold pieces from any number of stores. Each store is checked out on its own
secure site; there is no single payment across stores, and FitMix never takes or stores payment details.

| Piece | Where |
| --- | --- |
| Cart line: store, title, photo, listed price and currency, link, size, colour, variant | `FitMix/Models/Cart.swift` |
| Groups by store, estimated subtotals per currency, visits, clear-only-what-a-store-sold | `FitMix/Services/CartStore.swift` |
| Link checks, per-store checkout plan, receipts, log (no Shopify code) | `FitMix/Services/StoreCheckout.swift` |
| Shopify only: cart permalink, Checkout Kit completion → receipt | `FitMix/Services/ShopifyCartCheckout.swift` |
| Cart screen | `FitMix/Views/Checkout/CartView.swift` |
| Checkout screen | `FitMix/Views/Checkout/CheckoutView.swift` |
| Store pages in Safari View, hand-off to Safari | `FitMix/Views/Checkout/RetailerBrowser.swift` |
| Checkout Kit sheet for a prefilled Shopify cart | `FitMix/Views/Checkout/ShopifyCheckoutSheet.swift` |
| Shopify size/colour picker; not-Shopify fallback | `FitMix/Views/Checkout/VariantPickerSheet.swift`, `FitMix/Services/ShopifyProducts.swift` |
| Debug fixtures and launch script | `FitMix/Services/CheckoutFixtures.swift`, `FitMix/Services/DebugCheckoutScript.swift` |

## What gets saved

Add to Cart saves the listing the piece shows at that moment (`WorkingLook.Piece.product`): a confirmed swap,
else the listing the shopper picked from Studio's ranked list (`StudioStore.chooseListing`), else the best match.
The line keeps the title, store name, product photo URL, listed price and currency, the product URL, and size,
colour, variant ID and variant title when known. Cart files are `CartData` version 2; every field added since
version 1 is optional, so carts saved earlier still load.

## Cart

Lines are grouped by store: the listing's web host without `www.` (Google Lens `goto` links are unwrapped), else
the retailer name. Each row shows photo, title, store, price, selected variant (or "Size not listed · choose it at
the store"), quantity and remove. Subtotals are per currency and labeled **estimated**; different currencies are
never added or converted. Each retailer confirms the final price, availability, shipping and taxes.

## Checkout: one card per store

- **Prefilled cart**: only when FitMix has a verified way to put the exact variants and quantities in the store's
  cart. Today that is Shopify's cart permalink, `https://<store>/cart/<variant>:<qty>,…`, with numeric variant IDs
  read from the store's own `/products/<handle>.js`. **Checkout at [store]** opens it in Shopify Checkout Kit.
- **Open each item**: every other store. **Open at [store]** opens that piece's product page in Safari View, and
  the card says to add it there in the size and quantity shown, then check out on the store's site.
- **Unusable link**: no link, a link that isn't a web page, or a non-https link. That piece's button is disabled
  with the reason; the store's other pieces and other stores stay usable.

Done (Safari View) or closing checkout returns to Checkout to continue with the next store. A page that doesn't
load in Safari View offers **Open in Safari**; a prefilled cart whose checkout fails inside FitMix offers **Open
cart in Safari** with the same permalink.

**Nothing is marked purchased unless a store confirms it.** Opening, returning or cancelling leaves the cart as it
was, and the card says "Opened at …; FitMix hasn't received an order confirmation". Only Checkout Kit's completion
event removes lines, and only the variants and quantities that store sold. Pages opened in Safari View report
nothing back, so those pieces stay until the shopper removes them.

A Shopify-style link (`/products/<handle>`) on a store that isn't Shopify (Uniqlo, for one) can still be added: the
picker finds no Shopify product data and offers **Add to Cart** without a size. If the store's data can't be
loaded at all, **Add Without a Size** does the same. Only https links go to the picker.

## Debug launch arguments (Debug builds only)

| Variable | What it does |
| --- | --- |
| `FM_DEBUG_CHECKOUT_FIXTURE=1` | Studio Fit's search returns `CheckoutFixtureSearch`: T-shirt = Kotn tee (Shopify, CAD) then Uniqlo AIRism tee (not Shopify, USD); pants = Frank And Oak chino (Shopify, CAD); shoes = test listing with no link (CAD); jacket = test listing with an `http://` link (USD). The three real listings were hand-picked on 21 Nov 2026. |
| `FM_DEBUG_CHECKOUT_CHOOSE=tshirt:uniqlo-us-E465185-000` | Picks that listing from the piece's ranked list, as tapping it in Studio does. |
| `FM_DEBUG_CHECKOUT_PICKS=tshirt=*1;pants=Size:32X32*2;shoes=*1;jacket=*1` | Adds each piece from Shop This Look: via the picker for Shopify-style links, else plain Add to Cart. |
| `FM_DEBUG_CHECKOUT_OPEN=frankandoak.com,uniqlo.com` | Opens Checkout, then each store in turn (prefilled cart, else its first item with a link). |
| `FM_DEBUG_CHECKOUT_CLOSE_AFTER=20` | Closes each store after 20 s, like Done or closing checkout. |
| `FM_DEBUG_CHECKOUT_SIMULATE_COMPLETE=1` | **Simulated**: feeds a completion event built from what FitMix sent, to test cart clearing. No order exists; the receipt says "Simulated · no order". |
| `FM_DEBUG_CHECKOUT_PREFILL=montreal` | Pre-fills a public Montréal address and a reserved `example.com` email in the Shopify permalink. |
| `FM_DEBUG_MATCH_FIXTURE=shopify` | The earlier proof of concept's two Shopify listings (Kotn, Frank And Oak). |

With `FM_DEBUG_SCREEN=live-sample-tshirt` these run the whole flow without a camera. Every step is logged as
`[checkout] …`.

## Observed on 21 Nov 2026 (iPhone 17 simulator, iOS 27.2, Debug)

Fixture run: Uniqlo chosen as the alternative (rank 2 of 2), then pants Size 32X32 × 2, shoes and jacket.

| Store | Checkout | What happened |
| --- | --- | --- |
| Frank And Oak (Shopify) | Prefilled cart `https://www.frankandoak.com/cart/47362189885618:2` | Checkout Kit `start`/`update`: variant 47362189885618 × 2, CAD. Closed after 20 s: all 4 lines kept. |
| Uniqlo (not Shopify) | Product page `https://www.uniqlo.com/us/en/products/E465185-000/00` | Its `/products/….js` isn't Shopify data, so it was added without a size. Safari View loaded the page (`ok=true`, the AIRism Oversized T-Shirt). Done: all 4 lines kept. |
| FitMix Test Store | No link | Button disabled with the reason. |
| FitMix Test Outlet | `http://` link | Button disabled with the reason. |

Cart: 5 pieces from 4 stores, estimated US$84.90 and CA$283.50 shown separately. No order was placed and no
payment details were entered.

## Not done yet

- **iPhone**: Checkout Kit, Safari View, Apple Pay / Shop Pay hand-offs and returning to FitMix from a wallet or
  bank app need a real device.
- **A test order** (the only way to see a real completion event) needs a Shopify development store with a test
  gateway.
- **Other prefilled carts**: no verified cart link is used for any store that isn't Shopify. eBay, Amazon and
  others open product pages.
- **Colour for non-Shopify listings**: Studio's listings carry no colour, so those lines have none until a store
  supplies one.
