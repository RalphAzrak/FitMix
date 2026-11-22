# Checkout

Home → **Scan Fits** → Studio Fit → **Shop This Look** → **Add to Cart** → **Cart** → **Checkout**.

Which checkout the cart opens depends on the build:

| `FITMIX_CHECKOUT_MODE` (build setting → Info.plist `FMCheckoutMode`) | Configuration | Cart's Checkout |
| --- | --- | --- |
| `demo` | Debug (the FitMix scheme's Run action) | One full-page demo checkout for the whole cart: Order Review → Demo Payment → Order Summary |
| `shopify` | Release (Archive, Profile) | Each Shopify store's own checkout inside FitMix (Shopify Checkout Kit), one store at a time |

Debug builds can override it for one launch with `FM_DEBUG_CHECKOUT_MODE=demo|shopify`. A missing or unknown
value means `demo`.

## Demo checkout

It runs entirely in FitMix. It never collects card details, charges money, calls Shopify, a payment provider
or a retailer checkout, contacts a store or places a retailer order. It works offline; product photos load
only when online. It takes **any** cart line: no Shopify variant ID, supported-store list, retailer checkout
URL or fresh OpenAI/Trendtrack request is needed. Pieces without a listed price are allowed and counted.

| Piece | Where |
| --- | --- |
| Flow container, routes, Order Review, Demo Payment, Order Summary, shared line and totals views | `FitMix/Views/Checkout/CheckoutView.swift` |
| Cart (the flow's first page), recent demo orders | `FitMix/Views/Checkout/CartView.swift` |
| Opening the flow (bag icon, "View Cart") | `AppRouter.openCart` in `FitMix/Views/Shell/AppShell.swift` |
| `DemoOrder`, per-currency totals, sample contact and delivery | `FitMix/Models/DemoOrder.swift` |
| Saving demo orders | `FitMix/Services/DemoOrderStore.swift` |
| Mode switch | `FitMix/Services/CheckoutMode.swift` |
| Order History in Profile (lists the same demo orders) | `OrderHistoryView` in `FitMix/Views/Profile/ProfileInfoViews.swift` |
| UI tests | `FitMixUITests/DemoCheckoutUITests.swift` |

### Navigation

The flow is one full-screen cover (`CheckoutFlowView`) holding a `NavigationStack`. **Cart** is the root, and
**Order Review**, **Demo Payment** and **Order Summary** are pushed onto it (`CheckoutRoute`), never shown as
sheets.

- The bag icon (Home, Studio, Camera) and **View Cart** in Shop This Look open the same flow. Shop This Look is
  a sheet, so **View Cart** closes it first, and the cart opens once it's gone. **Done** on the cart closes the
  flow.
- Back works normally on Order Review and Demo Payment. While the order is saving, Back is hidden.
- After payment the stack is **replaced** by Order Summary: no Back button, the edge swipe does nothing, and
  **Done** closes the flow. There is no way back to a payable screen.

### Steps

1. **Cart**: lines grouped by store, with quantity controls, one **Checkout** button for every store together,
   and the recent demo orders.
2. **Order Review**: every line grouped by retailer, with photo, product name, quantity, size or variant, and
   price. Totals are shown per currency (CAD, USD…), never converted or added together. A piece without a listed
   price shows **Price unavailable** and is listed as "Not in any total", never counted as zero. **Continue to
   Payment**.
3. **Demo Payment**: **Demo mode**, the preset **Demo card •••• 4242** (a label, nothing to type), sample contact
   and delivery details (fixed text, tagged **Sample**, never the account's), the totals, and one **Pay Demo
   Order** button. The button is disabled while saving. Each visit to Demo Payment has a checkout ID: saving
   again with the same ID returns the order already saved, so repeated taps can't create duplicates.
4. Pay Demo Order approves locally, then saves one `DemoOrder` to disk **first**. The order holds a number like
   `FM-261122-932C`, a timestamp, a snapshot of every line, totals per currency, the count of unpriced pieces
   and the checkout ID. Only after the file is written are exactly those lines removed from the cart. If saving
   fails, the cart is unchanged and the alert offers **Try Again**.
5. **Order Summary**: **Demo order placed**, then the order number, date, payment status (**Approved · Demo card
   •••• 4242 (demo, not charged)**), retailers, items grouped by retailer, and totals. The same page opens from
   "Demo orders" in the cart and from Profile → Order History, also after a relaunch.

### Storage

`Application Support/Accounts/<user-id>/demo-orders.json` when signed in, `Accounts/guest/demo-orders.json` when
signed out, written atomically with complete file protection. There are no payment fields. Orders saved before
totals were stored are still read; their totals are recomputed from the items.

## Shopify store checkout (outside demo mode)

`FitMix/Views/Checkout/ShopifyStoreCheckout.swift` and `FitMix/Services/RetailerCheckout.swift`. Under each
store's lines the cart shows **Checkout at <store>** when every line is an exact Shopify variant, and opens
that store's checkout with Shopify Checkout Kit. Closing it keeps the cart. Completing it removes what that
store sold (`CartStore.completeCheckout`) and shows a receipt. Stores whose lines aren't Shopify variants
can't be checked out this way.

## Adding any retailer's piece

A listing whose link has `/products/<handle>` opens the Shopify variant picker. Many retailers that aren't on
Shopify use that path too (Uniqlo, for one), and their product data can't be loaded. The picker then offers
**Add Without a Store Variant**, which adds the listing as it is (no size). Such lines go through the demo
checkout like any other, but not through a Shopify store checkout.

## Debug launch arguments (Debug builds only)

| Variable | What it does |
| --- | --- |
| `FM_DEBUG_CHECKOUT_MODE=demo\|shopify` | Overrides the build's checkout mode for one launch. |
| `FM_DEBUG_CART_SEED=twostores` | Replaces the cart with two test fixtures: Kotn (CAD) and Uniqlo (USD, quantity 2). |
| `FM_DEBUG_CART_SEED=multistore` | Replaces the cart with four stores in two currencies, including one piece without a price. |
| `FM_DEBUG_CART_SEED=empty` | Empties the cart at launch. |
| `FM_DEBUG_MATCH_FIXTURE=mixed` | Sample look matches: a real Uniqlo listing (not Shopify) and a real Frank And Oak listing (Shopify). |
| `FM_DEBUG_CHECKOUT_PLACE=1` | Taps Checkout, Continue to Payment, then Pay Demo Order three times in a row. |
| `FM_DEBUG_ORDER_SAVE_FAIL=1` | The first demo-order save fails, to check the cart stays intact and Try Again works. |
| `FM_DEBUG_OPEN_ORDER=latest` | Opens the newest saved demo order's summary at launch. |
| `FM_DEBUG_SCREEN=cart` | Opens the checkout flow at the cart. |

Seeded pieces are labeled **Test fixture**. Seeding replaces the cart of whichever account is active.

## Tests (FitMixUITests, run with ⌘U on the FitMix scheme)

- `testBagIconOpensFullPageCartAndBackWorksBeforePayment`: the bag icon opens the cart over the tab bar. Back
  works from Order Review and from Demo Payment, and Done closes the flow.
- `testViewCartFromShopThisLookLeavesTheSheet`: Studio sample look → Shop This Look → choose a size → Add to
  Cart → View Cart. The cart opens full screen with the Shop This Look sheet gone.
- `testUnpricedItemsAreShownAndLeftOutOfTotals`: four stores, CAD and USD totals, the unpriced piece named.
- `testOneOrderFromTwoStoresSurvivesRepeatTapsAndRelaunch`: Kotn and Uniqlo, three taps on Pay Demo Order.
  Exactly one new order is saved, the summary has no Back, the cart is emptied, and the same summary opens
  after a relaunch.
- `testFailedSaveKeepsTheCartAndRetryPlacesTheOrder`: a failed save shows the error, and Try Again places one
  order.
- `testShopifyAndNonShopifyRetailersInOneDemoOrder`: the normal app flow with `FM_DEBUG_MATCH_FIXTURE=mixed`.
  Uniqlo is added without a store variant. Frank And Oak's real sizes are loaded from its store and an exact
  variant is added. Checkout, Demo Payment and Pay Demo Order follow, and one order holds both retailers and
  reopens after a relaunch. Adding Frank And Oak needs a network connection; the checkout itself doesn't.
