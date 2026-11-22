# Demo checkout

Shop This Look → **Add to Cart** → **View Cart** → **Checkout** → **Place Demo Order**. One checkout covers the
whole cart, whatever stores the pieces come from. It is a demo that runs entirely in FitMix: no backend calls,
no store redirects, no Shopify Checkout Kit, no payment details. It works offline (product photos load only when
online; everything else works without a connection).

| Piece | Where |
| --- | --- |
| Cart screen, recent demo orders | `FitMix/Views/Checkout/CartView.swift` |
| Checkout screen, confirmation, shared line and totals views | `FitMix/Views/Checkout/CheckoutView.swift` |
| `DemoOrder`, per-currency totals | `FitMix/Models/DemoOrder.swift` |
| Saving demo orders | `FitMix/Services/DemoOrderStore.swift` |
| Removing the ordered lines from the cart | `CartStore.remove(ids:)` in `FitMix/Services/CartStore.swift` |
| Debug seed and launch switches | `FitMix/Services/DemoCheckoutFixtures.swift`, `FitMix/Services/DebugCheckoutScript.swift` |

## Flow

1. **Checkout** lists every cart line, grouped by store for reading: photo, title, store, size or variant,
   quantity and listed price. Totals are shown per currency (e.g. CAD and USD), never converted or added
   together; pieces without a listed price are counted separately.
2. **Place Demo Order** saves a `DemoOrder` (order number like `FM-261121-6K8Z`, date, and a snapshot of every
   line) to disk **first**. Only after the file is written are exactly those lines removed from the cart; a
   piece added in the meantime stays. If saving fails, nothing changes and the cart is kept. If the order saves
   but the cart can't be updated, the confirmation says so.
3. The screen then shows **Demo order placed** with the number, items and totals. The cart lists recent demo
   orders, and each opens its confirmation again.

## Storage

`Application Support/Accounts/<user-id>/demo-orders.json` when signed in, `Accounts/guest/demo-orders.json` when
signed out, written atomically with complete file protection. Unlike the signed-out cart (memory only), a
guest's demo orders are kept on disk, so the confirmation is still there after a restart. Nothing is sent
anywhere.

## Not in the checkout path any more

The Shopify proof of concept's per-store Checkout Kit sheets, cart permalinks, receipts and the
`checkout-kit` package are removed, and the cart no longer links out to retailers. The Shopify size picker in
Shop This Look (`VariantPickerSheet`, `ShopifyProducts.swift`) is unchanged: it reads a store's public product
data when adding a piece, which needs a connection, but checkout doesn't.

## Debug launch arguments (Debug builds only)

| Variable | What it does |
| --- | --- |
| `FM_DEBUG_CART_SEED=multistore` | Fills the cart with test fixtures from four stores (Kotn and Frank And Oak in CAD, Uniqlo in USD, a test store with no price), each labeled **Test fixture**. |
| `FM_DEBUG_CHECKOUT_PLACE=1` | The cart opens Checkout and Checkout places the demo order, as tapping both buttons does. |
| `FM_DEBUG_SCREEN=cart` | Opens the cart (with the recent demo orders). |
| `FM_DEBUG_CHECKOUT_PICKS=…` | Adds pieces from Shop This Look through the size picker (see `DebugCheckoutScript`). |

## Observed on 21 Nov 2026 (iPhone 17 simulator, iOS 27.2, Debug, signed out)

- Seeded cart: 5 pieces, 4 stores. Checkout showed all four lines; totals CA$129.75 (2 items) and US$49.80
  (2 items), plus "1 item has no listed price".
- **Place Demo Order** saved `FM-261121-6K8Z` to `Accounts/guest/demo-orders.json`, then the cart had 0 lines,
  and **Demo order placed** showed the number, items and totals.
- After terminating and relaunching without any seed, the cart listed "Demo order placed · FM-261121-6K8Z", and
  the file still held all four lines (store, quantity, price, currency). No payment fields exist.
- The only network connection the app had open was to Shopify's image CDN, for product photos.

## Not done yet

- On a real iPhone and in airplane mode.
- Signed in: per-account orders and clearing the saved `cart.json` (the logic is the same; a signed-in run
  wasn't done here).
