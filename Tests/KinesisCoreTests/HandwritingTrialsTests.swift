import Foundation
import Testing
@testable import KinesisCore

private func trialSample(_ label: Int, sequence: UInt64) throws -> BandInferenceSample {
    var values = Data()
    for index in 0..<100 {
        var bits = Float(index == label ? 0 : -100).bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { values.append(contentsOf: $0) }
    }
    return try BandInferenceSample(payload: BandWire.field(1, sequence) + BandWire.field(2, 100_000 + sequence * 156_250)
        + BandWire.field(3, values) + BandWire.field(10, 3))
}

private func result(_ trial: HandwritingTrial, labels: [Int], interrupted: Bool = false) throws -> HandwritingTrialResult {
    var decoder = ExperimentalHandwritingDecoder()
    decoder.resetText(to: trial.initialText)
    var observation = HandwritingTrialObservation(trial: trial, order: 1, at: 10, decoder: decoder)
    for (i, label) in labels.enumerated() { observation.receive(label: decoder.consume(try trialSample(label, sequence: UInt64(i)))) }
    return observation.finish(order: 20, at: 15, interrupted: interrupted, decoder: decoder)
}

@Test func pilotFitsModelWindowAndKeepsDevelopmentPhrasesOutOfEvaluation() {
    let development = HandwritingTrial.pilot(split: .development), evaluation = HandwritingTrial.pilot(split: .evaluation)
    #expect(development.count == 28 && Set(development.map(\.id)).count == 28)
    #expect(development.reduce(0) { $0 + $1.actionSeconds + $1.settleSeconds } == 270)
    #expect(development.filter { $0.kind == .idle }.count == 2)
    #expect(development.filter { $0.kind == .command }.count == 10)
    #expect(development.contains { $0.intendedText == "hi kinesis" })
    #expect(!evaluation.contains { $0.intendedText == "hi kinesis" })
    #expect(development.contains { $0.intendedActions == ["backspace"] && $0.initialText.isEmpty })
}

@Test func trialScoringRequiresConfirmationAndCountsSpacesAndSubstitutions() throws {
    let trial = HandwritingTrial(kind: .text, prompt: "write hi kinesis", intendedText: "hi kinesis", actionSeconds: 5)
    let observed = try result(trial, labels: [7, 8, 19, 8, 13, 4, 18, 8, 18])
    #expect(observed.candidateText == "hitinesis")
    #expect(HandwritingTrialScore.evaluate(observed, annotation: nil).textErrors == nil)
    let score = HandwritingTrialScore.evaluate(observed, annotation: .asPrompted(trial))
    #expect(score.textErrors?.substitutions == 1 && score.textErrors?.deletions == 1 && score.textErrors?.insertions == 0)
    #expect(score.textErrors?.referenceCount == 10 && score.textErrors?.rate == 0.2)
    let actual = HandwritingTrialAnnotation(id: trial.id, status: .confirmed, referenceText: "hitinesis")
    #expect(HandwritingTrialScore.evaluate(observed, annotation: actual).textErrors?.rate == 0)
    let interrupted = try result(trial, labels: [7], interrupted: true)
    #expect(HandwritingTrialScore.evaluate(interrupted, annotation: .asPrompted(trial)).excludedReason == "interrupted trial")
}

@Test func commandScoringDistinguishesRepeatedDeletesFromUnchangedEmptyText() throws {
    let trial = HandwritingTrial(kind: .command, prompt: "delete once", intendedActions: ["backspace"], actionSeconds: 4)
    let observed = try result(trial, labels: [94, 87, 94])
    #expect(observed.candidateText.isEmpty)
    let score = HandwritingTrialScore.evaluate(observed, annotation: .asPrompted(trial))
    #expect(score.commandErrors?.insertions == 1 && score.commandFinalTextMatches == true)
    let missed = HandwritingTrialScore.evaluate(try result(trial, labels: [99]), annotation: .asPrompted(trial))
    #expect(missed.commandErrors?.deletions == 1)
    let wrong = HandwritingTrialScore.evaluate(try result(trial, labels: [88]), annotation: .asPrompted(trial))
    #expect(wrong.commandErrors?.substitutions == 1 && wrong.commandFinalTextMatches == false)
}

@Test func idleScoringCountsTextAndEditingEventsAndKeepsBoundaryHypothesisExplicit() throws {
    let trial = HandwritingTrial(kind: .idle, prompt: "rest", actionSeconds: 5)
    let score = HandwritingTrialScore.evaluate(try result(trial, labels: [0, 87, 94, 87, 88]), annotation: .asPrompted(trial))
    #expect(score.unintendedEvents == 3 && score.idleSeconds == 5 && score.textErrors == nil)
}

@Test func trialContextResetDoesNotRepeatAHeldModelOutput() throws {
    var decoder = ExperimentalHandwritingDecoder()
    decoder.consume(try trialSample(94, sequence: 0))
    decoder.resetText(to: "ab")
    #expect(decoder.consume(try trialSample(94, sequence: 1)) == nil)
    #expect(decoder.text == "ab" && decoder.rawText.isEmpty)
    decoder.consume(try trialSample(99, sequence: 2))
    decoder.consume(try trialSample(94, sequence: 3))
    #expect(decoder.text == "a" && decoder.rawText == "⌫")
}

@Test func trialWithMissingPacketsIsExcludedEvenWhenItsTextLooksCorrect() throws {
    let trial = HandwritingTrial(kind: .text, prompt: "write aa", intendedText: "aa", actionSeconds: 5)
    var decoder = ExperimentalHandwritingDecoder()
    var observation = HandwritingTrialObservation(trial: trial, order: 1, at: 10, decoder: decoder)
    observation.receive(label: decoder.consume(try trialSample(0, sequence: 0)))
    observation.receive(label: decoder.consume(try trialSample(0, sequence: 3)))
    let observed = observation.finish(order: 4, at: 15, interrupted: false, decoder: decoder)
    #expect(observed.candidateText == "aa" && observed.discontinuities == 1)
    #expect(HandwritingTrialScore.evaluate(observed, annotation: .asPrompted(trial)).excludedReason == "model stream discontinuity")
}
