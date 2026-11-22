import SwiftUI

/// Page 3 of FitMix's checkout: the order is confirmed. Back is hidden; Done returns to the cart.
struct OrderConfirmationView: View {
    var confirmation: OrderConfirmation
    var onFinish: () -> Void
    @Environment(AuthSession.self) private var auth

    private var order: DemoOrder { confirmation.order }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.fmGreen)
                        .accessibilityHidden(true)
                    Text(auth.user.map { "Thank you, \($0.displayName.split(separator: " ").first.map(String.init) ?? $0.displayName)" } ?? "Thank you")
                        .font(.fmDisplay(28))
                        .foregroundStyle(Color.fmInk)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 6) {
                        Text("Order \(order.id)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.fmSecondary)
                        TagPill(text: "Demo")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("confirmationOrderID")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

                NoticeRow(tone: .info, text: "This was a demo order: no payment was taken and no store received it.")
                    .fixedSize(horizontal: false, vertical: true)
                    .fmCard(padding: 12)
                if let problem = confirmation.problem {
                    NoticeRow(tone: .caution, text: problem).fixedSize(horizontal: false, vertical: true).fmCard(padding: 12)
                } else if !confirmation.saved {
                    NoticeRow(tone: .caution, text: "You're not signed in, so this order isn't saved to Order History.")
                        .fixedSize(horizontal: false, vertical: true)
                        .fmCard(padding: 12)
                }

                OrderReceiptView(order: order)

                VStack(spacing: 10) {
                    if confirmation.saved {
                        NavigationLink {
                            OrderHistoryView()
                        } label: {
                            Text("View in Order History")
                        }
                        .buttonStyle(FMOutlineButtonStyle())
                        .accessibilityIdentifier("confirmationHistory")
                    }
                    Button("Done", action: onFinish)
                        .buttonStyle(FMFilledButtonStyle())
                        .accessibilityIdentifier("confirmationDone")
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Color.fmBackground.ignoresSafeArea())
        .navigationTitle("Order Confirmed")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }
}

/// An order's items, delivery, payment and totals. Shared by the confirmation and Order History.
struct OrderReceiptView: View {
    var order: DemoOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FMSectionHeader(title: "Items") {
                Text(order.itemCount == 1 ? "1 piece" : "\(order.itemCount) pieces")
                    .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(order.lines.enumerated()), id: \.offset) { _, line in
                    OrderLineRow(line: line, currency: order.totals.currency)
                }
            }
            .fmCard()

            FMSectionHeader(title: "Delivery")
            VStack(alignment: .leading, spacing: 10) {
                detail(icon: "shippingbox", title: "\(order.delivery.title) · \(order.delivery.detail)",
                       lines: [order.shippingAddress.recipientName, order.shippingAddress.streetLine,
                               order.shippingAddress.cityLine, order.shippingAddress.countryName])
                detail(icon: "envelope", title: order.email, lines: [])
            }
            .fmCard()

            FMSectionHeader(title: "Payment")
            VStack(alignment: .leading, spacing: 12) {
                detail(icon: "creditcard", title: "\(order.cardBrand.name) •••• \(order.cardLast4)",
                       lines: [order.placedAt.formatted(date: .abbreviated, time: .shortened)])
                Divider()
                OrderTotalsView(totals: order.totals)
            }
            .fmCard()
        }
    }

    private func detail(icon: String, title: String, lines: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.fmSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmInk)
                ForEach(lines.filter { !$0.isEmpty }, id: \.self) { line in
                    Text(line).font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One line of an order: picture, name, options, shop, quantity and price.
struct OrderLineRow: View {
    var line: DemoOrder.Line
    /// The order's currency. Nil hides the price.
    var currency: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(line.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.fmInk)
                    .lineLimit(2)
                if let detail = line.detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                }
                if let retailer = line.retailer {
                    Text(retailer).font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let currency {
                    Text(Money.format(line.unitPrice * Decimal(line.quantity), currency))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.fmInk)
                }
                if line.quantity > 1 {
                    Text("Qty \(line.quantity)").font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var thumbnail: some View {
        AsyncImage(url: line.imageURL) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFit().padding(4)
            } else {
                Image(systemName: "tshirt").font(.system(size: 18)).foregroundStyle(Color.fmOutline)
            }
        }
        .frame(width: 52, height: 60)
        .background(Color.fmFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Subtotal, delivery, tax estimate and total.
struct OrderTotalsView: View {
    var totals: OrderTotals

    var body: some View {
        VStack(spacing: 8) {
            row("Subtotal", totals.format(totals.subtotal))
            row("Delivery", totals.format(totals.shipping))
            if let tax = totals.tax {
                row("Tax (est., \(totals.taxLabel ?? "sales tax"))", totals.format(tax))
            } else {
                row("Tax", "Calculated by the store")
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Total").font(.system(size: 17, weight: .bold))
                Spacer()
                Text(totals.format(totals.total)).font(.system(size: 20, weight: .bold).monospacedDigit())
            }
            .foregroundStyle(Color.fmInk)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("orderTotal")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
            Spacer()
            Text(value).font(.system(size: 14).monospacedDigit()).foregroundStyle(Color.fmInk)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One past order, from Profile → Order History.
struct OrderDetailView: View {
    var order: DemoOrder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                NoticeRow(tone: .info, text: "Demo order: no payment was taken and no store received it.")
                    .fixedSize(horizontal: false, vertical: true)
                    .fmCard(padding: 12)
                OrderReceiptView(order: order)
            }
            .padding(16)
        }
        .background(Color.fmBackground.ignoresSafeArea())
        .navigationTitle("Order \(order.id)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
