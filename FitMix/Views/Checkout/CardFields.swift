import SwiftUI

// MARK: - Shared checkout components

/// A labelled field on a soft fill, with its error underneath. Used across checkout and payment.
struct CheckoutField: View {
    var label: String
    @Binding var text: String
    var prompt: String?
    var content: UITextContentType?
    var keyboard: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .sentences
    var error: String?
    /// Short text shown at the end of the field, e.g. the card brand.
    var accessory: String?
    var identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.fmSecondary)
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                TextField(label, text: $text, prompt: prompt.map { Text($0).foregroundStyle(Color.fmOutline) })
                    .textContentType(content)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(capitalization)
                    .autocorrectionDisabled()
                    .font(.system(size: 16))
                    .foregroundStyle(Color.fmInk)
                    .accessibilityLabel(label)
                    .accessibilityValue(error.map { "\(text). \($0)" } ?? text)
                    .accessibilityIdentifier(identifier)
                if let accessory {
                    Text(accessory)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.fmCobaltDeep)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(Color.fmFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(error == nil ? Color.fmHairline : Color.fmError, lineWidth: error == nil ? 1 : 1.5))
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color.fmError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Says plainly that this checkout takes no real payment. Shown at the top of every checkout page.
struct CheckoutDemoBanner: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "testtube.2")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.fmAmber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(text: "Demo checkout", color: .fmAmber)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.fmInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.fmAmber.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.fmAmber.opacity(0.3)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("checkoutDemoBanner")
    }
}

// MARK: - Card form

/// Card number (grouped as typed, brand shown), expiry (MM/YY), security code and name on card.
/// The values stay in the payment page's state only.
struct CardFormFields: View {
    @Binding var card: CardInput
    var errors: [CardInput.Field: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CheckoutField(label: "Card number", text: number, prompt: "1234 1234 1234 1234", content: .creditCardNumber,
                          keyboard: .numberPad, capitalization: .never, error: errors[.number],
                          accessory: card.number.isEmpty || card.brand == .unknown ? nil : card.brand.name.uppercased(),
                          identifier: "cardNumber")
            HStack(alignment: .top, spacing: 12) {
                CheckoutField(label: "Expiry", text: expiry, prompt: "MM/YY", content: .creditCardExpiration,
                              keyboard: .numberPad, capitalization: .never, error: errors[.expiry], identifier: "cardExpiry")
                CheckoutField(label: "Security code", text: $card.cvc, prompt: card.brand == .amex ? "1234" : "123",
                              content: .creditCardSecurityCode, keyboard: .numberPad, capitalization: .never,
                              error: errors[.cvc], identifier: "cardCVC")
            }
            CheckoutField(label: "Name on card", text: $card.name, prompt: "As printed on the card", content: .creditCardName,
                          capitalization: .words, error: errors[.name], identifier: "cardName")
        }
    }

    private var number: Binding<String> {
        Binding(get: { CardInput.formatNumber(card.number) }, set: { card.number = $0 })
    }

    private var expiry: Binding<String> {
        Binding(get: { card.expiry }, set: { card.expiry = CardInput.formatExpiry($0) })
    }
}
