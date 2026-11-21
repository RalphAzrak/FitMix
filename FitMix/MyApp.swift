import SwiftUI

@main struct MyApp: App {
    @State private var store = AvatarStore()
    /// Restores any saved Supabase session at launch; the app still opens on My Avatar either way.
    @State private var auth = AuthSession()
    /// The current Studio look; survives leaving and reopening Studio during the session.
    @State private var studio = StudioStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .environment(auth)
                .environment(studio)
                .preferredColorScheme(.light)
                // Password-reset links (fitmix://reset-password), including when the app was closed.
                .onOpenURL { auth.handle(url: $0) }
        }
    }
}
