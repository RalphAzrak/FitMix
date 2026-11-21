import SwiftUI

@main struct MyApp: App {
    @State private var store = AvatarStore()
    /// Restores any saved Supabase session at launch; the app still opens on My Avatar either way.
    @State private var auth = AuthSession()
    /// The current Studio look; survives leaving and reopening Studio during the session.
    @State private var studio = StudioStore()
    /// The signed-in account's sizes and addresses. Follows whoever is signed in.
    @State private var profile = ProfileStore()

    init() { FMFonts.register() }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environment(store)
                .environment(auth)
                .environment(studio)
                .environment(profile)
                .preferredColorScheme(.light)
                // Auth email links (fitmix://reset-password, confirm-email, email-change), including when the app was closed.
                .onOpenURL { auth.handle(url: $0) }
                #if DEBUG
                // Debug builds only: FM_DEBUG_OPEN_URL feeds a link to the same handler at launch, so
                // link states can be checked without tapping the system "Open in FitMix?" prompt.
                .task {
                    if let raw = ProcessInfo.processInfo.environment["FM_DEBUG_OPEN_URL"], let url = URL(string: raw) {
                        auth.handle(url: url)
                    }
                }
                #endif
                // Only the signed-in account's saved data is ever loaded; signing out clears it from memory.
                .onChange(of: auth.user?.id, initial: true) { _, id in profile.activate(accountID: id) }
                // Studio always renders from the current try-on photo, including after it's replaced or removed.
                .onChange(of: store.bodyPhoto) { _, photo in studio.useTryOnPhoto(photo) }
        }
    }
}
