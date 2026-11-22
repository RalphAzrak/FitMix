# Demo checkout

Home → **Scan Fits** → Studio Fit → **Shop This Look** → **Add to Cart** → **Cart** → **Checkout** → **Payment** →
**Order Summary**. One checkout covers the whole cart, whatever stores the pieces come from.

It is a demo that runs entirely in FitMix. It never collects card details, charges money, calls Shopify or a
payment provider, contacts a store or places a retailer order, and it works offline (product photos load only
when online).

| Piece | Where |
| --- | --- |
| Flow container, routes, Checkout, Payment, Order Summary, shared line and totals views | `FitMix/Views/Checkout/CheckoutView.swift` |
| Cart (the flow's first page), recent demo orders | `FitMix/Views/Checkout/CartView.swift` |
| Opening the flow (bag icon, "View Cart") | `AppRouter.openCart` in `FitMix/Views/Shell/AppShell.swift` |
| `DemoOrder`, per-currency totals | `FitMix/Models/DemoOrder.swift` |
| Saving demo orders | `FitMix/Services/DemoOrderStore.swift` |
| UI tests | `FitMixUITests/DemoCheckoutUITests.swift` |

## Navigation

The flow is one full-screen cover (`CheckoutFlowView`) holding a `NavigationStack`: **Cart** is the root, and
**Checkout**, **Payment** and **Order Summary** are pushed onto it (`CheckoutRoute`), never shown as sheets.

- The bag icon (Home, Studio, Camera) and **View Cart** in Shop This Look open the same flow. Shop This Look is
  a sheet, so **View Cart** closes it first and the cart opens once it's gone (`AppRouter.openCart` /
  `shopLookDismissed`). Done on the cart closes the flow.
- Back works normally on Checkout and Payment. While Payment is saving, Back is hidden.
- After payment the stack is **replaced** by Order Summary: no Back button, the edge swipe does nothing, and
  **Done** closes the flow. There is no way back to a payable screen.
- Size selection in Shop This Look is unchanged: a menu, or the Shopify variant picker sheet.

## Steps

1. **Cart**: lines grouped by store, with quantity controls, one **Checkout** button for every store together,
   and the recent demo orders.
2. **Checkout**: every line grouped by store, with photo, size or variant, quantity and price. Totals are shown
   per currency (CAD, USD…), never converted or added together. A piece without a listed price shows **Price
   unavailable** and is listed as "Not in any total", never counted as zero. **Continue to Payment**.
3. **Payment**: **Demo mode**, the preset **Demo card •••• 4242** (a label, nothing to type), the totals, and
   **Simulate Payment**. The button is disabled while saving. Each visit to Payment has a checkout ID: saving
   again with the same ID returns the order already saved, so repeated taps can't create duplicates.
4. Simulate Payment approves locally, then saves one `DemoOrder` (number like `FM-261122-932C`, timestamp, a
   snapshot of every line, totals per currency, the count of unpriced pieces, the checkout ID) to disk
   **first**. Only after the file is written are exactly those lines removed from the cart. If saving fails,
   the cart is unchanged and the alert offers **Try Again**.
5. **Order Summary**: **Demo order placed**, the number, time, items grouped by store and totals. The same page
   opens from "Demo orders" in the cart, also after a relaunch (there, Back returns to the cart).

## Storage

`Application Support/Accounts/<user-id>/demo-orders.json` when signed in, `Accounts/guest/demo-orders.json` when
signed out, written atomically with complete file protection. Orders saved before totals were stored are
still read; their totals are recomputed from the items.

## Debug launch arguments (Debug builds only)

| Variable | What it does |
| --- | --- |
| `FM_DEBUG_CART_SEED=twostores` | Replaces the cart with two test fixtures: Kotn (CAD) and Uniqlo (USD, quantity 2). |
| `FM_DEBUG_CART_SEED=multistore` | Replaces the cart with four stores in two currencies, including one piece without a price. |
| `FM_DEBUG_CART_SEED=empty` | Empties the cart at launch. |
| `FM_DEBUG_CHECKOUT_PLACE=1` | Taps Checkout, Continue to Payment, then Simulate Payment three times in a row. |
| `FM_DEBUG_ORDER_SAVE_FAIL=1` | The first demo-order save fails, to check the cart stays intact and Try Again works. |
| `FM_DEBUG_OPEN_ORDER=latest` | Opens the newest saved demo order's summary at launch. |
| `FM_DEBUG_SCREEN=cart` | Opens the checkout flow at the cart. |

Seeded pieces are labeled **Test fixture**. Seeding replaces the cart of whichever account is active.

## Tests (FitMixUITests, run with ⌘U on the FitMix scheme)

- `testBagIconOpensFullPageCartAndBackWorksBeforePayment`: the bag icon opens the cart over the tab bar; Back
  from Checkout and from Payment; Done closes the flow.
- `testViewCartFromShopThisLookLeavesTheSheet`: Studio sample look → Shop This Look → choose a size → Add to
  Cart → View Cart. The cart opens full screen with the Shop This Look sheet gone.
- `testUnpricedItemsAreShownAndLeftOutOfTotals`: four stores, CAD and USD totals, the unpriced piece named.
- `testOneOrderFromTwoStoresSurvivesRepeatTapsAndRelaunch`: Kotn + Uniqlo, three taps on Simulate Payment,
  exactly one new order, no Back on the summary, cart emptied, and the same summary opens after a relaunch.
- `testFailedSaveKeepsTheCartAndRetryPlacesTheOrder`: a failed save shows the error, Try Again places one order.
