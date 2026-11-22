import SafariServices
import SwiftUI

/// A store's own page, opened inside FitMix in Safari View (the store's secure site, with Safari's
/// padlock, autofill and the "Open in Safari" button). Done returns to FitMix. Nothing the shopper
/// does on the store's site is visible to FitMix.
struct RetailerBrowser: UIViewControllerRepresentable {
    var url: URL
    /// Whether the first page loaded. A store that won't load here can be opened in Safari instead.
    var onInitialLoad: (Bool) -> Void = { _ in }
    var onDone: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .done
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var parent: RetailerBrowser
        init(_ parent: RetailerBrowser) { self.parent = parent }

        func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) {
            parent.onInitialLoad(didLoadSuccessfully)
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { parent.onDone() }
    }
}

/// Hands a store page to Safari itself, for stores that won't work inside FitMix.
enum BrowserHandoff {
    @MainActor
    static func open(_ url: URL, store: String) {
        CheckoutLog.record("handoff-safari", store: store, note: "url=\(url.absoluteString)")
        UIApplication.shared.open(url)
    }
}
