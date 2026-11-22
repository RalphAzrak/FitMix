import SwiftUI

/// Page 2 of FitMix's checkout: card, billing address, the total, and Pay.
///
/// Pay goes through `PaymentProcessor`. Today that's `DemoPaymentProcessor`: nothing leaves the phone
/// and nothing is charged. The card's digits live only in this page's state and are cleared after an
/// order; the order keeps only the brand and the last four digits.
struct PaymentView: View {
    var draft: CheckoutDraft
    var onFinish: () -> Void
    var processor: any PaymentProcessor = DemoPaymentProcessor()

    @Environment(CartStore.self) private var cart
    @Environment(OrderStore.self) private var orders
    @State private var card = CardInput()
    @State private var billingSameAsShipping = true
    @State private var billing = ShippingAddress()
    @State private var attempted = false
    @State private var paying = false
    @State private var declined: String?
    @State private var confirmation: OrderConfirmation?
    @State private var showConfirmation = false

    private var cardErrors: [CardInput.Field: String] { attempted ? card.errors() : [:] }
    private var billingErrors: [ShippingAddress.Field: String] { attempted && !billingSameAsShipping ? billing.errors() : [:] }
    private var isValid: Bool { card.errors().isEmpty && (billingSameAsShipping || billing.errors().isEmpty) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                CheckoutDemoBanner(text: "No real payment is taken. Use the test card 4242 4242 4242 4242 with any future date and any 3-digit code. 4000 0000 0000 0002 shows a declined card.")
                    .padding(.bottom, 8)
                cardSection
                billingSection
                totalSection
                if let declined {
                    NoticeRow(tone: .caution, text: declined)
                        .padding(.top, 4)
                        .accessibilityIdentifier("paymentDeclined")
                } else if attempted && !isValid {
                    NoticeRow(tone: .caution, text: "Check the highlighted fields above.").padding(.top, 4)
                }
                payButton.padding(.top, 12)
                Label("Card details stay on this iPhone in demo mode.", systemImage: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.fmSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(16)
            .disabled(paying)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.fmBackground.ignoresSafeArea())
        .navigationTitle("Payment")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(paying)
        .interactiveDismissDisabled(paying)
        .navigationDestination(isPresented: $showConfirmation) {
            if let confirmation { OrderConfirmationView(confirmation: confirmation, onFinish: onFinish) }
        }
    }

    // MARK: Sections

    private var cardSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FMSectionHeader(title: "Card") {
                HStack(spacing: 6) {
                    ForEach(["Visa", "Mastercard", "Amex"], id: \.self) { name in
                        Text(name.uppercased())
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(0.4)
                            .foregroundStyle(Color.fmSecondary)
                            .padding(.horizontal, 5)
                            .frame(minHeight: 18)
                            .background(Color.fmFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Visa, Mastercard and American Express accepted")
            }
            CardFormFields(card: $card, errors: cardErrors)
                .fmCard()
                .onChange(of: card) { declined = nil }
        }
    }

    private var billingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FMSectionHeader(title: "Billing address")
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Same as shipping address", isOn: $billingSameAsShipping.animation())
                    .font(.system(size: 15))
                    .tint(Color.fmCobalt)
                    .accessibilityIdentifier("paymentBillingSame")
                if billingSameAsShipping {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.address.recipientName).font(.system(size: 14, weight: .semibold))
                        Text(draft.address.streetLine).font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
                        Text(draft.address.cityLine).font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    AddressFormFields(address: $billing, errors: billingErrors, prefix: "billing")
                }
            }
            .fmCard()
        }
        .onAppear { if billing.street.isEmpty { billing = ShippingAddress(countryCode: draft.address.countryCode) } }
    }

    private var totalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FMSectionHeader(title: "Total")
            Group {
                if let totals = draft.totals {
                    OrderTotalsView(totals: totals)
                } else {
                    NoticeRow(tone: .caution, text: "This cart can't be paid in one checkout.")
                }
            }
            .fmCard()
        }
    }

    private var payButton: some View {
        Button(action: pay) {
            if paying {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Processing payment…")
                }
            } else {
                Label(draft.totals.map { "Pay \($0.format($0.total))" } ?? "Pay", systemImage: "lock.fill")
            }
        }
        .buttonStyle(FMFilledButtonStyle())
        .disabled(draft.totals == nil)
        .accessibilityIdentifier("paymentPay")
    }

    // MARK: Pay

    private func pay() {
        attempted = true
        declined = nil
        guard isValid, let totals = draft.totals, !paying else { return }
        paying = true
        let card = self.card
        let lines = draft.items
        Task {
            do {
                _ = try await processor.pay(amount: totals.total, currency: totals.currency, card: card)
            } catch is CancellationError {
                paying = false
                return
            } catch {
                declined = error.localizedDescription
                paying = false
                return
            }
            let order = DemoOrder(id: DemoOrder.newID(), placedAt: .now, lines: lines.map { DemoOrder.Line($0) }, totals: totals,
                                  delivery: draft.delivery, shippingAddress: draft.address,
                                  email: draft.contact.email.trimmingCharacters(in: .whitespaces),
                                  cardBrand: card.brand, cardLast4: card.last4)
            var saved = false
            var problem: String?
            do { saved = try orders.record(order) } catch { problem = error.localizedDescription }
            do { try cart.completeOrder(itemIDs: Set(lines.map(\.id))) } catch {
                problem = "The order went through, but your cart couldn't be updated: \(error.localizedDescription)"
            }
            self.card = CardInput()  // forget the digits as soon as they're no longer needed
            confirmation = OrderConfirmation(order: order, saved: saved, problem: problem)
            paying = false
            showConfirmation = true
        }
    }
}

/// What the confirmation page shows.
struct OrderConfirmation {
    var order: DemoOrder
    /// False when signed out (or saving failed): the order isn't in Order History.
    var saved: Bool
    var problem: String?
}
