import Foundation

/// A demo order placed from FitMix's own checkout. Nothing is paid, and no store receives it: it is
/// saved on this iPhone only, as a record of what was in the cart. See Docs/Checkout.md.
nonisolated struct DemoOrder: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// e.g. "FM-261121-7K3Q". Shown to the shopper; unique on this device.
    var number: String
    var placedAt: Date
    /// The cart lines exactly as they were when the order was placed.
    var items: [CartItem]
    /// Totals per currency at the time of the order, never converted or added across currencies.
    /// Nil for orders saved before totals were stored: `savedTotals` recomputes them from the items.
    var totals: [CurrencyTotal]?
    /// Pieces without a listed price, left out of every total.
    var unpricedPieces: Int?
    /// The Payment screen visit that placed it. A second tap from the same visit returns this order
    /// instead of saving another.
    var checkoutID: UUID?

    var savedTotals: [CurrencyTotal] { totals ?? CartItem.totals(of: items) }
    var savedUnpricedPieces: Int { unpricedPieces ?? CartItem.unpricedPieces(in: items) }
    var pieces: Int { items.reduce(0) { $0 + $1.quantity } }

    /// "FM-" + the date + four characters that can't be confused with each other.
    static func makeNumber(at date: Date, existing: Set<String>) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%02d%02d%02d", (parts.year ?? 0) % 100, parts.month ?? 0, parts.day ?? 0)
        while true {
            let suffix = String((0..<4).map { _ in alphabet.randomElement()! })
            let number = "FM-\(day)-\(suffix)"
            if !existing.contains(number) { return number }
        }
    }
}

/// What FitMix saves for the demo orders placed on this iPhone.
nonisolated struct DemoOrderData: Codable, Equatable, Sendable {
    var version = 1
    var orders: [DemoOrder] = []
}

/// Listed prices in one currency, added up. Different currencies are never added together or converted.
nonisolated struct CurrencyTotal: Codable, Equatable, Sendable {
    var price: Price
    /// Pieces (counting quantities) included.
    var pieces: Int
}

extension CartItem {
    /// One total per currency, in the order each currency first appears. Lines without a price are left out.
    static func totals(of items: [CartItem]) -> [CurrencyTotal] {
        var order: [String] = []
        var sums: [String: (amount: Decimal, pieces: Int)] = [:]
        for item in items {
            guard let line = item.lineTotal else { continue }
            if sums[line.currencyCode] == nil { order.append(line.currencyCode) }
            let current = sums[line.currencyCode] ?? (0, 0)
            sums[line.currencyCode] = (current.amount + line.amount, current.pieces + item.quantity)
        }
        return order.compactMap { code in
            sums[code].map { CurrencyTotal(price: Price(amount: $0.amount, currencyCode: code), pieces: $0.pieces) }
        }
    }

    /// Pieces (counting quantities) with no listed price.
    static func unpricedPieces(in items: [CartItem]) -> Int {
        items.filter { $0.unitPrice == nil }.reduce(0) { $0 + $1.quantity }
    }
}
