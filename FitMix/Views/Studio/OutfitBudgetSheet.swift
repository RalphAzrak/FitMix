import SwiftUI

struct OutfitBudgetSheet: View {
    let cap: Decimal?
    let save: (Decimal?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var amount = ""
    @FocusState private var editingAmount: Bool
    private let presets = [100, 200, 300]

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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Set a limit for the whole outfit before tax and shipping. FitMix uses listings priced in CAD.")
                        .font(.subheadline)
                        .foregroundStyle(Color.fmSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                        ForEach(presets, id: \.self) { preset in
                            let selected = validAmount == Decimal(preset)
                            Button {
                                amount = preset.formatted(.number.locale(locale))
                                editingAmount = false
                            } label: {
                                Text(Decimal(preset).formatted(.currency(code: OutfitBudget.currency)
                                    .presentation(.narrow).precision(.fractionLength(0))))
                                    .font(.headline)
                                    .foregroundStyle(selected ? .white : Color.fmCobalt)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(selected ? Color.fmCobalt : Color.fmFill, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("budgetPreset-\(preset)")
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Custom amount").font(.subheadline.weight(.semibold))
                        HStack {
                            TextField("Amount in CAD", text: $amount)
                                .keyboardType(.decimalPad)
                                .focused($editingAmount)
                                .accessibilityIdentifier("outfitBudgetAmount")
                            Text("CAD").font(.subheadline.weight(.semibold)).foregroundStyle(Color.fmSecondary)
                        }
                        .padding(12)
                        .background(Color.fmFill, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if cap != nil {
                        Button("Clear budget", role: .destructive) { apply(nil) }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.fmCanvas)
            .safeAreaInset(edge: .bottom) {
                Button("Apply Budget") {
                    if let validAmount { apply(validAmount) }
                }
                .buttonStyle(FMFilledButtonStyle())
                .disabled(validAmount == nil)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.fmCanvas)
            }
            .navigationTitle("Outfit budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .onAppear { amount = cap?.formatted(.number.locale(locale)) ?? "" }
    }

    private func apply(_ cap: Decimal?) {
        save(cap)
        dismiss()
    }
}
