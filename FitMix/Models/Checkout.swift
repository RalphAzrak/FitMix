import Foundation

// MARK: - FitMix's own checkout (demo mode)
//
// Cart → Checkout (contact, shipping, delivery) → Payment (card, billing) → Order confirmed.
// Payments run through `DemoPaymentProcessor`: no card details leave the phone, no money moves, and
// no store receives an order. Orders are labelled "Demo" everywhere they appear. A real provider can
// replace the processor without changing these screens. See Docs/Checkout.md.

/// How the order is delivered. Demo prices, in the cart's currency.
nonisolated enum DeliveryOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard, express

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .express: "Express"
        }
    }

    var detail: String {
        switch self {
        case .standard: "5–7 business days"
        case .express: "1–2 business days"
        }
    }

    var price: Decimal {
        switch self {
        case .standard: 8
        case .express: 20
        }
    }
}

/// Sales tax estimates by Canadian province or territory (GST, HST, PST and QST combined).
/// Shown as an estimate: a real store calculates the tax it charges.
nonisolated enum TaxEstimate {
    /// Rates as text, so they're exact decimals (a `Double` literal would turn 0.14975 into 0.149749…).
    static let canada: [String: (rate: Decimal, label: String)] = [
        "AB": ("0.05", "GST"), "BC": ("0.12", "GST + PST"), "MB": ("0.12", "GST + RST"), "NB": ("0.15", "HST"),
        "NL": ("0.15", "HST"), "NS": ("0.14", "HST"), "NT": ("0.05", "GST"), "NU": ("0.05", "GST"),
        "ON": ("0.13", "HST"), "PE": ("0.15", "HST"), "QC": ("0.14975", "GST + QST"), "SK": ("0.11", "GST + PST"),
        "YT": ("0.05", "GST"),
    ].mapValues { (rate: Decimal(string: $0.0, locale: Locale(identifier: "en_US_POSIX")) ?? 0, label: $0.1) }

    /// The rate and its name for an address, or nil when FitMix has no estimate (outside Canada).
    static func rate(for address: ShippingAddress) -> (rate: Decimal, label: String)? {
        guard address.countryCode == "CA" else { return nil }
        return canada[address.region]
    }
}

nonisolated enum Money {
    /// Rounded to cents, half up.
    static func round(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 2, .plain)
        return result
    }

    static func format(_ value: Decimal, _ currency: String) -> String {
        value.formatted(.currency(code: currency))
    }
}

/// What the order costs. `tax` is nil when there's no estimate for the address.
nonisolated struct OrderTotals: Codable, Equatable, Sendable {
    var currency: String
    var subtotal: Decimal
    var shipping: Decimal
    var tax: Decimal?
    /// e.g. "GST + QST (QC)".
    var taxLabel: String?

    var total: Decimal { subtotal + shipping + (tax ?? 0) }

    init(currency: String, subtotal: Decimal, delivery: DeliveryOption, address: ShippingAddress) {
        self.currency = currency
        self.subtotal = Money.round(subtotal)
        shipping = delivery.price
        if let estimate = TaxEstimate.rate(for: address) {
            // Tax on the goods and the shipping, as Canadian sales taxes apply to both.
            tax = Money.round((self.subtotal + shipping) * estimate.rate)
            taxLabel = "\(estimate.label) (\(address.region))"
        }
    }

    func format(_ value: Decimal) -> String { Money.format(value, currency) }
}

/// Why the cart can't be checked out yet, in words for the cart screen. Nil when it can.
@MainActor
enum CheckoutReadiness {
    static func problem(with items: [CartItem]) -> String? {
        if items.isEmpty { return "Your cart is empty." }
        if items.contains(where: { $0.unitPrice == nil }) {
            return "Remove the pieces without a price to check out."
        }
        if Set(items.compactMap(\.currencyCode)).count > 1 {
            return "Your cart has prices in several currencies, so it can't be paid in one checkout."
        }
        return nil
    }

    /// Subtotal and currency of a cart that passed `problem(with:)`.
    static func subtotal(of items: [CartItem]) -> (amount: Decimal, currency: String)? {
        guard problem(with: items) == nil, let currency = items.first?.currencyCode else { return nil }
        return (items.compactMap(\.lineTotal).reduce(Decimal.zero) { $0 + $1.amount }, currency)
    }
}

// MARK: - Contact

nonisolated struct CheckoutContact: Equatable, Sendable {
    var email = ""
    var phone = ""

    enum Field: Hashable { case email, phone }

    func errors() -> [Field: String] {
        var result: [Field: String] = [:]
        let trimmed = self.email.trimmingCharacters(in: .whitespaces)
        if trimmed.wholeMatch(of: #/[^@\s]+@[^@\s]+\.[^@\s]{2,}/#) == nil { result[.email] = "Enter an email address like name@example.com." }
        let digits = phone.filter(\.isNumber)
        if !(10...15).contains(digits.count) { result[.phone] = "Enter a phone number with its area code." }
        return result
    }
}

// MARK: - Card

nonisolated enum CardBrand: String, Codable, Sendable {
    case visa, mastercard, amex, discover, unknown

    var name: String {
        switch self {
        case .visa: "Visa"
        case .mastercard: "Mastercard"
        case .amex: "American Express"
        case .discover: "Discover"
        case .unknown: "Card"
        }
    }

    /// Digits in a full card number of this brand.
    var length: Int { self == .amex ? 15 : 16 }
    var cvcLength: Int { self == .amex ? 4 : 3 }

    /// The brand from the first digits typed.
    static func detect(_ digits: String) -> CardBrand {
        if digits.hasPrefix("4") { return .visa }
        if digits.hasPrefix("34") || digits.hasPrefix("37") { return .amex }
        if digits.hasPrefix("6011") || digits.hasPrefix("65") { return .discover }
        if let two = Int(digits.prefix(2)), (51...55).contains(two) { return .mastercard }
        if digits.count >= 4, let four = Int(digits.prefix(4)), (2221...2720).contains(four) { return .mastercard }
        return .unknown
    }
}

/// What the user typed on the payment page. Lives only in that page's state: it's never saved, logged
/// or sent anywhere. An order keeps only `brand` and `last4`.
nonisolated struct CardInput: Equatable, Sendable {
    /// Digits only.
    var number = "" { didSet { number = String(number.filter(\.isNumber).prefix(19)) } }
    /// "MM/YY" as typed (formatted by `formatExpiry`).
    var expiry = ""
    var cvc = "" { didSet { cvc = String(cvc.filter(\.isNumber).prefix(4)) } }
    var name = ""

    enum Field: Hashable { case number, expiry, cvc, name }

    var brand: CardBrand { CardBrand.detect(number) }
    var last4: String { String(number.suffix(4)) }

    /// "4242 4242 4242 4242", or "3782 822463 10005" for American Express.
    static func formatNumber(_ text: String) -> String {
        let digits = String(text.filter(\.isNumber).prefix(19))
        let groups = CardBrand.detect(digits) == .amex ? [4, 6, 5] : [4, 4, 4, 4, 3]
        var parts: [String] = []
        var rest = Substring(digits)
        for size in groups where !rest.isEmpty {
            parts.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return parts.joined(separator: " ")
    }

    /// "1", "12", "12/3", "12/30": the slash appears after the month.
    static func formatExpiry(_ text: String) -> String {
        var digits = String(text.filter(\.isNumber).prefix(4))
        // A first digit above 1 can only be a single-digit month: "5" → "05".
        if digits.count == 1, let first = digits.first, first > "1" { digits = "0" + digits }
        guard digits.count > 2 else { return digits }
        return "\(digits.prefix(2))/\(digits.dropFirst(2))"
    }

    /// The Luhn checksum every real card number passes.
    static func passesLuhn(_ digits: String) -> Bool {
        guard digits.count >= 12, digits.allSatisfy(\.isNumber) else { return false }
        var sum = 0
        for (offset, character) in digits.reversed().enumerated() {
            guard var digit = character.wholeNumberValue else { return false }
            if offset % 2 == 1 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
        }
        return sum % 10 == 0
    }

    /// Month and full year from "MM/YY", or nil when it isn't a valid month.
    static func parseExpiry(_ text: String) -> (month: Int, year: Int)? {
        let digits = text.filter(\.isNumber)
        guard digits.count == 4, let month = Int(digits.prefix(2)), let year = Int(digits.suffix(2)), (1...12).contains(month) else { return nil }
        return (month, 2000 + year)
    }

    func errors(now: Date = .now) -> [Field: String] {
        var result: [Field: String] = [:]
        if number.count != brand.length || !Self.passesLuhn(number) {
            result[.number] = number.isEmpty ? "Enter your card number." : "Check the card number."
        }
        if let expiry = Self.parseExpiry(expiry) {
            let calendar = Calendar(identifier: .gregorian)
            let current = calendar.dateComponents([.year, .month], from: now)
            if (expiry.year, expiry.month) < (current.year ?? 0, current.month ?? 0) { result[.expiry] = "This card has expired." }
        } else {
            result[.expiry] = "Enter the expiry date as MM/YY."
        }
        if cvc.count != brand.cvcLength { result[.cvc] = "Enter the \(brand.cvcLength)-digit security code." }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { result[.name] = "Enter the name on the card." }
        return result
    }
}

// MARK: - Order

/// An order placed through the demo checkout. Saved per account (`OrderStore`) and always shown as a demo.
nonisolated struct DemoOrder: Codable, Identifiable, Equatable, Sendable {
    nonisolated struct Line: Codable, Equatable, Sendable {
        var name: String
        /// "Size M", or the store's options, e.g. "Color Black · Size M".
        var detail: String?
        var retailer: String?
        var quantity: Int
        var unitPrice: Decimal
        var imageURL: URL?
    }

    /// e.g. "FM-48213".
    var id: String
    var placedAt: Date
    var lines: [Line]
    var totals: OrderTotals
    var delivery: DeliveryOption
    var shippingAddress: ShippingAddress
    var email: String
    var cardBrand: CardBrand
    var cardLast4: String
    /// Always true: FitMix doesn't take real payments yet.
    var isDemo = true

    var itemCount: Int { lines.reduce(0) { $0 + $1.quantity } }

    static func newID() -> String { "FM-\(Int.random(in: 10000...99999))" }
}

nonisolated struct OrderData: Codable, Sendable {
    var version = 1
    var orders: [DemoOrder] = []
}

@MainActor
extension DemoOrder.Line {
    init(_ item: CartItem) {
        let detail: String? = if let line = item.shopify {
            (line.displayOptions + (line.colourFixedByListing ? ["Colour as pictured"] : [])).joined(separator: " · ")
        } else {
            item.size.map { "Size \($0)" }
        }
        self.init(name: item.name, detail: detail?.isEmpty == true ? nil : detail, retailer: item.shopify?.storeName ?? item.retailer,
                  quantity: item.quantity, unitPrice: item.priceAmount ?? 0, imageURL: item.imageURL)
    }
}
