import Foundation

// MARK: Sizing preferences

/// Letter sizes for tops, outerwear, and dresses. These are the same in every sizing system.
nonisolated enum LetterSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case xxs = "XXS", xs = "XS", s = "S", m = "M", l = "L", xl = "XL", xxl = "XXL", xxxl = "3XL"

    var id: String { rawValue }

    /// Other spellings retailers use for the same size, normalized (uppercased, no spaces).
    var aliases: Set<String> {
        switch self {
        case .xxs: ["XXS", "2XS"]
        case .xs: ["XS"]
        case .s: ["S", "SMALL"]
        case .m: ["M", "MEDIUM"]
        case .l: ["L", "LARGE"]
        case .xl: ["XL"]
        case .xxl: ["XXL", "2XL"]
        case .xxxl: ["3XL", "XXXL"]
        }
    }
}

/// The usual bottom size. Numeric sizes always carry their system, since "8" or "38" alone is ambiguous.
nonisolated struct BottomSize: Codable, Equatable, Sendable {
    enum System: String, Codable, CaseIterable, Sendable, Identifiable {
        case letter, waist, us, eu
        var id: String { rawValue }

        var title: String {
            switch self {
            case .letter: "Letter (S, M, L)"
            case .waist: "Waist (inches)"
            case .us: "US numeric"
            case .eu: "EU numeric"
            }
        }

        var values: [String] {
            switch self {
            case .letter: LetterSize.allCases.map(\.rawValue)
            case .waist: (24...46).map(String.init)
            case .us: ["00", "0"] + stride(from: 2, through: 24, by: 2).map(String.init)
            case .eu: stride(from: 30, through: 56, by: 2).map(String.init)
            }
        }

        var defaultValue: String {
            switch self {
            case .letter: "M"
            case .waist: "32"
            case .us: "8"
            case .eu: "38"
            }
        }
    }

    static let inseams = Array(26...38)

    var system: System
    var value: String
    /// Inches. Only used with `.waist`.
    var inseam: Int?

    var display: String {
        switch system {
        case .letter: value
        case .waist: inseam.map { "W\(value) L\($0)" } ?? "W\(value)"
        case .us: "US \(value)"
        case .eu: "EU \(value)"
        }
    }

    var isValid: Bool { system.values.contains(value) && (inseam.map(Self.inseams.contains) ?? true) && (system == .waist || inseam == nil) }
}

/// The usual shoe size, with its system: a US men's 9 and a US women's 9 are different shoes.
nonisolated struct ShoeSize: Codable, Equatable, Sendable {
    enum System: String, Codable, CaseIterable, Sendable, Identifiable {
        case usMen, usWomen, uk, eu
        var id: String { rawValue }

        var title: String {
            switch self {
            case .usMen: "US Men's"
            case .usWomen: "US Women's"
            case .uk: "UK"
            case .eu: "EU"
            }
        }

        var values: [Double] {
            switch self {
            case .usMen: Array(stride(from: 4.0, through: 16.0, by: 0.5))
            case .usWomen: Array(stride(from: 4.0, through: 13.0, by: 0.5))
            case .uk: Array(stride(from: 2.0, through: 14.0, by: 0.5))
            case .eu: Array(stride(from: 34.0, through: 50.0, by: 0.5))
            }
        }

        var defaultValue: Double {
            switch self {
            case .usMen: 10
            case .usWomen: 8
            case .uk: 8
            case .eu: 41
            }
        }

        /// Spellings retailers use for this system, normalized (uppercased, no spaces or apostrophes).
        var prefixes: [String] {
            switch self {
            case .usMen: ["USM", "USMEN", "USMENS", "MUS", "MENSUS"]
            case .usWomen: ["USW", "USWOMEN", "USWOMENS", "WUS", "WOMENSUS"]
            case .uk: ["UK"]
            case .eu: ["EU"]
            }
        }
    }

    var system: System
    var value: Double

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    var display: String { "\(system.title) \(Self.format(value))" }
    var isValid: Bool { system.values.contains(value) }
}

/// The signed-in user's usual sizes. Every field is optional and saved independently.
nonisolated struct SizingPreferences: Codable, Equatable, Sendable {
    var top: LetterSize?
    var bottom: BottomSize?
    var shoe: ShoeSize?

    var isEmpty: Bool { top == nil && bottom == nil && shoe == nil }

    /// One line for the Profile row, e.g. "Top M · Bottom W32 L30 · Shoe US Men's 10".
    var summary: String {
        var parts: [String] = []
        if let top { parts.append("Top \(top.rawValue)") }
        if let bottom { parts.append("Bottom \(bottom.display)") }
        if let shoe { parts.append("Shoe \(shoe.display)") }
        return parts.isEmpty ? "Add your usual sizes" : parts.joined(separator: " · ")
    }

    var isValid: Bool { (bottom?.isValid ?? true) && (shoe?.isValid ?? true) }

    /// The size from `sizes` (a product's listed sizes) that matches the saved preference for
    /// `category`, or nil when nothing matches unambiguously. Product sizes are free text, so only
    /// sizes that state the same system are matched (e.g. a saved "EU 41" never matches a bare "41").
    func preferredSize(among sizes: [String], for category: GarmentCategory) -> String? {
        switch category {
        case .jacket, .tshirt, .top, .dress:
            guard let top else { return nil }
            return sizes.first { top.aliases.contains(Self.normalize($0)) }
        case .pants, .skirt, .shorts, .bottoms:
            guard let bottom else { return nil }
            return sizes.first { Self.matches(bottom, Self.normalize($0)) }
        case .shoes:
            guard let shoe else { return nil }
            let value = ShoeSize.format(shoe.value)
            let accepted = Set(shoe.system.prefixes.map { $0 + value })
            return sizes.first { accepted.contains(Self.normalize($0)) }
        case .bag, .hat, .accessory, .other:
            return nil
        }
    }

    private static func normalize(_ size: String) -> String {
        size.uppercased()
            .replacingOccurrences(of: "×", with: "X")
            .filter { !$0.isWhitespace && $0 != "'" && $0 != "’" }
    }

    private static func matches(_ bottom: BottomSize, _ size: String) -> Bool {
        switch bottom.system {
        case .letter:
            return LetterSize(rawValue: bottom.value)?.aliases.contains(size) ?? false
        case .us:
            return size == "US" + bottom.value
        case .eu:
            return size == "EU" + bottom.value
        case .waist:
            // "32", "W32", "32X30", "W32L30", "32/30".
            let digits = size.split(whereSeparator: { !$0.isNumber }).map(String.init)
            let letters = size.filter { $0.isLetter }
            guard ["", "W", "X", "WL"].contains(letters) else { return false }
            guard let waist = digits.first, waist == bottom.value else { return false }
            switch (digits.count, bottom.inseam) {
            case (1, nil): return true
            case (2, let inseam?): return digits[1] == String(inseam)
            default: return false
            }
        }
    }
}

// MARK: Shipping addresses

nonisolated struct ShippingAddress: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var recipientName = ""
    var street = ""
    /// Apartment, suite, or unit. Optional.
    var unit = ""
    var city = ""
    /// Province or state code for countries with a fixed list (e.g. "QC"), otherwise free text.
    var region = ""
    var postalCode = ""
    /// ISO 3166-1 alpha-2, e.g. "CA".
    var countryCode = "CA"

    var format: AddressFormat { AddressFormat.for(countryCode) }

    /// "Montréal, QC H2X 1Y4"
    var cityLine: String {
        let regionPostal = [region, postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        return [city, regionPostal].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var streetLine: String { unit.isEmpty ? street : "\(street), \(unit)" }

    var countryName: String { Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode }

    /// Trims every field and puts the postal code in the country's standard form.
    func normalized() -> ShippingAddress {
        var copy = self
        copy.recipientName = recipientName.trimmed
        copy.street = street.trimmed
        copy.unit = unit.trimmed
        copy.city = city.trimmed
        copy.region = region.trimmed
        copy.postalCode = format.normalizePostal(postalCode.trimmed)
        return copy
    }

    /// Problems with each field, keyed by field. Empty means the address can be saved.
    func errors() -> [Field: String] {
        let address = normalized()
        let format = address.format
        var result: [Field: String] = [:]
        if address.recipientName.isEmpty { result[.recipient] = "Enter the recipient's name." }
        if address.street.isEmpty { result[.street] = "Enter a street address." }
        if address.city.isEmpty { result[.city] = "Enter a \(format.cityLabel.lowercased())." }
        if format.regionRequired, address.region.isEmpty {
            result[.region] = "Choose a \(format.regionLabel.lowercased())."
        } else if let regions = format.regions, !address.region.isEmpty, !regions.contains(where: { $0.code == address.region }) {
            result[.region] = "Choose a \(format.regionLabel.lowercased()) from the list."
        }
        if let error = format.postalError(address.postalCode, region: address.region) { result[.postalCode] = error }
        return result
    }

    enum Field: Hashable { case recipient, street, unit, city, region, postalCode, country }
}

/// Labels and validation rules for one country's addresses.
nonisolated struct AddressFormat: Sendable {
    struct Region: Hashable, Sendable {
        var code: String
        var name: String
    }

    var cityLabel = "City"
    var regionLabel = "State / Province / Region"
    var regionRequired = false
    /// A fixed list to pick from, or nil for free text.
    var regions: [Region]?
    var postalLabel = "Postal code"
    var postalPrompt = ""
    var postalRequired = false
    var postalKeyboardIsNumeric = false
    fileprivate var postalPattern: String?
    fileprivate var postalExample: String?
    fileprivate var postalNormalizer: (@Sendable (String) -> String)?
    /// Checks that the postal code belongs to the chosen region. Returns a message when it doesn't.
    fileprivate var regionCheck: (@Sendable (String, String) -> String?)?

    func normalizePostal(_ value: String) -> String { postalNormalizer?(value) ?? value }

    func postalError(_ value: String, region: String) -> String? {
        let value = normalizePostal(value.trimmed)
        if value.isEmpty { return postalRequired ? "Enter a \(postalLabel.lowercased())." : nil }
        if let postalPattern, value.wholeMatch(of: try! Regex(postalPattern)) == nil {
            return "Enter a \(postalLabel.lowercased()) like \(postalExample ?? "")."
        }
        return regionCheck?(value, region)
    }

    static func `for`(_ countryCode: String) -> AddressFormat {
        switch countryCode {
        case "CA": .canada
        case "US": .unitedStates
        case "GB": .unitedKingdom
        default: AddressFormat()
        }
    }

    static let canada: AddressFormat = {
        var format = AddressFormat()
        format.regionLabel = "Province or territory"
        format.regionRequired = true
        format.regions = [
            Region(code: "AB", name: "Alberta"), Region(code: "BC", name: "British Columbia"),
            Region(code: "MB", name: "Manitoba"), Region(code: "NB", name: "New Brunswick"),
            Region(code: "NL", name: "Newfoundland and Labrador"), Region(code: "NS", name: "Nova Scotia"),
            Region(code: "NT", name: "Northwest Territories"), Region(code: "NU", name: "Nunavut"),
            Region(code: "ON", name: "Ontario"), Region(code: "PE", name: "Prince Edward Island"),
            Region(code: "QC", name: "Quebec"), Region(code: "SK", name: "Saskatchewan"),
            Region(code: "YT", name: "Yukon"),
        ]
        format.postalLabel = "Postal code"
        format.postalPrompt = "A1A 1A1"
        format.postalRequired = true
        // Canada Post never uses D, F, I, O, Q, U, and W or Z never start a code.
        format.postalPattern = #"[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z] \d[ABCEGHJ-NPRSTV-Z]\d"#
        format.postalExample = "H3A 0G4"
        format.postalNormalizer = { value in
            let compact = value.uppercased().filter { $0.isLetter || $0.isNumber }
            guard compact.count == 6 else { return value.uppercased() }
            return "\(compact.prefix(3)) \(compact.suffix(3))"
        }
        format.regionCheck = { postal, region in
            // The first letter of a Canadian postal code identifies the province or territory.
            let byLetter: [Character: Set<String>] = [
                "A": ["NL"], "B": ["NS"], "C": ["PE"], "E": ["NB"], "G": ["QC"], "H": ["QC"], "J": ["QC"],
                "K": ["ON"], "L": ["ON"], "M": ["ON"], "N": ["ON"], "P": ["ON"], "R": ["MB"], "S": ["SK"],
                "T": ["AB"], "V": ["BC"], "X": ["NT", "NU"], "Y": ["YT"],
            ]
            guard !region.isEmpty, let first = postal.first, let allowed = byLetter[first], !allowed.contains(region) else { return nil }
            let name = AddressFormat.canada.regions?.first { $0.code == region }?.name ?? region
            return "This postal code isn't in \(name). Check the postal code or province."
        }
        return format
    }()

    static let unitedStates: AddressFormat = {
        var format = AddressFormat()
        format.regionLabel = "State"
        format.regionRequired = true
        let states: [(String, String)] = [
            ("AL", "Alabama"), ("AK", "Alaska"), ("AZ", "Arizona"), ("AR", "Arkansas"), ("CA", "California"),
            ("CO", "Colorado"), ("CT", "Connecticut"), ("DE", "Delaware"), ("DC", "District of Columbia"),
            ("FL", "Florida"), ("GA", "Georgia"), ("HI", "Hawaii"), ("ID", "Idaho"), ("IL", "Illinois"),
            ("IN", "Indiana"), ("IA", "Iowa"), ("KS", "Kansas"), ("KY", "Kentucky"), ("LA", "Louisiana"),
            ("ME", "Maine"), ("MD", "Maryland"), ("MA", "Massachusetts"), ("MI", "Michigan"), ("MN", "Minnesota"),
            ("MS", "Mississippi"), ("MO", "Missouri"), ("MT", "Montana"), ("NE", "Nebraska"), ("NV", "Nevada"),
            ("NH", "New Hampshire"), ("NJ", "New Jersey"), ("NM", "New Mexico"), ("NY", "New York"),
            ("NC", "North Carolina"), ("ND", "North Dakota"), ("OH", "Ohio"), ("OK", "Oklahoma"), ("OR", "Oregon"),
            ("PA", "Pennsylvania"), ("RI", "Rhode Island"), ("SC", "South Carolina"), ("SD", "South Dakota"),
            ("TN", "Tennessee"), ("TX", "Texas"), ("UT", "Utah"), ("VT", "Vermont"), ("VA", "Virginia"),
            ("WA", "Washington"), ("WV", "West Virginia"), ("WI", "Wisconsin"), ("WY", "Wyoming"),
            ("AS", "American Samoa"), ("GU", "Guam"), ("MP", "Northern Mariana Islands"), ("PR", "Puerto Rico"),
            ("VI", "U.S. Virgin Islands"), ("AA", "Armed Forces Americas"), ("AE", "Armed Forces Europe"),
            ("AP", "Armed Forces Pacific"),
        ]
        format.regions = states.map { Region(code: $0.0, name: $0.1) }
        format.postalLabel = "ZIP code"
        format.postalPrompt = "12345"
        format.postalRequired = true
        format.postalKeyboardIsNumeric = true
        format.postalPattern = #"\d{5}(-\d{4})?"#
        format.postalExample = "10001 or 10001-1234"
        return format
    }()

    static let unitedKingdom: AddressFormat = {
        var format = AddressFormat()
        format.cityLabel = "Town or city"
        format.regionLabel = "County (optional)"
        format.postalLabel = "Postcode"
        format.postalPrompt = "SW1A 1AA"
        format.postalRequired = true
        format.postalPattern = #"[A-Z]{1,2}\d[A-Z\d]? \d[A-Z]{2}"#
        format.postalExample = "SW1A 1AA"
        format.postalNormalizer = { value in
            let compact = value.uppercased().filter { $0.isLetter || $0.isNumber }
            guard (5...7).contains(compact.count) else { return value.uppercased() }
            return "\(compact.dropLast(3)) \(compact.suffix(3))"
        }
        return format
    }()

    /// Countries offered in the address form: Canada and the US first, then the rest by name.
    static let countries: [(code: String, name: String)] = {
        let pinned = ["CA", "US"]
        let all = Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
            .compactMap { code in Locale.current.localizedString(forRegionCode: code).map { (code: code, name: $0) } }
        let rest = all.filter { !pinned.contains($0.code) }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        return pinned.compactMap { code in all.first { $0.code == code } } + rest
    }()
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
