import CryptoKit
import CoreFoundation
import Foundation
import KinesisCore

struct CaptureAnalysisError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct CaptureAnalysis {
    struct Source: Codable { let bytes: Int; let sha256: String }
    struct Discontinuity: Codable {
        let stream: String
        let kind: String
        let sequence: UInt64?
        let deviceTime: UInt64
        let missing: UInt64?
    }
    struct Token: Equatable, Codable { let sequence: UInt64; let label: Int }
    struct Report: Codable {
        var schemaVersion = 2
        var sources: [String: Source] = [:]
        var pipeline3Packets = 0
        var pipelineCounts: [String: Int] = [:]
        var emgBatches = 0
        var emgRecordedRows = 0
        var emgSampleFrames = 0
        var gyroSamples = 0
        var touchEvents = 0
        var clickEvents = 0
        var discontinuities: [Discontinuity] = []
        var medianPipeline3IntervalUs: Double?
        var rawCandidateText = ""
        var editedCandidateText = ""
        var replayedTokens: [Token] = []
        var recordedTokens: [Token] = []
        var tokenReplayMatches: Bool?
        var recordedAlphabetMatches: Bool?
        var decoderAlphabet = ExperimentalHandwritingDecoder.characters
        var decoderBlank = ExperimentalHandwritingDecoder.blank
        var previewActions = Dictionary(uniqueKeysWithValues: ExperimentalHandwritingDecoder.previewActions.map { (String($0.key), $0.value.rawValue) })
        var recordingWindowExact = false
        var restorationVerified: Bool?
        var hasSessionEnd = false
        var annotationPresent = false
        var characterErrorRate: Double? = nil
        var handwritingReview: HandwritingTrialReview?
        var trialScores: [HandwritingTrialScore] = []
        var savedTrialResultsMatch: Bool?
        var scoredTextTrials = 0
        var textErrorCounts = HandwritingEditCounts()
        var limits = ["Character and control mappings remain experimental.",
                      "Native payloads are not an independent packet-MAC verification.",
                      "Host receipt times do not establish end-to-end model latency.",
                      "Trackpad coordinates are normalized device coordinates, not millimeters.",
                      "Freeform session annotations have no exact trial bounds and are not scored."]
    }

    private struct Row {
        let fields: [String: Any]
        let file: String
        let line: Int
        var event: String { fields["event"] as? String ?? "" }
        func number(_ key: String) throws -> Double {
            guard let value = fields[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
                throw error("missing or invalid \(key)")
            }
            return value.doubleValue
        }
        func integer(_ key: String) throws -> UInt64 {
            guard let value = fields[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  let integer = UInt64(value.stringValue) else { throw error("invalid integer \(key)") }
            return integer
        }
        func hex(_ key: String) throws -> Data {
            guard let text = fields[key] as? String, text.utf8.count.isMultiple(of: 2) else { throw error("invalid hex \(key)") }
            var bytes = Data(); bytes.reserveCapacity(text.utf8.count / 2)
            var nibble: UInt8?
            for byte in text.utf8 {
                let value: UInt8
                switch byte { case 48...57: value = byte - 48; case 65...70: value = byte - 55; case 97...102: value = byte - 87; default: throw error("invalid hex \(key)") }
                if let high = nibble { bytes.append(high << 4 | value); nibble = nil } else { nibble = value }
            }
            return bytes
        }
        func error(_ message: String) -> CaptureAnalysisError { .init("\(file):\(line): \(message)") }
    }

    private struct Continuity {
        var sequence: UInt64?
        var timestamp: UInt64?
        var segment = 0

        mutating func check(sequence next: UInt64?, time: UInt64, stream: String, report: inout Report) -> Bool {
            defer { sequence = next; timestamp = time }
            guard let timestamp else { return false }
            let kind: String?
            var missing: UInt64?
            if next == sequence, time == timestamp { kind = "duplicate" }
            else if time <= timestamp { kind = "clock_or_sequence_reset" }
            else if let sequence, let next, next != ((sequence + 1) & UInt64(UInt32.max)) {
                if next > sequence { missing = next - sequence - 1; kind = "gap" }
                else { kind = "sequence_reset" }
            } else { kind = nil }
            if let kind {
                segment += 1
                report.discontinuities.append(.init(stream: stream, kind: kind, sequence: next, deviceTime: time, missing: missing))
                return false
            }
            return true
        }
    }

    /// Streams large sensor files; memory use is bounded by a JSONL row. Hashes
    /// cover the bytes actually parsed, including the final newline.
    private static func rows(_ url: URL, copyTo: FileHandle? = nil, receive: (Row) throws -> Void) throws -> Source {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data(), hash = SHA256(), count = 0, line = 0
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try copyTo?.write(contentsOf: chunk)
            hash.update(data: chunk); count += chunk.count; pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let data = pending[..<newline]
                line += 1
                do {
                    guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CaptureAnalysisError("expected a JSON object") }
                    try receive(Row(fields: fields, file: url.lastPathComponent, line: line))
                } catch { throw CaptureAnalysisError("\(url.lastPathComponent):\(line): \(error.localizedDescription)") }
                pending.removeSubrange(...newline)
            }
        }
        guard pending.isEmpty else { throw CaptureAnalysisError("\(url.lastPathComponent): incomplete final JSONL record") }
        return Source(bytes: count, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func csv(_ fields: [String], to handle: FileHandle) throws {
        let line = fields.map { value in
            value.contains(",") || value.contains("\"") || value.contains("\n") ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }.joined(separator: ",") + "\n"
        try handle.write(contentsOf: Data(line.utf8))
    }

    static func run(directory: URL, output: URL) throws -> Report {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw CaptureAnalysisError("output directory already exists") }
        let staging = output.deletingLastPathComponent().appendingPathComponent(".capture-report-\(UUID())")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        var handles: [String: FileHandle] = [:]
        defer { for handle in handles.values { try? handle.close() } }
        for name in ["pipeline3.csv", "emg.csv", "gyro.csv", "touches.csv", "clicks.csv", "markers.jsonl"] {
            let url = staging.appendingPathComponent(name)
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            handles[name] = try FileHandle(forWritingTo: url)
        }
        let inferenceCSV = handles["pipeline3.csv"]!, emgCSV = handles["emg.csv"]!, gyroCSV = handles["gyro.csv"]!, touchCSV = handles["touches.csv"]!, clickCSV = handles["clicks.csv"]!
        try csv(["logged_unix", "received_monotonic", "device_us", "sequence", "segment", "winner", "device_latency_us"] + (0..<100).map { "log_probability_\($0)" }, to: inferenceCSV)
        try csv(["processed_monotonic", "batch_sequence", "batch_device_us", "sample_offset_us", "segment"] + (0..<8).map { "adc_\($0)" }, to: emgCSV)
        try csv(["received_monotonic", "device_us", "segment", "x_raw", "y_raw", "z_raw"], to: gyroCSV)
        try csv(["logged_monotonic", "event_monotonic", "contact_id", "phase", "resting", "x_normalized", "y_normalized", "device_width_points", "device_height_points"], to: touchCSV)
        try csv(["logged_monotonic", "event_monotonic", "pressed"], to: clickCSV)

        var report = Report(), journal: [Row] = []
        let markerURL = directory.appendingPathComponent("markers.jsonl")
        report.sources["markers.jsonl"] = try rows(markerURL, copyTo: handles["markers.jsonl"]) { row in
            journal.append(row)
            if row.event == "candidate_character" {
                let label = try row.integer("class")
                guard label < 100 else { throw row.error("invalid class") }
                report.recordedTokens.append(Token(sequence: try row.integer("sequence"), label: Int(label)))
            }
            if row.event == "session_end" { report.hasSessionEnd = true; report.restorationVerified = row.fields["restoration_verified"] as? Bool }
            if row.event == "decoder_candidate", let alphabet = row.fields["characters"] as? [String] {
                report.recordedAlphabetMatches = alphabet == ExperimentalHandwritingDecoder.characters
            }
        }
        var inferenceContinuity = Continuity(), intervals: [UInt64] = [], emgConfiguration: EMGConfiguration?
        report.sources["inference.jsonl"] = try rows(directory.appendingPathComponent("inference.jsonl")) { row in
            if row.event == "inference_configuration" {
                let data = try row.hex("payload")
                if let config = try? EMGConfiguration(response: data) {
                    if let previous = emgConfiguration, previous != config { throw row.error("EMG configuration changed; split the recording before exporting samples") }
                    emgConfiguration = config
                }
                return
            }
            guard row.event == "raw_inference_payload" else { return }
            let sample = try BandInferenceSample(payload: row.hex("payload"))
            guard try sample.sequence == row.integer("sequence"), try sample.timestampUs == row.integer("timestamp_us"), try sample.pipeline == row.integer("pipeline_type") else {
                throw row.error("metadata disagrees with inference payload")
            }
            report.pipelineCounts[String(sample.pipeline), default: 0] += 1
            guard sample.pipeline == 3 else { return }
            guard sample.isTextDistribution else { throw row.error("pipeline 3 is not a normalized 100-class distribution") }
            let oldTime = inferenceContinuity.timestamp
            let continuous = inferenceContinuity.check(sequence: sample.sequence, time: sample.timestampUs, stream: "pipeline3", report: &report)
            if continuous, let oldTime { intervals.append(sample.timestampUs - oldTime) }
            let winner = sample.values.indices.max { sample.values[$0] < sample.values[$1] }!
            let metadata = [String(try row.number("host_unix")), String(try row.number("host_monotonic")), String(sample.timestampUs), String(sample.sequence), String(inferenceContinuity.segment), String(winner), sample.latencyUs.map { String($0) } ?? ""]
            try csv(metadata + sample.values.map { String($0) }, to: inferenceCSV)
            report.pipeline3Packets += 1
            journal.append(row)
        }
        if !intervals.isEmpty {
            intervals.sort()
            let middle = intervals.count / 2
            report.medianPipeline3IntervalUs = intervals.count.isMultiple(of: 2) ? (Double(intervals[middle - 1]) + Double(intervals[middle])) / 2 : Double(intervals[middle])
        }
        let exactOrder = journal.allSatisfy { $0.fields["journal_order"] != nil }
        let keyed = try journal.map { (try $0.number(exactOrder ? "journal_order" : "host_unix"), $0) }
        if exactOrder, Set(keyed.map(\.0)).count != keyed.count { throw CaptureAnalysisError("duplicate journal order") }
        journal = keyed.sorted { $0.0 < $1.0 }.map(\.1)
        let explicitStart = exactOrder && journal.contains { $0.event == "recording_started" }
        report.recordingWindowExact = explicitStart && journal.contains { $0.event == "recording_stopped" }
        if !report.recordingWindowExact { report.limits.append("Recording boundaries are incomplete or lack shared journal order; exact UI timing is unavailable.") }
        var decoder = ExperimentalHandwritingDecoder(), active = false, sawDecoder = false
        var trialObservation: HandwritingTrialObservation?
        var trialResults: [HandwritingTrialResult] = []
        var trialIDs: Set<String> = []
        for row in journal {
            switch row.event {
            case "recording_started": active = row.fields["mode"] as? String == "handwriting"
            case "decoder_candidate":
                if !explicitStart { active = true }
                sawDecoder = true
            case "recording_stopped": active = false
            case "model_state":
                if !explicitStart, ["restoring", "finished"].contains(row.fields["state"] as? String ?? "") { active = false }
            case "handwriting_clear":
                guard trialObservation == nil else { throw row.error("text cleared during a guided trial") }
                decoder.clearText()
            case "handwriting_trial_start":
                guard active, trialObservation == nil, explicitStart,
                      let fields = row.fields["trial"] else {
                    throw row.error("trial start has no exact active recording window or overlaps another trial")
                }
                let trial = try JSONDecoder().decode(HandwritingTrial.self, from: JSONSerialization.data(withJSONObject: fields))
                guard trialIDs.insert(trial.id).inserted else { throw row.error("duplicate handwriting trial ID") }
                decoder.resetText(to: trial.initialText)
                trialObservation = HandwritingTrialObservation(trial: trial, order: try row.integer("journal_order"),
                    at: try row.number("host_monotonic"), decoder: decoder)
            case "handwriting_trial_end":
                guard active, let observation = trialObservation, row.fields["trial_id"] as? String == observation.trial.id,
                      let interrupted = row.fields["interrupted"] as? Bool else { throw row.error("unmatched handwriting trial end") }
                trialResults.append(observation.finish(order: try row.integer("journal_order"), at: try row.number("host_monotonic"),
                    interrupted: interrupted, decoder: decoder))
                trialObservation = nil
            case "raw_inference_payload":
                guard active else { continue }
                let sample = try BandInferenceSample(payload: row.hex("payload"))
                let label = decoder.consume(sample)
                trialObservation?.receive(label: label)
                if let label { report.replayedTokens.append(Token(sequence: sample.sequence, label: label)) }
            default: break
            }
        }
        report.rawCandidateText = decoder.rawText; report.editedCandidateText = decoder.text
        if sawDecoder { report.tokenReplayMatches = report.replayedTokens == report.recordedTokens }
        if let observation = trialObservation, let last = journal.last {
            trialResults.append(observation.finish(order: try last.integer("journal_order"), at: try last.number("host_monotonic"),
                interrupted: true, decoder: decoder))
        }
        let reviewURL = directory.appendingPathComponent("handwriting-trials.json")
        if !trialResults.isEmpty || fm.fileExists(atPath: reviewURL.path) {
            guard let session = journal.first(where: { $0.event == "session_start" }),
                  let surface = session.fields["surface"] as? String, let wearing = session.fields["wearing_id"] as? String,
                  let hand = session.fields["hand"] as? String, let splitText = session.fields["handwriting_split"] as? String,
                  let split = HandwritingTrial.Split(rawValue: splitText) else { throw CaptureAnalysisError("guided trial session metadata is missing") }
            var review = HandwritingTrialReview(recordingID: directory.lastPathComponent, surface: surface, wearingID: wearing,
                hand: hand, split: split, results: trialResults)
            if fm.fileExists(atPath: reviewURL.path) {
                let data = try Data(contentsOf: reviewURL)
                let saved = try JSONDecoder().decode(HandwritingTrialReview.self, from: data)
                guard saved.schemaVersion == 1, saved.recordingID == review.recordingID, saved.surface == surface,
                      saved.wearingID == wearing, saved.hand == hand, saved.split == split,
                      Set(saved.results.map(\.id)).count == saved.results.count,
                      Set(saved.annotations.map(\.id)).count == saved.annotations.count,
                      Set(saved.annotations.map(\.id)).isSubset(of: Set(saved.results.map(\.id))) else {
                    throw CaptureAnalysisError("trial annotations do not match the recorded session")
                }
                report.savedTrialResultsMatch = saved.results.allSatisfy { savedResult in trialResults.contains(savedResult) }
                guard report.savedTrialResultsMatch == true else { throw CaptureAnalysisError("saved trial results disagree with native replay") }
                review.annotations = saved.annotations
                report.sources["handwriting-trials.json"] = Source(bytes: data.count,
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
                let copy = staging.appendingPathComponent("handwriting-trials.json")
                try data.write(to: copy)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
            }
            report.handwritingReview = review
            report.trialScores = trialResults.map { result in
                HandwritingTrialScore.evaluate(result, annotation: review.annotations.first { $0.id == result.id })
            }
            for score in report.trialScores {
                if let errors = score.textErrors {
                    report.scoredTextTrials += 1
                    report.textErrorCounts.referenceCount += errors.referenceCount
                    report.textErrorCounts.substitutions += errors.substitutions
                    report.textErrorCounts.deletions += errors.deletions
                    report.textErrorCounts.insertions += errors.insertions
                }
            }
            report.characterErrorRate = report.textErrorCounts.rate
            report.limits.append("Trial windows use host processing order and include a settling tail; they are not independent action-completion timestamps.")
            report.limits.append("Idle counts omit the tentatively ignored class 87; original emitted labels remain in each trial result.")
        }

        let emgURL = directory.appendingPathComponent("emg.jsonl")
        if fm.fileExists(atPath: emgURL.path) {
            var continuity = Continuity()
            report.sources["emg.jsonl"] = try rows(emgURL) { row in
                report.emgRecordedRows += 1
                guard let config = emgConfiguration else { return }
                let batch = try EMGBatch(payload: row.hex("payload"), configuration: config)
                guard batch.sequence <= UInt32.max else { throw row.error("invalid EMG sequence") }
                _ = continuity.check(sequence: batch.sequence, time: batch.timestampUs, stream: "emg", report: &report)
                let arrival = try row.number("uptime")
                for sample in 0..<EMGBatch.sampleCount {
                    let values = batch.values[(sample * 8)..<(sample * 8 + 8)]
                    try csv([String(arrival), String(batch.sequence), String(batch.timestampUs), String(Double(sample) * EMGBatch.sampleIntervalUs), String(continuity.segment)] + values.map(String.init), to: emgCSV)
                }
                report.emgBatches += 1; report.emgSampleFrames += EMGBatch.sampleCount
            }
            if emgConfiguration == nil { report.limits.append("No recorded EMG configuration was found; EMG values were not exported or validated.") }
        }
        let gyroURL = directory.appendingPathComponent("motion.jsonl")
        if fm.fileExists(atPath: gyroURL.path) {
            var continuity = Continuity()
            report.sources["motion.jsonl"] = try rows(gyroURL) { row in
                guard row.event == "gyro" else { return }
                let time = try row.integer("t")
                guard let values = row.fields["v"] as? [Double], values.count == 3, values.allSatisfy(\.isFinite) else { throw row.error("invalid gyro vector") }
                _ = continuity.check(sequence: nil, time: time, stream: "gyro", report: &report)
                try csv([String(try row.number("at")), String(time), String(continuity.segment)] + values.map { String($0) }, to: gyroCSV)
                report.gyroSamples += 1
            }
        }
        let touchURL = directory.appendingPathComponent("touches.jsonl")
        if fm.fileExists(atPath: touchURL.path) {
            report.sources["touches.jsonl"] = try rows(touchURL) { row in
                if let click = row.fields["click"] {
                    guard let pressed = click as? Bool else { throw row.error("invalid click state") }
                    try csv([String(try row.number("host_monotonic")), String(try row.number("t")), String(pressed)], to: clickCSV)
                    report.clickEvents += 1
                    return
                }
                guard let phase = row.fields["phase"] as? String, ["began", "moved", "stationary", "ended", "cancelled"].contains(phase), let resting = row.fields["resting"] as? Bool else { throw row.error("invalid touch state") }
                guard let contact = row.fields["id"] as? NSNumber, CFGetTypeID(contact) != CFBooleanGetTypeID(),
                      let identifier = Int64(contact.stringValue) else { throw row.error("invalid contact identifier") }
                let x = try row.number("x"), y = try row.number("y"), width = try row.number("w"), height = try row.number("h")
                guard (0...1).contains(x), (0...1).contains(y), width > 0, height > 0 else { throw row.error("invalid trackpad coordinates") }
                try csv([String(try row.number("host_monotonic")), String(try row.number("t")), String(identifier), phase, String(resting), String(x), String(y), String(width), String(height)], to: touchCSV)
                report.touchEvents += 1
            }
        }
        report.annotationPresent = fm.fileExists(atPath: directory.appendingPathComponent("user-annotation.json").path)
        if !report.hasSessionEnd { report.limits.append("No session-end marker: recording may still be active or was interrupted.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reportURL = staging.appendingPathComponent("report.json")
        try encoder.encode(report).write(to: reportURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        for handle in handles.values { try handle.close() }; handles = [:]
        try fm.moveItem(at: staging, to: output)
        return report
    }
}
