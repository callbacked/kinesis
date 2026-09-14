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
    static let paper = adaptive(light: NSColor(red: 0.96, green: 0.955, blue: 0.94, alpha: 1), dark: NSColor(white: 0.085, alpha: 1))
    static let ink = adaptive(light: NSColor(white: 0.13, alpha: 1), dark: NSColor(white: 0.91, alpha: 1))
    static let secondary = adaptive(light: NSColor(white: 0.43, alpha: 1), dark: NSColor(white: 0.61, alpha: 1))
    static let surface = adaptive(light: NSColor(white: 1, alpha: 0.68), dark: NSColor(white: 1, alpha: 0.045))
    static let line = adaptive(light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.09))
    static let green = adaptive(light: NSColor(red: 0.28, green: 0.48, blue: 0.36, alpha: 1), dark: NSColor(red: 0.54, green: 0.76, blue: 0.62, alpha: 1))
    static let blue = adaptive(light: NSColor(red: 0.15, green: 0.44, blue: 0.7, alpha: 1), dark: NSColor(red: 0.42, green: 0.7, blue: 0.96, alpha: 1))
    static let warning = adaptive(light: NSColor(red: 0.58, green: 0.31, blue: 0.16, alpha: 1), dark: NSColor(red: 0.92, green: 0.64, blue: 0.42, alpha: 1))
    static let rail = Color(red: 0.115, green: 0.125, blue: 0.12)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

struct KinesisButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 17).padding(.vertical, 12)
            .foregroundStyle(prominent ? KinesisStyle.paper : KinesisStyle.ink)
            .background(prominent ? KinesisStyle.ink : KinesisStyle.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? .clear : KinesisStyle.line))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .contentShape(Capsule())
            .scaleEffect(reduceMotion || !enabled ? 1 : configuration.isPressed ? 0.97 : hovered ? 1.015 : 1)
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
    var onDark = false
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(live ? (onDark ? Color(red: 0.66, green: 0.83, blue: 0.71) : KinesisStyle.green) : Color.gray)
                .frame(width: 5, height: 5)
            Text(text.lowercased()).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(onDark ? Color.white.opacity(0.75) : KinesisStyle.secondary)
        .accessibilityElement(children: .combine)
    }
}
