import Foundation
import Testing
@testable import KinesisCapture
@testable import KinesisCore

private struct CaptureFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-analysis-\(UUID())")
    var source: URL { root.appendingPathComponent("source") }
    var output: URL { root.appendingPathComponent("report") }
    init() throws { try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true) }
    func write(_ name: String, _ rows: [[String: Any]]) throws {
        let data = try rows.reduce(into: Data()) { $0 += try JSONSerialization.data(withJSONObject: $1); $0.append(10) }
        try data.write(to: source.appendingPathComponent(name))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func inference(_ label: Int, sequence: UInt64, order: Int, device: UInt64? = nil) -> [String: Any] {
    var values = Data()
    for index in 0..<100 {
        var bits = Float(index == label ? 0 : -100).bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { values.append(contentsOf: $0) }
    }
    let time = device ?? (sequence * 156_250 + 1)
    let payload = BandWire.field(1, sequence) + BandWire.field(2, time) + BandWire.field(3, values) + BandWire.field(10, 3)
    return ["event": "raw_inference_payload", "sequence": sequence, "timestamp_us": time, "pipeline_type": 3,
            "payload": payload.map { String(format: "%02x", $0) }.joined(), "host_unix": Double(order), "host_monotonic": Double(order), "journal_order": order]
}

@Test func nativeReplayUsesExactBoundariesAndPreservesRawEditingTokens() throws {
    let fixture = try CaptureFixture(); defer { fixture.remove() }
    try fixture.write("markers.jsonl", [
        ["event": "recording_started", "mode": "handwriting", "journal_order": 1],
        ["event": "decoder_candidate", "journal_order": 2],
        ["event": "candidate_character", "class": 7, "sequence": 1, "journal_order": 3],
        ["event": "candidate_character", "class": 87, "sequence": 2, "journal_order": 5],
        ["event": "candidate_character", "class": 88, "sequence": 3, "journal_order": 7],
        ["event": "candidate_character", "class": 94, "sequence": 4, "journal_order": 9],
        ["event": "recording_stopped", "journal_order": 11],
        ["event": "session_end", "restoration_verified": true, "journal_order": 13]])
    try fixture.write("inference.jsonl", [inference(0, sequence: 0, order: 0), inference(7, sequence: 1, order: 4),
        inference(87, sequence: 2, order: 6), inference(88, sequence: 3, order: 8), inference(94, sequence: 4, order: 10),
        inference(1, sequence: 5, order: 12)])
    let report = try CaptureAnalysis.run(directory: fixture.source, output: fixture.output)
    #expect(report.editedCandidateText == "h" && report.rawCandidateText == "h^_⌫")
    #expect(report.tokenReplayMatches == true && report.recordingWindowExact)
    #expect(report.pipeline3Packets == 6 && report.restorationVerified == true)
    #expect(report.medianPipeline3IntervalUs == 156_250 && report.discontinuities.isEmpty)
    #expect(report.characterErrorRate == nil)
    #expect(try Data(contentsOf: fixture.source.appendingPathComponent("markers.jsonl")) == Data(contentsOf: fixture.output.appendingPathComponent("markers.jsonl")))
    let csv = try String(contentsOf: fixture.output.appendingPathComponent("pipeline3.csv"), encoding: .utf8)
    #expect(csv.contains("log_probability_99") && csv.split(separator: "\n").count == 7)
    #expect(throws: CaptureAnalysisError.self) { try CaptureAnalysis.run(directory: fixture.source, output: fixture.output) }
}

@Test func captureReportsGapsDuplicatesResetsAndSequenceWrapWithoutJoiningThem() throws {
    let fixture = try CaptureFixture(); defer { fixture.remove() }
    try fixture.write("markers.jsonl", [["event": "decoder_candidate", "host_unix": -1]])
    try fixture.write("inference.jsonl", [inference(0, sequence: UInt64(UInt32.max), order: 0, device: 10),
        inference(0, sequence: 0, order: 1, device: 20), inference(0, sequence: 0, order: 2, device: 20),
        inference(0, sequence: 3, order: 3, device: 50), inference(0, sequence: 0, order: 4, device: 1)])
    let report = try CaptureAnalysis.run(directory: fixture.source, output: fixture.output)
    #expect(report.discontinuities.map(\.kind) == ["duplicate", "gap", "clock_or_sequence_reset"])
    #expect(report.discontinuities[1].missing == 2)
    #expect(!report.recordingWindowExact && !report.hasSessionEnd && report.tokenReplayMatches == false)
    #expect(report.rawCandidateText == "aaa")
}

@Test func nativeSensorExportsUseRecordedConfigurationAndKeepExactContactIdentity() throws {
    let fixture = try CaptureFixture(); defer { fixture.remove() }
    try fixture.write("markers.jsonl", [])
    let emgConfig = BandWire.field(2, 1) + BandWire.field(6, BandWire.field(42,
        BandWire.field(1, 2048) + BandWire.field(2, 8) + BandWire.field(4, 16) + BandWire.field(5, 16) + BandWire.field(10, 0)))
    try fixture.write("inference.jsonl", [["event": "inference_configuration", "payload": emgConfig.map { String(format: "%02x", $0) }.joined()]])
    var values = Data()
    for value in UInt16(0)..<128 { var v = value.littleEndian; withUnsafeBytes(of: &v) { values.append(contentsOf: $0) } }
    let payload = BandWire.field(1, 8) + BandWire.field(2, 100_000) + BandWire.field(3, values)
    try fixture.write("emg.jsonl", [["payload": payload.map { String(format: "%02x", $0) }.joined(), "uptime": 5.0]])
    try fixture.write("motion.jsonl", [["event": "gyro", "at": 5.0, "t": 100_000, "v": [1, -2, 3]]])
    try fixture.write("touches.jsonl", [["host_monotonic": 5.0, "t": 4.9, "id": Int64.max, "phase": "moved", "resting": false, "x": 0.25, "y": 0.75, "w": 120, "h": 75],
                                      ["host_monotonic": 5.1, "t": 5.0, "click": true]])
    let report = try CaptureAnalysis.run(directory: fixture.source, output: fixture.output)
    #expect(report.emgBatches == 1 && report.emgSampleFrames == 16 && report.gyroSamples == 1 && report.touchEvents == 1)
    let emg = try String(contentsOf: fixture.output.appendingPathComponent("emg.csv"), encoding: .utf8)
    #expect(emg.contains("5.0,8,100000,0.0,0,0,1,2,3,4,5,6,7\n"))
    #expect(emg.contains(",120,121,122,123,124,125,126,127\n"))
    let touch = try String(contentsOf: fixture.output.appendingPathComponent("touches.csv"), encoding: .utf8)
    #expect(touch.contains("9223372036854775807,moved,false,0.25,0.75,120.0,75.0"))
    #expect(report.clickEvents == 1)
    #expect(try String(contentsOf: fixture.output.appendingPathComponent("clicks.csv"), encoding: .utf8) == "logged_monotonic,event_monotonic,pressed\n5.1,5.0,true\n")
}

@Test func corruptOrTruncatedCaptureNeverLeavesASuccessReport() throws {
    let fixture = try CaptureFixture(); defer { fixture.remove() }
    try fixture.write("markers.jsonl", [])
    var row = inference(0, sequence: 0, order: 0); row["sequence"] = 42
    try fixture.write("inference.jsonl", [row])
    #expect(throws: CaptureAnalysisError.self) { try CaptureAnalysis.run(directory: fixture.source, output: fixture.output) }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
    try Data("{\"event\":\"raw_inference_payload\"".utf8).write(to: fixture.source.appendingPathComponent("inference.jsonl"))
    #expect(throws: CaptureAnalysisError.self) { try CaptureAnalysis.run(directory: fixture.source, output: fixture.output) }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
}

@Test func guidedReplayUsesUIBoundariesChecksReviewProvenanceAndRetainsAnInterruptedTrial() throws {
    let fixture = try CaptureFixture(); defer { fixture.remove() }
    let trial = HandwritingTrial(kind: .text, prompt: "write ba", intendedText: "ba", actionSeconds: 5)
    let trialFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trial))
    let markers: [[String: Any]] = [
        ["event": "session_start", "surface": "desk", "wearing_id": "wearing-one", "hand": "right", "handwriting_split": "development", "journal_order": 0],
        ["event": "recording_started", "mode": "handwriting", "journal_order": 1],
        ["event": "decoder_candidate", "journal_order": 2],
        ["event": "handwriting_trial_start", "trial": trialFields, "journal_order": 3, "host_monotonic": 3],
        ["event": "candidate_character", "class": 1, "sequence": 0, "journal_order": 4],
        ["event": "model_state", "state": "restoring", "journal_order": 6],
        ["event": "candidate_character", "class": 0, "sequence": 1, "journal_order": 7],
        ["event": "handwriting_trial_end", "trial_id": trial.id, "interrupted": false, "journal_order": 9, "host_monotonic": 9],
        ["event": "recording_stopped", "journal_order": 10],
        ["event": "session_end", "journal_order": 11]]
    try fixture.write("markers.jsonl", markers)
    try fixture.write("inference.jsonl", [inference(1, sequence: 0, order: 5), inference(0, sequence: 1, order: 8)])
    let unreviewed = try CaptureAnalysis.run(directory: fixture.source, output: fixture.output)
    #expect(unreviewed.tokenReplayMatches == true && unreviewed.characterErrorRate == nil)
    var review = try #require(unreviewed.handwritingReview)
    #expect(review.results[0].candidateText == "ba" && review.results[0].sampleCount == 2)
    review.annotations = [.asPrompted(trial)]
    let reviewFile = fixture.source.appendingPathComponent("handwriting-trials.json")
    try JSONEncoder().encode(review).write(to: reviewFile)
    let reviewed = try CaptureAnalysis.run(directory: fixture.source, output: fixture.root.appendingPathComponent("reviewed"))
    #expect(reviewed.savedTrialResultsMatch == true && reviewed.characterErrorRate == 0 && reviewed.scoredTextTrials == 1)
    var corrupt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: reviewFile)) as? [String: Any])
    var results = try #require(corrupt["results"] as? [[String: Any]])
    results[0]["candidateText"] = "invented"
    corrupt["results"] = results
    try JSONSerialization.data(withJSONObject: corrupt).write(to: reviewFile)
    #expect(throws: CaptureAnalysisError.self) {
        try CaptureAnalysis.run(directory: fixture.source, output: fixture.root.appendingPathComponent("corrupted"))
    }
    try FileManager.default.removeItem(at: reviewFile)
    try fixture.write("markers.jsonl", Array(markers.prefix(4)))
    let interrupted = try CaptureAnalysis.run(directory: fixture.source, output: fixture.root.appendingPathComponent("interrupted"))
    #expect(interrupted.handwritingReview?.results[0].interrupted == true)
    #expect(interrupted.trialScores[0].excludedReason == "interrupted trial")
    #expect(!interrupted.hasSessionEnd && !interrupted.recordingWindowExact)
}
