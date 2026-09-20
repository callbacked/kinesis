import AppKit
import SwiftUI
import KinesisCore

private enum AppPage: String, CaseIterable, Identifiable {
    case overview, gestures, band
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "circle.grid.2x2"
        case .gestures: "hand.draw"
        case .band: "circle.dotted.circle"
        }
    }
}

struct MainView: View {
    @ObservedObject var model: BandModel
    @State private var page = AppPage.overview
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.showingSetup {
                SetupView(model: model)
            } else {
                HStack(spacing: 0) {
                    sidebar
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        ScrollView {
                            VStack(alignment: .leading, spacing: 28) {
                                switch page {
                                case .overview: OverviewView(model: model, editGestures: { page = .gestures }, openBand: { page = .band })
                                case .gestures: GestureSettingsView(model: model)
                                case .band: BandSettingsView(model: model)
                                }
                                if let error = model.error { ErrorNote(text: error) }
                            }.frame(maxWidth: 780, alignment: .leading)
                                .padding(.horizontal, 32).padding(.vertical, 22)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
                    }
                }
            }
        }
        .frame(minWidth: 880, minHeight: 660)
        .background(KinesisStyle.paper)
        .foregroundStyle(KinesisStyle.ink)
        .tint(KinesisStyle.ink)
        .preferredColorScheme(appearance.colorScheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.showingSetup)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: page)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                KinesisMark()
                Text("kinesis").font(.system(size: 22, weight: .medium, design: .rounded)).tracking(-0.8)
            }.foregroundStyle(.white.opacity(0.95)).padding(.top, 26).padding(.bottom, 46)
            ForEach(AppPage.allCases) { item in
                Button { page = item } label: {
                    HStack(spacing: 13) {
                        Image(systemName: item.symbol).font(.system(size: 15, weight: .regular)).frame(width: 20)
                        Text(item.rawValue).font(.system(size: 13, weight: .medium))
                        Spacer()
                        if page == item { Circle().fill(.white.opacity(0.85)).frame(width: 4, height: 4) }
                    }
                    .padding(.horizontal, 13).padding(.vertical, 13)
                    .background(page == item ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }.buttonStyle(KinesisPressStyle())
                    .foregroundStyle(.white.opacity(page == item ? 0.95 : 0.5))
                    .padding(.bottom, 5)
            }
            Spacer()
            AppearanceMenu().foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 13).padding(.bottom, 17)
            Button { model.beginSetup() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.counterclockwise").frame(width: 20)
                    Text("quick setup")
                    Spacer(minLength: 0)
                }.font(.system(size: 12))
            }.buttonStyle(KinesisPressStyle()).foregroundStyle(.white.opacity(0.55)).padding(.horizontal, 13).padding(.bottom, 25)
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            VStack(alignment: .leading, spacing: 9) {
                Text(model.bandName.lowercased()).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                ConnectionBadge(live: model.live, text: model.phase, onDark: true)
                if let battery = model.battery {
                    Label("\(battery)%", systemImage: "battery.75percent").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
            }.padding(.horizontal, 13).padding(.top, 22).padding(.bottom, 24)
        }.padding(.horizontal, 18).frame(width: 190).background(KinesisStyle.rail)
    }

    private var header: some View {
        HStack {
            Spacer()
            Button { model.toggleControls() } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.controlsEnabled ? "pause.fill" : "play.fill").font(.system(size: 9))
                    Text(model.controlsEnabled ? "pause controls" : "enable controls")
                }
            }.buttonStyle(KinesisButtonStyle(prominent: true))
                .disabled(!model.live && !model.controlsEnabled)
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }.padding(.horizontal, 32).padding(.vertical, 13)
            .overlay(alignment: .bottom) { Rectangle().fill(KinesisStyle.line).frame(height: 1) }
    }
}

private struct OverviewView: View {
    @ObservedObject var model: BandModel
    var editGestures: () -> Void
    var openBand: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.controlsEnabled ? "go about your day." : "ready when you are.")
                        .font(.system(size: 32, weight: .regular)).tracking(-1.2)
                    Text(model.controlsEnabled ? "a small gesture. your Mac follows." : "your usual Mac, with a little less reaching.")
                        .font(.system(size: 13)).foregroundStyle(KinesisStyle.secondary)
                }
                Spacer(minLength: 0)
            }
            ZStack(alignment: .bottomLeading) {
                HandSceneView(hand: model.bandHand, highlight: handHighlight, revision: model.gestureCount,
                              sustained: model.pinchedFinger != nil || model.dialEngaged)
                    .frame(height: 235)
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: model.live ? "last gesture" : "neural band")
                        Text(model.live ? model.lastGesture.lowercased() : "waiting for your band")
                            .font(.system(size: 16, weight: .medium))
                    }
                    Spacer()
                    Image(systemName: model.lastDirection?.symbol ?? (model.dialEngaged ? "arrow.trianglehead.2.clockwise.rotate.90" : "waveform"))
                        .font(.system(size: 20, weight: .light)).foregroundStyle(KinesisStyle.secondary)
                }.padding(23)
            }
            .background(KinesisStyle.surface, in: RoundedRectangle(cornerRadius: 19))
            .clipShape(RoundedRectangle(cornerRadius: 19))
            .overlay(alignment: .topLeading) {
                ConnectionBadge(live: model.controlsEnabled && model.live, text: model.controlsEnabled ? "controls live" : "controls paused")
                    .padding(23)
            }
            HStack(alignment: .top, spacing: 18) {
                summaryTile(model.totalGestureCount.formatted(), subtitle: "gestures so far", symbol: "hand.draw")
                Rectangle().fill(KinesisStyle.line).frame(width: 1, height: 46)
                summaryTile(model.dialTarget.title.lowercased(), subtitle: "pinch + turn", symbol: "dial.low")
            }.padding(.horizontal, 4)
            if !model.live {
                HStack {
                    Text("pick up where you left off.").font(.system(size: 13)).foregroundStyle(KinesisStyle.secondary)
                    Spacer()
                    Button(model.selectedAddress.isEmpty ? "find your band" : model.wantsConnection ? "view connection" : "connect band") {
                        if model.selectedAddress.isEmpty || model.wantsConnection { openBand() } else { model.connect() }
                    }.buttonStyle(KinesisButtonStyle()).disabled(model.busy && !model.wantsConnection)
                }
            } else if !model.accessibilityAllowed {
                PermissionCard(model: model)
            } else {
                HStack {
                    Text(model.lastAction.lowercased()).font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary).lineLimit(2)
                    Spacer()
                    Button("edit gestures", action: editGestures).buttonStyle(KinesisButtonStyle())
                }
            }
            Text("close this window. kinesis stays in your menu bar.")
                .font(.system(size: 11)).foregroundStyle(KinesisStyle.secondary)
        }
    }
    private var handHighlight: HandHighlight {
        guard model.live else { return .none }
        if let finger = model.pinchedFinger { return finger == "middle" ? .middle : .index }
        if model.dialEngaged { return .index }
        switch model.recognizedGesture {
        case .swipe: return .index
        case .tap(let tap): return tap.finger == "middle" ? .middle : .index
        case nil: return .none
        }
    }
    private func summaryTile(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 21, weight: .ultraLight)).foregroundStyle(KinesisStyle.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 19, weight: .medium)).monospacedDigit()
                Text(subtitle).font(.system(size: 11)).foregroundStyle(KinesisStyle.secondary)
            }
            Spacer()
        }
    }
}

private struct GestureSettingsView: View {
    @ObservedObject var model: BandModel
    @State private var section = "swipe"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let sections = ["swipe", "tap", "turn"]
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("little moves. your rules.").font(.system(size: 32)).tracking(-1.2)
            Picker("Gesture family", selection: $section) {
                ForEach(sections, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                Text(section == "swipe" ? "a shortcut at your fingertips." : section == "tap" ? "one finger. two taps." : "turn it just a little.")
                    .font(.system(size: 20)).tracking(-0.4)
                Text(section == "swipe" ? "slide your thumb across your index finger in any direction." : section == "tap" ? "touch your thumb to your index or middle finger." : "pinch thumb and index, then turn your wrist. release to reset.")
                    .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
            }
            VStack(spacing: 0) {
                if section == "swipe" {
                    ForEach(SwipeDirection.allCases) { direction in
                        assignment(direction.label, symbol: direction.symbol, selection: Binding(
                            get: { model.mappings[direction] ?? .none }, set: { model.mappings[direction] = $0 }))
                    }
                } else if section == "tap" {
                    ForEach(TapGesture.allCases) { tap in
                        assignment(tap.label, symbol: tap.action == "tap" ? "circle" : "circle.circle", selection: Binding(
                            get: { model.tapMappings[tap] ?? .none }, set: { model.tapMappings[tap] = $0 }))
                    }
                } else {
                    HStack {
                        Label("pinch + turn", systemImage: "dial.low")
                        Spacer()
                        Picker("Dial controls", selection: $model.dialTarget) {
                            ForEach(DialTarget.allCases) { Text($0.title.lowercased()).tag($0) }
                        }.labelsHidden().frame(width: 190)
                    }.padding(20)
                    Rectangle().fill(KinesisStyle.line).frame(height: 1)
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("sensitivity")
                            Spacer()
                            Text(model.dialSensitivity.formatted(.number.precision(.fractionLength(2))) + "×")
                                .font(.system(size: 12)).monospacedDigit()
                        }
                        Slider(value: $model.dialSensitivity, in: 0.5...4, step: 0.25).accessibilityLabel("Dial sensitivity")
                        HStack {
                            Text("more precise")
                            Spacer()
                            Text("less movement")
                        }.font(.system(size: 10)).foregroundStyle(KinesisStyle.secondary)
                    }.padding(20)
                }
            }.background(KinesisStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9), value: section)
            Text(section == "swipe" ? "desktop actions use the Mac’s Control + arrow shortcuts. window and tab actions stay in the current app." : section == "tap" ? "single taps start unassigned, leaving room for double taps and the dial." : "volume follows your audio output, including AirPods. brightness controls your Mac’s display; external displays may not respond. pinch again after changing settings.")
                .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary).lineSpacing(4)
        }
    }
    private func assignment(_ label: String, symbol: String, selection: Binding<MacAction>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 21).foregroundStyle(KinesisStyle.secondary)
                Text(label.lowercased()).font(.system(size: 13))
                Spacer()
                Picker(label, selection: selection) {
                    ForEach(MacAction.allCases) { action in Text(action.title.lowercased()).tag(action) }
                }.labelsHidden().frame(width: 200)
            }.padding(20)
            Rectangle().fill(KinesisStyle.line).frame(height: 1).padding(.horizontal, 20)
        }
    }
}

private struct BandSettingsView: View {
    @ObservedObject var model: BandModel
    @State private var confirmingForget = false
    @State private var remindingToReset = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("just you and your band.").font(.system(size: 32)).tracking(-1.2)
            if model.showsPairAction {
                // Until the band is paired this card is the band: showing both
                // drew it twice and offered settings that could do nothing yet.
                PairBandControl(model: model)
            } else if !model.selectedAddress.isEmpty {
                bandCard
                VStack(alignment: .leading, spacing: 0) {
                    SettingRow(title: "band hand", detail: model.handSettingStatus) {
                        Picker("Band hand", selection: Binding(get: { model.pendingHand ?? model.bandHand }, set: { model.selectHand($0) })) {
                            ForEach(BandHand.allCases) { hand in Text(hand.rawValue).tag(hand) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                            .disabled(!model.canChangeHand)
                    }
                    Rectangle().fill(KinesisStyle.line).frame(height: 1)
                    SettingRow(title: "start automatically",
                               detail: "connect your band and enable controls when kinesis opens.") {
                        Toggle("Start automatically", isOn: $model.startsAutomatically)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(KinesisStyle.blue)
                    }
                }.padding(.horizontal, 18).background(KinesisStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            }
            PermissionCard(model: model)
            HStack(alignment: .firstTextBaseline) {
                Text("the connection stays on this Mac. no glasses or phone needed.")
                Spacer(minLength: 16)
                if !model.selectedAddress.isEmpty {
                    Button("forget this band…") { confirmingForget = true }.buttonStyle(.plain)
                        .help("removes this band, its key, and your meta sign-in from kinesis.")
                }
            }.font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
        }
        .confirmationDialog("forget this band?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("forget band", role: .destructive) {
                model.forgetEverything()
                // Kinesis has let go; the band has not. Say so while it is the next thing to do.
                remindingToReset = true
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("this clears the band, its key, and your meta sign-in from this Mac.")
        }
        .sheet(isPresented: $remindingToReset) {
            FactoryResetReminder { remindingToReset = false }
        }
    }

    private var bandCard: some View {
        HStack(spacing: 25) {
            BandArtwork().frame(width: 150, height: 135)
            VStack(alignment: .leading, spacing: 12) {
                Text(model.bandName.lowercased()).font(.system(size: 21)).tracking(-0.5)
                ConnectionBadge(live: model.live, text: model.phase)
                if model.justPaired {
                    Label("paired. you’re all set.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(KinesisStyle.green)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if let battery = model.battery {
                    Text("\(battery)% battery" + (model.live ? "" : " when last connected"))
                        .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
                }
            }.animation(.easeOut(duration: 0.3), value: model.justPaired)
            Spacer(minLength: 12)
            if model.live || model.wantsConnection {
                Button("disconnect") { model.disconnect() }.buttonStyle(KinesisButtonStyle())
                    .disabled(model.busy && !model.wantsConnection)
                    .help("stops using the band until you connect again.")
            } else if !model.showsPairAction {
                // A paired band that was disconnected by hand needs a way back.
                Button("connect") { model.connect() }.buttonStyle(KinesisButtonStyle(prominent: true))
                    .disabled(model.busy)
            }
        }
    }
}

/// Shown right after a band is forgotten. Forgetting clears the Mac's side only;
/// the band stays claimed until its own button wipes it.
struct FactoryResetReminder: View {
    var done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HoldArtwork(hint: .prompt).frame(width: 190, height: 150)
                .frame(maxWidth: .infinity).padding(.bottom, 26)
            Text("now factory reset the band").font(.system(size: 26)).tracking(-0.9)
            Text("kinesis forgot it, but the band is still claimed by your meta account. to wipe it, \(OwnershipCeremony.factoryResetHint).")
                .font(.system(size: 13)).foregroundStyle(KinesisStyle.secondary).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            GuideLink(title: "how to factory reset", url: PairingPresentation.factoryResetGuide).padding(.top, 14)
            Spacer(minLength: 24)
            HStack(spacing: 14) {
                Spacer()
                Button("not now", action: done).buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
                Button("i’ve reset it", action: done).buttonStyle(KinesisButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 28)
        .frame(width: 520, height: 470)
        .background(KinesisStyle.paper).foregroundStyle(KinesisStyle.ink)
    }
}

/// One settings line: what it is on the left, its control at the right edge.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            control
        }.padding(.vertical, 16)
    }
}

struct PermissionCard: View {
    @ObservedObject var model: BandModel
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: model.accessibilityAllowed ? "checkmark.circle" : "keyboard")
                .font(.system(size: 20, weight: .light)).foregroundStyle(model.accessibilityAllowed ? KinesisStyle.green : KinesisStyle.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text(model.accessibilityAllowed ? "Mac controls are allowed" : "give your gestures a way in")
                    .font(.system(size: 13, weight: .medium))
                Text(model.accessibilityAllowed ? "kinesis can send your assigned shortcuts." : "allow Accessibility access so kinesis can send your shortcuts.")
                    .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
                if !model.accessibilityAllowed {
                    HStack {
                        Button("allow access") { model.requestAccessibility() }.buttonStyle(KinesisButtonStyle(prominent: true))
                        Button("open settings") { MacShortcuts.openAccessSettings() }.buttonStyle(KinesisButtonStyle())
                    }.padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }.padding(18).background(KinesisStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ErrorNote: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.system(size: 12)).foregroundStyle(KinesisStyle.warning)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
