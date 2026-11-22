# Checkout (FitMix's own pages, demo mode)

Cart → **Checkout** → **Payment** → **Order confirmed**. All three are native FitMix screens in the app's
style, pushed on the cart's navigation stack. They don't open a pop-up, an Apple Pay sheet, or a store's web
checkout.

**Demo mode:** Pay runs `DemoPaymentProcessor`. No card details leave the phone, no money moves, and no store
receives an order. Every page and order says so ("Demo"). A real provider can replace the processor (see
"Going live" below) without changing the screens.

| Piece | Where |
| --- | --- |
| Delivery options, tax estimate, totals, card validation, `DemoOrder` | `FitMix/Models/Checkout.swift` |
| `PaymentProcessor` protocol, `DemoPaymentProcessor` | `FitMix/Services/PaymentProcessor.swift` |
| Orders per account (`orders.json`) | `FitMix/Services/OrderStore.swift` |
| Checkout page (contact, ship to, delivery, summary), `CheckoutDraft`, `AddressFormFields` | `FitMix/Views/Checkout/CheckoutView.swift` |
| Payment page (card, billing, total, Pay) | `FitMix/Views/Checkout/PaymentView.swift` |
| Card fields, shared field style, demo banner | `FitMix/Views/Checkout/CardFields.swift` |
| Confirmation, receipt, order detail | `FitMix/Views/Checkout/OrderConfirmationView.swift` |
| Checkout button and its guards | `FitMix/Views/Checkout/CartView.swift` |
| Order History | `OrderHistoryView` in `FitMix/Views/Profile/ProfileInfoViews.swift` |

## The flow

1. **Cart.** **Checkout** is enabled only when every line has a price, in one currency. Otherwise the cart
   says what to fix.
2. **Checkout.**
   - **Contact:** the email comes from the account, and a phone number is required.
   - **Ship to:**
     - The default saved address is filled in, and the menu offers the other saved addresses or a new one.
     - The fields and rules are the same as Profile → Addresses (`ShippingAddress.errors()`,
       `AddressFormat`). For example, a Canadian postal code must match the province.
     - Signed in, **Save to my addresses** adds a new address to Profile. If saving fails, checkout still
       continues and says so.
   - **Delivery:** Standard ($8, 5–7 days) or Express ($20, 1–2 days). These are demo prices.
   - **Summary:** the items and totals.
   - **Continue** shows the problem under each field until they're all valid.
3. **Payment.**
   - **The card number** is grouped as it's typed, and the brand (Visa, Mastercard, Amex, Discover) is shown. It
     must have the brand's length and pass the Luhn check.
   - **Expiry** is MM/YY and not in the past. **The security code** is 3 digits, or 4 for Amex. **The name** is
     required.
   - **Billing** is the shipping address by default, or a separate address with the same rules.
   - **Pay $X** shows "Processing payment…", and Back is blocked meanwhile.
4. **Confirmation.**
   - It shows the order number (`FM-12345`), the **Demo** tag, the items, the address, the card (brand ••••
     last 4) and the totals.
   - The paid lines leave the cart, and other lines stay.
   - **Done** returns to the cart. **View in Order History** appears when the order was saved.

## Totals

- **Subtotal:** the listed prices of the cart lines (what the listings showed when added).
- **Delivery:** the option's price.
- **Tax:** an **estimate** for Canadian addresses, on goods and delivery, by province. Examples: QC 14.975%
  (GST + QST), ON 13% (HST), NS 14% (HST), AB 5% (GST). Outside Canada the total says "Calculated by the store".
- **Total:** the sum, rounded to cents.

## Card data

- The card's digits live only in the payment page's state, and are cleared after the order.
- They're never saved, logged or sent.
- An order keeps only the brand and the last four digits.
- The fields use iOS card content types, so autofill can offer saved cards.

## Demo outcomes

| Card | Result |
| --- | --- |
| `4242 4242 4242 4242`, any future date, any CVC | Approved |
| Any other number that passes the checks | Approved |
| `4000 0000 0000 0002` | **Declined**: the message shows on the payment page, and the cart and form stay |

## Orders

`OrderStore` saves orders per account in `Application Support/Accounts/<user-id>/orders.json`, with complete
file protection, next to `cart.json`.
- **Signed out:** the confirmation shows the order and says it isn't saved.
- **Order History** (Profile) lists saved orders, newest first, each tagged **Demo**, and opens a detail page.

## Debug (Debug builds only)

| Variable | What it does |
| --- | --- |
| `FM_DEBUG_SCREEN=checkout` | Opens the cart and goes straight to Checkout. An empty cart is first filled with two labelled sample pieces (CAD). |
| `FM_DEBUG_CHECKOUT_DEMO=decline` | Every card is declined. |

## Going live

1. A payment provider has to be integrated. For example, **Stripe**:
   - The backend creates a PaymentIntent and prices the order itself (never trusting the app's totals).
   - The app collects the card with Stripe's own fields, so FitMix never handles raw card numbers.
   - The provider's confirmation (a webhook) marks the order paid.
2. A new `PaymentProcessor` wraps that, and `PaymentView.processor` uses it instead of the demo processor.
3. **Who sells the goods** has to be decided first. Today the products belong to other stores, so FitMix
   charging for them would make FitMix the merchant: refunds, shipping and tax become its job.

## Shopify store checkout (no longer opened)

The cart used to open each Shopify store's own checkout in a sheet (Shopify Checkout Kit, cart permalinks).
That code is still in the app, but the cart doesn't open it any more: `RetailerCheckout.swift`, the
`ShopifyCheckoutKit` package, and `CartStore.completeCheckout`.
- The variant picker (`VariantPickerSheet`, `ShopifyProducts`) is still used, so Shopify lines keep their exact
  variant.
- To bring store checkout back, open `RetailerCheckout(group:)`'s URL with `ShopifyCheckout(checkout:)` again.
  Git history has the previous `CartView`.
- The `FM_DEBUG_CHECKOUT_OPEN`, `_CLOSE_AFTER`, `_SIMULATE_COMPLETE` and `_PREFILL` variables belonged to it,
  and do nothing now. `FM_DEBUG_CHECKOUT_PICKS` (adding variants through the picker) is still read.
