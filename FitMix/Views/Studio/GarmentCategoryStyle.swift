import SwiftUI

// MARK: - Garment category identity
//
// Every garment type has its own color and glyph, used the same way everywhere in Studio (photo
// outlines, cards, the avatar outfit board, jump chips), so a jacket never looks like a pair of pants.
// Cobalt stays reserved for selection and actions; these hues sit apart from it and from each other.

extension Color {
    /// Jackets, coats and hoodies: terracotta.
    static let fmJacket = Color(hex: 0xC4532D)
    /// Shirts and tops: teal.
    static let fmTop = Color(hex: 0x0E8580)
    /// Pants, shorts and skirts: plum.
    static let fmBottoms = Color(hex: 0x8E3A8C)
    /// Shoes: ochre.
    static let fmShoes = Color(hex: 0xB07800)
    /// Anything else (bags, hats, accessories).
    static let fmOtherGarment = Color(hex: 0x5E6470)
}

extension GarmentCategory {
    /// The family a garment belongs to: what its color, glyph and avatar slot follow.
    enum Family: Int, CaseIterable, Comparable {
        case jacket, top, bottoms, shoes, other

        static func < (lhs: Family, rhs: Family) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var family: Family {
        switch self {
        case .jacket: .jacket
        case .tshirt, .top, .dress: .top
        case .pants, .skirt, .shorts, .bottoms: .bottoms
        case .shoes: .shoes
        case .bag, .hat, .accessory, .other: .other
        }
    }

    var tint: Color { family.tint }

    /// Head-to-toe order, so lists always read jacket → top → pants → shoes.
    var bodyOrder: Int { family.rawValue }
}

extension GarmentCategory.Family {
    var tint: Color {
        switch self {
        case .jacket: .fmJacket
        case .top: .fmTop
        case .bottoms: .fmBottoms
        case .shoes: .fmShoes
        case .other: .fmOtherGarment
        }
    }

    /// Short caps label for badges.
    var badgeTitle: String {
        switch self {
        case .jacket: "Jacket"
        case .top: "Shirt"
        case .bottoms: "Pants"
        case .shoes: "Shoes"
        case .other: "Extra"
        }
    }
}

extension AvatarOutfitSlot {
    /// The garment family that fills this slot on the avatar.
    var family: GarmentCategory.Family {
        switch self {
        case .outerwear: .jacket
        case .tshirt: .top
        case .pants: .bottoms
        case .shoes: .shoes
        }
    }

    /// Head-to-toe, the order the outfit board shows the slots in.
    static let bodyOrder: [AvatarOutfitSlot] = [.outerwear, .tshirt, .pants, .shoes]
}

/// The garment's glyph. SF Symbols has no pants, so that one is drawn.
struct GarmentGlyph: View {
    var family: GarmentCategory.Family
    var size: CGFloat = 14
    var filled = true

    var body: some View {
        Group {
            switch family {
            case .bottoms:
                PantsShape()
                    .fill(style: FillStyle(eoFill: true))
                    .frame(width: size * 0.78, height: size)
            case .jacket: Image(systemName: filled ? "jacket.fill" : "jacket").font(.system(size: size * 0.92, weight: .semibold))
            case .top: Image(systemName: filled ? "tshirt.fill" : "tshirt").font(.system(size: size * 0.92, weight: .semibold))
            case .shoes: Image(systemName: filled ? "shoe.fill" : "shoe").font(.system(size: size * 0.92, weight: .semibold))
            case .other: Image(systemName: "sparkles").font(.system(size: size * 0.92, weight: .semibold))
            }
        }
        .frame(width: size * 1.25, height: size * 1.1)
        .accessibilityHidden(true)
    }
}

/// A simple pair of trousers: waistband, two legs, a gap between them.
struct PantsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        var path = Path()
        path.move(to: CGPoint(x: x + w * 0.08, y: y))
        path.addLine(to: CGPoint(x: x + w * 0.92, y: y))
        path.addLine(to: CGPoint(x: x + w, y: y + h))
        path.addLine(to: CGPoint(x: x + w * 0.58, y: y + h))
        path.addLine(to: CGPoint(x: x + w * 0.5, y: y + h * 0.36))
        path.addLine(to: CGPoint(x: x + w * 0.42, y: y + h))
        path.addLine(to: CGPoint(x: x, y: y + h))
        path.closeSubpath()
        return path
    }
}

/// "▮ JACKET": the category's glyph and name in its own color. `solid` is for use over photos.
struct GarmentCategoryBadge: View {
    var family: GarmentCategory.Family
    /// Overrides the family name, e.g. "T-shirt" or a garment label from search.
    var title: String? = nil
    var solid = false

    init(_ category: GarmentCategory, title: String? = nil, solid: Bool = false) {
        family = category.family
        self.title = title ?? (category.family == .other ? category.title : nil)
        self.solid = solid
    }

    init(family: GarmentCategory.Family, title: String? = nil, solid: Bool = false) {
        self.family = family
        self.title = title
        self.solid = solid
    }

    var body: some View {
        HStack(spacing: 5) {
            GarmentGlyph(family: family, size: 11)
            Text((title ?? family.badgeTitle).uppercased())
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.8)
                .lineLimit(1)
        }
        .foregroundStyle(solid ? .white : family.tint)
        .padding(.horizontal, 9)
        .frame(minHeight: 24)
        .background(solid ? AnyShapeStyle(family.tint) : AnyShapeStyle(family.tint.opacity(0.12)), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? family.badgeTitle)
    }
}
