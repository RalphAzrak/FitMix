import XCTest

/// The full-page demo checkout, driven by real taps: Cart → Checkout → Payment → Order Summary.
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
        XCTAssertTrue(bar("Checkout").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["checkoutContinueToPayment"].exists)
        back(from: "Checkout")
        XCTAssertTrue(bar("Cart").waitForExistence(timeout: 5))

        app.buttons["cartCheckout"].tap()
        app.buttons["checkoutContinueToPayment"].tap()
        XCTAssertTrue(bar("Payment").waitForExistence(timeout: 5))
        back(from: "Payment")
        XCTAssertTrue(bar("Checkout").waitForExistence(timeout: 5))
        back(from: "Checkout")
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
        XCTAssertTrue(bar("Checkout").waitForExistence(timeout: 5))

        // Closing the flow goes back to Studio, not to the sheet.
        back(from: "Checkout")
        app.buttons["cartDone"].tap()
        XCTAssertTrue(shop.waitForExistence(timeout: 5))
        XCTAssertFalse(bar("Shop This Look").exists)
    }

    /// A piece without a listed price says so, and isn't counted in any total.
    func testUnpricedItemsAreShownAndLeftOutOfTotals() {
        launch(["FM_DEBUG_CART_SEED": "multistore"])
        openCartFromBag()
        app.buttons["cartCheckout"].tap()
        XCTAssertTrue(bar("Checkout").waitForExistence(timeout: 5))
        let unpriced = app.descendants(matching: .any)["total-unpriced"]
        for _ in 0..<4 where !unpriced.isHittable { app.swipeUp() }
        XCTAssertTrue(unpriced.exists, "the unpriced line should be shown in the totals")
        XCTAssertTrue(unpriced.label.contains("Price unavailable") && unpriced.label.contains("Not in any total"), unpriced.label)
        XCTAssertTrue(app.staticTexts["Price unavailable"].exists || app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS 'Price unavailable'")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["total-CAD"].exists && app.descendants(matching: .any)["total-USD"].exists)
        snapshot("checkout-four-stores-unpriced")
    }

    // MARK: A complete order

    /// Two stores, two currencies, repeated taps on Simulate Payment, then the summary after a relaunch.
    func testOneOrderFromTwoStoresSurvivesRepeatTapsAndRelaunch() {
        launch(["FM_DEBUG_CART_SEED": "twostores"])
        openCartFromBag()
        let ordersBefore = savedOrderCount()
        snapshot("1-cart")

        app.buttons["cartCheckout"].tap()
        XCTAssertTrue(bar("Checkout").waitForExistence(timeout: 5))
        snapshot("2-checkout")
        XCTAssertTrue(app.otherElements["store-Kotn"].exists || app.staticTexts["KOTN"].exists, "Kotn group missing")
        XCTAssertTrue(app.otherElements["store-Uniqlo"].exists || app.staticTexts["UNIQLO"].exists, "Uniqlo group missing")
        XCTAssertTrue(app.descendants(matching: .any)["total-CAD"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["total-USD"].exists)

        app.buttons["checkoutContinueToPayment"].tap()
        XCTAssertTrue(bar("Payment").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Demo mode"].exists)
        XCTAssertTrue(app.staticTexts["Demo card •••• 4242"].exists)
        snapshot("3-payment")

        // Three quick taps: only one order may be saved.
        let pay = app.buttons["paymentSimulate"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
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
        XCTAssertFalse(bar("Payment").exists)

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
        XCTAssertTrue(bar("Payment").waitForExistence(timeout: 5))
        app.buttons["paymentSimulate"].tap()

        let alert = app.alerts["Couldn't place the demo order"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Your cart is unchanged'")).firstMatch.exists)
        alert.buttons["Try Again"].tap()

        XCTAssertTrue(app.staticTexts["demoOrderHeadline"].waitForExistence(timeout: 10))
        app.buttons["orderSummaryDoneButton"].tap()
        openCartFromBag()
        XCTAssertEqual(savedOrderCount(), ordersBefore + 1)
    }
}
