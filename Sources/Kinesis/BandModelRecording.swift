import AppKit
import SwiftUI
import KinesisCore

@MainActor final class BandModelRecording: ObservableObject {
    struct Cue {
        let label: String
        let text: String
        let seconds: Double
        let trial: Int
        let block: Int
        let phase: String
    }

    static let cues: [Cue] = {
        let blocks = [
            ["wrist", "hover", "up", "counterclockwise", "touch", "lap", "clockwise", "right", "down", "left"],
            ["left", "clockwise", "lap", "down", "touch", "right", "counterclockwise", "wrist", "up", "hover"],
            ["touch", "down", "right", "hover", "counterclockwise", "up", "left", "clockwise", "lap", "wrist"]
        ]
        let text = ["left": "slide left once.", "right": "slide right once.", "up": "slide up once.", "down": "slide down once.",
                    "clockwise": "draw one clockwise circle.", "counterclockwise": "draw one counterclockwise circle.",
                    "hover": "hover above the trackpad. stay still.", "touch": "touch lightly. keep your finger still.",
                    "lap": "rest your hand on your lap.", "wrist": "fingers off the trackpad. gently rotate your wrist."]
        var result = [Cue(label: "baseline_before", text: "rest your hand on your lap. relax.", seconds: 10, trial: 0, block: 0, phase: "baseline")]
        for (block, labels) in blocks.enumerated() {
            for (index, label) in labels.enumerated() {
                let trial = block * labels.count + index + 1
                result.append(Cue(label: label, text: text[label]!, seconds: 4, trial: trial, block: block + 1, phase: "go"))
                result.append(Cue(label: label, text: "lift your finger. relax and return to the start.", seconds: 2, trial: trial, block: block + 1, phase: "rest"))
            }
        }
        result.append(Cue(label: "baseline_after", text: "rest your hand on your lap. relax.", seconds: 10, trial: 0, block: 0, phase: "baseline"))
        return result
    }()

    enum Mode { case trackpad, handwriting }
    let mode: Mode
    @Published private(set) var candidateText = ""
    @Published private(set) var rawHandwritingText = ""
    @Published private(set) var decodeDiscontinuities = 0
    @Published var surface = "desk"
    @Published var guidedHandwriting = false
    @Published var handwritingSplit = HandwritingTrial.Split.development
    @Published private(set) var writingTrials: [HandwritingTrial] = []
    @Published private(set) var writingTrialIndex: Int?
    @Published private(set) var trialSettling = false
    @Published private(set) var writingTrialEndsAt = Date()
    @Published private(set) var trialReview: HandwritingTrialReview?
    private var trialObservation: HandwritingTrialObservation?
    private var trialMissed = false
    private let handwritingPlan: (HandwritingTrial.Split) -> [HandwritingTrial]
    private var decoder = ExperimentalHandwritingDecoder()

    enum Phase { case idle, preparing, recording, restoring, done }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var cueIndex: Int?
    @Published private(set) var cueEndsAt = Date()
    @Published private(set) var fingers: [CGPoint] = []
    @Published private(set) var touchCount = 0
    @Published private(set) var inferenceCount = 0
    @Published private(set) var inferenceGaps = 0
    @Published private(set) var folder: URL?
    @Published private(set) var problem: String?
    @Published private(set) var status = ""
    private(set) var padSize = CGSize(width: 1, height: 0.62)
    let model: BandModel
    private var files: [String: FileHandle] = [:]
    private var task: Task<Void, Never>?
    private var started = Date()
    private var cueBegan: Double?
    private var lastInference: UInt64?
    private var lastEMG = -Double.infinity
    private var lastGyro = -Double.infinity
    private var restoreControls = false
    private var modelRequested = false
    private var held = false
    private let root: URL
    private var journalOrder = 0
    private let owner = UUID()

    /// Whether a session saves its signals to the Lab folder for research. Dev builds do.
    /// Release builds only write: no files, and no raw sEMG stream.
    let saves: Bool
    static var savesByDefault: Bool {
        #if KINESIS_DEV
        true
        #else
        false
        #endif
    }
    nonisolated static var labFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kinesis/Lab", isDirectory: true)
    }

    init(model: BandModel, mode: Mode = .trackpad, saves: Bool = BandModelRecording.savesByDefault,
         root: URL = BandModelRecording.labFolder,
         handwritingPlan: @escaping (HandwritingTrial.Split) -> [HandwritingTrial] = HandwritingTrial.pilot) {
        self.model = model; self.mode = mode; self.saves = saves; self.root = root
        self.handwritingPlan = handwritingPlan
    }

    /// True while the band's streams are fresh. Without saving, no raw sEMG is asked for, and
    /// the band model's own watch on its output stands in.
    private var streamsFresh: Bool {
        !saves || ProcessInfo.processInfo.systemUptime - min(lastEMG, lastGyro) < 3
    }
    var isRunning: Bool { phase == .preparing || phase == .recording || phase == .restoring }
    var done: Bool { phase == .done }
    var ready: Bool { model.live && model.developerMode && !model.modelControlsUnavailable }

    func start() {
        guard !isRunning else { return }
        guard ready else { problem = "connect the band and turn on developer mode first."; return }
        guard model.rawRecordingURL == nil else { problem = "stop the other recording first."; return }
        // Guided tests and trackpad recordings exist to save their signals.
        guard saves || (mode == .handwriting && !guidedHandwriting) else { problem = "this build doesn’t record."; return }
        if mode == .handwriting && guidedHandwriting,
           surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.recordingWearingID.isEmpty {
            problem = "enter a surface and choose a wearing before starting a guided test."; return
        }
        problem = nil; touchCount = 0; inferenceCount = 0; inferenceGaps = 0
        lastInference = nil; lastEMG = -.infinity; lastGyro = -.infinity; modelRequested = false
        decoder = ExperimentalHandwritingDecoder(); candidateText = ""; rawHandwritingText = ""; decodeDiscontinuities = 0
        writingTrials = mode == .handwriting && guidedHandwriting ? handwritingPlan(handwritingSplit) : []
        writingTrialIndex = nil; trialObservation = nil; trialReview = nil
        started = Date()
        journalOrder = 0
        folder = nil
        if saves { guard openFiles() else { return } }
        restoreControls = model.controlsEnabled
        do { try model.acquireModelRecording(owner) }
        catch {
            for file in files.values { try? file.close() }; files = [:]
            problem = error.localizedDescription
            return
        }
        phase = .preparing; status = saves ? "waiting for muscle and motion signals…" : "getting the band ready…"
        model.rawEMGListeners["band model recording"] = { [weak self] _, arrived in self?.lastEMG = arrived }
        model.gyroListeners["band model recording"] = { [weak self] values, stamp, arrived in
            guard let self else { return }
            self.lastGyro = arrived
            self.write(["event": "gyro", "at": arrived, "t": stamp, "v": [values.x, values.y, values.z]], to: "motion.jsonl")
        }
        model.modelCaptureListeners["band model recording"] = { [weak self] event in self?.receiveModel(event) }
        if saves, let folder {
            held = true
            model.holdRawEMG("band model recording", true)
            model.startRawRecording(to: folder.appendingPathComponent("emg.jsonl"))
            guard model.rawRecordingURL != nil else { problem = model.error ?? "couldn’t save EMG"; finish(); return }
        }
        write(["event": "session_start", "hand": model.bandHand.rawValue, "surface": mode == .trackpad ? "mac_trackpad" : surface, "finger": "index",
               "mode": String(describing: mode), "wearing_id": model.recordingWearingID,
               "handwriting_split": handwritingSplit.rawValue, "guided_handwriting": !writingTrials.isEmpty,
               "decoder_mapping_verified": false], to: "markers.jsonl")
        guard phase == .preparing else { return }
        task = Task { [self] in
            do {
                let deadline = ContinuousClock.now + .seconds(12)
                while saves && (!model.rawEMGActive || ProcessInfo.processInfo.systemUptime - min(lastEMG, lastGyro) > 2) {
                    guard model.live, ContinuousClock.now < deadline else { throw KinesisError(message: "no fresh EMG and gyro from the band") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                try model.setModelCaptureEnabled(true)
                modelRequested = true
                let readyDeadline = ContinuousClock.now + .seconds(45)
                while model.modelCaptureStatus.phase != .ready {
                    guard model.live, model.modelCaptureStatus.active, ContinuousClock.now < readyDeadline else {
                        throw KinesisError(message: model.modelCaptureStatus.problem ?? "the band model did not become ready")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                phase = .recording
                write(["event": "recording_started", "mode": String(describing: mode)], to: "markers.jsonl")
                guard phase == .recording else { return }
                if mode == .handwriting {
                    write(["event": "decoder_candidate", "characters": ExperimentalHandwritingDecoder.characters,
                           "blank": ExperimentalHandwritingDecoder.blank, "method": "greedy_ctc",
                           "preview_edits": Dictionary(uniqueKeysWithValues: ExperimentalHandwritingDecoder.previewActions.map { (String($0.key), $0.value.rawValue) }),
                           "source": "https://github.com/facebookresearch/generic-neuromotor-interface/blob/6d1de94afdfe0c921d08dd24933a5c8d11e8307a/generic_neuromotor_interface/handwriting_utils.py",
                           "firmware_mapping_verified": false], to: "markers.jsonl")
                    if !writingTrials.isEmpty {
                        try await runWritingTrials()
                        finish()
                        return
                    }
                    status = "write with your band hand on your desk or another surface."
                    while model.modelCaptureStatus.phase == .ready {
                        guard model.live, streamsFresh else {
                            throw KinesisError(message: "recording stopped because a band stream ended")
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    finish()
                    return
                }
                CGAssociateMouseAndMouseCursorPosition(0)
                for (index, cue) in Self.cues.enumerated() {
                    try Task.checkCancellation()
                    cueIndex = index
                    cueBegan = ProcessInfo.processInfo.systemUptime
                    cueEndsAt = Date().addingTimeInterval(cue.seconds)
                    mark("phase_start", cue: cue)
                    let end = ContinuousClock.now + .seconds(cue.seconds)
                    while ContinuousClock.now < end {
                        guard model.live, model.modelCaptureStatus.phase == .ready, streamsFresh else {
                            throw KinesisError(message: "recording stopped because a band stream ended")
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    endCue(interrupted: false)
                }
                finish()
            } catch is CancellationError { }
            catch { problem = error.localizedDescription; finish() }
        }
    }

    /// Makes the session's folder and files. False, with the problem set, when it can't.
    private func openFiles() -> Bool {
        let stamp = started.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let folder = root.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8))-\(mode == .trackpad ? "trackpad" : "handwriting")", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for name in ["touches.jsonl", "cues.jsonl", "markers.jsonl", "inference.jsonl", "motion.jsonl"] {
                let path = folder.appendingPathComponent(name).path
                guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                files[name] = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            }
        } catch {
            for file in files.values { try? file.close() }; files = [:]
            problem = "couldn’t save the recording: \(error.localizedDescription)"
            return false
        }
        self.folder = folder
        if !writingTrials.isEmpty {
            trialReview = HandwritingTrialReview(recordingID: folder.lastPathComponent, surface: surface,
                wearingID: model.recordingWearingID, hand: model.bandHand.rawValue, split: handwritingSplit)
        }
        return true
    }

    func clearHandwriting() {
        guard writingTrials.isEmpty || !isRunning else { return }
        decoder.clearText(); candidateText = ""; rawHandwritingText = ""
        write(["event": "handwriting_clear"], to: "markers.jsonl")
    }

    private func runWritingTrials() async throws {
        for (index, trial) in writingTrials.enumerated() {
            try Task.checkCancellation()
            guard phase == .recording else { return }
            writingTrialIndex = index; trialSettling = false; trialMissed = false
            decoder.resetText(to: trial.initialText)
            candidateText = decoder.text; rawHandwritingText = decoder.rawText
            let now = ProcessInfo.processInfo.systemUptime
            trialObservation = HandwritingTrialObservation(trial: trial, order: UInt64(journalOrder), at: now, decoder: decoder)
            let trialFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trial))
            write(["event": "handwriting_trial_start", "trial": trialFields, "host_monotonic": now], to: "markers.jsonl")
            guard phase == .recording else { return }
            status = trial.prompt
            writingTrialEndsAt = Date().addingTimeInterval(trial.actionSeconds)
            try await waitForWriting(seconds: trial.actionSeconds)
            write(["event": "handwriting_action_end", "trial_id": trial.id], to: "markers.jsonl")
            if trial.settleSeconds > 0 {
                trialSettling = true
                status = "stop writing. keep your hand still while the result arrives."
                writingTrialEndsAt = Date().addingTimeInterval(trial.settleSeconds)
                try await waitForWriting(seconds: trial.settleSeconds)
            }
            finishWritingTrial(interrupted: false)
        }
    }

    private func waitForWriting(seconds: Double) async throws {
        let end = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < end {
            try Task.checkCancellation()
            guard phase == .recording, model.live, model.modelCaptureStatus.phase == .ready, streamsFresh else {
                throw KinesisError(message: "trial interrupted because a band stream ended")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func markWritingTrialMissed() {
        guard let trial = trialObservation?.trial else { return }
        trialMissed = true
        write(["event": "handwriting_trial_missed", "trial_id": trial.id], to: "markers.jsonl")
        status = "trial marked missed. wait for the next prompt."
    }

    private func finishWritingTrial(interrupted: Bool) {
        guard let observation = trialObservation else { return }
        trialObservation = nil; writingTrialIndex = nil
        let now = ProcessInfo.processInfo.systemUptime
        let result = observation.finish(order: UInt64(journalOrder), at: now, interrupted: interrupted || trialMissed, decoder: decoder)
        trialReview?.results.append(result)
        trialReview?.annotations.append(.init(id: result.id, status: trialMissed ? .excluded : .unreviewed,
                                              note: trialMissed ? "marked missed during capture" : ""))
        write(["event": "handwriting_trial_end", "trial_id": result.id, "interrupted": result.interrupted,
               "host_monotonic": now], to: "markers.jsonl")
        do { try saveTrialReview() }
        catch {
            problem = "couldn’t save the trial review: \(error.localizedDescription)"
            finish()
        }
    }

    private func saveTrialReview() throws {
        guard let trialReview, let folder else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = folder.appendingPathComponent("handwriting-trials.json")
        try encoder.encode(trialReview).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func annotateTrial(_ annotation: HandwritingTrialAnnotation) {
        guard done, let index = trialReview?.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        let previous = trialReview
        trialReview?.annotations[index] = annotation
        do { try saveTrialReview() }
        catch { trialReview = previous; problem = "couldn’t save the annotation: \(error.localizedDescription)" }
    }

    func loadTrialReview(from folder: URL) {
        guard !isRunning else { return }
        do {
            let review = try JSONDecoder().decode(HandwritingTrialReview.self, from: Data(contentsOf: folder.appendingPathComponent("handwriting-trials.json")))
            guard review.schemaVersion == 1, review.recordingID == folder.lastPathComponent,
                  Set(review.results.map(\.id)).count == review.results.count,
                  Set(review.annotations.map(\.id)) == Set(review.results.map(\.id)),
                  review.annotations.count == review.results.count else { throw KinesisError(message: "trial review does not match this recording") }
            self.folder = folder; trialReview = review; phase = .done; problem = nil
            status = "saved recording · review what you actually performed."
        } catch { problem = "couldn’t open the trial review: \(error.localizedDescription)" }
    }

    func markMissed() {
        guard let index = cueIndex, Self.cues[index].trial > 0 else { return }
        write(["event": "trial_invalid", "trial_id": Self.cues[index].trial, "valid": false], to: "markers.jsonl")
        status = "trial marked missed"
    }

    private func receiveModel(_ event: BandEvent) {
        switch event.payload {
        case .inferenceFrame(let sample):
            if sample.pipeline == 3 {
                inferenceCount += 1
                if let previous = lastInference, sample.sequence > previous + 1 { inferenceGaps += Int(sample.sequence - previous - 1) }
                lastInference = sample.sequence
                if mode == .handwriting, phase == .recording {
                    let label = decoder.consume(sample)
                    trialObservation?.receive(label: label)
                    if let label {
                        candidateText = decoder.text
                        rawHandwritingText = decoder.rawText
                        write(["event": "candidate_character", "sequence": sample.sequence,
                               "class": label, "character": ExperimentalHandwritingDecoder.characters[label],
                               "host_monotonic": event.receivedAt], to: "markers.jsonl")
                    }
                    decodeDiscontinuities = decoder.discontinuities
                }
            }
            write(["event": "raw_inference_payload", "sequence": sample.sequence, "timestamp_us": sample.timestampUs,
                   "pipeline_type": sample.pipeline, "payload": sample.payload.map { String(format: "%02x", $0) }.joined(),
                   "host_monotonic": event.receivedAt], to: "inference.jsonl")
        case .inferenceConfiguration(let data):
            write(["event": "inference_configuration", "payload": data.map { String(format: "%02x", $0) }.joined()], to: "inference.jsonl")
        case .modelCaptureState(let value):
            status = value.message
            if let message = value.problem { problem = message }
            write(["event": "model_state", "state": String(describing: value.phase), "message": value.message,
                   "problem": value.problem as Any? ?? NSNull(), "restoration_verified": value.restorationVerified], to: "markers.jsonl")
        default: break
        }
    }

    func receive(_ event: NSEvent, in view: NSView) {
        guard isRunning else { return }
        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            write(["t": event.timestamp, "click": event.type == .leftMouseDown], to: "touches.jsonl"); return
        }
        let all = event.touches(matching: .any, in: view)
        var now: [CGPoint] = []
        for touch in all {
            let phase = switch touch.phase { case .began: "began"; case .moved: "moved"; case .stationary: "stationary"; case .ended: "ended"; default: "cancelled" }
            padSize = touch.deviceSize
            write(["t": event.timestamp, "id": touch.identity.hash, "phase": phase, "resting": touch.isResting,
                   "x": touch.normalizedPosition.x, "y": touch.normalizedPosition.y,
                   "w": touch.deviceSize.width, "h": touch.deviceSize.height], to: "touches.jsonl")
            if touch.phase != .ended && touch.phase != .cancelled { now.append(touch.normalizedPosition) }
        }
        touchCount += all.count; fingers = now
    }

    private func write(_ fields: [String: Any], to name: String) {
        guard let file = files[name] else { return }
        var row = fields
        row["journal_order"] = journalOrder
        journalOrder += 1
        row["host_unix"] = Date().timeIntervalSince1970
        if row["host_monotonic"] == nil { row["host_monotonic"] = ProcessInfo.processInfo.systemUptime }
        do { try file.write(contentsOf: JSONSerialization.data(withJSONObject: row) + Data([10])) }
        catch {
            problem = "couldn’t save the recording: \(error.localizedDescription)"
            if phase != .restoring { finish() }
        }
    }

    private func mark(_ event: String, cue: Cue, interrupted: Bool = false) {
        write(["event": event, "trial_id": cue.trial, "block": cue.block, "prompt": cue.label,
               "phase": cue.phase, "interrupted": interrupted, "surface": "mac_trackpad"], to: "markers.jsonl")
    }

    private func endCue(interrupted: Bool) {
        guard let index = cueIndex, let begin = cueBegan else { return }
        cueBegan = nil
        let cue = Self.cues[index]
        mark("phase_end", cue: cue, interrupted: interrupted)
        write(["cue": cue.label, "start": begin, "end": ProcessInfo.processInfo.systemUptime,
               "phase": cue.phase, "trial_id": cue.trial, "interrupted": interrupted], to: "cues.jsonl")
    }

    func finish() {
        guard phase == .preparing || phase == .recording else { return }
        phase = .restoring
        finishWritingTrial(interrupted: true)
        write(["event": "recording_stopped"], to: "markers.jsonl")
        task?.cancel()
        endCue(interrupted: true)
        cueIndex = nil; fingers = []
        if mode == .trackpad { CGAssociateMouseAndMouseCursorPosition(1) }
        task = Task { [self] in
            if modelRequested && model.modelCaptureStatus.active {
                do { try model.setModelCaptureEnabled(false) }
                catch { problem = error.localizedDescription }
                let deadline = ContinuousClock.now + .seconds(40)
                while model.modelCaptureStatus.active && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let restored = modelRequested && model.modelCaptureStatus.restorationVerified
            if modelRequested && !restored { problem = model.modelCaptureStatus.problem ?? "normal band mode could not be verified" }
            model.stopRawRecording()
            model.rawEMGListeners["band model recording"] = nil
            model.gyroListeners["band model recording"] = nil
            model.modelCaptureListeners["band model recording"] = nil
            if held { model.holdRawEMG("band model recording", false); held = false }
            write(["event": "session_end", "restoration_verified": restored, "model_requested": modelRequested,
                   "problem": problem as Any? ?? NSNull()], to: "markers.jsonl")
            for file in files.values { try? file.close() }; files = [:]
            if let folder {
                let summary: [String: Any] = ["started": started.formatted(.iso8601), "seconds": Date().timeIntervalSince(started),
                    "hand": model.bandHand.rawValue, "mode": String(describing: mode),
                    "candidateText": candidateText, "rawHandwritingText": rawHandwritingText,
                    "decoderMappingVerified": false, "touchEvents": touchCount, "trackpadPoints": [padSize.width, padSize.height],
                    "pipeline3Packets": inferenceCount, "pipeline3Missing": inferenceGaps, "restorationVerified": restored,
                    "problem": problem as Any? ?? NSNull()]
                if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: folder.appendingPathComponent("summary.json"), options: .atomic)
                }
            }
            model.releaseModelRecording(owner)
            if restoreControls && (!modelRequested || restored) && model.live && !model.controlsEnabled { model.toggleControls() }
            phase = .done
            status = saves ? (restored ? "saved · \(model.modelCaptureStatus.message)" : "saved") : (restored ? model.modelCaptureStatus.message : "")
            task = nil
        }
    }
}
