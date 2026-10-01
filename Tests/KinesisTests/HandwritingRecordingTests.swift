#if KINESIS_DEV
import Foundation
import Testing
@testable import KinesisCore
@testable import Kinesis
@testable import KinesisCapture

@MainActor private func waitForRecording(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
}

@Suite(.serialized) @MainActor struct HandwritingRecordingTests {
    @Test(arguments: [false, true]) func guidedTrialsRoundTripThroughNativeRecordingReviewAndOfflineScoring(markedMissed: Bool) async throws {
        let connection = RecordedConnection()
        let model = BandModel(defaults: MemoryDefaults(), connection: connection, sessionStore: SavedSessionStore())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handwriting-trials-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectedAddress = "test-band"; model.connect()
        connection.send(.connected, at: ProcessInfo.processInfo.systemUptime)
        connection.send(.heartbeat, at: ProcessInfo.processInfo.systemUptime)
        model.developerMode = true
        let plan = [HandwritingTrial(kind: .text, prompt: "write hi", intendedText: "hi", actionSeconds: 0.3, settleSeconds: 0.1),
                    HandwritingTrial(kind: .command, prompt: "delete once", intendedActions: ["backspace"], initialText: "ab", actionSeconds: 0.3, settleSeconds: 0.1)]
        let recording = BandModelRecording(model: model, mode: .handwriting, root: root, handwritingPlan: { _ in plan })
        recording.guidedHandwriting = true
        recording.start()
        let configData = BandWire.field(2, 1) + BandWire.field(6, BandWire.field(42,
            BandWire.field(1, 2048) + BandWire.field(2, 8) + BandWire.field(4, 16) + BandWire.field(5, 16) + BandWire.field(10, 0)))
        connection.send(.rawEMGConfiguration(try EMGConfiguration(response: configData)), at: ProcessInfo.processInfo.systemUptime)
        connection.send(.rawEMGState(true), at: ProcessInfo.processInfo.systemUptime)
        connection.send(.rawEMGFrame(BandWire.field(1, 1) + BandWire.field(2, 1_000_000)
            + BandWire.field(3, Data(repeating: 0, count: 256))), at: ProcessInfo.processInfo.systemUptime)
        connection.send(.gyro(timestamp: 1_000_000, values: .zero), at: ProcessInfo.processInfo.systemUptime)
        try await waitForRecording { connection.modelCaptureRequests == [true] }
        connection.send(.inferenceConfiguration(configData), at: ProcessInfo.processInfo.systemUptime)
        connection.send(.modelCaptureState(.init(phase: .ready, message: "ready")), at: ProcessInfo.processInfo.systemUptime)
        try await waitForRecording { recording.writingTrialIndex == 0 }
        for (sequence, label) in [7, 8].enumerated() {
            connection.send(.inferenceFrame(try writingSample(label, sequence: UInt64(sequence))), at: ProcessInfo.processInfo.systemUptime)
        }
        if markedMissed { recording.markWritingTrialMissed() }
        try await waitForRecording { recording.writingTrialIndex == 1 }
        recording.annotateTrial(.asPrompted(plan[0]))
        #expect(recording.trialReview?.annotations[0].status == (markedMissed ? .excluded : .unreviewed))
        connection.send(.inferenceFrame(try writingSample(94, sequence: 2)), at: ProcessInfo.processInfo.systemUptime)
        try await waitForRecording { connection.modelCaptureRequests == [true, false] }
        connection.send(.modelCaptureState(.init(phase: .finished, message: "restored", restorationVerified: true)), at: ProcessInfo.processInfo.systemUptime)
        try await waitForRecording { recording.done }
        let review = try #require(recording.trialReview), folder = try #require(recording.folder)
        #expect(review.results.map(\.candidateText) == ["hi", "a"])
        #expect(review.results.map(\.sampleCount) == [2, 1])
        #expect(review.results[0].interrupted == markedMissed && !review.results[1].interrupted)
        #expect(review.wearingID == model.recordingWearingID && review.split == .development)
        let before = try CaptureAnalysis.run(directory: folder, output: root.appendingPathComponent("before-review"))
        #expect(before.savedTrialResultsMatch == true && before.tokenReplayMatches == true)
        #expect(before.scoredTextTrials == 0 && before.characterErrorRate == nil)
        recording.annotateTrial(.asPrompted(plan[0]))
        recording.annotateTrial(.asPrompted(plan[1]))
        let after = try CaptureAnalysis.run(directory: folder, output: root.appendingPathComponent("after-review"))
        #expect(after.scoredTextTrials == (markedMissed ? 0 : 1) && after.characterErrorRate == (markedMissed ? nil : 0))
        #expect(after.trialScores[1].commandErrors?.errors == 0 && after.trialScores[1].commandFinalTextMatches == true)
        #expect(after.handwritingReview?.results == review.results)
        let reopened = BandModelRecording(model: model, mode: .handwriting, root: root)
        reopened.loadTrialReview(from: folder)
        #expect(reopened.done && reopened.trialReview?.annotations.allSatisfy { $0.status == .confirmed } == true)
        await model.shutdown()
    }

    @Test func handwritingUsesBandSamplesWithoutTouchesAndWaitsForRestoration() async throws {
        let connection = RecordedConnection()
        let model = BandModel(defaults: MemoryDefaults(), connection: connection, sessionStore: SavedSessionStore())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handwriting-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectedAddress = "test-band"
        model.connect()
        connection.send(.connected, at: ProcessInfo.processInfo.systemUptime)
        connection.send(.heartbeat, at: ProcessInfo.processInfo.systemUptime)
        model.developerMode = true
        let recording = BandModelRecording(model: model, mode: .handwriting, root: root)
        recording.start()
        let configuration = try EMGConfiguration(response: BandWire.field(2, 1) + BandWire.field(6,
            BandWire.field(42, BandWire.field(1, 2048) + BandWire.field(2, 8) + BandWire.field(4, 16)
                + BandWire.field(5, 16) + BandWire.field(10, 0))))
        connection.send(.rawEMGConfiguration(configuration), at: ProcessInfo.processInfo.systemUptime)
        connection.send(.rawEMGState(true), at: ProcessInfo.processInfo.systemUptime)
        connection.send(.rawEMGFrame(BandWire.field(1, 1) + BandWire.field(2, 1_000_000)
            + BandWire.field(3, Data(repeating: 0, count: 256))), at: ProcessInfo.processInfo.systemUptime)
        connection.send(.gyro(timestamp: 1_000_000, values: .zero), at: ProcessInfo.processInfo.systemUptime)
        try await waitForRecording { connection.modelCaptureRequests == [true] }
        connection.send(.modelCaptureState(.init(phase: .ready, message: "ready")), at: ProcessInfo.processInfo.systemUptime)
        try await waitForRecording { recording.phase == .recording }
        var values = Data()
        for index in 0..<100 {
            var bits = Float(index == 0 ? 0 : -100).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { values.append(contentsOf: $0) }
        }
        let sample = try BandInferenceSample(payload: BandWire.field(1, 1) + BandWire.field(2, 1_000_000)
            + BandWire.field(3, values) + BandWire.field(10, 3))
        connection.send(.inferenceFrame(sample), at: ProcessInfo.processInfo.systemUptime)
        #expect(recording.candidateText == "a" && recording.touchCount == 0 && recording.cueIndex == nil)
        recording.finish()
        try await waitForRecording { connection.modelCaptureRequests == [true, false] }
        #expect(recording.phase == .restoring && model.rawRecordingURL != nil)
        connection.send(.modelCaptureState(.init(phase: .finished, message: "restored", restorationVerified: true)), at: ProcessInfo.processInfo.systemUptime)
        try await waitForRecording { recording.done }
        #expect(model.rawRecordingURL == nil && !connection.rawEMGMode)
        #expect(model.modelCaptureListeners.isEmpty && model.rawEMGListeners.isEmpty && model.gyroListeners.isEmpty)
        let folder = try #require(recording.folder)
        let summary = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("summary.json"))) as? [String: Any])
        #expect(summary["candidateText"] as? String == "a")
        #expect(summary["restorationVerified"] as? Bool == true)
        #expect(summary["decoderMappingVerified"] as? Bool == false)
        await model.shutdown()
    }

    @Test func cancellingPreparationReleasesRecordingWithoutSwitchingBandModel() async throws {
        let connection = RecordedConnection()
        let model = BandModel(defaults: MemoryDefaults(), connection: connection, sessionStore: SavedSessionStore())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handwriting-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectedAddress = "test-band"
        model.connect()
        connection.send(.connected, at: ProcessInfo.processInfo.systemUptime)
        connection.send(.heartbeat, at: ProcessInfo.processInfo.systemUptime)
        model.developerMode = true
        let recording = BandModelRecording(model: model, mode: .handwriting, root: root)
        recording.start()
        recording.finish()
        try await waitForRecording { recording.done }
        #expect(connection.modelCaptureRequests.isEmpty)
        #expect(model.rawRecordingURL == nil && !connection.rawEMGMode)
        #expect(recording.candidateText.isEmpty && model.modelCaptureListeners.isEmpty)
        await model.shutdown()
    }
}

private func writingSample(_ label: Int, sequence: UInt64) throws -> BandInferenceSample {
    var values = Data()
    for index in 0..<100 {
        var bits = Float(index == label ? 0 : -100).bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { values.append(contentsOf: $0) }
    }
    return try BandInferenceSample(payload: BandWire.field(1, sequence) + BandWire.field(2, 1_000_000 + sequence * 156_250)
        + BandWire.field(3, values) + BandWire.field(10, 3))
}
#endif
