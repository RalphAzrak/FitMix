import SwiftUI
import UIKit

/// Screens Profile opens.
enum ProfileRoute: Hashable {
    case account, sizing, addresses, payments, orders, privacy
}

/// Profile: the signed-in account, the try-on photo, sizes, addresses, payments, orders, and
/// account security. Opened from the account button on My Avatar (via `AccountFlowView`).
struct ProfileView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(AvatarStore.self) private var avatar
    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss

    @State private var path: [ProfileRoute] = ProfileView.debugRoute.map { [$0] } ?? []
    @State private var confirmSignOut = false
    @State private var signingOut = false
    @State private var signOutFailure: String?
    @State private var showPasswordReset = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Profile")
                        .font(.fmDisplay(34, relativeTo: .largeTitle))
                        .foregroundStyle(AuthPalette.onSurface)
                        .accessibilityAddTraits(.isHeader)

                    if let user = auth.user { AccountCard(user: user) }
                    TryOnPhotoCard()
                    if case .failed(let message) = profile.state { loadFailure(message) }

                    ProfileSection(title: "Sizing Preferences") {
                        NavigationLink(value: ProfileRoute.sizing) {
                            ProfileRowLabel(icon: "ruler", title: "My Sizes", detail: sizingDetail)
                        }
                        .accessibilityIdentifier("profileSizes")
                    }

                    ProfileSection(title: "Shipping & Payment") {
                        NavigationLink(value: ProfileRoute.addresses) {
                            ProfileRowLabel(icon: "shippingbox", title: "Shipping Addresses", detail: addressDetail)
                        }
                        .accessibilityIdentifier("profileAddresses")
                        ProfileDivider()
                        NavigationLink(value: ProfileRoute.payments) {
                            ProfileRowLabel(icon: "creditcard", title: "Payment Methods", detail: "Not available yet")
                        }
                        .accessibilityIdentifier("profilePayments")
                    }

                    ProfileSection(title: "Order History") {
                        NavigationLink(value: ProfileRoute.orders) {
                            ProfileRowLabel(icon: "bag", title: "Orders", detail: "No FitMix orders yet")
                        }
                        .accessibilityIdentifier("profileOrders")
                    }

                    ProfileSection(title: "Account & Security") {
                        Button { showPasswordReset = true } label: {
                            ProfileRowLabel(icon: "key", title: "Change Password", detail: "We'll email you a link to set a new one")
                        }
                        ProfileDivider()
                        NavigationLink(value: ProfileRoute.privacy) {
                            ProfileRowLabel(icon: "hand.raised", title: "Privacy & Data", detail: "How your photo and details are stored")
                        }
                        .accessibilityIdentifier("profilePrivacy")
                        ProfileDivider()
                        Button { confirmSignOut = true } label: {
                            ProfileRowLabel(icon: "rectangle.portrait.and.arrow.right",
                                            title: signingOut ? "Signing out…" : "Sign Out",
                                            detail: nil, showsChevron: false, tint: .fmError)
                        }
                        .disabled(signingOut)
                        .accessibilityIdentifier("profileSignOut")
                    }
                    if let signOutFailure { NoticeRow(tone: .caution, text: signOutFailure) }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
            .defaultScrollAnchor(ProfileView.debugScrollToBottom ? .bottom : .top)
            .background(AuthPalette.surface.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("profileClose")
                }
            }
            .navigationTitle("Profile")
            .toolbarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .navigationDestination(for: ProfileRoute.self) { route in
                switch route {
                case .account: AccountDetailsView()
                case .sizing: SizingPreferencesView()
                case .addresses: AddressListView()
                case .payments: PaymentMethodsView()
                case .orders: OrderHistoryView()
                case .privacy: PrivacyDataView()
                }
            }
        }
        .tint(AuthPalette.primaryContainer)
        .preferredColorScheme(.light)
        .fullScreenCover(isPresented: $showPasswordReset) {
            ForgotPasswordView(email: auth.user?.email ?? "")
        }
        .confirmationDialog("Sign out of FitMix?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive, action: signOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your try-on photo and avatar stay on this iPhone. Your sizes and addresses come back when you sign in again here.")
        }
        .alert("Couldn't update your photo", isPresented: Binding(get: { avatar.storageErrorMessage != nil },
                                                                  set: { if !$0 { avatar.storageErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(avatar.storageErrorMessage ?? "")
        }
    }

    private var sizingDetail: String {
        if case .failed = profile.state { return "Couldn't load" }
        return profile.sizing.summary
    }

    private var addressDetail: String {
        if case .failed = profile.state { return "Couldn't load" }
        guard let address = profile.defaultAddress else { return "No saved addresses" }
        let more = profile.addresses.count - 1
        let line = "\(address.recipientName) · \(address.city)"
        return more > 0 ? "\(line) + \(more) more" : line
    }

    private func loadFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NoticeRow(tone: .caution, text: message)
            Button("Try Again") { profile.reload() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuthPalette.primaryContainer)
                .frame(minHeight: 44)
        }
        .profileCard()
    }

    private func signOut() {
        signingOut = true
        signOutFailure = nil
        Task {
            defer { signingOut = false }
            do {
                try await auth.signOut()
                // AccountFlowView switches back to Sign In.
            } catch {
                signOutFailure = AuthFailure(error).message
            }
        }
    }

    /// Debug builds: FM_DEBUG_PROFILE_SCROLL=bottom opens the overview scrolled to the end.
    private static var debugScrollToBottom: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["FM_DEBUG_PROFILE_SCROLL"] == "bottom"
        #else
        false
        #endif
    }

    /// Debug builds: FM_DEBUG_PROFILE_ROUTE=account | sizing | addresses | payments | orders | privacy.
    private static var debugRoute: ProfileRoute? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["FM_DEBUG_PROFILE_ROUTE"] {
        case "account": .account
        case "sizing": .sizing
        case "addresses": .addresses
        case "payments": .payments
        case "orders": .orders
        case "privacy": .privacy
        default: nil
        }
        #else
        nil
        #endif
    }
}

// MARK: Account card

private struct AccountCard: View {
    var user: AccountUser
    @ScaledMetric(relativeTo: .title2) private var badge: CGFloat = 56
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Stacks at accessibility text sizes so the name and Edit never break mid-word.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        layout {
            Text(user.initials)
                .font(.fmDisplay(21, relativeTo: .title3).weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: badge, height: badge)
                .background(AuthPalette.primaryContainer, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(user.displayName)
                    .font(.fmDisplay(21, relativeTo: .title3))
                    .foregroundStyle(AuthPalette.onSurface)
                if let email = user.email {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(AuthPalette.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let pending = user.pendingEmail {
                    Text("Confirming \(pending)")
                        .font(.footnote)
                        .foregroundStyle(Color.fmAmber)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            NavigationLink(value: ProfileRoute.account) {
                Text("Edit")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuthPalette.primaryContainer)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(AuthPalette.primaryContainer.opacity(0.1), in: Capsule())
                    .fixedSize()
            }
            .accessibilityLabel("Edit account details")
            .accessibilityIdentifier("profileEditAccount")
        }
        .profileCard()
    }
}

// MARK: Try-on photo

/// The user's full-body photo for try-on. It's the same photo the avatar and Studio use
/// (`AvatarStore.bodyPhoto`), and separate from the account's profile badge.
private struct TryOnPhotoCard: View {
    @Environment(AvatarStore.self) private var avatar
    @State private var request: PhotoSourceKind?
    @State private var candidate: AvatarStore.CheckedBodyPhoto?
    @State private var chooseReplacement = false
    @State private var confirmRemove = false
    @ScaledMetric(relativeTo: .body) private var previewWidth: CGFloat = 96
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("My Try-On Photo")
                    .font(.fmDisplay(21, relativeTo: .title3))
                    .foregroundStyle(AuthPalette.onSurface)
                    .accessibilityAddTraits(.isHeader)
                Text("Needed for virtual try-on.")
                    .font(.subheadline)
                    .foregroundStyle(AuthPalette.secondary)
            }
            if let photo = avatar.bodyPhoto {
                filled(photo)
            } else {
                empty
            }
        }
        .profileCard()
        .photoPicker(request: $request, camera: .rear) { image in
            Task { candidate = await avatar.checkBodyPhoto(image) }
        }
        .sheet(item: $candidate) { checked in
            PhotoConfirmSheet(title: "Try-on photo", image: checked.image, label: "Your new try-on photo",
                              notice: checked.analysis.notice, useLabel: "Use This Photo") {
                avatar.saveBodyPhoto(checked.image, analysis: checked.analysis)
            }
        }
        .confirmationDialog("Replace your try-on photo", isPresented: $chooseReplacement, titleVisibility: .visible) {
            Button("Take Photo") { request = .camera }
            Button("Choose from Library") { request = .library }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove your try-on photo?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Photo", role: .destructive) { avatar.removeBodyPhoto() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's deleted from this iPhone and Studio stops using it. Your avatar keeps its current shape until you add a new photo.")
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "figure.stand")
                    .font(.title2)
                    .foregroundStyle(AuthPalette.primaryContainer)
                    .frame(width: 44, height: 44)
                    .background(AuthPalette.containerLow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                Text("Use a clear, full-body photo to see outfits on yourself.")
                    .font(.body)
                    .foregroundStyle(AuthPalette.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { request = .camera } label: { Label("Take photo", systemImage: "camera") }
                .buttonStyle(AuthPrimaryButtonStyle())
                .accessibilityIdentifier("tryOnTakePhoto")
            Button { request = .library } label: { Label("Choose from library", systemImage: "photo.on.rectangle") }
                .buttonStyle(AuthSocialButtonStyle(background: AuthPalette.container, foreground: AuthPalette.onSurface))
                .accessibilityIdentifier("tryOnChooseLibrary")
        }
    }

    private func filled(_ photo: UIImage) -> some View {
        let notice = avatar.profile.photoAnalysis.notice
        let stacked = typeSize.isAccessibilitySize
        let width = stacked ? 160 : previewWidth
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                             : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        return layout {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: width * 4 / 3)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AuthPalette.containerHigh))
                .accessibilityLabel("Your try-on photo")
                .accessibilityIdentifier("tryOnPreview")
            VStack(alignment: .leading, spacing: 10) {
                NoticeRow(tone: notice.tone, text: notice.text)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Button { chooseReplacement = true } label: {
                    Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AuthPalette.primaryContainer)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("Replace try-on photo")
                .accessibilityIdentifier("tryOnReplace")
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label("Remove", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.fmError)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("Remove try-on photo")
                .accessibilityIdentifier("tryOnRemove")
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: Shared components

extension View {
    /// A rounded white card on the Profile background.
    func profileCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.fmCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.fmHairline))
    }
}

/// A titled group of rows in one white card.
struct ProfileSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Color.fmInk)
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .profileCard(padding: 0)
        }
    }
}

struct ProfileDivider: View {
    var body: some View {
        Rectangle().fill(AuthPalette.containerHigh).frame(height: 1).padding(.leading, 60)
    }
}

/// One compact row: icon, title, optional detail, and a chevron when it opens a screen.
struct ProfileRowLabel: View {
    var icon: String
    var title: String
    var detail: String?
    var showsChevron = true
    var tint: Color = AuthPalette.onSurface
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 32
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            // Decorative; dropped at accessibility text sizes to leave room for the words.
            if !typeSize.isAccessibilitySize { rowIcon }
            text
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AuthPalette.outline)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var rowIcon: some View {
        Image(systemName: icon)
            .font(.body)
            .foregroundStyle(tint == AuthPalette.onSurface ? AuthPalette.primaryContainer : tint)
            .frame(width: iconSize, height: iconSize)
            .background(AuthPalette.containerLow, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AuthPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A centred message for screens with nothing to show yet.
struct ProfileEmptyState<Actions: View>: View {
    var icon: String
    var title: String
    var message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(AuthPalette.primaryContainer)
                .accessibilityHidden(true)
            Text(title)
                .font(.fmDisplay(24, relativeTo: .title2))
                .foregroundStyle(AuthPalette.onSurface)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .foregroundStyle(AuthPalette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions.padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .profileCard()
    }
}

extension ProfileEmptyState where Actions == EmptyView {
    init(icon: String, title: String, message: String) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}
