# Cart

Shop This Look (the bag button) → **Add to Cart** on each piece → **View Cart** at the bottom of Shop This
Look. **Choose Size & Add** opens FitMix's own size page (`SizePickerSheet`) for every piece: the sizes are
FitMix's, never loaded from the retailer, so the page opens for any store. The cart is
grouped by store. In demo builds **Checkout** goes through Order Review, Demo Payment and Order Summary for the
whole cart inside FitMix; outside demo mode each Shopify store has its own checkout. See [Checkout.md](Checkout.md).

| Piece | Where |
| --- | --- |
| Saved line item (`CartItem`, `CartData`) | `FitMix/Models/Cart.swift` |
| `CartStore` (add, quantity, remove, clear, totals per currency) | `FitMix/Services/CartStore.swift` |
| Cart screen | `FitMix/Views/Checkout/CartView.swift` |
| Add to Cart buttons, View Cart | `FitMix/Views/Studio/ShoppingReviewView.swift` |
| Bag button with count badge | `FMBagButton` in `FitMix/Views/Theme.swift` |

## Behaviour

- **Sizes.** FitMix offers its own sizes by kind of garment: letter sizes for tops and jackets, waist sizes
  for bottoms (or the system saved in Profile), shoe sizes in the saved system (US Men's by default), and
  One Size for accessories. The saved Profile size is preselected. A size must be chosen before adding. The
  page says these are FitMix sizes and to check the retailer's own chart.
- **Lines.** The same product in the same size is one line; adding it again raises the quantity (1 to 10).
- **Prices.** Each line stores the listed price and currency at the time it was added. The cart shows one total
  per currency (never converted or added across currencies) and how many pieces have no price. Nothing is
  charged: checkout is a demo.
- **Fixtures.** Test-fixture listings are labeled **Test fixture** in the cart.

## Storage

Signed in: `Application Support/Accounts/<supabase-user-id>/cart.json` with complete file protection, next
to `profile.json`. Signed out: memory only. Items added while signed out move into the account's cart on
sign-in, and signing out clears the cart from memory. An unreadable file is never overwritten. The Cart
screen offers **Clear Cart**, which deletes it. Sample-catalog photos aren't saved, so after a relaunch
those items show the category symbol.

## Debug

`FM_DEBUG_SCREEN=cart` opens the Cart, and `FM_DEBUG_SCREEN=shop` opens Shop This Look. To fill the cart
without a camera, open a sample look (`FM_DEBUG_SCREEN=live-sample-jacket`, with `FM_DEBUG_MATCH_FIXTURE=match`
for a listing) and add it from Shop This Look. `FM_DEBUG_MATCH_FIXTURE=mixed` matches the sample's T-shirt to a
real Uniqlo listing (not on Shopify) and its pants to a real Frank And Oak listing (Shopify), so one cart holds
both kinds.
