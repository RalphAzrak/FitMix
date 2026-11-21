import SwiftUI

@main struct MyApp: App {
    @State private var store = AvatarStore()
    /// Restores any saved Supabase session at launch; the app still opens on My Avatar either way.
    @State private var auth = AuthSession()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .environment(auth)
                .preferredColorScheme(.light)
                // Password-reset links (fitmix://reset-password), including when the app was closed.
                .onOpenURL { auth.handle(url: $0) }
        }
    }
}
