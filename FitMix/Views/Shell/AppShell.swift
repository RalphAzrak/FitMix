import SwiftUI

/// Where the app is: the selected tab and whatever is presented over it. Screens change these
/// instead of presenting covers themselves, so only one full-screen flow shows at a time.
@Observable final class AppRouter {
    enum Tab: String, CaseIterable, Identifiable {
        case home, studio, closet, saved
        var id: String { rawValue }
    }

    /// The Camera flow: capture, then Outfit Review.
    enum Capture: String, Identifiable {
        case camera, review
        var id: String { rawValue }
    }

    var tab: Tab = .home
    var capture: Capture?
    /// The step the avatar flow is open at, or `nil` when it is closed.
    var flow: SetupStep?
    var authPreview: AuthView.Mode?
    var showOutfit = false
    /// The checkout flow (Cart → Order Review → Demo Payment → Order Summary in demo mode), full screen. Open it with `openCart`.
    var showCart = false
    /// What the checkout flow opens on, below the cart (e.g. a saved order's summary).
    var cartStartPath: [CheckoutRoute] = []
    var showShopLook = false
    /// Set when "View Cart" is tapped in Shop This Look: the cart opens once that sheet has closed.
    @ObservationIgnored private var cartAfterShopLook = false
    var showMetricsEditor = false
    /// Set when sign-in or sign-up finishes and there is no avatar yet; opens the avatar flow once Account closes.
    var setupAfterAuth = false

    func openCamera() { capture = .camera }

    /// Opens the checkout flow, full screen. From Shop This Look (a sheet), that sheet closes first, so
    /// the cart and the rest of checkout take the whole screen rather than stacking on the sheet.
    func openCart(at path: [CheckoutRoute] = []) {
        cartStartPath = path
        if showShopLook {
            cartAfterShopLook = true
            showShopLook = false
        } else {
            showCart = true
        }
    }

    /// Shop This Look's sheet finished closing.
    func shopLookDismissed() {
        guard cartAfterShopLook else { return }
        cartAfterShopLook = false
        showCart = true
    }
    func openAccount() { authPreview = .signIn }
}

/// The app's root: one screen per tab, the tab bar underneath, and the app-wide covers and sheets.
struct AppShell: View {
    @Environment(AvatarStore.self) private var store
    @Environment(StudioStore.self) private var studio
    @Environment(AuthSession.self) private var auth
    @Environment(CartStore.self) private var cart
    @Environment(DemoOrderStore.self) private var orders
    @State private var router = AppRouter()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Home and Studio stay alive in the background so switching tabs keeps their place.
                layer(.home) { HomeView() }
                layer(.studio) { StudioView(openCamera: router.openCamera) }
                if router.tab == .closet { WardrobeView() }
                if router.tab == .saved { SavedView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            FMTabBar(selection: $router.tab, openCamera: router.openCamera)
        }
        .background(Color.fmBackground.ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
        .environment(router)
        .tint(Color.fmCobalt)
        .fullScreenCover(isPresented: $router.showOutfit) { OutfitBuilderView() }
        .fullScreenCover(item: $router.flow) { SetupFlowView(startAt: $0) }
        .fullScreenCover(item: $router.capture) { route in
            switch route {
            case .camera:
                CameraView(close: {
                    // Back to the tab Camera was opened from; Studio keeps its previous look.
                    router.capture = nil
                }, select: { selection in
                    studio.openLive(selection, tryOnSource: nil)
                    router.tab = .studio
                    router.capture = nil
                }, confirm: { scan in
                    studio.review(scan)
                    router.capture = .review
                })
            case .review:
                if let scan = studio.pendingScan {
                    OutfitReviewView(scan: scan, retake: {
                        studio.discardReview()
                        router.capture = .camera
                    }, close: {
                        studio.discardReview()
                        router.capture = nil
                    }, openStudio: {
                        router.tab = .studio
                        router.capture = nil
                    })
                    // Another scan starts its selection fresh.
                    .id(scan.id)
                }
            }
        }
        .fullScreenCover(item: $router.authPreview, onDismiss: {
            // Cleared after the cover closes so it doesn't flash Profile on the way out.
            auth.finishConfirmation()
            if router.setupAfterAuth {
                router.setupAfterAuth = false
                router.flow = store.resumeStep
            }
        }) { mode in
            AccountFlowView(mode: mode) { _ in
                router.setupAfterAuth = store.profile.avatar == nil && store.profile.candidate == nil
                router.authPreview = nil
            }
        }
        .sheet(isPresented: $router.showMetricsEditor) { MetricsEditorSheet() }
        // Presented content sits outside `.environment(router)` above, so it gets the router explicitly.
        .fullScreenCover(isPresented: $router.showCart) {
            CheckoutFlowView(startingAt: router.cartStartPath).environment(router)
        }
        .sheet(isPresented: $router.showShopLook, onDismiss: router.shopLookDismissed) {
            ShoppingReviewView().environment(router)
        }
        .alert("Couldn't save", isPresented: Binding(get: { store.storageErrorMessage != nil && router.flow == nil },
                                                    set: { if !$0 { store.storageErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.storageErrorMessage ?? "")
        }
        .onChange(of: auth.hasOpenAuthLink) { _, active in
            if active { showAuthLink() }
        }
        .onAppear {
            if auth.hasOpenAuthLink { showAuthLink() }
            #if DEBUG
            // FM_DEBUG_OPEN_ORDER=latest: opens the newest saved demo order's summary (checks it survives a relaunch).
            if ProcessInfo.processInfo.environment["FM_DEBUG_OPEN_ORDER"] == "latest" {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    if let latest = orders.orders.first {
                        CheckoutLog.record("debug-open-order", store: "-", note: "number=\(latest.number) orders=\(orders.orders.count)")
                        router.openCart(at: [.summary(latest.id, justPlaced: false)])
                    } else {
                        CheckoutLog.record("debug-open-order", store: "-", note: "none saved")
                    }
                }
            }
            #endif
            switch Self.debugScreen {
            case "setup": router.flow = store.resumeStep
            case "generate": router.flow = .generate
            case "metrics": router.showMetricsEditor = true
            case "auth", "profile": router.authPreview = .signIn
            case "auth-create": router.authPreview = .createAccount
            case "cart", "checkout": router.openCart()
            case "shop": router.showShopLook = true
            case "studio": router.tab = .studio
            #if DEBUG
            case "studio-sample":
                // Studio on the code-drawn sample look, without going through Camera.
                studio.open(SampleScans.scanA(), tryOnSource: store.bodyPhoto)
                router.tab = .studio
            case let screen? where screen.hasPrefix("live-sample-"):
                if let category = GarmentCategory(rawValue: String(screen.dropFirst("live-sample-".count))),
                   let selection = SampleScans.liveSelection(category) {
                    studio.openLive(selection, tryOnSource: nil)
                    router.tab = .studio
                    if let next = ProcessInfo.processInfo.environment["FM_DEBUG_THEN_SELECT"].flatMap(GarmentCategory.init(rawValue:)) {
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            if let piece = studio.look?.pieces.first(where: { $0.detected.category == next }) {
                                studio.select(piece.id)
                            }
                        }
                    }
                    // Checkout proof of concept: select each scripted garment in turn (a new selection cancels
                    // a search still running), wait for its match, then open Shop This Look.
                    if let script = DebugCheckoutScript.current {
                        Task {
                            for category in script.order {
                                guard let piece = studio.look?.pieces.first(where: { $0.detected.category == category }) else { continue }
                                if studio.matchStates[piece.id] == nil { studio.select(piece.id) }
                                for _ in 0..<60 where studio.matchStates[piece.id] == .searching || studio.matchStates[piece.id] == nil {
                                    try? await Task.sleep(for: .milliseconds(250))
                                }
                            }
                            router.showShopLook = true
                        }
                    }
                }
            #endif
            case "outfit": router.showOutfit = true
            case "closet", "wardrobe": router.tab = .closet
            case "saved": router.tab = .saved
            case "camera": router.capture = .camera
            default: break
            }
        }
    }

    private func layer<Content: View>(_ tab: AppRouter.Tab, @ViewBuilder content: () -> Content) -> some View {
        let visible = router.tab == tab
        return content()
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }

    /// A reset or sign-up confirmation link was opened: show it in the Account cover. Anything else
    /// presented here closes first (the avatar flow saves as it goes), since only one can show at a time.
    private func showAuthLink() {
        guard router.authPreview == nil else { return }
        let otherOpen = router.flow != nil || router.showMetricsEditor || router.capture != nil || router.showCart || router.showShopLook || router.showOutfit
        router.flow = nil
        router.showMetricsEditor = false
        router.capture = nil
        router.showOutfit = false
        router.showCart = false
        router.showShopLook = false
        router.setupAfterAuth = false
        Task {
            if otherOpen { try? await Task.sleep(for: .milliseconds(650)) }
            router.authPreview = .signIn
        }
    }

    /// Debug builds can open straight into a screen with FM_DEBUG_SCREEN=setup | generate | avatar-profile |
    /// metrics | auth | auth-create | profile | studio | studio-sample | closet | saved | camera | cart | checkout | shop.
    static var debugScreen: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["FM_DEBUG_SCREEN"]
        #else
        nil
        #endif
    }
}

// MARK: - Tab bar

/// Home · Studio · Camera · Wardrobe · Saved. Camera is a raised cobalt button that opens the capture
/// flow over the current tab; the others switch tabs.
struct FMTabBar: View {
    @Binding var selection: AppRouter.Tab
    var openCamera: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            item(.home, title: "Home", icon: "house", selectedIcon: "house.fill")
            item(.studio, title: "Studio", icon: "tshirt", selectedIcon: "tshirt.fill")
            // Center slot, so the raised button sits in the middle of the bar.
            cameraButton
            item(.closet, title: "Wardrobe", icon: "square.grid.2x2", selectedIcon: "square.grid.2x2.fill")
            item(.saved, title: "Saved", icon: "bookmark", selectedIcon: "bookmark.fill")
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background {
            Color.fmBackground
                .overlay(alignment: .top) { Rectangle().fill(Color.fmHairline).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func item(_ tab: AppRouter.Tab, title: String, icon: String, selectedIcon: String) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: selected ? selectedIcon : icon)
                    .font(.system(size: 21, weight: .medium))
                    .frame(height: 26)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Color.fmCobalt : Color.fmSecondary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("tab-\(tab.rawValue)")
    }

    private var cameraButton: some View {
        Button(action: openCamera) {
            VStack(spacing: 4) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(.fmPrimaryGradient, in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 4))
                    .shadow(color: Color.fmCobalt.opacity(0.35), radius: 10, y: 4)
                    .padding(.top, -30)
                    .frame(height: 26, alignment: .bottom)
                Text("Camera")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.fmSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera")
        .accessibilityHint("Scan an outfit")
        .accessibilityIdentifier("tab-camera")
    }
}

// MARK: - Saved

/// Saved: looks the user keeps. Saving isn't built yet, so it says so.
struct SavedView: View {
    var body: some View {
        TabPlaceholder(title: "Saved", caption: "Looks", icon: "bookmark",
                       heading: "Saved looks are coming soon",
                       message: "You'll be able to save looks from Studio and come back to them here. Your current look stays in Studio until you scan a new one.",
                       actionTitle: "Open Studio", actionIcon: "tshirt") { $0.tab = .studio }
    }
}

private struct TabPlaceholder: View {
    var title: String
    var caption: String
    var icon: String
    var heading: String
    var message: String
    var actionTitle: String
    var actionIcon: String
    var action: (AppRouter) -> Void

    @Environment(AppRouter.self) private var router
    @Environment(CartStore.self) private var cart

    var body: some View {
        VStack(spacing: 0) {
            FMTopBar { FMBagButton(count: cart.count) { router.openCart() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FMTitleLine(title: title, caption: caption)
                    VStack(spacing: 14) {
                        Image(systemName: icon)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(Color.fmCobalt)
                            .frame(width: 72, height: 72)
                            .background(.white, in: Circle())
                            .fmFloatingShadow()
                            .accessibilityHidden(true)
                        Text(heading)
                            .font(.fmDisplay(24, relativeTo: .title2))
                            .foregroundStyle(Color.fmInk)
                            .multilineTextAlignment(.center)
                        Text(message)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.fmSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { action(router) } label: { Label(actionTitle, systemImage: actionIcon) }
                            .buttonStyle(FMFilledButtonStyle())
                            .padding(.top, 6)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity)
                    .fmHeroFrame()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
        }
        .background(Color.fmBackground)
    }
}
