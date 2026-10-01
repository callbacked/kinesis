import Foundation
import Testing
@testable import KinesisCore
@testable import Kinesis

@MainActor private func waitForWriting(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
}

/// Handwriting as release builds run it.
@Suite(.serialized) @MainActor struct HandwritingWritingTests {
    /// What release builds do: write, without saving anything or asking for raw sEMG.
    @Test func writingWithoutSavingLeavesNoFilesAndNeedsNoSEMG() async throws {
        let connection = RecordedConnection()
        let model = BandModel(defaults: MemoryDefaults(), connection: connection, sessionStore: SavedSessionStore())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handwriting-nosave-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectedAddress = "test-band"; model.connect()
        connection.send(.connected, at: ProcessInfo.processInfo.systemUptime)
        connection.send(.heartbeat, at: ProcessInfo.processInfo.systemUptime)
        model.developerMode = true
        let recording = BandModelRecording(model: model, mode: .handwriting, saves: false, root: root)
        // A guided test only exists to save its signals.
        recording.guidedHandwriting = true
        recording.start()
        #expect(!recording.isRunning && recording.problem != nil)
        recording.guidedHandwriting = false
        recording.start()
        // No sEMG has arrived, and none is asked for: the band switches right away.
        try await waitForWriting { connection.modelCaptureRequests == [true] }
        #expect(!connection.rawEMGMode)
        connection.send(.modelCaptureState(.init(phase: .ready, message: "ready")), at: ProcessInfo.processInfo.systemUptime)
        try await waitForWriting { recording.phase == .recording }
        for (sequence, label) in [7, 8].enumerated() {
            connection.send(.inferenceFrame(try handwritingFrame(label, sequence: UInt64(sequence))), at: ProcessInfo.processInfo.systemUptime)
        }
        try await waitForWriting { recording.candidateText == "hi" }
        recording.finish()
        try await waitForWriting { connection.modelCaptureRequests == [true, false] }
        connection.send(.modelCaptureState(.init(phase: .finished, message: "restored", restorationVerified: true)), at: ProcessInfo.processInfo.systemUptime)
        try await waitForWriting { recording.done }
        #expect(recording.folder == nil && recording.problem == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

private func handwritingFrame(_ label: Int, sequence: UInt64) throws -> BandInferenceSample {
    var values = Data()
    for index in 0..<100 {
        var bits = Float(index == label ? 0 : -100).bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { values.append(contentsOf: $0) }
    }
    return try BandInferenceSample(payload: BandWire.field(1, sequence) + BandWire.field(2, 1_000_000 + sequence * 156_250)
        + BandWire.field(3, values) + BandWire.field(10, 3))
}
