import SwiftUI

@main struct MyApp: App {
    @State private var store = AvatarStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .preferredColorScheme(.light)
        }
    }
}
