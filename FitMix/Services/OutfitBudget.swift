import Foundation

nonisolated enum OutfitBudget {
    static let currency = "CAD"

    struct Option: Sendable {
        let id: String
        let price: Decimal
        let score: Int
    }

    private struct Choice {
        var ids: [String?]
        var price: Decimal
        var count: Int
        var score: Int
    }

    /// Maximize covered garments, then total visual similarity, then prefer a lower subtotal.
    /// Keep the cheapest plan for each coverage and score. Future garments depend only on
    /// remaining budget, so a more expensive plan with the same coverage and score can be dropped.
    static func select(_ groups: [[Option]], cap: Decimal) -> [String?] {
        var plans = [0: Choice(ids: [], price: 0, count: 0, score: 0)]
        for group in groups {
            var next: [Int: Choice] = [:]
            for plan in plans.values {
                add(Choice(ids: plan.ids + [nil], price: plan.price, count: plan.count, score: plan.score), to: &next)
                for option in group where plan.price + option.price <= cap {
                    add(Choice(ids: plan.ids + [option.id], price: plan.price + option.price,
                               count: plan.count + 1, score: plan.score + option.score), to: &next)
                }
            }
            plans = next
        }
        return plans.max { $0.key < $1.key }?.value.ids ?? []
    }

    private static func add(_ plan: Choice, to plans: inout [Int: Choice]) {
        let rank = plan.count * 1000 + plan.score
        if let existing = plans[rank] {
            if existing.price < plan.price { return }
            if existing.price == plan.price,
               !plan.ids.map({ $0 ?? "~" }).lexicographicallyPrecedes(existing.ids.map({ $0 ?? "~" })) { return }
        }
        plans[rank] = plan
    }
}
