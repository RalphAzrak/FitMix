# Cart

Shop This Look (the bag button) → **Add to Cart** on each piece → **View Cart** → **Checkout**. One cart holds
pieces from any number of stores, grouped by store; each store checks out on its own site. See
[Checkout.md](Checkout.md).

| Piece | Where |
| --- | --- |
| Saved line item (`CartItem`, `CartData`) | `FitMix/Models/Cart.swift` |
| `CartStore` (add, quantity, remove, clear, subtotal) | `FitMix/Services/CartStore.swift` |
| Cart screen | `FitMix/Views/Checkout/CartView.swift` |
| Add to Cart buttons, View Cart | `FitMix/Views/Studio/ShoppingReviewView.swift` |
| Bag button with count badge | `FMBagButton` in `FitMix/Views/Theme.swift` |

## Behaviour

- **Sizes.** A product that lists sizes needs one chosen before it can be added (the saved Profile size is
  preselected when it matches). A product that lists none, like most live eBay matches, is added without a
  size and shows "Size not listed".
- **Lines.** The same product in the same size is one line; adding it again raises the quantity (1 to 10).
- **Prices.** Each line stores the listed price and currency at the time it was added. The cart shows an
  estimated subtotal per currency (never converted or added across currencies) and how many pieces have no
  price. Nothing is charged by FitMix: each store's own checkout prices the order.
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
for a listing) and add it from Shop This Look.
