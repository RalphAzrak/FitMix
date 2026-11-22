import SwiftUI

/// FitMix has no payment provider yet, so there's no way to add a card securely. This screen says
/// so instead of offering a card form that couldn't save anything safely.
struct PaymentMethodsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // When a provider is integrated: add cards through its SDK or hosted flow, and keep
                // only display details (brand, last four). Never store card numbers or CVVs.
                ProfileEmptyState(icon: "creditcard", title: "Payment methods aren't available yet",
                                  message: "FitMix doesn't take payments in the app yet, so there's no card to add. When you buy a piece now, you pay on the retailer's site.")
            }
            .padding(16)
        }
        .background(AuthPalette.surface.ignoresSafeArea())
        .navigationTitle("Payment Methods")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Demo orders placed through FitMix's demo checkout, newest first. Nothing was paid and no store
/// received them, and they're labelled that way. Purchases made on retailer sites never appear here.
struct OrderHistoryView: View {
    @Environment(DemoOrderStore.self) private var orders

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let loadError = orders.loadError {
                    NoticeRow(tone: .caution, text: loadError).fmCard()
                }
                if orders.orders.isEmpty {
                    ProfileEmptyState(icon: "bag", title: "No orders yet",
                                      message: "Demo orders placed through FitMix will appear here.")
                } else {
                    VStack(spacing: 12) {
                        ForEach(orders.orders) { order in
                            NavigationLink {
                                ScrollView { DemoOrderSummary(order: order).padding(16) }
                                    .background(AuthPalette.surface.ignoresSafeArea())
                                    .navigationTitle("Order Summary")
                                    .navigationBarTitleDisplayMode(.inline)
                            } label: { row(order) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("order-\(order.number)")
                        }
                    }
                }
                NoticeRow(tone: .info, text: "Purchases you make on a retailer's website, including from View at retailer, don't appear here automatically. Check your email or the retailer's account for those orders.")
                    .fixedSize(horizontal: false, vertical: true)
                    .fmCard()
            }
            .padding(16)
        }
        .background(AuthPalette.surface.ignoresSafeArea())
        .navigationTitle("Order History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ order: DemoOrder) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Order \(order.number)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.fmInk)
                    TagPill(text: "Demo")
                }
                Text(order.placedAt.formatted(date: .abbreviated, time: .omitted) + " · " + (order.pieces == 1 ? "1 piece" : "\(order.pieces) pieces"))
                    .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
            }
            Spacer()
            Text(order.savedTotals.isEmpty ? "No prices" : order.savedTotals.map(\.price.formatted).joined(separator: " · "))
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.fmInk)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.fmOutline)
        }
        .fmCard(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

/// How FitMix stores the try-on photo and the account's details, stated only as far as the app
/// actually does it today. Update this text if a try-on renderer that uploads photos is added
/// (`TryOnRenderers.current`) or if sizes and addresses move to the server.
struct PrivacyDataView: View {
    @Environment(ProfileStore.self) private var profile
    @State private var confirmDeleteSaved = false
    @State private var failure: String?
    @State private var deleted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                block(title: "Your try-on photo", icon: "figure.stand", paragraphs: [
                    "Your try-on photo is saved only on this iPhone, inside FitMix. It's encrypted while your iPhone is locked and isn't included in iCloud or computer backups. FitMix doesn't upload it.",
                    "FitMix uses it on this iPhone to check that your full body is visible, to shape your avatar, and as the starting picture when you try on outfits in Studio.",
                    "It belongs to this iPhone, not to your account. It stays here when you sign out, and anyone who uses FitMix on this iPhone can see it. Remove it any time from My Try-On Photo in Profile.",
                ])
                block(title: "Sizes and addresses", icon: "ruler", paragraphs: [
                    "Your sizing preferences and shipping addresses are saved on this iPhone and linked to your account. They only appear when you're signed in to this account, and they don't sync to your other devices yet.",
                ]) {
                    if deleted {
                        NoticeRow(tone: .good, text: "Your saved sizes and addresses were deleted from this iPhone.")
                    }
                    Button("Delete Saved Sizes and Addresses", role: .destructive) { confirmDeleteSaved = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.fmError)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("privacyDeleteSaved")
                }
                block(title: "Your account", icon: "person.crop.circle", paragraphs: [
                    "Your name and email are stored with your FitMix account (on Supabase, FitMix's sign-in service) so you can sign in and see them on any device.",
                ])
                block(title: "Deleting your account", icon: "person.crop.circle.badge.xmark", paragraphs: [
                    "Deleting your FitMix account isn't available in the app yet. Signing out doesn't delete it.",
                ])
            }
            .padding(16)
        }
        .background(AuthPalette.surface.ignoresSafeArea())
        .navigationTitle("Privacy & Data")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete your saved sizes and addresses?", isPresented: $confirmDeleteSaved, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do { try profile.deleteSavedData(); deleted = true } catch { failure = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes them from this iPhone for this account. It can't be undone.")
        }
        .alert("Couldn't delete", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func block(title: String, icon: String, paragraphs: [String]) -> some View {
        block(title: title, icon: icon, paragraphs: paragraphs) { EmptyView() }
    }

    private func block<Extra: View>(title: String, icon: String, paragraphs: [String], @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title).font(.fmDisplay(18, semibold: true, relativeTo: .headline))
            } icon: {
                Image(systemName: icon).foregroundStyle(AuthPalette.primaryContainer)
            }
            .accessibilityAddTraits(.isHeader)
            ForEach(paragraphs, id: \.self) { text in
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(AuthPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            extra()
        }
        .foregroundStyle(AuthPalette.onSurface)
        .fmCard()
    }
}
