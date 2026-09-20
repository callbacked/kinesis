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
        if compact {
            menu.buttonStyle(KinesisIconStyle())
        } else {
            menu.buttonStyle(KinesisPressStyle())
        }
    }

    private var menu: some View {
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
        }.menuStyle(.button).menuIndicator(.hidden)
            .fixedSize(horizontal: compact, vertical: true).accessibilityLabel("Appearance")
    }
}

/// Graphite for the ground, the way the band's weave is graphite, and one blue accent.
/// The band's bronze stays the only warm thing on screen.
enum KinesisStyle {
    /// The window is one field of soft tone, lighter at the top. Sheets use `paper`, its middle.
    static let fieldTop = adaptive(light: NSColor(red: 0.95, green: 0.951, blue: 0.953, alpha: 1), dark: NSColor(red: 0.118, green: 0.123, blue: 0.128, alpha: 1))
    static let fieldBottom = adaptive(light: NSColor(red: 0.868, green: 0.871, blue: 0.876, alpha: 1), dark: NSColor(red: 0.05, green: 0.053, blue: 0.057, alpha: 1))
    static let paper = adaptive(light: NSColor(red: 0.918, green: 0.92, blue: 0.924, alpha: 1), dark: NSColor(red: 0.09, green: 0.094, blue: 0.099, alpha: 1))
    /// The soft light an object sits in: the band, the hand.
    static let pool = adaptive(light: NSColor(white: 1, alpha: 0.78), dark: NSColor(red: 0.75, green: 0.88, blue: 1.0, alpha: 0.085))
    static let ink = adaptive(light: NSColor(red: 0.1, green: 0.105, blue: 0.112, alpha: 1), dark: NSColor(red: 0.94, green: 0.946, blue: 0.952, alpha: 1))
    static let secondary = adaptive(light: NSColor(red: 0.42, green: 0.435, blue: 0.455, alpha: 1), dark: NSColor(red: 0.6, green: 0.62, blue: 0.645, alpha: 1))
    static let surface = adaptive(light: NSColor(white: 1, alpha: 0.68), dark: NSColor(white: 1, alpha: 0.045))
    static let line = adaptive(light: NSColor(red: 0.1, green: 0.12, blue: 0.15, alpha: 0.11), dark: NSColor(red: 0.92, green: 0.96, blue: 1.0, alpha: 0.09))
    static let green = adaptive(light: NSColor(red: 0.22, green: 0.55, blue: 0.36, alpha: 1), dark: NSColor(red: 0.6, green: 0.83, blue: 0.64, alpha: 1))
    private static let accentLight = NSColor(red: 0.05, green: 0.4, blue: 0.85, alpha: 1)
    private static let accentDark = NSColor(red: 0.45, green: 0.74, blue: 1.0, alpha: 1)
    /// Blue: what is live, what was just felt, and the one action that matters.
    static let accent = adaptive(light: accentLight, dark: accentDark)
    static let warning = adaptive(light: NSColor(red: 0.78, green: 0.2, blue: 0.17, alpha: 1), dark: NSColor(red: 1, green: 0.52, blue: 0.46, alpha: 1))
    /// The tray that holds pills, and the chip that marks the chosen one.
    static let tray = adaptive(light: NSColor(red: 0.1, green: 0.12, blue: 0.15, alpha: 0.065), dark: NSColor(red: 0.92, green: 0.96, blue: 1.0, alpha: 0.075))
    static let trayHover = adaptive(light: NSColor(red: 0.1, green: 0.12, blue: 0.15, alpha: 0.105), dark: NSColor(red: 0.92, green: 0.96, blue: 1.0, alpha: 0.12))
    static let trayStrong = adaptive(light: NSColor(red: 0.1, green: 0.12, blue: 0.15, alpha: 0.18), dark: NSColor(red: 0.92, green: 0.96, blue: 1.0, alpha: 0.2))
    static let chip = adaptive(light: NSColor(white: 1, alpha: 1), dark: NSColor(red: 0.92, green: 0.96, blue: 1.0, alpha: 0.17))

    /// The light on the hand's fingers, in linear light the way its shader mixes it into the
    /// skin. On the white hand it is a brighter blue than the accent that text uses.
    static func glow(dark: Bool) -> SIMD3<Float> {
        let color = dark ? accentDark : NSColor(red: 0.16, green: 0.56, blue: 1.0, alpha: 1)
        return SIMD3(Float(pow(color.redComponent, 2.2)), Float(pow(color.greenComponent, 2.2)), Float(pow(color.blueComponent, 2.2)))
    }

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
            .foregroundStyle(prominent ? KinesisStyle.accent : KinesisStyle.ink)
            .background(prominent ? KinesisStyle.accent.opacity(lifted ? 0.2 : 0.13) : (lifted ? KinesisStyle.trayHover : KinesisStyle.tray),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? KinesisStyle.accent.opacity(0.24) : .clear))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Capsule())
            .scaleEffect(reduceMotion || !enabled ? 1 : configuration.isPressed ? 0.975 : 1)
            .animation(reduceMotion ? nil : KinesisMotion.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : KinesisMotion.settle, value: hovered)
            .onHover { hovered = $0 }
    }
}

struct KinesisPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : KinesisMotion.press, value: configuration.isPressed)
    }
}

/// A bare icon in the top bar. Under the pointer it gets a soft round tray.
struct KinesisIconStyle: ButtonStyle {
    /// The quick setup arrow winds back a little under the pointer, the way it will wind setup back.
    var winds = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .rotationEffect(.degrees(winds && hovered && !reduceMotion ? -45 : 0))
            .frame(width: 30, height: 30)
            .background(Circle().fill(hovered ? KinesisStyle.tray : .clear))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : KinesisMotion.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : KinesisMotion.select, value: hovered)
            .onHover { hovered = $0 }
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
