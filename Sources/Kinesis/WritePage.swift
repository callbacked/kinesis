import AppKit
import OSLog
import SwiftUI
import KinesisCore

/// One handwriting recorder for the app, so the text stays when you switch pages.
@MainActor final class HandwritingSession {
    static let shared = HandwritingSession()
    private var recording: BandModelRecording?

    func recording(for model: BandModel) -> BandModelRecording {
        if let recording { return recording }
        let made = BandModelRecording(model: model, mode: .handwriting)
        recording = made
        return made
    }

    private var pendingTest: (split: HandwritingTrial.Split, at: Double)?

    /// Asks the write page to start a guided test when it opens.
    func requestTest(_ split: HandwritingTrial.Split) {
        pendingTest = (split, ProcessInfo.processInfo.systemUptime)
        NotificationCenter.default.post(name: .kinesisOpenPage, object: AppPage.write.rawValue)
    }

    /// A request only counts as the page opens for it, never on a later visit.
    func takePendingTest() -> HandwritingTrial.Split? {
        defer { pendingTest = nil }
        guard let pendingTest, ProcessInfo.processInfo.systemUptime - pendingTest.at < 5 else { return nil }
        return pendingTest.split
    }

    private static let log = Logger(subsystem: "local.callbacked.kinesis", category: "handwriting")

    /// Lets a gesture bound to "handwriting on / off" start and end writing from anywhere.
    func install(_ model: BandModel) {
        HandwritingInput.shared.watchApps()
        model.onToggleHandwriting = { [weak self, weak model] in
            guard let self, let model else { return }
            let recording = self.recording(for: model)
            if recording.isRunning {
                if HandwritingInput.shared.active { HandwritingInput.shared.stop() }
                else if recording.phase != .restoring { recording.finish() }
                return
            }
            guard recording.ready else { return }
            let kinesisInFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
            if kinesisInFront {
                // In Kinesis, the write page shows the writing.
                recording.guidedHandwriting = false
                recording.start()
            } else {
                Task { @MainActor in
                    // A browser can take a moment to show a page's fields: look twice.
                    var takesText = HandwritingInput.shared.focusTakesText()
                    if !takesText {
                        try? await Task.sleep(for: .milliseconds(350))
                        takesText = HandwritingInput.shared.focusTakesText()
                    }
                    guard takesText else {
                        // Nowhere to type: say so, quietly, and leave the band as it is.
                        Self.log.info("No text field for handwriting: \(HandwritingInput.shared.lastRefusal, privacy: .public)")
                        HandwritingInput.shared.flash("click a text field first")
                        return
                    }
                    guard !recording.isRunning, recording.ready else { return }
                    recording.guidedHandwriting = false
                    recording.start()
                    if recording.isRunning { HandwritingInput.shared.begin(recording) }
                }
            }
        }
    }

    /// Ends writing, as the page leaves or Kinesis quits, so the band goes back to normal.
    func finish() {
        if recording?.isRunning == true { recording?.finish() }
    }
}

/// Write with the band hand on a desk or any surface. The band's own handwriting model
/// reads it, and the text shows on the page. The research tools live on Readings.
struct WritePage: View {
    @ObservedObject var model: BandModel
    @ObservedObject private var recording: BandModelRecording

    init(model: BandModel) {
        self.model = model
        _recording = ObservedObject(wrappedValue: HandwritingSession.shared.recording(for: model))
    }

    private var on: Bool { recording.phase == .preparing || recording.phase == .recording }
    private var guided: Bool { recording.writingTrialIndex != nil }
    private var canStart: Bool { !recording.isRunning && recording.ready }

    /// One short line, only when something needs saying.
    private var status: String? {
        switch recording.phase {
        case .preparing: return "getting the band ready"
        case .restoring: return "setting the band back to normal"
        default: break
        }
        if !model.live { return "connect your band to write" }
        if model.modelRecoveryRequired { return "reconnect your band to finish setting it back to normal" }
        if model.modelControlsUnavailable && !recording.isRunning { return "another recording is using the band" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("write on any surface.").font(KinesisType.title).tracking(-1.2).reveal(0)
            VStack(alignment: .leading, spacing: 8) {
                OpenRow(title: "handwriting", detail: "experimental") {
                    Toggle("Handwriting", isOn: Binding(get: { on }, set: { $0 ? startWriting(guided: false) : recording.finish() }))
                        .toggleStyle(KinesisToggleStyle())
                        .disabled(recording.phase == .restoring || (!on && !canStart))
                }
                if let status {
                    Text(status).font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                        .transition(.opacity)
                }
            }.reveal(1)

            stage.reveal(2)

            HStack(alignment: .center, spacing: 10) {
                Text("push forward for a space. sweep back to delete.")
                    .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                Spacer()
                if !recording.candidateText.isEmpty && !guided {
                    Button("clear") { recording.clearHandwriting() }.buttonStyle(KinesisButtonStyle())
                    Button("copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(recording.candidateText, forType: .string)
                    }.buttonStyle(KinesisButtonStyle(prominent: true))
                }
            }.reveal(3)

            if let problem = recording.problem { ErrorNote(text: problem) }
        }
        .animation(KinesisMotion.settle, value: status)
        .animation(KinesisMotion.settle, value: recording.candidateText.isEmpty)
        .onExitCommand { if recording.isRunning { recording.finish() } }
        .onAppear {
            // A guided test started from Readings runs here, where its prompts show.
            if let split = HandwritingSession.shared.takePendingTest() {
                recording.handwritingSplit = split
                startWriting(guided: true)
            }
        }
        .onDisappear { HandwritingSession.shared.finish() }
    }

    /// The page's one stage: the writing, or a guided test's prompt while one runs.
    private var stage: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18).fill(KinesisStyle.surface)
            if let index = recording.writingTrialIndex {
                prompt(index)
            } else if recording.candidateText.isEmpty {
                HStack(spacing: 10) {
                    if on {
                        Pulse(active: recording.phase == .recording) { beat in
                            Circle().fill(KinesisStyle.accent).frame(width: 7, height: 7).opacity(0.45 + 0.55 * (1 - beat))
                        }
                    }
                    Text(on ? (recording.phase == .recording ? "write with your band hand" : "one moment") : "your writing shows up here")
                        .font(.system(size: 26, weight: .light)).foregroundStyle(KinesisStyle.secondary)
                }.padding(26)
            } else {
                ScrollView {
                    Text(recording.candidateText)
                        .font(.system(size: 30, weight: .light)).foregroundStyle(KinesisStyle.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(26)
                }.scrollIndicators(.hidden)
            }
        }
        .frame(height: 230)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Handwriting")
    }

    private func prompt(_ index: Int) -> some View {
        let trial = recording.writingTrials[index]
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(index + 1) of \(recording.writingTrials.count)").font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    Text("\(max(0, Int(ceil(recording.writingTrialEndsAt.timeIntervalSince(context.date)))))")
                        .font(KinesisType.micro).monospacedDigit().foregroundStyle(KinesisStyle.secondary)
                }
            }
            Text(recording.trialSettling ? "hold still" : trial.prompt)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(recording.trialSettling ? KinesisStyle.secondary : KinesisStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !recording.candidateText.isEmpty {
                Text(recording.candidateText).font(KinesisType.lead).foregroundStyle(KinesisStyle.secondary).lineLimit(1)
            }
            HStack {
                Spacer()
                Button("missed it") { recording.markWritingTrialMissed() }
                    .buttonStyle(.plain).font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
            }
        }.padding(26)
    }

    private func startWriting(guided: Bool) {
        recording.guidedHandwriting = guided
        recording.start()
    }

}
