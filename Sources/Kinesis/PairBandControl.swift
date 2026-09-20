import SwiftUI

/// The band page's single pairing action. One button runs the whole
/// pipeline — scan, connect, evaluate, and (when the band needs it) claim —
/// with inline progress, contextual hints, and the account-switch escape
/// hatch. The Meta sign-in sheet appears only when no session is saved or
/// one failed.
struct PairBandControl: View {
    @ObservedObject var model: BandModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { model.pairBand() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11))
                        Text("pair band")
                    }
                }.buttonStyle(KinesisButtonStyle(prominent: true))
                    .disabled(!model.canPair)
                    .help("finds your band, connects, and claims it if the band needs it.")
                if model.pairInProgress {
                    ProgressView().controlSize(.small).tint(KinesisStyle.ink)
                }
                Spacer(minLength: 0)
            }
            if let progress = model.pairProgressText {
                Text(progress).font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
            }
            if model.showsHoldHint {
                Text("hold the band button for 3 seconds until it flashes")
                    .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
            }
            if !model.pairInProgress, let failure = model.pairFailure {
                Text(failure).font(.system(size: 12)).foregroundStyle(KinesisStyle.warning)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            if model.pairRoute == .enrolling && model.hasSavedMetaSession {
                Button("use a different account") { model.switchMetaAccount() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(KinesisStyle.secondary)
                    .help("signs out of meta so the band can bind to another account.")
            }
        }
        .sheet(isPresented: Binding(get: { model.enrollmentStage == .login },
                                    set: { if !$0 { model.cancelEnrollment() } })) {
            MetaLoginView(onSession: { model.enroll(session: $0) },
                          onCancel: { model.cancelEnrollment() })
        }
    }
}
