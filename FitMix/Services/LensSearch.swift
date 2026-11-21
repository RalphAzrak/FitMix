import Foundation

// MARK: - Google Lens product search (primary)
//
// For each garment crop from a scan, Studio asks the FitMix backend (`POST /v1/lens-search`), which asks Google
// Lens through Scrappa and returns the best credible retailer listing, or nothing. The backend holds
// SCRAPPA_API_KEY; the phone never sees it. Only the garment crop, its category and the on-device clues are
// sent. The backend caches answers per crop, joins duplicate in-flight searches and caps monthly usage, so
// reopening Studio or retrying doesn't spend extra credits.

/// `POST /v1/lens-search` on the FitMix backend. Answers `.lensMatch(listing)` or `.lensNoMatch`.
nonisolated struct LensRetailerSearch: RetailerSearching {
    var config: BackendConfig?
    var session: URLSession = BackendRetailerSearch.makeSession()

    private struct Response: Decodable {
        struct Listing: Decodable {
            struct Amount: Decodable { var value: String; var currency: String }
            var id: String
            var title: String
            var retailer: String
            var image_url: String?
            var url: String?
            var price: Amount?
            var brand: String?
            var evidence: [String]?
            var score: Double?
        }
        var status: String
        var result: Listing?
    }

    private struct Failure: Decodable {
        struct Detail: Decodable { var code: String; var message: String }
        var error: Detail
    }

    /// Backend error codes that mean the monthly allowance is used up: retrying won't help until it resets.
    static let limitCodes: Set<String> = ["provider_quota", "budget_exhausted"]

    func search(_ request: GarmentSearchRequest) async throws -> RetailerSearchOutcome {
        guard let config else {
            throw RetailerSearchError.lensFailed("No FitMix backend in this build (BackendConfig.current is nil).")
        }
        var form = MultipartForm()
        form.add(file: request.crop, name: "crop", fileName: "garment.jpg", type: "image/jpeg")
        form.add(value: request.category.rawValue, name: "category")
        let clues = request.clues
        if let color = clues.color { form.add(value: color, name: "color") }
        if !clues.text.isEmpty { form.add(value: clues.text.joined(separator: ","), name: "text") }
        if let pattern = clues.pattern { form.add(value: pattern, name: "pattern") }
        if let style = clues.style { form.add(value: style, name: "style") }

        var urlRequest = URLRequest(url: config.baseURL.appendingPathComponent("v1/lens-search"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        if let token = config.token, !token.isEmpty { urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.upload(for: urlRequest, from: form.finished())
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw RetailerSearchError.lensFailed(error.code == .timedOut ? "The search timed out."
                                                 : "FitMix couldn't reach its backend at \(config.baseURL.host() ?? "?").")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw RetailerSearchError.lensFailed("No response.") }
        guard http.statusCode == 200 else {
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            if let code = failure?.error.code, Self.limitCodes.contains(code) { throw RetailerSearchError.searchLimitReached }
            throw RetailerSearchError.lensFailed(failure.map { "\($0.error.code): \($0.error.message)" } ?? "HTTP \(http.statusCode)")
        }
        guard let body = try? JSONDecoder().decode(Response.self, from: data) else {
            throw RetailerSearchError.lensFailed("Unreadable response.")
        }
        guard body.status == "matched", let item = body.result, let listing = Self.listing(from: item) else { return .lensNoMatch }
        return .lensMatch(listing)
    }

    /// Nil unless the listing has a product link and a photo FitMix can show.
    private static func listing(from item: Response.Listing) -> RetailerListing? {
        guard let link = item.url.flatMap(URL.init(string:)), ["https", "http"].contains(link.scheme ?? ""),
              let photo = item.image_url.flatMap(URL.init(string:)), photo.scheme == "https" else { return nil }
        return RetailerListing(id: item.id, title: item.title, retailer: item.retailer, seller: nil,
                               imageURL: photo, listingURL: link,
                               price: item.price.flatMap { Decimal(string: $0.value, locale: Locale(identifier: "en_US_POSIX")) },
                               currency: item.price?.currency, tier: .similar, brand: item.brand,
                               evidence: item.evidence ?? [], provider: "google_lens", score: item.score ?? 0, isFixture: false)
    }
}
