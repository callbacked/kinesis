#if KINESIS_DEV
import SwiftUI
import KinesisCore

struct HandwritingTrialReviewView: View {
    @ObservedObject var recording: BandModelRecording
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("review your test.").font(KinesisType.title)
                Spacer()
                Button("done") { dismiss() }.buttonStyle(KinesisButtonStyle())
            }
            if let review = recording.trialReview {
                Text("\(review.surface) · \(review.split.rawValue) · \(review.annotations.filter { $0.status != .unreviewed }.count) of \(review.results.count) reviewed")
                    .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                Text("confirm what you actually performed. leave anything you can’t recall unreviewed, or exclude it.")
                    .font(KinesisType.caption)
                HStack(alignment: .top, spacing: 20) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(review.results.enumerated()), id: \.element.id) { index, result in
                                Button {
                                    selectedID = result.id
                                } label: {
                                    Text("\(index + 1). \(result.trial.prompt)")
                                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                        .background((selectedID ?? review.results.first?.id) == result.id ? KinesisStyle.accent.opacity(0.12) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(width: 190)
                    Divider()
                    if let result = review.results.first(where: { $0.id == selectedID }) ?? review.results.first {
                        TrialAnnotationForm(result: result,
                            annotation: review.annotations.first { $0.id == result.id },
                            save: recording.annotateTrial).id(result.id)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            if let problem = recording.problem { ErrorNote(text: problem) }
            Text("changes save locally after each confirmation. original model output is preserved.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
        }.padding(24).frame(width: 740, height: 530).background(KinesisStyle.paper)
    }
}

private struct TrialAnnotationForm: View {
    let result: HandwritingTrialResult
    let annotation: HandwritingTrialAnnotation?
    let save: (HandwritingTrialAnnotation) -> Void
    @State private var reference = ""
    @State private var command = "space"
    @State private var commandCount = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(result.trial.prompt).font(.system(size: 22, weight: .medium))
            if annotation?.status == .confirmed {
                Text("recognized: \(result.candidateText.debugDescription)").font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
            }
            if result.interrupted {
                Text("this trial was interrupted or marked missed. it stays outside the accuracy score.")
                    .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
            }
            Button(result.trial.kind == .idle ? "confirm this rest trial" : "I did exactly this prompt") {
                reference = result.trial.intendedText
                command = result.trial.intendedActions.first ?? "space"
                commandCount = max(1, result.trial.intendedActions.count)
                save(.asPrompted(result.trial))
            }.buttonStyle(KinesisButtonStyle()).disabled(result.interrupted)
            if result.trial.kind == .text {
                TextField("what you actually wrote", text: $reference).textFieldStyle(.roundedBorder)
                Button("confirm actual text") {
                    save(.init(id: result.id, status: .confirmed, referenceText: reference, note: "wearer entered actual text"))
                }.buttonStyle(.link).disabled(reference.isEmpty || result.interrupted)
            } else if result.trial.kind == .command {
                Text("starting text: \(result.trial.initialText.debugDescription)").font(KinesisType.caption)
                Picker("actual gesture", selection: $command) {
                    Text("forward / space").tag("space")
                    Text("back / delete").tag("backspace")
                }
                Stepper("\(commandCount) performed", value: $commandCount, in: 1...10)
                Button("confirm actual gestures") {
                    save(.init(id: result.id, status: .confirmed, performedActions: Array(repeating: command, count: commandCount), note: "wearer entered actual gestures"))
                }.buttonStyle(.link).disabled(result.interrupted)
            }
            HStack {
                Button("exclude / unsure") { save(.init(id: result.id, status: .excluded, note: "wearer could not confirm the performed action")) }
                    .buttonStyle(.link)
                Spacer()
                Button("reset review") { save(.init(id: result.id, status: .unreviewed)) }.buttonStyle(.link)
            }
            let score = HandwritingTrialScore.evaluate(result, annotation: annotation)
            if let reason = score.excludedReason {
                Text(reason).font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
            } else if let errors = score.textErrors {
                Text("\(errors.errors) character errors / \(errors.referenceCount) reference characters").font(KinesisType.caption)
            } else if let errors = score.commandErrors {
                Text("\(errors.deletions) missed · \(errors.insertions) extra · \(errors.substitutions) wrong actions").font(KinesisType.caption)
            } else if let events = score.unintendedEvents, let seconds = score.idleSeconds {
                Text("\(events) unintended events during \(seconds, specifier: "%.1f")s").font(KinesisType.caption)
            }
            Spacer()
        }.onAppear {
            reference = annotation?.referenceText ?? ""
            command = annotation?.performedActions?.first ?? result.trial.intendedActions.first ?? "space"
            commandCount = annotation?.performedActions?.count ?? max(1, result.trial.intendedActions.count)
        }
    }
}
#endif
