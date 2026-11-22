import Foundation

/// Takes payment for an order. The checkout screens only talk to this protocol, so a real provider
/// (for example Stripe, through the FitMix backend) can replace `DemoPaymentProcessor` later.
protocol PaymentProcessor: Sendable {
    /// True when no real money moves. Every screen and order says "Demo" then.
    var isDemo: Bool { get }
    func pay(amount: Decimal, currency: String, card: CardInput) async throws -> PaymentResult
}

nonisolated struct PaymentResult: Sendable {
    /// The processor's reference for the payment.
    var reference: String
}

nonisolated enum PaymentError: LocalizedError, Equatable {
    case declined

    var errorDescription: String? {
        switch self {
        case .declined: "Your card was declined. Try another card. (Demo: 4000 0000 0000 0002 is always declined.)"
        }
    }
}

/// The demo processor: waits like a real payment, then approves. Nothing leaves the phone and nothing
/// is charged. The card number `4000 0000 0000 0002` is declined, to show what a decline looks like.
nonisolated struct DemoPaymentProcessor: PaymentProcessor {
    static let declinedNumber = "4000000000000002"
    var isDemo: Bool { true }
    /// Debug builds: FM_DEBUG_CHECKOUT_DEMO=decline declines every card.
    var declineEverything = DemoPaymentProcessor.debugDeclines

    func pay(amount: Decimal, currency: String, card: CardInput) async throws -> PaymentResult {
        try await Task.sleep(for: .seconds(1.5))
        if declineEverything || card.number == Self.declinedNumber { throw PaymentError.declined }
        return PaymentResult(reference: "demo_" + UUID().uuidString.prefix(8).lowercased())
    }

    private static var debugDeclines: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["FM_DEBUG_CHECKOUT_DEMO"] == "decline"
        #else
        false
        #endif
    }
}
