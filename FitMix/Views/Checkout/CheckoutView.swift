import SwiftUI

/// What the shopper has entered so far, shared by the checkout and payment pages.
@Observable
final class CheckoutDraft {
    /// The cart lines being bought, as they were when checkout opened.
    var items: [CartItem] = []
    var contact = CheckoutContact()
    var address = ShippingAddress()
    /// The saved address the shipping fields came from, or nil for a new one.
    var savedAddressID: UUID?
    var saveAddress = false
    var delivery: DeliveryOption = .standard
    @ObservationIgnored private var loaded = false

    /// Fills the draft once: the cart's lines, the account's email, and the default saved address.
    func load(items: [CartItem], email: String?, defaultAddress: ShippingAddress?) {
        guard !loaded else { return }
        loaded = true
        self.items = items
        contact.email = email ?? ""
        if let defaultAddress { use(defaultAddress) } else { newAddress() }
    }

    func use(_ saved: ShippingAddress) {
        address = saved
        savedAddressID = saved.id
        saveAddress = false
    }

    func newAddress() {
        let region = Locale.current.region?.identifier
        address = ShippingAddress(countryCode: region.flatMap { code in AddressFormat.countries.contains { $0.code == code } ? code : nil } ?? "CA")
        savedAddressID = nil
    }

    var totals: OrderTotals? {
        guard let subtotal = CheckoutReadiness.subtotal(of: items) else { return nil }
        return OrderTotals(currency: subtotal.currency, subtotal: subtotal.amount, delivery: delivery, address: address.normalized())
    }
}

/// Page 1 of FitMix's checkout: contact, shipping address, delivery, and the order summary.
/// Continue goes to the payment page. Nothing is charged here.
struct CheckoutView: View {
    /// Closes checkout and returns to the cart (after an order, or from the confirmation).
    var onFinish: () -> Void

    @Environment(CartStore.self) private var cart
    @Environment(ProfileStore.self) private var profile
    @Environment(AuthSession.self) private var auth
    @State private var draft = CheckoutDraft()
    @State private var attempted = false
    @State private var showPayment = false
    @State private var saveNotice: String?

    private var contactErrors: [CheckoutContact.Field: String] { attempted ? draft.contact.errors() : [:] }
    private var addressErrors: [ShippingAddress.Field: String] { attempted ? draft.address.errors() : [:] }
    private var isValid: Bool { draft.contact.errors().isEmpty && draft.address.errors().isEmpty && draft.totals != nil }
    private var canSaveAddresses: Bool { profile.accountID != nil && profile.state == .ready }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                CheckoutDemoBanner(text: "This checkout is a demo. No payment is taken, and no store receives an order.")
                    .padding(.bottom, 8)
                contactSection
                shippingSection
                deliverySection
                summarySection
                if attempted && !isValid {
                    NoticeRow(tone: .caution, text: "Check the highlighted fields above.")
                        .padding(.top, 4)
                }
                if let saveNotice { NoticeRow(tone: .caution, text: saveNotice).padding(.top, 4) }
                Button(action: proceed) {
                    Label("Continue to Payment", systemImage: "creditcard")
                }
                .buttonStyle(FMFilledButtonStyle())
                .padding(.top, 12)
                .accessibilityIdentifier("checkoutContinue")
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.fmBackground.ignoresSafeArea())
        .navigationTitle("Checkout")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showPayment) { PaymentView(draft: draft, onFinish: onFinish) }
        .onAppear {
            draft.load(items: cart.items, email: auth.user?.email, defaultAddress: profile.defaultAddress)
        }
    }

    // MARK: Sections

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FMSectionHeader(title: "Contact")
            VStack(alignment: .leading, spacing: 14) {
                CheckoutField(label: "Email", text: $draft.contact.email, prompt: "name@example.com", content: .emailAddress,
                              keyboard: .emailAddress, capitalization: .never, error: contactErrors[.email],
                              identifier: "checkoutEmail")
                CheckoutField(label: "Phone", text: $draft.contact.phone, prompt: "514 555 0123", content: .telephoneNumber,
                              keyboard: .phonePad, capitalization: .never, error: contactErrors[.phone],
                              identifier: "checkoutPhone")
            }
            .fmCard()
        }
    }

    private var shippingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FMSectionHeader(title: "Ship to") {
                if !profile.addresses.isEmpty { savedAddressMenu }
            }
            VStack(alignment: .leading, spacing: 14) {
                AddressFormFields(address: $draft.address, errors: addressErrors, prefix: "shipping")
                if canSaveAddresses && draft.savedAddressID == nil {
                    Toggle("Save to my addresses", isOn: $draft.saveAddress)
                        .font(.system(size: 15))
                        .tint(Color.fmCobalt)
                        .accessibilityIdentifier("checkoutSaveAddress")
                }
            }
            .fmCard()
        }
    }

    private var savedAddressMenu: some View {
        Menu {
            ForEach(profile.addresses) { saved in
                Button {
                    draft.use(saved)
                } label: {
                    Text("\(saved.recipientName) · \(saved.streetLine)")
                }
            }
            Divider()
            Button("New address", systemImage: "plus") { draft.newAddress() }
        } label: {
            HStack(spacing: 4) {
                Text(draft.savedAddressID == nil ? "New address" : "Saved addresses")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.fmCobaltDeep)
        }
        .accessibilityIdentifier("checkoutSavedAddresses")
    }

    private var deliverySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FMSectionHeader(title: "Delivery")
            VStack(spacing: 0) {
                ForEach(DeliveryOption.allCases) { option in
                    Button {
                        draft.delivery = option
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: draft.delivery == option ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(draft.delivery == option ? Color.fmCobalt : Color.fmOutline)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.fmInk)
                                Text(option.detail).font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                            }
                            Spacer()
                            Text(draft.totals.map { $0.format(option.price) } ?? "")
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.fmInk)
                        }
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(draft.delivery == option ? .isSelected : [])
                    .accessibilityIdentifier("checkoutDelivery-\(option.rawValue)")
                    if option != DeliveryOption.allCases.last { Divider() }
                }
            }
            .fmCard(padding: 12)
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FMSectionHeader(title: "Order summary") {
                let pieces = draft.items.reduce(0) { $0 + $1.quantity }
                Text(pieces == 1 ? "1 piece" : "\(pieces) pieces")
                    .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(draft.items) { item in
                    OrderLineRow(line: DemoOrder.Line(item), currency: item.currencyCode)
                }
                if let totals = draft.totals {
                    Divider()
                    OrderTotalsView(totals: totals)
                }
            }
            .fmCard()
        }
    }

    // MARK: Actions

    private func proceed() {
        attempted = true
        guard isValid else { return }
        draft.address = draft.address.normalized()
        saveNotice = nil
        if draft.saveAddress && canSaveAddresses {
            do {
                try profile.saveAddress(draft.address)
                draft.savedAddressID = draft.address.id
                draft.saveAddress = false
            } catch {
                // Not saving the address never blocks checkout.
                saveNotice = "This address couldn't be saved to your profile: \(error.localizedDescription) You can still continue."
            }
        }
        showPayment = true
    }
}

/// Country, recipient, street, unit, city, province or state, and postal code, with the same rules as
/// Profile → Addresses (`ShippingAddress.errors()`, `AddressFormat`).
struct AddressFormFields: View {
    @Binding var address: ShippingAddress
    var errors: [ShippingAddress.Field: String]
    /// Distinguishes shipping and billing fields for UI tests.
    var prefix: String

    private var format: AddressFormat { address.format }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Country or region").font(.footnote.weight(.medium)).foregroundStyle(Color.fmSecondary)
                Picker("Country or region", selection: country) {
                    ForEach(AddressFormat.countries, id: \.code) { Text($0.name).tag($0.code) }
                }
                .pickerStyle(.navigationLink)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(Color.fmFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("\(prefix)Country")
            }
            CheckoutField(label: "Full name", text: $address.recipientName, content: .name, capitalization: .words,
                          error: errors[.recipient], identifier: "\(prefix)Name")
            CheckoutField(label: "Street address", text: $address.street, content: .streetAddressLine1, capitalization: .words,
                          error: errors[.street], identifier: "\(prefix)Street")
            CheckoutField(label: "Apartment, suite, or unit (optional)", text: $address.unit, content: .streetAddressLine2,
                          capitalization: .words, error: errors[.unit], identifier: "\(prefix)Unit")
            CheckoutField(label: format.cityLabel, text: $address.city, content: .addressCity, capitalization: .words,
                          error: errors[.city], identifier: "\(prefix)City")
            HStack(alignment: .top, spacing: 12) {
                region
                CheckoutField(label: format.postalLabel, text: $address.postalCode,
                              prompt: format.postalPrompt.isEmpty ? nil : format.postalPrompt, content: .postalCode,
                              keyboard: format.postalKeyboardIsNumeric ? .numbersAndPunctuation : .default,
                              capitalization: .characters, error: errors[.postalCode], identifier: "\(prefix)Postal")
            }
        }
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
            VStack(alignment: .leading, spacing: 6) {
                Text(format.regionLabel).font(.footnote.weight(.medium)).foregroundStyle(Color.fmSecondary)
                Picker(format.regionLabel, selection: $address.region) {
                    Text("Choose…").tag("")
                    ForEach(regions, id: \.code) { Text($0.name).tag($0.code) }
                }
                .pickerStyle(.menu)
                .tint(Color.fmInk)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 6)
                .background(Color.fmFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(errors[.region] == nil ? Color.fmHairline : Color.fmError))
                .accessibilityIdentifier("\(prefix)Region")
                if let message = errors[.region] {
                    Text(message).font(.footnote).foregroundStyle(Color.fmError).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            CheckoutField(label: format.regionLabel, text: $address.region, content: .addressState, capitalization: .words,
                          error: errors[.region], identifier: "\(prefix)Region")
        }
    }
}
