import Foundation

public struct HandwritingTrial: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, command, idle }
    public enum Split: String, Codable, CaseIterable, Sendable { case development, evaluation }
    public let id: String
    public let kind: Kind
    public let prompt: String
    public let intendedText: String
    public let intendedActions: [String]
    public let initialText: String
    public let actionSeconds: Double
    public let settleSeconds: Double

    public init(id: String = UUID().uuidString, kind: Kind, prompt: String, intendedText: String = "",
                intendedActions: [String] = [], initialText: String = "", actionSeconds: Double, settleSeconds: Double = 0) {
        self.id = id; self.kind = kind; self.prompt = prompt; self.intendedText = intendedText
        self.intendedActions = intendedActions; self.initialText = initialText
        self.actionSeconds = actionSeconds; self.settleSeconds = settleSeconds
    }

    public static func pilot(split: Split) -> [Self] {
        var trials = [Self(kind: .idle, prompt: "rest your hand. don’t write.", actionSeconds: 30)]
        for text in ["k", "t", "i", "l", "n", "m", "o", "s", "kk", "tt", "ll", "oo"].shuffled() {
            let lift = text == "kk" || text == "ll" ? " lift between the letters." : ""
            trials.append(Self(kind: .text, prompt: "write “\(text)”.\(lift)", intendedText: text, actionSeconds: 5, settleSeconds: 2.5))
        }
        for index in 0..<10 {
            let space = index.isMultiple(of: 2), count = index >= 6 && index < 8 ? 2 : 1
            let action = space ? "space" : "backspace"
            let gesture = space ? "push forward" : "sweep back"
            trials.append(Self(kind: .command, prompt: "\(gesture) \(count == 1 ? "once" : "twice"). then wait.",
                intendedActions: Array(repeating: action, count: count), initialText: index == 9 ? "" : "ab",
                actionSeconds: 4, settleSeconds: 2))
        }
        let phrases = split == .development ? ["hi kinesis", "hello mom", "look at this", "one small step"]
            : ["quiet lake", "green lamp", "sun on stone", "a little room"]
        for text in phrases {
            trials.append(Self(kind: .text, prompt: "write “\(text)”.", intendedText: text, actionSeconds: 12, settleSeconds: 3))
        }
        trials.append(Self(kind: .idle, prompt: "don’t write. gently reposition your hand and wrist.", actionSeconds: 30))
        return trials
    }
}

public struct HandwritingTrialAnnotation: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case unreviewed, confirmed, excluded }
    public let id: String
    public let status: Status
    public let referenceText: String?
    public let performedActions: [String]?
    public let note: String

    public init(id: String, status: Status, referenceText: String? = nil, performedActions: [String]? = nil, note: String = "") {
        self.id = id; self.status = status; self.referenceText = referenceText; self.performedActions = performedActions; self.note = note
    }
    public static func asPrompted(_ trial: HandwritingTrial) -> Self {
        Self(id: trial.id, status: .confirmed, referenceText: trial.kind == .text ? trial.intendedText : nil,
             performedActions: trial.kind == .command ? trial.intendedActions : nil, note: "wearer confirmed the prompt was performed")
    }
}

public struct HandwritingTrialResult: Codable, Equatable, Identifiable, Sendable {
    public var id: String { trial.id }
    public let trial: HandwritingTrial
    public let startOrder: UInt64
    public let endOrder: UInt64
    public let startedAt: Double
    public let endedAt: Double
    public let interrupted: Bool
    public let sampleCount: Int
    public let discontinuities: Int
    public let candidateText: String
    public let rawText: String
    public let emittedLabels: [Int]
}

/// The live panel and offline replay take the same snapshots of the shared decoder.
public struct HandwritingTrialObservation: Sendable {
    public let trial: HandwritingTrial
    private let startOrder: UInt64
    private let startedAt: Double
    private let initialDiscontinuities: Int
    private var labels: [Int] = []
    private var sampleCount = 0

    public init(trial: HandwritingTrial, order: UInt64, at time: Double, decoder: ExperimentalHandwritingDecoder) {
        self.trial = trial; startOrder = order; startedAt = time; initialDiscontinuities = decoder.discontinuities
    }
    public mutating func receive(label: Int?) {
        sampleCount += 1
        if let label { labels.append(label) }
    }
    public func finish(order: UInt64, at time: Double, interrupted: Bool, decoder: ExperimentalHandwritingDecoder) -> HandwritingTrialResult {
        HandwritingTrialResult(trial: trial, startOrder: startOrder, endOrder: order, startedAt: startedAt, endedAt: time,
            interrupted: interrupted, sampleCount: sampleCount, discontinuities: decoder.discontinuities - initialDiscontinuities,
            candidateText: decoder.text, rawText: decoder.rawText, emittedLabels: labels)
    }
}

public struct HandwritingTrialReview: Codable, Sendable {
    public var schemaVersion = 1
    public let recordingID: String
    public let surface: String
    public let wearingID: String
    public let hand: String
    public let split: HandwritingTrial.Split
    public var results: [HandwritingTrialResult]
    public var annotations: [HandwritingTrialAnnotation]

    public init(recordingID: String, surface: String, wearingID: String, hand: String, split: HandwritingTrial.Split,
                results: [HandwritingTrialResult] = [], annotations: [HandwritingTrialAnnotation] = []) {
        self.recordingID = recordingID; self.surface = surface; self.wearingID = wearingID; self.hand = hand
        self.split = split; self.results = results; self.annotations = annotations
    }
}

public struct HandwritingEditCounts: Codable, Equatable, Sendable {
    public var substitutions = 0
    public var deletions = 0
    public var insertions = 0
    public var referenceCount = 0
    public var errors: Int { substitutions + deletions + insertions }
    public var rate: Double? { referenceCount > 0 ? Double(errors) / Double(referenceCount) : nil }
    public init(substitutions: Int = 0, deletions: Int = 0, insertions: Int = 0, referenceCount: Int = 0) {
        self.substitutions = substitutions; self.deletions = deletions; self.insertions = insertions; self.referenceCount = referenceCount
    }

    public static func compare<T: Equatable>(reference: [T], hypothesis: [T]) -> Self {
        var previous = (0...hypothesis.count).map { Self(insertions: $0) }
        for (i, expected) in reference.enumerated() {
            var current = [Self(deletions: i + 1)]
            for (j, actual) in hypothesis.enumerated() {
                var substitution = previous[j]
                substitution.substitutions += expected == actual ? 0 : 1
                var deletion = previous[j + 1]; deletion.deletions += 1
                var insertion = current[j]; insertion.insertions += 1
                // Deterministic ties: substitution, then deletion, then insertion.
                var best = substitution
                if deletion.errors < best.errors { best = deletion }
                if insertion.errors < best.errors { best = insertion }
                current.append(best)
            }
            previous = current
        }
        var result = previous[hypothesis.count]; result.referenceCount = reference.count
        return result
    }
}

public struct HandwritingTrialScore: Codable, Sendable {
    public let id: String
    public var excludedReason: String?
    public var textErrors: HandwritingEditCounts?
    public var commandErrors: HandwritingEditCounts?
    public var commandFinalTextMatches: Bool?
    public var idleSeconds: Double?
    public var unintendedEvents: Int?

    public static func evaluate(_ result: HandwritingTrialResult, annotation: HandwritingTrialAnnotation?) -> Self {
        var score = Self(id: result.id)
        if result.interrupted { score.excludedReason = "interrupted trial"; return score }
        if result.sampleCount == 0 { score.excludedReason = "no model samples"; return score }
        if result.discontinuities > 0 { score.excludedReason = "model stream discontinuity"; return score }
        guard result.endedAt > result.startedAt, result.endOrder > result.startOrder else {
            score.excludedReason = "invalid trial boundaries"; return score
        }
        guard let annotation, annotation.id == result.id, annotation.status == .confirmed else {
            score.excludedReason = annotation?.status == .excluded ? "wearer excluded trial: \(annotation?.note ?? "")" : "awaiting wearer confirmation"
            return score
        }
        let events = result.emittedLabels.compactMap { label -> String? in
            guard label >= 0, label < ExperimentalHandwritingDecoder.characters.count else { return "invalid" }
            switch ExperimentalHandwritingDecoder.previewActions[label] {
            case .tentativeBoundary: return nil
            case let action?: return action.rawValue
            case nil: return "character:\(ExperimentalHandwritingDecoder.characters[label])"
            }
        }
        switch result.trial.kind {
        case .text:
            guard let reference = annotation.referenceText, !reference.isEmpty else {
                score.excludedReason = "text reference is empty or missing"; return score
            }
            score.textErrors = .compare(reference: Array(reference), hypothesis: Array(result.candidateText))
        case .command:
            guard let actions = annotation.performedActions, !actions.isEmpty,
                  actions.allSatisfy({ $0 == "space" || $0 == "backspace" }) else {
                score.excludedReason = "performed editing actions are missing or unsupported"; return score
            }
            score.commandErrors = .compare(reference: actions, hypothesis: events)
            var expected = result.trial.initialText
            for action in actions {
                if action == "space" { expected += " " }
                else if !expected.isEmpty { expected.removeLast() }
            }
            score.commandFinalTextMatches = expected == result.candidateText
        case .idle:
            score.idleSeconds = result.endedAt - result.startedAt
            score.unintendedEvents = events.count
        }
        return score
    }
}
