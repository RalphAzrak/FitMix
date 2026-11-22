import Foundation

/// Which checkout the cart's **Checkout** button opens. Set per build configuration by the
/// `FITMIX_CHECKOUT_MODE` build setting (Info.plist key `FMCheckoutMode`): Debug builds are `demo`,
/// Release builds `shopify`. See Docs/Checkout.md.
nonisolated enum CheckoutMode: String, Sendable {
    /// FitMix's own full-page demo checkout for the whole cart: order review, a preset demo payment
    /// method, and a locally saved demo order. Works for any cart line; nothing is charged and no
    /// payment provider, Shopify or retailer is contacted.
    case demo
    /// Each Shopify store's own checkout inside FitMix (Shopify Checkout Kit), one store at a time.
    /// Only lines with an exact Shopify variant can be checked out this way.
    case shopify

    static let current: CheckoutMode = {
        #if DEBUG
        // FM_DEBUG_CHECKOUT_MODE=shopify|demo overrides the build setting for one launch (tests).
        if let override = ProcessInfo.processInfo.environment["FM_DEBUG_CHECKOUT_MODE"].flatMap(CheckoutMode.init(rawValue:)) {
            return override
        }
        #endif
        let configured = Bundle.main.object(forInfoDictionaryKey: "FMCheckoutMode") as? String
        return configured.flatMap { CheckoutMode(rawValue: $0.lowercased()) } ?? .demo
    }()
}
