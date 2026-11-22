import Foundation

// MARK: - Shopify product links
//
// A Studio Fit listing is just a retailer URL. When that URL is a product page on a Shopify store
// (`…/products/<handle>`), the store publishes the product's variants at `/products/<handle>.js`:
// a public, unauthenticated endpoint that every Shopify online store serves. FitMix reads it to turn
// "this listing" into one exact variant (size + colour) with a numeric variant ID, which is what a
// cart permalink and Checkout Kit need. No Storefront API token is involved. See Docs/Checkout.md.

/// A product page on a (probably) Shopify store, read from a listing URL.
nonisolated struct ShopifyProductLink: Equatable, Sendable {
    /// The host exactly as the listing used it, e.g. `www.frankandoak.com`. Custom domains work.
    var host: String
    var handle: String
    /// `?variant=` on the listing URL, when the listing pointed at one variant.
    var variantID: Int64?

    /// Reads `https://<store>/…/products/<handle>[?variant=<id>]`. Product search links
    /// (`google.com/goto?url=<listing>` or `/url?q=`) are unwrapped first.
    init?(url: URL) {
        var url = url
        if let host = url.host?.lowercased(), host == "google.com" || host.hasSuffix(".google.com"),
           let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
               .first(where: { $0.name == "url" || $0.name == "q" })?.value,
           let innerURL = URL(string: inner) {
            url = innerURL
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let parts = url.pathComponents
        guard let index = parts.lastIndex(of: "products"), index + 1 < parts.count else { return nil }
        var handle = parts[index + 1]
        for suffix in [".js", ".json", ".oembed"] where handle.hasSuffix(suffix) { handle.removeLast(suffix.count) }
        guard !handle.isEmpty, handle.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        self.host = host
        self.handle = handle
        self.variantID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "variant" }?.value.flatMap { Int64($0) }
    }

    var productDataURL: URL { URL(string: "https://\(host)/products/\(handle).js")! }
}

/// One product's purchasable variants, from the store's public product data.
nonisolated struct ShopifyProduct: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        var name: String
        /// The values real variants use, in the store's order. A store can list values in an option
        /// that no variant of this product has (Kotn lists every colour of the tee on each colour's
        /// product); those are left out, because they can't be bought here.
        var values: [String]
        var isColour: Bool { ["color", "colour", "couleur"].contains(name.lowercased()) }
        var isSize: Bool { ["size", "taille", "sizes"].contains(name.lowercased()) }
    }

    struct Variant: Equatable, Sendable, Identifiable {
        var id: Int64
        var title: String
        /// Values in the same order as `ShopifyProduct.options`.
        var values: [String]
        var available: Bool
        /// Price in the store's currency (the product data doesn't say which; checkout does).
        var price: Decimal?
    }

    var link: ShopifyProductLink
    var id: Int64
    var title: String
    var vendor: String?
    var imageURL: URL?
    var options: [Option]
    var variants: [Variant]

    /// Options the shopper has to choose (more than one value among real variants).
    var choices: [Int] { options.indices.filter { options[$0].values.count > 1 } }
    /// Options with a single value for every variant, e.g. a colour fixed by the listing.
    var fixed: [(name: String, value: String)] {
        options.indices.filter { options[$0].values.count == 1 }.map { (options[$0].name, options[$0].values[0]) }
    }
    /// True when no option names a colour: the store sells each colour as its own product, so the
    /// listing's URL itself fixes the colour.
    var colourIsFixedByListing: Bool { !options.contains(where: \.isColour) }

    /// The variant whose every option matches `selection` (option index → value), if exactly one does.
    func variant(for selection: [Int: String]) -> Variant? {
        let matches = variants.filter { variant in
            options.indices.allSatisfy { index in
                guard let picked = selection[index] else { return options[index].values.count == 1 }
                return variant.values.indices.contains(index) && variant.values[index] == picked
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Values of `option` that a real variant has, given the other picks.
    func values(for option: Int, given selection: [Int: String]) -> [(value: String, available: Bool)] {
        options[option].values.compactMap { value in
            let candidates = variants.filter { variant in
                guard variant.values.indices.contains(option), variant.values[option] == value else { return false }
                return selection.allSatisfy { index, picked in
                    index == option || !variant.values.indices.contains(index) || variant.values[index] == picked
                }
            }
            guard !candidates.isEmpty else { return nil }
            return (value, candidates.contains(where: \.available))
        }
    }

    /// Starting picks: the listing's own `?variant=` if it named one, then the shopper's saved size.
    func initialSelection(preferredSize: String?) -> [Int: String] {
        if let id = link.variantID, let variant = variants.first(where: { $0.id == id }) {
            return Dictionary(uniqueKeysWithValues: choices.compactMap { index in
                variant.values.indices.contains(index) ? (index, variant.values[index]) : nil
            })
        }
        var selection: [Int: String] = [:]
        if let preferredSize, let size = choices.first(where: { options[$0].isSize }),
           values(for: size, given: [:]).contains(where: { $0.value.caseInsensitiveCompare(preferredSize) == .orderedSame && $0.available }) {
            selection[size] = options[size].values.first { $0.caseInsensitiveCompare(preferredSize) == .orderedSame }
        }
        return selection
    }
}

// MARK: - Decoding the store's product data

/// `/products/<handle>.js`. Older themes return options as plain names; newer ones as objects.
nonisolated private struct ProductJS: Decodable {
    struct Option: Decodable {
        var name: String
        init(from decoder: Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.name = name
            } else {
                name = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .name)
            }
        }
        enum Keys: String, CodingKey { case name }
    }
    struct Variant: Decodable {
        var id: Int64
        var title: String
        var option1: String?
        var option2: String?
        var option3: String?
        var available: Bool?
        var price: Price?
    }
    /// Cents as a number in `.js`, a decimal string in `.json`.
    struct Price: Decodable {
        var amount: Decimal
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let cents = try? container.decode(Int.self) {
                amount = Decimal(cents) / 100
            } else {
                let text = try container.decode(String.self)
                guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "price")
                }
                amount = value
            }
        }
    }
    var id: Int64
    var title: String
    var vendor: String?
    var featured_image: String?
    var options: [Option]
    var variants: [Variant]
}

nonisolated enum ShopifyProductError: LocalizedError, Equatable {
    case notShopify, busy, offline, unavailable

    var errorDescription: String? {
        switch self {
        case .notShopify: "This retailer's sizes can't be read in FitMix. Choose them on the retailer's page."
        case .busy: "The store is busy right now. Wait a minute and try again."
        case .offline: "You're offline. Connect to the internet and try again."
        case .unavailable: "FitMix couldn't load this product's sizes. Try again."
        }
    }
}

nonisolated enum ShopifyProducts {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: configuration)
    }()

    /// Loads the product's real variants. Throws `.notShopify` when the page isn't Shopify product data.
    static func load(_ link: ShopifyProductLink, session: URLSession = session) async throws -> ShopifyProduct {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(from: link.productDataURL)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .dataNotAllowed {
            throw ShopifyProductError.offline
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ShopifyProductError.unavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw ShopifyProductError.busy }
        guard status == 200 else { throw status == 404 ? ShopifyProductError.notShopify : ShopifyProductError.unavailable }
        return try decode(data, link: link)
    }

    static func decode(_ data: Data, link: ShopifyProductLink) throws -> ShopifyProduct {
        guard let raw = try? JSONDecoder().decode(ProductJS.self, from: data), !raw.variants.isEmpty else {
            throw ShopifyProductError.notShopify
        }
        let variants = raw.variants.map { variant in
            ShopifyProduct.Variant(id: variant.id, title: variant.title,
                                   values: [variant.option1, variant.option2, variant.option3].prefix(raw.options.count).map { $0 ?? "" },
                                   available: variant.available ?? true, price: variant.price?.amount)
        }
        let options = raw.options.enumerated().map { index, option in
            var seen = Set<String>()
            let values = variants.compactMap { $0.values.indices.contains(index) ? $0.values[index] : nil }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            return ShopifyProduct.Option(name: option.name, values: values)
        }
        let image = raw.featured_image.flatMap { $0.hasPrefix("//") ? URL(string: "https:" + $0) : URL(string: $0) }
        return ShopifyProduct(link: link, id: raw.id, title: raw.title, vendor: raw.vendor, imageURL: image,
                              options: options, variants: variants)
    }
}
