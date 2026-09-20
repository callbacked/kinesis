import SwiftUI
import KinesisCore

struct BandPage: View {
    @ObservedObject var model: BandModel
    @State private var confirmingForget = false
    @State private var remindingToReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("just you and your band.").font(KinesisType.title).tracking(-1.2)
            if model.showsPairAction {
                // The pane already shows the band. Until it is paired, this card is the whole page.
                PairBandControl(model: model)
            } else if !model.selectedAddress.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SettingRow(title: "band hand", detail: model.handSettingStatus) {
                        PillTray(options: BandHand.allCases.map { Choice($0, $0.rawValue) },
                                 selection: model.pendingHand ?? model.bandHand,
                                 select: { model.selectHand($0) }, label: "Band hand")
                            .disabled(!model.canChangeHand)
                    }
                    Rectangle().fill(KinesisStyle.line).frame(height: 1)
                    SettingRow(title: "start automatically",
                               detail: "connect your band and enable controls when kinesis opens.") {
                        Toggle("Start automatically", isOn: $model.startsAutomatically).toggleStyle(KinesisToggleStyle())
                    }
                }.padding(.horizontal, 20).background(KinesisStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            }
            PermissionCard(model: model)
            HStack(alignment: .firstTextBaseline) {
                Text("the connection stays on this Mac. no glasses or phone needed.")
                Spacer(minLength: 16)
                if !model.selectedAddress.isEmpty {
                    Button("forget this band…") { confirmingForget = true }.buttonStyle(.plain)
                        .help("removes this band, its key, and your meta sign-in from kinesis.")
                }
            }.font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
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
                .font(KinesisType.body).foregroundStyle(KinesisStyle.secondary).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            GuideLink(title: "how to factory reset", url: PairingPresentation.factoryResetGuide).padding(.top, 14)
            Spacer(minLength: 24)
            HStack(spacing: 14) {
                Spacer()
                Button("not now", action: done).buttonStyle(.plain)
                    .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
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
                Text(title).font(KinesisType.label)
                Text(detail).font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true).contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            control
        }.padding(.vertical, 17)
    }
}

struct PermissionCard: View {
    @ObservedObject var model: BandModel
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: model.accessibilityAllowed ? "checkmark.circle" : "keyboard")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(model.accessibilityAllowed ? KinesisStyle.green : KinesisStyle.secondary)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 7) {
                Text(model.accessibilityAllowed ? "Mac controls are allowed" : "give your gestures a way in")
                    .font(KinesisType.label)
                Text(model.accessibilityAllowed ? "kinesis can send your assigned shortcuts." : "allow Accessibility access so kinesis can send your shortcuts.")
                    .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                if !model.accessibilityAllowed {
                    HStack {
                        Button("allow access") { model.requestAccessibility() }.buttonStyle(KinesisButtonStyle(prominent: true))
                        Button("open settings") { MacShortcuts.openAccessSettings() }.buttonStyle(KinesisButtonStyle())
                    }.padding(.top, 5)
                }
            }
            Spacer(minLength: 0)
        }.padding(20).background(KinesisStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            .animation(KinesisMotion.settle, value: model.accessibilityAllowed)
    }
}
