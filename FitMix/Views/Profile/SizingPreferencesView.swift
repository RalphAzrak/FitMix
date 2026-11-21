import SwiftUI

/// Usual top, bottom, and shoe sizes. Each is optional and can be cleared on its own.
struct SizingPreferencesView: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SizingPreferences()
    @State private var loaded = false
    @State private var saveFailure: String?

    private var hasChanges: Bool { loaded && draft != profile.sizing }

    var body: some View {
        Form {
            if case .failed(let message) = profile.state {
                Section {
                    NoticeRow(tone: .caution, text: message)
                    Button("Try Again") { profile.reload(); draft = profile.sizing }
                }
            }

            Section {
                Picker("Size", selection: $draft.top) {
                    Text("Not set").tag(LetterSize?.none)
                    ForEach(LetterSize.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                .accessibilityIdentifier("sizeTop")
                if draft.top != nil { clearButton("Clear Top Size") { draft.top = nil } }
            } header: {
                Text("Tops")
            } footer: {
                Text("Shirts, sweaters, jackets, and dresses.")
            }

            Section {
                Picker("Sizing system", selection: bottomSystem) {
                    Text("Not set").tag(BottomSize.System?.none)
                    ForEach(BottomSize.System.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .accessibilityIdentifier("sizeBottomSystem")
                if let bottom = draft.bottom {
                    Picker(bottom.system == .waist ? "Waist" : "Size", selection: bottomValue) {
                        ForEach(bottom.system.values, id: \.self) { Text($0).tag($0) }
                    }
                    if bottom.system == .waist {
                        Picker("Inseam (optional)", selection: bottomInseam) {
                            Text("Not set").tag(Int?.none)
                            ForEach(BottomSize.inseams, id: \.self) { Text("\($0) in").tag(Optional($0)) }
                        }
                    }
                    clearButton("Clear Bottom Size") { draft.bottom = nil }
                }
            } header: {
                Text("Bottoms")
            } footer: {
                Text("Pants, jeans, skirts, and shorts. Numeric sizes include their system, since a US 8 and an EU 8 aren't the same.")
            }

            Section {
                Picker("Sizing system", selection: shoeSystem) {
                    Text("Not set").tag(ShoeSize.System?.none)
                    ForEach(ShoeSize.System.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .accessibilityIdentifier("sizeShoeSystem")
                if let shoe = draft.shoe {
                    Picker("Size", selection: shoeValue) {
                        ForEach(shoe.system.values, id: \.self) { Text(ShoeSize.format($0)).tag($0) }
                    }
                    clearButton("Clear Shoe Size") { draft.shoe = nil }
                }
            } header: {
                Text("Shoes")
            }

            Section {
                Text("When a product in Shop This Look lists one of your sizes exactly, FitMix selects it for you. You can still pick a different size there.")
                    .font(.footnote)
                    .foregroundStyle(AuthPalette.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuthPalette.surface.ignoresSafeArea())
        .navigationTitle("Sizing Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasChanges)
        .toolbar {
            if hasChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!hasChanges || !draft.isValid)
                    .accessibilityIdentifier("sizeSave")
            }
        }
        .alert("Couldn't save your sizes", isPresented: Binding(get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } })) {
            Button("Try Again", action: save)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(saveFailure ?? "")
        }
        .onAppear {
            guard !loaded else { return }
            draft = profile.sizing
            loaded = true
        }
    }

    private func save() {
        do {
            try profile.saveSizing(draft)
            dismiss()
        } catch {
            saveFailure = error.localizedDescription
        }
    }

    private func clearButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, role: .destructive, action: action)
    }

    // MARK: Bindings that keep each size valid when its system changes

    private var bottomSystem: Binding<BottomSize.System?> {
        Binding(get: { draft.bottom?.system }, set: { system in
            guard system != draft.bottom?.system else { return }
            draft.bottom = system.map { BottomSize(system: $0, value: $0.defaultValue, inseam: nil) }
        })
    }

    private var bottomValue: Binding<String> {
        Binding(get: { draft.bottom?.value ?? "" }, set: { draft.bottom?.value = $0 })
    }

    private var bottomInseam: Binding<Int?> {
        Binding(get: { draft.bottom?.inseam }, set: { draft.bottom?.inseam = $0 })
    }

    private var shoeSystem: Binding<ShoeSize.System?> {
        Binding(get: { draft.shoe?.system }, set: { system in
            guard system != draft.shoe?.system else { return }
            draft.shoe = system.map { ShoeSize(system: $0, value: $0.defaultValue) }
        })
    }

    private var shoeValue: Binding<Double> {
        Binding(get: { draft.shoe?.value ?? 0 }, set: { draft.shoe?.value = $0 })
    }
}
