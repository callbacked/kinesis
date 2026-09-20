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
            Text("just you and your band.").font(KinesisType.title).tracking(-1.2)
            if model.showsPairAction {
                // Until the band is paired, pairing is the whole page.
                PairBandControl(model: model)
            } else if !model.selectedAddress.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "band").padding(.bottom, 6)
                    OpenRow(title: "wrist", detail: model.handSettingStatus) {
                        PillTray(options: BandHand.allCases.map { Choice($0, $0.rawValue) },
                                 selection: model.pendingHand ?? model.bandHand,
                                 select: { model.selectHand($0) }, label: "Band hand")
                            .disabled(!model.canChangeHand)
                    }
                }
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
            }
            if !model.selectedAddress.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    OpenRow(title: "forget this band",
                            detail: "clears the band, its key, and your meta sign-in from this Mac.") {
                        Button("forget…") { confirmingForget = true }.buttonStyle(KinesisButtonStyle())
                    }
                }
            }
            Text("the connection stays on this Mac. no glasses or phone needed.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary.opacity(0.85))
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

/// Accessibility access as one row: allowed, or what to do about it.
struct PermissionRow: View {
    @ObservedObject var model: BandModel
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
        }.animation(KinesisMotion.settle, value: model.accessibilityAllowed)
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
