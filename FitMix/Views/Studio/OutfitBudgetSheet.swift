import SwiftUI

struct OutfitBudgetSheet: View {
    let cap: Decimal?
    let save: (Decimal?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var amount = ""

    private var validAmount: Decimal? {
        let value = amount.trimmingCharacters(in: .whitespaces)
        guard let parsed = try? Decimal(value, format: .number.locale(locale), lenient: false),
              parsed > 0, parsed <= 100_000 else { return nil }
        var exact = parsed
        var rounded = Decimal()
        NSDecimalRound(&rounded, &exact, 2, .plain)
        return parsed == rounded ? parsed : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Total in CAD", text: $amount)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("outfitBudgetAmount")
                } footer: {
                    Text("Set one cap for the entire outfit, before tax and shipping.")
                }
                if cap != nil {
                    Button("Clear budget", role: .destructive) { apply(nil) }
                }
            }
            .navigationTitle("Outfit budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let validAmount { apply(validAmount) }
                    }
                    .disabled(validAmount == nil)
                }
            }
        }
        .onAppear { amount = cap?.formatted(.number.locale(locale)) ?? "" }
    }

    private func apply(_ cap: Decimal?) {
        save(cap)
        dismiss()
    }
}
