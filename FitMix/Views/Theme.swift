import SwiftUI
import UIKit
import CoreText

// MARK: - Design tokens
//
// FitMix's look ("High-Energy Editorial"): white surfaces, cool-gray tiles with hairline borders,
// Playfair Display for titles, a cobalt gradient for the main action, and a lime dot for anything live.
// Every screen draws from these tokens; `AuthPalette` and the older `Color.fm*` names map onto them.

extension Color {
    // Surfaces
    /// Page background.
    static let fmBackground = Color(hex: 0xFFFFFF)
    /// Cards and tiles that sit on the page.
    static let fmCard = Color(hex: 0xF5F6F8)
    /// A tile inside a card.
    static let fmTile = Color(hex: 0xFFFFFF)
    /// Soft fill for chips, segmented tracks and secondary buttons.
    static let fmFill = Color(hex: 0xF1F2F5)
    /// Warm backdrop behind photos and portraits, like a studio wall.
    static let fmStudio = Color(hex: 0xECE7DF)
    /// 1-pt borders and dividers.
    static let fmHairline = Color(hex: 0xE4E6EB)

    // Text
    static let fmInk = Color(hex: 0x111214)
    static let fmSecondary = Color(hex: 0x6B7079)
    static let fmOutline = Color(hex: 0x9CA1AA)
    static let fmCharcoal = Color(hex: 0x1C1D20)

    // Accents
    /// Primary blue: selection, links, badges, the main action.
    static let fmCobalt = Color(hex: 0x2B54D6)
    /// Deeper blue for blue text on light backgrounds.
    static let fmCobaltDeep = Color(hex: 0x1E40B8)
    /// "Live" signal: the dot on status chips and garment hotspots.
    static let fmLime = Color(hex: 0xCDEB5B)

    // Status
    static let fmGreen = Color(hex: 0x1E8C55)
    static let fmAmber = Color(hex: 0xB7730D)
    static let fmError = Color(hex: 0xB8261F)

    init(hex: UInt32, opacity: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// The palette the account, auth and Studio screens were written against, mapped onto the shared tokens.
enum AuthPalette {
    static let surface = Color.fmBackground
    static let containerLowest = Color.white
    static let containerLow = Color.fmCard
    static let container = Color.fmFill
    static let containerHigh = Color.fmHairline
    static let onSurface = Color.fmInk
    static let secondary = Color.fmSecondary
    static let outline = Color.fmOutline
    static let primary = Color.fmCobaltDeep
    static let primaryContainer = Color.fmCobalt
}

extension ShapeStyle where Self == LinearGradient {
    /// The main action's fill: cobalt, a touch lighter at the top left.
    static var fmPrimaryGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x3863E4), Color(hex: 0x1F43BF)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Type

enum FMFonts {
    static let display = "PlayfairDisplay-Bold"
    static let displaySemibold = "PlayfairDisplay-SemiBold"

    /// Registers the bundled Playfair Display faces. Call once at launch; safe to call again.
    static func register() {
        for name in [display, displaySemibold] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Font {
    /// Editorial display serif for titles ("FitMix", "Look 01"). Scales with Dynamic Type.
    static func fmDisplay(_ size: CGFloat, semibold: Bool = false, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom(semibold ? FMFonts.displaySemibold : FMFonts.display, size: size, relativeTo: style)
    }

    /// Kept for existing call sites; same face as `fmDisplay`.
    static func fmSerif(_ size: CGFloat) -> Font { fmDisplay(size) }
    static let fmEyebrow = Font.system(size: 11, weight: .semibold)
}

/// Small uppercase label used above headings and in card corners.
struct Eyebrow: View {
    var text: String
    var color: Color = .fmSecondary

    var body: some View {
        Text(text.uppercased())
            .font(.fmEyebrow)
            .tracking(1.2)
            .foregroundStyle(color)
    }
}

/// A section's heading row: bold tracked caps on the left, an optional blue text action on the right.
struct FMSectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Color.fmInk)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 44)
    }
}

extension FMSectionHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// "Look 01 · STUDIO FIT": a display title followed by a small tracked caption.
struct FMTitleLine: View {
    var title: String
    var caption: String?
    var size: CGFloat = 30

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.fmDisplay(size))
                .foregroundStyle(Color.fmInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text("· " + caption.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Color.fmSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Surfaces

struct FMCard: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.fmCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.fmHairline))
    }
}

extension View {
    func fmCard(padding: CGFloat = 16) -> some View { modifier(FMCard(padding: padding)) }

    /// The large rounded frame used for hero photos: warm backdrop, 24-pt corners, soft lift.
    func fmHeroFrame() -> some View {
        self
            .background(Color.fmStudio)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.black.opacity(0.04)))
            .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }

    /// Soft lift for white floating controls.
    func fmFloatingShadow() -> some View {
        shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

// MARK: - Buttons

/// Full-width capsule for the main action. Cobalt uses the brand gradient and a soft blue glow;
/// any other color is a solid fill.
struct FMFilledButtonStyle: ButtonStyle {
    var color: Color = .fmCobalt
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isBrand = color == .fmCobalt
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                if isBrand { Capsule().fill(.fmPrimaryGradient) } else { Capsule().fill(color) }
            }
            .shadow(color: (isBrand ? Color.fmCobalt : .black).opacity(isEnabled ? 0.3 : 0), radius: 12, y: 6)
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Full-width capsule for lower-emphasis choices: soft gray with a hairline border.
struct FMOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.fmInk)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Color.fmFill.opacity(configuration.isPressed ? 0.6 : 1), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.fmHairline))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// White circle floating over a photo (zoom, switch view).
struct FMFloatingButton: View {
    var systemName: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.fmInk)
                .frame(width: 48, height: 48)
                .background(.white, in: Circle())
                .fmFloatingShadow()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 44-pt soft circle with a hairline, for toolbar-style actions (options, close, back).
struct FMRoundIconButton: View {
    var systemName: String
    var label: String
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) { FMRoundIcon(systemName: systemName).opacity(isEnabled ? 1 : 0.5) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}

/// The look of `FMRoundIconButton`, for use as a `Menu` label.
struct FMRoundIcon: View {
    var systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.fmInk)
            .frame(width: 44, height: 44)
            .background(Color.fmFill, in: Circle())
            .overlay(Circle().strokeBorder(Color.fmHairline))
            .contentShape(Circle())
    }
}

/// The shopping bag with a blue count badge. The badge hides at zero.
struct FMBagButton: View {
    var count: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bag")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.fmInk)
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(min(count, 99))")
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(minWidth: 20, minHeight: 20)
                            .padding(.horizontal, count > 9 ? 3 : 0)
                            .background(Color.fmCobalt, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white, lineWidth: 2))
                            .offset(x: 2, y: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shopping bag")
        .accessibilityValue(count == 1 ? "1 item" : "\(count) items")
        .accessibilityIdentifier("cartButton")
    }
}

// MARK: - Chips and markers

/// Capsule status chip: "● Live Twin", "● ⟲ Jeans Swapped".
struct FMChip: View {
    enum Style { case floating, soft }
    var text: String
    /// Leading dot color, e.g. lime for live, gray for off.
    var dot: Color?
    var icon: String?
    var style: Style = .floating

    var body: some View {
        HStack(spacing: 7) {
            if let dot {
                Circle().fill(dot).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.black.opacity(0.08)))
            }
            if let icon {
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.fmCobalt)
            }
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.fmInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 34)
        .background {
            switch style {
            case .floating: Capsule().fill(.white).fmFloatingShadow()
            case .soft: Capsule().fill(Color.fmFill).overlay(Capsule().strokeBorder(Color.fmHairline))
            }
        }
    }
}

/// Dark pill used as a tooltip over photos ("W32 L30 · Raw Denim").
struct FMTooltip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Color.fmCharcoal.opacity(0.9), in: Capsule())
    }
}

/// Lime dot ringed in cobalt that marks a garment on a photo.
struct FMHotspot: View {
    var body: some View {
        Circle()
            .fill(Color.fmLime)
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Color.fmCobalt, lineWidth: 2.5))
            .padding(2)
            .background(.white.opacity(0.6), in: Circle())
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}

// MARK: - Header

/// The top bar used across tabs: "FitMix" in the display serif, trailing actions, hairline underneath.
struct FMTopBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading
            Text("FitMix")
                .font(.fmDisplay(28, relativeTo: .title2))
                .foregroundStyle(Color.fmInk)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(Color.fmBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.fmHairline).frame(height: 1) }
    }
}

extension FMTopBar where Leading == EmptyView {
    init(@ViewBuilder trailing: () -> Trailing) { self.init(leading: { EmptyView() }, trailing: trailing) }
}

// MARK: - Notices

/// An inline notice with an icon: used for warnings, fallbacks, and check results.
struct NoticeRow: View {
    enum Tone { case good, caution, info }
    var tone: Tone
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).foregroundStyle(Color.fmInk)
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var icon: String {
        switch tone {
        case .good: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .good: .fmGreen
        case .caution: .fmAmber
        case .info: .fmSecondary
        }
    }
}

extension BodyPhotoAnalysis? {
    /// What the photo check found, in words. Only states what was actually checked.
    var notice: (tone: NoticeRow.Tone, text: String) {
        guard let self else { return (.info, "The photo check couldn't run on this device. Make sure your whole body is visible, head to shoes.") }
        if !self.personDetected { return (.caution, "No person found in this photo. Choose one that shows your whole body, head to shoes.") }
        if !self.fullBodyVisible { return (.caution, "Your whole body isn't visible from head to shoes, so the avatar may be less accurate.") }
        return (.good, "Full body found, head to shoes.")
    }
}
