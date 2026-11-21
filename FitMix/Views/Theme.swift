import SwiftUI

extension Color {
    static let fmBackground = Color(red: 0.961, green: 0.949, blue: 0.925)
    static let fmCard = Color(red: 0.925, green: 0.914, blue: 0.890)
    static let fmTile = Color(red: 0.969, green: 0.961, blue: 0.945)
    static let fmCharcoal = Color(red: 0.125, green: 0.125, blue: 0.13)
    static let fmCobalt = Color(red: 0.11, green: 0.27, blue: 0.82)
    static let fmInk = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let fmSecondary = Color(red: 0.42, green: 0.40, blue: 0.37)
    static let fmStudio = Color(red: 0.914, green: 0.902, blue: 0.875)
    static let fmHairline = Color.black.opacity(0.07)
    static let fmGreen = Color(red: 0.13, green: 0.55, blue: 0.33)
    static let fmAmber = Color(red: 0.72, green: 0.45, blue: 0.05)
    static let fmError = Color(red: 0.72, green: 0.15, blue: 0.12)
}

extension Font {
    static func fmSerif(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static let fmEyebrow = Font.system(size: 11, weight: .semibold)
}

/// Small uppercase label used above headings and in card corners.
struct Eyebrow: View {
    var text: String
    var color: Color = .fmSecondary

    var body: some View {
        Text(text.uppercased())
            .font(.fmEyebrow)
            .tracking(1.4)
            .foregroundStyle(color)
    }
}

struct FMCard: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.fmCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.fmHairline))
    }
}

extension View {
    func fmCard(padding: CGFloat = 16) -> some View { modifier(FMCard(padding: padding)) }
}

/// Full-width filled button: cobalt for the primary action, charcoal for the secondary one.
struct FMFilledButtonStyle: ButtonStyle {
    var color: Color = .fmCobalt
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(color.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Full-width outlined button for lower-emphasis choices.
struct FMOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.fmInk)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.fmTile.opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.14)))
    }
}

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
        guard let self else { return (.info, "The photo check couldn't run on this device. Body shape will use height and weight only.") }
        if !self.personDetected { return (.caution, "No person found in this photo. Body shape will use height and weight only.") }
        if !self.fullBodyVisible { return (.caution, "Your full body isn't visible from head to feet. Body shape will use height and weight only.") }
        return (.good, "Full body found, head to feet.")
    }
}
