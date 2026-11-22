import XCTest

/// The full-page demo checkout, driven by real taps: Cart → Order Review → Demo Payment → Order Summary.
///
/// Carts come from Debug fixtures (`FM_DEBUG_CART_SEED`), which replace the cart at launch; every piece is
/// labeled "Test fixture". Nothing here contacts a store, Shopify or a payment provider.
final class DemoCheckoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ environment: [String: String]) {
        app = XCUIApplication()
        app.launchEnvironment = environment
        app.launch()
    }

    private func bar(_ title: String) -> XCUIElement { app.navigationBars[title] }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openCartFromBag(file: StaticString = #filePath, line: UInt = #line) {
        _ = app.buttons["cartButton"].firstMatch.waitForExistence(timeout: 10)
        let bag = app.buttons.matching(identifier: "cartButton").allElementsBoundByIndex.first { $0.isHittable }
        if bag == nil { print(app.debugDescription) }
        XCTAssertNotNil(bag, "no visible bag button", file: file, line: line)
        bag?.tap()
        XCTAssertTrue(bar("Cart").waitForExistence(timeout: 5), "Cart didn't open", file: file, line: line)
    }

    /// Saved demo orders, read from the cart's "Demo orders" header (0 when there are none).
    private func savedOrderCount() -> Int {
        let section = app.otherElements["demoOrdersSection"].firstMatch
        let element = section.exists ? section : app.staticTexts["demoOrdersSection"].firstMatch
        guard element.exists else { return 0 }
        return Int(element.value as? String ?? "") ?? 0
    }

    private func back(from title: String) {
        let button = bar(title).buttons.firstMatch
        XCTAssertTrue(button.exists, "no Back button on \(title)")
        button.tap()
    }

    // MARK: Entry points

    /// The bag icon opens the cart full screen, and Back works on every step before payment.
    func testBagIconOpensFullPageCartAndBackWorksBeforePayment() {
        launch(["FM_DEBUG_CART_SEED": "twostores"])
        openCartFromBag()
        // Full screen: the tab bar underneath is covered.
        XCTAssertFalse(app.buttons["Home"].isHittable, "the cart should cover the tab bar")

        app.buttons["cartCheckout"].tap()
        XCTAssertTrue(bar("Order Review").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["checkoutContinueToPayment"].exists)
        back(from: "Order Review")
        XCTAssertTrue(bar("Cart").waitForExistence(timeout: 5))

        app.buttons["cartCheckout"].tap()
        app.buttons["checkoutContinueToPayment"].tap()
        XCTAssertTrue(bar("Demo Payment").waitForExistence(timeout: 5))
        back(from: "Demo Payment")
        XCTAssertTrue(bar("Order Review").waitForExistence(timeout: 5))
        back(from: "Order Review")
        XCTAssertTrue(bar("Cart").waitForExistence(timeout: 5))

        app.buttons["cartDone"].tap()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 5))
        XCTAssertFalse(bar("Cart").exists)
    }

    /// Shop This Look's "View Cart" closes that sheet and opens the same full-page cart.
    func testViewCartFromShopThisLookLeavesTheSheet() {
        launch(["FM_DEBUG_SCREEN": "studio-sample", "FM_DEBUG_CART_SEED": "empty"])
        let shop = app.buttons["shopThisLook"]
        XCTAssertTrue(shop.waitForExistence(timeout: 10))
        shop.tap()
        XCTAssertTrue(bar("Shop This Look").waitForExistence(timeout: 5))

        // Choose a size (the size menu, as a shopper would), then Add to Cart.
        let sizeMenu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Size for '")).firstMatch
        XCTAssertTrue(sizeMenu.waitForExistence(timeout: 5), "no size menu in Shop This Look")
        sizeMenu.tap()
        let firstSize = app.collectionViews.buttons.firstMatch.exists ? app.collectionViews.buttons.firstMatch : app.buttons.element(boundBy: 0)
        XCTAssertTrue(firstSize.waitForExistence(timeout: 5))
        firstSize.tap()
        // Rows set their own identifier on the whole row, so the button is found by its label.
        let adds = app.buttons.matching(NSPredicate(format: "label == 'Add to Cart'"))
        XCTAssertTrue(adds.firstMatch.waitForExistence(timeout: 5), "no Add to Cart button")
        let add = adds.allElementsBoundByIndex.first { $0.isEnabled && $0.isHittable }
        XCTAssertNotNil(add, "Add to Cart didn't enable after choosing a size")
        add?.tap()
        let viewCart = app.buttons["shopViewCart"]
        XCTAssertTrue(viewCart.waitForExistence(timeout: 5))
        viewCart.tap()

        XCTAssertTrue(bar("Cart").waitForExistence(timeout: 5))
        XCTAssertFalse(bar("Shop This Look").exists, "Shop This Look should close before the cart opens")
        XCTAssertTrue(app.buttons["cartCheckout"].exists)
        app.buttons["cartCheckout"].tap()
        XCTAssertTrue(bar("Order Review").waitForExistence(timeout: 5))

        // Closing the flow goes back to Studio, not to the sheet.
        back(from: "Order Review")
        app.buttons["cartDone"].tap()
        XCTAssertTrue(shop.waitForExistence(timeout: 5))
        XCTAssertFalse(bar("Shop This Look").exists)
    }

    /// A piece without a listed price says so, and isn't counted in any total.
    func testUnpricedItemsAreShownAndLeftOutOfTotals() {
        launch(["FM_DEBUG_CART_SEED": "multistore"])
        openCartFromBag()
        app.buttons["cartCheckout"].tap()
        XCTAssertTrue(bar("Order Review").waitForExistence(timeout: 5))
        let unpriced = app.descendants(matching: .any)["total-unpriced"]
        for _ in 0..<4 where !unpriced.isHittable { app.swipeUp() }
        XCTAssertTrue(unpriced.exists, "the unpriced line should be shown in the totals")
        XCTAssertTrue(unpriced.label.contains("Price unavailable") && unpriced.label.contains("Not in any total"), unpriced.label)
        XCTAssertTrue(app.staticTexts["Price unavailable"].exists || app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS 'Price unavailable'")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["total-CAD"].exists && app.descendants(matching: .any)["total-USD"].exists)
        snapshot("checkout-four-stores-unpriced")
    }

    // MARK: A complete order

    /// Two stores, two currencies, repeated taps on Pay Demo Order, then the summary after a relaunch.
    func testOneOrderFromTwoStoresSurvivesRepeatTapsAndRelaunch() {
        launch(["FM_DEBUG_CART_SEED": "twostores"])
        openCartFromBag()
        let ordersBefore = savedOrderCount()
        snapshot("1-cart")

        app.buttons["cartCheckout"].tap()
        XCTAssertTrue(bar("Order Review").waitForExistence(timeout: 5))
        snapshot("2-checkout")
        XCTAssertTrue(app.otherElements["store-Kotn"].exists || app.staticTexts["KOTN"].exists, "Kotn group missing")
        XCTAssertTrue(app.otherElements["store-Uniqlo"].exists || app.staticTexts["UNIQLO"].exists, "Uniqlo group missing")
        XCTAssertTrue(app.descendants(matching: .any)["total-CAD"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["total-USD"].exists)

        app.buttons["checkoutContinueToPayment"].tap()
        XCTAssertTrue(bar("Demo Payment").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Demo mode"].exists)
        XCTAssertTrue(app.staticTexts["Demo card •••• 4242"].exists)
        snapshot("3-payment")

        // Three quick taps: only one order may be saved.
        let pay = app.buttons["paymentPayDemoOrder"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        pay.tap(); pay.tap(); pay.tap()

        XCTAssertTrue(app.staticTexts["demoOrderHeadline"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["demoOrderHeadline"].label, "Demo order placed")
        let number = app.staticTexts["demoOrderNumber"].label.replacingOccurrences(of: "Order ", with: "")
        XCTAssertTrue(number.hasPrefix("FM-"), "unexpected order number \(number)")
        XCTAssertTrue(bar("Order Summary").exists)
        snapshot("4-order-summary")
        // No way back to a payable screen: only Done in the bar, and an edge swipe stays put.
        XCTAssertEqual(bar("Order Summary").buttons.count, 0, "no Back on a just-placed order")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(bar("Order Summary").exists, "swiping back left the summary")
        XCTAssertFalse(bar("Demo Payment").exists)

        app.buttons["orderSummaryDoneButton"].tap()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 5))

        // The cart is empty now, and exactly one new order was saved.
        openCartFromBag()
        XCTAssertFalse(app.buttons["cartCheckout"].exists, "purchased items should leave the cart")
        XCTAssertEqual(savedOrderCount(), ordersBefore + 1, "repeat taps must not create duplicate orders")
        app.buttons["cartDone"].tap()

        // Relaunch without a seed: the same summary opens from recent demo orders.
        app.terminate()
        launch([:])
        openCartFromBag()
        let row = app.buttons["demoOrder-\(number)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "order \(number) isn't listed after relaunch")
        row.tap()
        XCTAssertTrue(bar("Order Summary").waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["demoOrderNumber"].label, "Order \(number)")
        snapshot("5-summary-after-relaunch")
        // Opened from the list, it's an ordinary page: Back returns to the cart.
        back(from: "Order Summary")
        XCTAssertTrue(bar("Cart").waitForExistence(timeout: 5))
    }

    /// A save that fails keeps the cart, and Try Again places the order.
    func testFailedSaveKeepsTheCartAndRetryPlacesTheOrder() {
        launch(["FM_DEBUG_CART_SEED": "twostores", "FM_DEBUG_ORDER_SAVE_FAIL": "1"])
        openCartFromBag()
        let ordersBefore = savedOrderCount()
        app.buttons["cartCheckout"].tap()
        app.buttons["checkoutContinueToPayment"].tap()
        XCTAssertTrue(bar("Demo Payment").waitForExistence(timeout: 5))
        app.buttons["paymentPayDemoOrder"].tap()

        let alert = app.alerts["Couldn't place the demo order"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Your cart is unchanged'")).firstMatch.exists)
        alert.buttons["Try Again"].tap()

        XCTAssertTrue(app.staticTexts["demoOrderHeadline"].waitForExistence(timeout: 10))
        app.buttons["orderSummaryDoneButton"].tap()
        openCartFromBag()
        XCTAssertEqual(savedOrderCount(), ordersBefore + 1)
    }

    // MARK: Any retailer

    /// The normal app flow with two kinds of retailer: a Shopify store's exact variant (Frank And Oak,
    /// chosen in the variant picker from the store's live product data) and a retailer that isn't on
    /// Shopify (Uniqlo, added without a store variant). Both go through Shop This Look, the cart's
    /// Checkout button, Demo Payment, and end up in the same saved demo order, which reopens after a
    /// relaunch. Matches come from FM_DEBUG_MATCH_FIXTURE=mixed (hand-picked real listings), so no
    /// OpenAI or Trendtrack request is made.
    func testShopifyAndNonShopifyRetailersInOneDemoOrder() {
        launch(["FM_DEBUG_SCREEN": "live-sample-tshirt", "FM_DEBUG_MATCH_FIXTURE": "mixed", "FM_DEBUG_CART_SEED": "empty"])
        let shop = app.buttons["shopThisLook"]
        XCTAssertTrue(shop.waitForExistence(timeout: 15))
        shop.tap()
        XCTAssertTrue(bar("Shop This Look").waitForExistence(timeout: 5))

        // Uniqlo: its link looks like a product page, but the store isn't Shopify, so sizes can't load.
        // Rows set their identifier on everything inside them, so buttons are found by row and label.
        func rowButton(_ row: String, _ label: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", row, label)).firstMatch
        }
        let addTee = rowButton("shopRow-tshirt", "Choose Size & Add")
        XCTAssertTrue(addTee.waitForExistence(timeout: 10), "no Uniqlo T-shirt in Shop This Look")
        addTee.tap()
        let withoutVariant = app.buttons["variantAddWithoutVariant"]
        XCTAssertTrue(withoutVariant.waitForExistence(timeout: 20), "Uniqlo should offer Add Without a Store Variant")
        snapshot("mixed-1-uniqlo-no-variant")
        withoutVariant.tap()
        XCTAssertTrue(bar("Shop This Look").waitForExistence(timeout: 5))

        // Frank And Oak: a Shopify store, so the picker loads real sizes and adds an exact variant.
        let addPants = rowButton("shopRow-pants", "Choose Size & Add")
        XCTAssertTrue(addPants.waitForExistence(timeout: 10), "no Frank And Oak pants in Shop This Look")
        addPants.tap()
        let addVariant = app.buttons["variantAdd"]
        XCTAssertTrue(addVariant.waitForExistence(timeout: 20), "Frank And Oak sizes didn't load")
        let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'variantOption-' AND NOT (label CONTAINS 'sold out')"))
        for index in 0..<min(options.count, 12) where !addVariant.isEnabled {
            let option = options.element(boundBy: index)
            if option.isHittable { option.tap() }
        }
        XCTAssertTrue(addVariant.isEnabled, "no in-stock Frank And Oak variant could be chosen")
        snapshot("mixed-2-frank-and-oak-variant")
        addVariant.tap()

        let viewCart = app.buttons["shopViewCart"]
        XCTAssertTrue(viewCart.waitForExistence(timeout: 5))
        viewCart.tap()
        XCTAssertTrue(bar("Cart").waitForExistence(timeout: 5))
        let ordersBefore = savedOrderCount()
        XCTAssertTrue(app.descendants(matching: .any).containing(NSPredicate(format: "label BEGINSWITH 'Variant '")).firstMatch.exists,
                      "the Frank And Oak line should carry its Shopify variant")
        snapshot("mixed-3-cart")

        app.buttons["cartCheckout"].tap()
        XCTAssertTrue(bar("Order Review").waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["store-uniqlo.com"].exists || app.staticTexts["UNIQLO"].exists, "Uniqlo group missing")
        XCTAssertTrue(app.staticTexts["FRANK AND OAK"].exists || app.descendants(matching: .any).containing(NSPredicate(format: "identifier BEGINSWITH 'store-' AND label CONTAINS[c] 'frank'")).firstMatch.exists,
                      "Frank And Oak group missing")
        XCTAssertTrue(app.descendants(matching: .any)["total-USD"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["total-CAD"].exists)
        snapshot("mixed-4-order-review")

        app.buttons["checkoutContinueToPayment"].tap()
        XCTAssertTrue(bar("Demo Payment").waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["paymentSampleDetails"].exists)
        XCTAssertTrue(app.buttons["Pay Demo Order"].exists)
        snapshot("mixed-5-demo-payment")
        app.buttons["paymentPayDemoOrder"].tap()

        XCTAssertTrue(app.staticTexts["demoOrderHeadline"].waitForExistence(timeout: 10))
        let number = app.staticTexts["demoOrderNumber"].label.replacingOccurrences(of: "Order ", with: "")
        let retailers = app.descendants(matching: .any)["demoOrderRetailers"].label
        XCTAssertTrue(retailers.contains("Uniqlo") && retailers.contains("Frank And Oak"), "retailers: \(retailers)")
        XCTAssertTrue(app.descendants(matching: .any)["demoOrderPaymentStatus"].label.contains("Approved"))
        snapshot("mixed-6-order-summary")
        app.buttons["orderSummaryDoneButton"].tap()

        openCartFromBag()
        XCTAssertFalse(app.buttons["cartCheckout"].exists, "both lines should leave the cart")
        XCTAssertEqual(savedOrderCount(), ordersBefore + 1)
        app.buttons["cartDone"].tap()

        app.terminate()
        launch([:])
        openCartFromBag()
        let row = app.buttons["demoOrder-\(number)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "order \(number) isn't listed after relaunch")
        row.tap()
        XCTAssertTrue(bar("Order Summary").waitForExistence(timeout: 5))
        let reopened = app.descendants(matching: .any)["demoOrderRetailers"].label
        XCTAssertTrue(reopened.contains("Uniqlo") && reopened.contains("Frank And Oak"), "after relaunch: \(reopened)")
        snapshot("mixed-7-summary-after-relaunch")
        print("MIXED-ORDER-NUMBER \(number)")
    }
}
