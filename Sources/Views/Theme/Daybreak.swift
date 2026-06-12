import SwiftUI
import UIKit

/// The Daybreak Bridge design language: one namespace for every color, font,
/// and gradient token, plus the card/button/chip styles built from them.
/// Screens compose these — no screen defines its own colors.
///
/// Every token carries two faces: Daybreak (light — dawn cream/blush) and
/// Nightfall (dark — dusk indigo, same warm sun accents). Tokens resolve per
/// the environment's color scheme, so screens get night mode for free.
enum Daybreak {
    // MARK: - Palette (light / dark)

    static let skyTop = Color(daybreakLight: 0xFDF3E7, dark: 0x2C2347)
    static let skyMid = Color(daybreakLight: 0xF7E3E0, dark: 0x1B1736)
    static let skyLow = Color(daybreakLight: 0xE8E6F7, dark: 0x121024)
    static let card = Color(daybreakLight: 0xFFFFFF, dark: 0x262145)

    /// Primary text.
    static let ink = Color(daybreakLight: 0x2A2440, dark: 0xEFECFA)
    /// Secondary text.
    static let mid = Color(daybreakLight: 0x75708C, dark: 0xA9A3C8)
    /// Tertiary text / section labels.
    static let faint = Color(daybreakLight: 0xAAA6BD, dark: 0x6E6890)
    /// Hairline separators.
    static let line = Color(daybreakLight: 0xECE9F4, dark: 0x37315C)
    /// Meter/strip track behind progress fills.
    static let track = Color(daybreakLight: 0xF3F0FB, dark: 0x322C52)

    /// CTA gradient endpoints — the sun stays the sun, day or night.
    static let sun = Color(daybreakHex: 0xFF9D5C)
    static let sunDeep = Color(daybreakHex: 0xF4753A)

    /// Links / secondary actions.
    static let plum = Color(daybreakLight: 0x6C5CE0, dark: 0x9D8FF5)

    static let ok = Color(daybreakLight: 0x2FA56F, dark: 0x4CC793)
    static let warn = Color(daybreakLight: 0xD98A1C, dark: 0xE8A94A)
    static let fail = Color(daybreakLight: 0xD9512C, dark: 0xE87355)

    /// Tinted chip backgrounds, paired with the colors above.
    static let okChipBackground = Color(daybreakLight: 0xE3F5EC, dark: 0x1E3A2E)
    static let warnChipBackground = Color(daybreakLight: 0xFBF0DC, dark: 0x3D2F17)
    static let failChipBackground = Color(daybreakLight: 0xFBE3DC, dark: 0x3D211A)
    static let newChipBackground = Color(daybreakLight: 0xEDE9FF, dark: 0x2D2756)

    /// Card drop shadow — plum haze by day, deeper black by night.
    static let cardShadow = Color(
        daybreakLight: 0x6C5CE0, lightAlpha: 0.16,
        dark: 0x000000, darkAlpha: 0.45
    )

    // MARK: - Sleep stage scale (shared by Google + Apple lanes)

    static let stageAwake = Color(daybreakHex: 0xFFB066)
    static let stageREM = Color(daybreakHex: 0xA88CF5)
    static let stageCore = Color(daybreakHex: 0x5FC6D8)
    static let stageDeep = Color(daybreakHex: 0x5F74E8)
    static let stageInBed = Color.gray.opacity(0.45)

    // MARK: - Gradients

    /// Full-screen background, top → bottom.
    static let sky = LinearGradient(
        colors: [skyTop, skyMid, skyLow],
        startPoint: .top, endPoint: .bottom
    )

    /// Primary-button fill.
    static let cta = LinearGradient(
        colors: [sun, sunDeep],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // MARK: - Typography (SF Rounded everywhere)

    static let titleFont = Font.system(size: 30, weight: .bold, design: .rounded)
    static let bodyFont = Font.system(.subheadline, design: .rounded)
    static let captionFont = Font.system(.caption, design: .rounded)
    static let chipFont = Font.system(size: 11.5, weight: .bold, design: .rounded)
    static let sectionLabelFont = Font.system(size: 11.5, weight: .semibold, design: .rounded)

    /// Big-number font for banners and stats; pair emphasis spans with `sunDeep`.
    static func numberFont(size: CGFloat = 44) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }
}

/// The user's appearance preference: follow the system, or pin one face.
enum DaybreakAppearance: String, CaseIterable, Identifiable {
    case system, day, night

    static let storageKey = "airkit.appearance"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "Match system"
        case .day: "Daybreak"
        case .night: "Nightfall"
        }
    }

    var detail: String {
        switch self {
        case .system: "Follows your iPhone's light and dark setting."
        case .day: "Always the warm morning look."
        case .night: "Always the dusk look — easy on night-shift eyes."
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .day: "sun.max.fill"
        case .night: "moon.stars.fill"
        }
    }

    /// `nil` means follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .day: .light
        case .night: .dark
        }
    }
}

extension Color {
    /// `Color(daybreakHex: 0x2A2440)` — sRGB from a 24-bit RGB literal.
    init(daybreakHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Dynamic token: resolves to `light` or `dark` per the trait environment.
    init(daybreakLight light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            let alpha = traits.userInterfaceStyle == .dark ? darkAlpha : lightAlpha
            return UIColor(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: alpha
            )
        })
    }
}

// MARK: - Card

struct DaybreakCardModifier: ViewModifier {
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Daybreak.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: Daybreak.cardShadow, radius: 15, y: 10)
    }
}

extension View {
    /// White rounded card with the Daybreak plum shadow.
    func daybreakCard(padding: CGFloat = 20) -> some View {
        modifier(DaybreakCardModifier(padding: padding))
    }

    /// Uppercase tracked section label ("READY FOR REVIEW").
    func daybreakSectionLabel() -> some View {
        font(Daybreak.sectionLabelFont)
            .textCase(.uppercase)
            .tracking(1.6)
            .foregroundStyle(Daybreak.faint)
    }

    /// Full-screen sky gradient behind the content.
    func daybreakBackground() -> some View {
        background(Daybreak.sky.ignoresSafeArea())
    }
}

// MARK: - Buttons

struct DaybreakPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Daybreak.cta, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Daybreak.sunDeep.opacity(0.45), radius: 14, y: 8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct DaybreakGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Daybreak.plum)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Daybreak.plum.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension ButtonStyle where Self == DaybreakPrimaryButtonStyle {
    static var daybreakPrimary: DaybreakPrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == DaybreakGhostButtonStyle {
    static var daybreakGhost: DaybreakGhostButtonStyle { .init() }
}

// MARK: - Chips

/// Tiny capsule status chip ("✓ checks pass", "new to Apple").
struct DaybreakChip: View {
    enum Status {
        case ok, warn, fail, new, neutral

        var foreground: Color {
            switch self {
            case .ok: Daybreak.ok
            case .warn: Daybreak.warn
            case .fail: Daybreak.fail
            case .new: Daybreak.plum
            case .neutral: Daybreak.mid
            }
        }

        var background: Color {
            switch self {
            case .ok: Daybreak.okChipBackground
            case .warn: Daybreak.warnChipBackground
            case .fail: Daybreak.failChipBackground
            case .new: Daybreak.newChipBackground
            case .neutral: Daybreak.line
            }
        }
    }

    let text: String
    let status: Status

    init(_ text: String, status: Status) {
        self.text = text
        self.status = status
    }

    var body: some View {
        Text(text)
            .font(Daybreak.chipFont)
            .foregroundStyle(status.foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(status.background, in: Capsule())
    }
}
