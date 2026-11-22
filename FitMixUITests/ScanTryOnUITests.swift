import XCTest

/// Photo try-on for scanned outfits: Scan → select garments → Studio Fit → Your Try-On.
///
/// Renders use the Debug stand-in (`FM_DEBUG_TRYON_STUB=1`), which never contacts OpenAI: it returns the
/// try-on photo stamped "DEBUG STAND-IN · NOT A TRY-ON" with the garments it was handed (their ids and
/// their images along the bottom), so the screenshots show exactly what reached the renderer.
///
/// Test photos aren't in the repo. Pass them to the test runner (xcodebuild forwards TEST_RUNNER_*):
///   TEST_RUNNER_FM_TRYON_PERSON  a full-body photo used as the saved try-on photo
///   TEST_RUNNER_FM_TRYON_SCAN    a 1080×1920 outfit photo analyzed as the live camera frame
///   TEST_RUNNER_FM_TRYON_REPLAY  detections in that frame, e.g. "tshirt:0.28,0.24,0.43,0.31;pants:…"
///   TEST_RUNNER_FM_TRYON_GARMENT a garment image for Wardrobe Try-On
///   TEST_RUNNER_FM_TRYON_BACKEND optional local test backend for testLiveScanWithoutMatchesRendersOnSavedPhoto
final class ScanTryOnUITests: XCTestCase {
    private var app: XCUIApplication!
    /// A local stand-in account (no Supabase): Wardrobe items belong to an account.
    private static let account = "5E1F7C1A-0000-4000-8000-00000000F17E"
    private let env = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
    }

    private func path(_ key: String) throws -> String {
        guard let value = env[key], !value.isEmpty else { throw XCTSkip("\(key) isn't set") }
        return value
    }

    private func launch(_ environment: [String: String]) {
        app = XCUIApplication()
        app.launchEnvironment = environment
        app.launch()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var hero: XCUIElement { app.descendants(matching: .any)["tryOnHero"].firstMatch }
    private var renderedImage: XCUIElement {
        app.images.matching(NSPredicate(format: "identifier == 'tryOnImage' AND label == 'Stand-in preview, not a try-on'")).firstMatch
    }

    /// Camera on a test photo, with the scanner's detections replayed (the simulator can't run body pose).
    private func liveScanEnvironment(photo: String?) throws -> [String: String] {
        var environment = ["FM_DEBUG_SCREEN": "camera", "FM_DEBUG_CAPTURE_PHOTO": try path("FM_TRYON_SCAN"),
                           "FM_DEBUG_AUTO_ANALYZE": "1", "FM_DEBUG_REPLAY": try path("FM_TRYON_REPLAY"),
                           "FM_DEBUG_MATCH_FIXTURE": "nomatch", "FM_DEBUG_TRYON_STUB": "1"]
        environment["FM_DEBUG_SEED_PHOTO"] = photo ?? "none"
        return environment
    }

    /// Taps the T-shirt target in the Camera, then opens the Try On tab in Studio.
    private func scanAndOpenYourTryOn() {
        let target = app.buttons["liveTarget-tshirt"]
        XCTAssertTrue(target.waitForExistence(timeout: 15), "no T-shirt target in the Camera")
        snapshot("1-camera-targets")
        target.tap()
        let tryOn = app.buttons["Try On"]
        XCTAssertTrue(tryOn.waitForExistence(timeout: 10), "Studio didn't open")
        XCTAssertTrue(app.buttons["Scanned Outfit"].isSelected)
        tryOn.tap()
    }

    // MARK: Live scan

    /// Two or more garments from a live scan, no retailer matches, the saved try-on photo reused.
    func testLiveScanWithoutMatchesRendersOnSavedPhoto() throws {
        var environment = try liveScanEnvironment(photo: try path("FM_TRYON_PERSON"))
        let testBackend = env["FM_TRYON_BACKEND"]
        if let testBackend {
            environment["FM_DEBUG_TRYON_STUB"] = nil
            environment["FITMIX_BACKEND_URL"] = testBackend
        }
        launch(environment)
        scanAndOpenYourTryOn()
        let image = testBackend == nil ? renderedImage : app.images.matching(NSPredicate(
            format: "identifier == 'tryOnImage' AND label == 'You wearing the selected look'")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 15), "no rendered try-on")
        let status = testBackend == nil ? "Sample Preview" : "Try-On"
        XCTAssertTrue(app.descendants(matching: .any)["tryOnStatus"].label.contains(status))
        snapshot("2-your-try-on")
        // No retailer match was needed.
        let noMatch = app.staticTexts.matching(identifier: "noMatch")
        XCTAssertGreaterThanOrEqual(noMatch.count, 2, "expected the garments to have no retailer matches")
    }

    /// No saved photo: Your Try-On asks for one, and once chosen continues with the same scanned outfit.
    func testNoSavedPhotoAsksForOneThenContinues() throws {
        launch(try liveScanEnvironment(photo: nil))
        scanAndOpenYourTryOn()
        let add = app.buttons["Add Your Photo"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Your Try-On should ask for a photo")
        XCTAssertTrue(app.staticTexts["Add a full-body photo of yourself. Try-on starts from it."].exists)
        snapshot("2-needs-photo")
        add.tap()
        let take = app.buttons["Take Photo"]
        XCTAssertTrue(take.waitForExistence(timeout: 5))
        take.tap()
        let library = app.buttons["Choose from Photos"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.tap()
        // The system photo picker: choose the first photo (the test photo added to the simulator's library).
        let photo = app.images.matching(NSPredicate(format: "label CONTAINS[c] 'photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "photo picker didn't show photos")
        photo.tap()
        let use = app.buttons["Use This Photo"]
        XCTAssertTrue(use.waitForExistence(timeout: 20))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: use)
        waitForExpectations(timeout: 20)
        snapshot("3-photo-chosen")
        use.tap()
        XCTAssertTrue(renderedImage.waitForExistence(timeout: 15), "the same look should render on the new photo")
        snapshot("4-your-try-on")
    }

    // MARK: Selected garments and swaps

    /// Sample Scan A through Outfit Review (garments selected), then a swap while the first render is
    /// still running: only the newer render may show, and it uses the swapped product's photo.
    func testSelectedGarmentsAndSwapReplaceAStaleRender() throws {
        launch(["FM_DEBUG_SCREEN": "camera", "FM_DEBUG_SAMPLE_SCANS": "1", "FM_DEBUG_SEED_PHOTO": try path("FM_TRYON_PERSON"),
                "FM_DEBUG_TRYON_STUB": "1", "FM_DEBUG_TRYON_STUB_DELAY": "4"])
        let sample = app.buttons["Finish with Sample Scan A"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        sample.tap()
        let tryFull = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Try Full Look'")).firstMatch
        XCTAssertTrue(tryFull.waitForExistence(timeout: 10))
        snapshot("1-outfit-review")
        tryFull.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tryOnRendering"].waitForExistence(timeout: 10), "no loading state")
        snapshot("2-rendering")

        // Swap the selected piece while that render is still running.
        let swap = app.buttons["Swap item"]
        XCTAssertTrue(swap.waitForExistence(timeout: 5))
        swap.tap()
        let alternative = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'swapOption-' AND NOT (identifier == 'swapOption-original')")).firstMatch
        if alternative.waitForExistence(timeout: 5) { alternative.tap() } else {
            let rows = app.scrollViews.buttons
            XCTAssertGreaterThan(rows.count, 1, "no alternatives to swap in")
            rows.element(boundBy: 1).tap()
        }
        app.buttons["Swap in this piece"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["swapBadge"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["tryOnRendering"].exists, "the swap should restart the render")
        XCTAssertTrue(renderedImage.waitForExistence(timeout: 15))
        snapshot("3-rendered-after-swap")
    }

    // MARK: Wardrobe Try-On

    /// Studio's Wardrobe Try-On (an accessory) behaves as before: accessories can't be rendered.
    func testWardrobeAccessoryTryOnUnchanged() throws {
        launch(["FM_DEBUG_SCREEN": "wardrobe-tryon", "FM_DEBUG_WARDROBE_GARMENT": try path("FM_TRYON_GARMENT"),
                "FM_DEBUG_SEED_PHOTO": try path("FM_TRYON_PERSON"), "FM_DEBUG_ACCOUNT_ID": Self.account])
        XCTAssertTrue(app.staticTexts["Try-on isn't available yet"].waitForExistence(timeout: 10))
        snapshot("wardrobe-accessory")
    }

    /// The same renderer serves Wardrobe Try-On when the garment has an outfit slot.
    func testWardrobeGarmentUsesTheSameRenderer() throws {
        launch(["FM_DEBUG_SCREEN": "wardrobe-tryon", "FM_DEBUG_WARDROBE_GARMENT": try path("FM_TRYON_GARMENT"),
                "FM_DEBUG_WARDROBE_CATEGORY": "tshirt", "FM_DEBUG_SEED_PHOTO": try path("FM_TRYON_PERSON"), "FM_DEBUG_TRYON_STUB": "1",
                "FM_DEBUG_ACCOUNT_ID": Self.account])
        XCTAssertTrue(renderedImage.waitForExistence(timeout: 15))
        snapshot("wardrobe-tshirt")
    }

    /// Without a backend (and without the stand-in) Your Try-On says try-on isn't available, as before.
    func testWithoutBackendYourTryOnSaysUnavailable() throws {
        var environment = try liveScanEnvironment(photo: try path("FM_TRYON_PERSON"))
        environment["FM_DEBUG_TRYON_STUB"] = nil
        launch(environment)
        scanAndOpenYourTryOn()
        XCTAssertTrue(app.descendants(matching: .any)["tryOnUnavailable"].waitForExistence(timeout: 10))
        snapshot("no-backend")
    }
}
