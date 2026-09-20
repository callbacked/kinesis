import AppKit
import SwiftUI
import KinesisCore

enum AppPage: String, CaseIterable, Identifiable {
    case overview, gestures, band
    var id: String { rawValue }
}

/// The window is one field. The band's column sits on the left of it. The rest is
/// what you do with the band, one page at a time.
struct MainView: View {
    @ObservedObject var model: BandModel
    @State private var page: AppPage
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Scroll views do not draw offscreen, so the render gallery turns this off.
    private let scrolls: Bool

    init(model: BandModel, page: AppPage = .overview, scrolls: Bool = true) {
        self.model = model
        self.scrolls = scrolls
        _page = State(initialValue: page)
    }

    var body: some View {
        Group {
            if model.showingSetup {
                SetupView(model: model)
            } else {
                HStack(spacing: 0) {
                    BandPane(model: model, openBandPage: { open(.band) })
                    VStack(alignment: .leading, spacing: 0) {
                        topBar
                        if scrolls {
                            ScrollView { content }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
                        } else {
                            content.frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 920, minHeight: 660)
        .background(Field())
        .foregroundStyle(KinesisStyle.ink)
        .tint(KinesisStyle.ink)
        .preferredColorScheme(appearance.colorScheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.showingSetup)
        // At the root, so a pair run can ask for the sign-in from setup or from any page.
        .sheet(isPresented: Binding(get: { model.enrollmentStage == .login },
                                    set: { if !$0 { model.cancelEnrollment() } })) {
            MetaLoginView(onSession: { model.enroll(session: $0) },
                          onCancel: { model.cancelEnrollment() })
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            // First, where it is seen without scrolling, even in the smallest window.
            if let error = model.error { ErrorNote(text: error).transition(.opacity.combined(with: .offset(y: -6))) }
            Group {
                switch page {
                case .overview: OverviewPage(model: model)
                case .gestures: GesturesPage(model: model)
                case .band: BandPage(model: model)
                }
            // The old page leaves at once. The new one arrives part by part, from the top.
            }.id(page).transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.1))))
        }
        .animation(reduceMotion ? nil : KinesisMotion.settle, value: model.error)
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 38).padding(.top, 22).padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            TextTabs(options: AppPage.allCases.map { Choice($0, $0.rawValue) }, selection: $page)
            Spacer()
            AppearanceMenu(compact: true).foregroundStyle(KinesisStyle.secondary)
            Button { model.beginSetup() } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 14))
            }.buttonStyle(KinesisIconStyle(winds: true)).foregroundStyle(KinesisStyle.secondary)
                .help("run quick setup again").accessibilityLabel("Quick setup")
        }.padding(.leading, 38).padding(.trailing, 30).padding(.top, 36)
    }

    private func open(_ next: AppPage) {
        withAnimation(reduceMotion ? nil : KinesisMotion.select) { page = next }
    }
}

struct ErrorNote: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(KinesisType.caption).foregroundStyle(KinesisStyle.warning)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
