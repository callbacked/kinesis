import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct AppearanceMenu: View {
    var compact = false
    @AppStorage("appearance") private var appearance = AppAppearance.system
    var body: some View {
        Menu {
            ForEach(AppAppearance.allCases) { option in
                Button { appearance = option } label: {
                    if appearance == option { Label(option.rawValue, systemImage: "checkmark") }
                    else { Text(option.rawValue) }
                }
            }
        } label: {
            if compact { Image(systemName: "circle.lefthalf.filled").font(.system(size: 15)) }
            else {
                HStack(spacing: 10) {
                    Image(systemName: "circle.lefthalf.filled").frame(width: 20)
                    Text("appearance")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }.font(.system(size: 12))
            }
        }.menuStyle(.button).buttonStyle(KinesisPressStyle()).menuIndicator(.hidden)
            .fixedSize(horizontal: compact, vertical: true).accessibilityLabel("Appearance")
    }
}

enum KinesisStyle {
    /// The window is one field of soft, cool tone, lighter at the top. Sheets use `paper`, its middle.
    static let fieldTop = adaptive(light: NSColor(red: 0.93, green: 0.934, blue: 0.942, alpha: 1), dark: NSColor(red: 0.142, green: 0.166, blue: 0.186, alpha: 1))
    static let fieldBottom = adaptive(light: NSColor(red: 0.858, green: 0.866, blue: 0.882, alpha: 1), dark: NSColor(red: 0.066, green: 0.077, blue: 0.087, alpha: 1))
    static let paper = adaptive(light: NSColor(red: 0.905, green: 0.91, blue: 0.92, alpha: 1), dark: NSColor(red: 0.1, green: 0.117, blue: 0.131, alpha: 1))
    /// The soft light an object sits in: the band, the hand.
    static let pool = adaptive(light: NSColor(white: 1, alpha: 0.78), dark: NSColor(red: 0.72, green: 0.84, blue: 0.95, alpha: 0.085))
    static let ink = adaptive(light: NSColor(red: 0.09, green: 0.1, blue: 0.118, alpha: 1), dark: NSColor(red: 0.925, green: 0.94, blue: 0.955, alpha: 1))
    static let secondary = adaptive(light: NSColor(red: 0.4, green: 0.425, blue: 0.46, alpha: 1), dark: NSColor(red: 0.585, green: 0.62, blue: 0.655, alpha: 1))
    static let surface = adaptive(light: NSColor(white: 1, alpha: 0.68), dark: NSColor(white: 1, alpha: 0.045))
    static let line = adaptive(light: NSColor(red: 0.1, green: 0.13, blue: 0.2, alpha: 0.1), dark: NSColor(white: 1, alpha: 0.09))
    static let green = adaptive(light: NSColor(red: 0.2, green: 0.56, blue: 0.4, alpha: 1), dark: NSColor(red: 0.56, green: 0.82, blue: 0.67, alpha: 1))
    static let blue = adaptive(light: NSColor(red: 0.1, green: 0.42, blue: 0.86, alpha: 1), dark: NSColor(red: 0.47, green: 0.74, blue: 0.99, alpha: 1))
    static let warning = adaptive(light: NSColor(red: 0.7, green: 0.36, blue: 0.12, alpha: 1), dark: NSColor(red: 0.95, green: 0.68, blue: 0.4, alpha: 1))
    /// The tray that holds pills, and the chip that marks the chosen one.
    static let tray = adaptive(light: NSColor(red: 0.1, green: 0.13, blue: 0.2, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.075))
    static let trayHover = adaptive(light: NSColor(red: 0.1, green: 0.13, blue: 0.2, alpha: 0.1), dark: NSColor(white: 1, alpha: 0.12))
    static let trayStrong = adaptive(light: NSColor(red: 0.1, green: 0.13, blue: 0.2, alpha: 0.17), dark: NSColor(white: 1, alpha: 0.2))
    static let chip = adaptive(light: NSColor(white: 1, alpha: 1), dark: NSColor(white: 1, alpha: 0.17))

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// The window's ground: one field of tone from edge to edge, with nothing boxed off.
struct Field: View {
    var body: some View {
        LinearGradient(colors: [KinesisStyle.fieldTop, KinesisStyle.fieldBottom], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// A pill. The key action is tinted with the accent. Everything else is a quiet tray.
struct KinesisButtonStyle: ButtonStyle {
    var prominent = false
    /// Fills the width it is given, as the band column's one button does.
    var wide = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        let lifted = hovered && enabled
        return configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: wide ? .infinity : nil)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .foregroundStyle(prominent ? KinesisStyle.blue : KinesisStyle.ink)
            .background(prominent ? KinesisStyle.blue.opacity(lifted ? 0.2 : 0.13) : (lifted ? KinesisStyle.trayHover : KinesisStyle.tray),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? KinesisStyle.blue.opacity(0.24) : .clear))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Capsule())
            .scaleEffect(reduceMotion || !enabled ? 1 : configuration.isPressed ? 0.975 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .onHover { hovered = $0 }
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .foregroundStyle(KinesisStyle.secondary)
    }
}

struct KinesisPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

struct BandArtwork: View {
    private static let image = Bundle.kinesis.url(forResource: "neural-band", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    var body: some View {
        GeometryReader { geometry in
            if let image = Self.image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }
        }.accessibilityLabel("Meta Neural Band product image")
    }
}

struct ConnectionBadge: View {
    let live: Bool
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(live ? KinesisStyle.green : KinesisStyle.secondary.opacity(0.6)).frame(width: 5, height: 5)
            Text(text.lowercased()).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(KinesisStyle.secondary)
        .accessibilityElement(children: .combine)
    }
}
