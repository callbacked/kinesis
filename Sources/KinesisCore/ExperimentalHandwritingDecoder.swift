import Foundation

/// Candidate interpretation of pipeline 3, pending validation on the consumer band.
/// The class order and CTC blank follow Meta's public research character set:
/// https://github.com/facebookresearch/generic-neuromotor-interface/blob/6d1de94afdfe0c921d08dd24933a5c8d11e8307a/generic_neuromotor_interface/handwriting_utils.py
/// Matching dimensions alone do not establish firmware compatibility.
public struct ExperimentalHandwritingDecoder: Sendable {
    public static let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~").map(String.init)
        + ["⌫", "⏎", " ", "⇧", "🤏"]
    public static let blank = 99
    public enum PreviewAction: String, Sendable { case tentativeBoundary, space, backspace, newline, shift }
    // Class 87 follows letters and editing gestures in desk recordings. Its
    // precise firmware meaning is unknown; the preview treats it as a boundary.
    // The wearer identified class 88's forward gesture as space and 94 as delete.
    // An up arrow gives 97 (⇧): it capitalizes the next letter. 98 (🤏) has no known
    // meaning yet, so it adds nothing to the text.
    public static let previewActions: [Int: PreviewAction] = [87: .tentativeBoundary, 88: .space, 94: .backspace, 95: .newline,
                                                             96: .space, 97: .shift, 98: .tentativeBoundary]
    public private(set) var text = ""
    public private(set) var rawText = ""
    public private(set) var discontinuities = 0
    private var previousLabel: Int?
    private var previousSequence: UInt64?
    private var previousTimestamp: UInt64?
    private var shifted = false

    public init() {}

    /// Returns a newly emitted class, preserving its original glyph for inspection.
    /// Editing affects only the preview, never another app's keyboard input.
    @discardableResult
    public mutating func consume(_ sample: BandInferenceSample) -> Int? {
        guard sample.isTextDistribution else { return nil }
        if sample.sequence == previousSequence, sample.timestampUs == previousTimestamp { return nil }
        if let sequence = previousSequence, let timestamp = previousTimestamp,
           sample.sequence != ((sequence + 1) & UInt64(UInt32.max)) || sample.timestampUs <= timestamp {
            previousLabel = nil
            discontinuities += 1
        }
        previousSequence = sample.sequence
        previousTimestamp = sample.timestampUs
        let label = sample.values.indices.max { sample.values[$0] < sample.values[$1] }!
        let oldLabel = previousLabel
        previousLabel = label
        guard label != Self.blank, label != oldLabel else { return nil }
        rawText += Self.characters[label]
        switch Self.previewActions[label] {
        case .tentativeBoundary: break
        case .shift: shifted = true
        case .space: text += " "; shifted = false
        case .backspace: if !text.isEmpty { text.removeLast() }
        case .newline: text += "\n"; shifted = false
        case nil:
            text += shifted ? Self.characters[label].uppercased() : Self.characters[label]
            shifted = false
        }
        return label
    }

    /// Keep collapse state so clearing during a held output cannot duplicate it.
    public mutating func clearText() { resetText(to: "") }

    /// A trial can seed editing context without inventing a new CTC boundary.
    public mutating func resetText(to initialText: String) { text = initialText; rawText = ""; shifted = false }
}
