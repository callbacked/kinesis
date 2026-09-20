import SwiftUI
import KinesisCore

/// The band's own page. The band's column already shows what the band is and how it is,
/// so this page holds only what you decide about it, as rows on open ground.
struct BandPage: View {
    @ObservedObject var model: BandModel
    @State private var confirmingForget = false
    @State private var remindingToReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("just you and your band.").font(KinesisType.title).tracking(-1.2).reveal(0)
            if model.showsPairAction {
                // Until the band is paired, pairing is the whole page.
                PairBandControl(model: model).reveal(1)
            } else if !model.selectedAddress.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "band").padding(.bottom, 6)
                    OpenRow(title: "wrist", detail: model.handSettingStatus) {
                        PillTray(options: BandHand.allCases.map { Choice($0, $0.rawValue) },
                                 selection: model.pendingHand ?? model.bandHand,
                                 select: { model.selectHand($0) }, label: "Band hand")
                            .disabled(!model.canChangeHand)
                    }
                }.reveal(1)
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "this Mac").padding(.bottom, 6)
                if !model.showsPairAction && !model.selectedAddress.isEmpty {
                    OpenRow(title: "start automatically",
                            detail: "connect your band and enable controls when kinesis opens.") {
                        Toggle("Start automatically", isOn: $model.startsAutomatically).toggleStyle(KinesisToggleStyle())
                    }
                }
                PermissionRow(model: model)
            }.reveal(2)
            if !model.selectedAddress.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    OpenRow(title: "forget this band",
                            detail: "clears the band, its key, and your meta sign-in from this Mac.") {
                        Button("forget…") { confirmingForget = true }.buttonStyle(KinesisButtonStyle())
                    }
                }.reveal(3)
            }
            Text("the connection stays on this Mac. no glasses or phone needed.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary.opacity(0.85)).reveal(4)
        }
        .confirmationDialog("forget this band?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("forget band", role: .destructive) {
                model.forgetEverything()
                // Kinesis has let go. The band and macOS have not. Say so while it is the next thing to do.
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

/// Accessibility access as one row: allowed, or what to do about it.
struct PermissionRow: View {
    @ObservedObject var model: BandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        OpenRow(title: "Mac controls",
                detail: model.accessibilityAllowed ? "kinesis can send your assigned shortcuts."
                    : "allow Accessibility access so kinesis can send your shortcuts.") {
            if model.accessibilityAllowed {
                Label("allowed", systemImage: "checkmark.circle.fill").font(KinesisType.label)
                    .foregroundStyle(KinesisStyle.green).transition(.opacity)
            } else {
                HStack(spacing: 12) {
                    Button("open settings") { MacShortcuts.openAccessSettings() }.buttonStyle(.plain)
                        .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                    Button("allow access") { model.requestAccessibility() }.buttonStyle(KinesisButtonStyle(prominent: true))
                }
            }
        }.animation(reduceMotion ? nil : KinesisMotion.settle, value: model.accessibilityAllowed)
    }
}

/// Shown right after a band is forgotten. Forgetting clears the Mac's side only;
/// the band stays claimed until its own button wipes it.
struct FactoryResetReminder: View {
    var done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BandArtwork().frame(width: 190, height: 150)
                .frame(maxWidth: .infinity).padding(.bottom, 26)
            Text("two quick things").font(.system(size: 26)).tracking(-0.9)
            VStack(alignment: .leading, spacing: 16) {
                step(1, "factory reset the band",
                     "\(OwnershipCeremony.factoryResetHint). it clears the old owner, so setup goes smoothly next time.",
                     GuideLink(title: "how to factory reset", url: PairingPresentation.factoryResetGuide))
                step(2, "forget it in bluetooth settings",
                     "an old entry there can cause pairing issues later.",
                     GuideLink(title: "open bluetooth settings", url: NativeBandConnection.bluetoothSettings))
            }.padding(.top, 14)
            Spacer(minLength: 24)
            HStack(spacing: 14) {
                Spacer()
                Button("not now", action: done).buttonStyle(.plain)
                    .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                Button("done", action: done).buttonStyle(KinesisButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 28)
        .frame(width: 520, height: 520)
        .background(KinesisStyle.paper).foregroundStyle(KinesisStyle.ink)
    }

    private func step(_ number: Int, _ title: String, _ detail: String, _ link: GuideLink) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(KinesisType.label).monospacedDigit().foregroundStyle(KinesisStyle.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(KinesisType.lead)
                Text(detail).font(KinesisType.body).foregroundStyle(KinesisStyle.secondary).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                link.padding(.top, 3)
            }
        }
    }
}
