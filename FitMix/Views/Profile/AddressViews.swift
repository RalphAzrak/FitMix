import SwiftUI

/// Saved shipping addresses: add, edit, remove, and choose the default.
struct AddressListView: View {
    @Environment(ProfileStore.self) private var profile
    @State private var editing: AddressEditorTarget?
    @State private var pendingDelete: ShippingAddress?
    @State private var failure: String?

    var body: some View {
        Group {
            if case .failed(let message) = profile.state {
                ScrollView {
                    ProfileEmptyState(icon: "exclamationmark.triangle", title: "Couldn't load addresses", message: message) {
                        Button("Try Again") { profile.reload() }
                            .buttonStyle(AuthPrimaryButtonStyle())
                    }
                    .padding(16)
                }
            } else if profile.addresses.isEmpty {
                ScrollView {
                    ProfileEmptyState(icon: "shippingbox", title: "No saved addresses",
                                      message: "Add where you'd like orders shipped. Your first address becomes the default.") {
                        Button { editing = .new } label: { Label("Add Address", systemImage: "plus") }
                            .buttonStyle(AuthPrimaryButtonStyle())
                            .accessibilityIdentifier("addressAddEmpty")
                    }
                    .padding(16)
                }
            } else {
                list
            }
        }
        .background(AuthPalette.surface.ignoresSafeArea())
        .navigationTitle("Shipping Addresses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if profile.state == .ready {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .new } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add address")
                        .accessibilityIdentifier("addressAdd")
                }
            }
        }
        .navigationDestination(item: $editing) { target in
            AddressEditorView(target: target)
        }
        .confirmationDialog("Remove this address?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { address in
            Button("Remove Address", role: .destructive) { remove(address) }
            Button("Cancel", role: .cancel) {}
        } message: { address in
            Text("\(address.recipientName), \(address.streetLine)")
        }
        .alert("Couldn't update addresses", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(profile.addresses) { address in
                    Button { editing = .edit(address) } label: { AddressRow(address: address, isDefault: profile.isDefault(address)) }
                        .foregroundStyle(AuthPalette.onSurface)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { pendingDelete = address } label: { Label("Remove", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            if !profile.isDefault(address) {
                                Button { setDefault(address) } label: { Label("Make Default", systemImage: "star") }
                                    .tint(AuthPalette.primaryContainer)
                            }
                        }
                        .accessibilityAction(named: "Remove") { pendingDelete = address }
                        .accessibilityActions {
                            if !profile.isDefault(address) {
                                Button("Make Default") { setDefault(address) }
                            }
                        }
                }
            } footer: {
                Text("Tap an address to edit it or make it your default. Swipe for quick actions.")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func setDefault(_ address: ShippingAddress) {
        do { try profile.setDefaultAddress(id: address.id) } catch { failure = error.localizedDescription }
    }

    private func remove(_ address: ShippingAddress) {
        do { try profile.deleteAddress(id: address.id) } catch { failure = error.localizedDescription }
    }
}

private struct AddressRow: View {
    var address: ShippingAddress
    var isDefault: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(address.recipientName).font(.body.weight(.semibold))
                    if isDefault {
                        Text("Default")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AuthPalette.primaryContainer)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(AuthPalette.primaryContainer.opacity(0.1), in: Capsule())
                    }
                }
                Text(address.streetLine)
                Text(address.cityLine)
                Text(address.countryName)
            }
            .font(.subheadline)
            .foregroundStyle(AuthPalette.onSurface)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AuthPalette.outline)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit address")
    }
}

enum AddressEditorTarget: Hashable {
    case new
    case edit(ShippingAddress)

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    private var key: String {
        switch self {
        case .new: "new"
        case .edit(let address): address.id.uuidString
        }
    }
}

/// Add or edit one address. Labels, region choices, and postal code rules follow the chosen country.
struct AddressEditorView: View {
    var target: AddressEditorTarget
    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss
    @State private var address = ShippingAddress()
    @State private var original = ShippingAddress()
    @State private var makeDefault = false
    @State private var loaded = false
    @State private var attempted = false
    @State private var saveFailure: String?
    @State private var confirmDelete = false
    @FocusState private var focus: ShippingAddress.Field?

    private var isNew: Bool { if case .new = target { true } else { false } }
    private var format: AddressFormat { address.format }
    private var errors: [ShippingAddress.Field: String] { attempted ? address.errors() : [:] }
    private var isCurrentDefault: Bool { !isNew && profile.isDefault(address) }
    private var hasChanges: Bool { loaded && (address != original || makeDefault) }

    var body: some View {
        Form {
            Section {
                Picker("Country or region", selection: country) {
                    ForEach(AddressFormat.countries, id: \.code) { Text($0.name).tag($0.code) }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("addressCountry")
            }

            Section {
                field("Recipient name", text: $address.recipientName, field: .recipient, content: .name)
                field("Street address", text: $address.street, field: .street, content: .streetAddressLine1)
                field("Apartment, suite, or unit (optional)", text: $address.unit, field: .unit, content: .streetAddressLine2)
                field(format.cityLabel, text: $address.city, field: .city, content: .addressCity)
                region
                field(format.postalLabel, text: $address.postalCode, field: .postalCode, content: .postalCode,
                      prompt: format.postalPrompt.isEmpty ? nil : format.postalPrompt,
                      keyboard: format.postalKeyboardIsNumeric ? .numbersAndPunctuation : .default,
                      capitalization: .characters)
            }

            if !isCurrentDefault {
                Section {
                    Toggle("Use as default address", isOn: $makeDefault)
                        .accessibilityIdentifier("addressMakeDefault")
                } footer: {
                    if isNew && profile.addresses.isEmpty { Text("Your first address is the default.") }
                }
            } else {
                Section { Label("This is your default address", systemImage: "star.fill").foregroundStyle(AuthPalette.secondary) }
            }

            if !isNew {
                Section {
                    Button("Remove Address", role: .destructive) { confirmDelete = true }
                        .accessibilityIdentifier("addressRemove")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuthPalette.surface.ignoresSafeArea())
        .navigationTitle(isNew ? "New Address" : "Edit Address")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasChanges)
        .toolbar {
            if hasChanges {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!hasChanges && !isNew)
                    .accessibilityIdentifier("addressSave")
            }
        }
        .confirmationDialog("Remove this address?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove Address", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't save this address", isPresented: Binding(get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } })) {
            Button("Try Again", action: save)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(saveFailure ?? "")
        }
        .onAppear(perform: load)
    }

    /// Changing country clears a province or state picked from the old country's list.
    private var country: Binding<String> {
        Binding(get: { address.countryCode }, set: { new in
            guard new != address.countryCode else { return }
            if format.regions != nil || AddressFormat.for(new).regions != nil { address.region = "" }
            address.countryCode = new
        })
    }

    @ViewBuilder
    private var region: some View {
        if let regions = format.regions {
            VStack(alignment: .leading, spacing: 4) {
                Picker(format.regionLabel, selection: $address.region) {
                    Text("Choose…").tag("")
                    ForEach(regions, id: \.code) { Text($0.name).tag($0.code) }
                }
                .accessibilityIdentifier("addressRegion")
                error(for: .region)
            }
        } else {
            field(format.regionLabel, text: $address.region, field: .region, content: .addressState)
        }
    }

    private func field(_ label: String, text: Binding<String>, field: ShippingAddress.Field, content: UITextContentType,
                       prompt: String? = nil, keyboard: UIKeyboardType = .default,
                       capitalization: TextInputAutocapitalization = .words) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AuthPalette.secondary)
                .accessibilityHidden(true)
            TextField(label, text: text, prompt: prompt.map { Text($0) })
                .textContentType(content)
                .keyboardType(keyboard)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled(field == .postalCode)
                .focused($focus, equals: field)
                .accessibilityLabel(label)
                .accessibilityValue(errors[field].map { "\(text.wrappedValue). \($0)" } ?? text.wrappedValue)
            error(for: field)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func error(for field: ShippingAddress.Field) -> some View {
        if let message = errors[field] {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color.fmError)
                .accessibilityHidden(true)
        }
    }

    private func load() {
        guard !loaded else { return }
        switch target {
        case .new:
            let region = Locale.current.region?.identifier
            address = ShippingAddress(countryCode: region.flatMap { code in AddressFormat.countries.contains { $0.code == code } ? code : nil } ?? "CA")
        case .edit(let saved):
            address = profile.addresses.first { $0.id == saved.id } ?? saved
        }
        original = address
        loaded = true
    }

    private func save() {
        attempted = true
        let problems = address.errors()
        guard problems.isEmpty else {
            let order: [ShippingAddress.Field] = [.recipient, .street, .city, .region, .postalCode]
            focus = order.first { problems[$0] != nil && $0 != .region }
            UIAccessibility.post(notification: .announcement, argument: "Check the highlighted fields.")
            return
        }
        do {
            try profile.saveAddress(address, makeDefault: makeDefault)
            dismiss()
        } catch {
            saveFailure = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try profile.deleteAddress(id: address.id)
            dismiss()
        } catch {
            saveFailure = error.localizedDescription
        }
    }
}
