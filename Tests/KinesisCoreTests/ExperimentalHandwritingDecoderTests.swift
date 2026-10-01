import Foundation
import Testing
@testable import KinesisCore

private func handwritingSample(_ label: Int, sequence: UInt64, timestamp: UInt64? = nil, pipeline: UInt64 = 3) throws -> BandInferenceSample {
    var bytes = Data()
    for index in 0..<100 {
        var bits = Float(index == label ? 0 : -100).bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
    }
    return try BandInferenceSample(payload: BandWire.field(1, sequence)
        + BandWire.field(2, timestamp ?? (sequence * 156_250 + 1))
        + BandWire.field(3, bytes) + BandWire.field(10, pipeline))
}

@Test func candidateHandwritingAlphabetHasExpectedClassBoundaries() {
    let chars = ExperimentalHandwritingDecoder.characters
    #expect(chars.count == ExperimentalHandwritingDecoder.blank)
    #expect([0, 25, 26, 51, 52, 61, 62, 93, 94, 95, 96, 97, 98].map { chars[$0] }
        == ["a", "z", "A", "Z", "0", "9", "!", "~", "⌫", "⏎", " ", "⇧", "🤏"])
}

@Test func candidateCTCCollapsesRunsButKeepsBlankSeparatedRepeats() throws {
    var decoder = ExperimentalHandwritingDecoder()
    for (sequence, label) in [99, 7, 7, 4, 11, 11, 99, 11, 14, 99].enumerated() {
        decoder.consume(try handwritingSample(label, sequence: UInt64(sequence)))
    }
    #expect(decoder.text == "hello" && decoder.rawText == "hello")
    #expect(decoder.discontinuities == 0)
}

@Test func handwritingClearAndDuplicateFramesDoNotEmitHeldCharacters() throws {
    var decoder = ExperimentalHandwritingDecoder()
    let first = try handwritingSample(0, sequence: 1)
    #expect(decoder.consume(first) == 0)
    decoder.clearText()
    #expect(decoder.consume(first) == nil)
    #expect(decoder.consume(try handwritingSample(0, sequence: 2)) == nil)
    #expect(decoder.text == "" && decoder.rawText == "")
    decoder.consume(try handwritingSample(99, sequence: 3))
    #expect(decoder.consume(try handwritingSample(0, sequence: 4)) == 0)
    #expect(decoder.text == "a")
}

@Test func handwritingDiscontinuitiesBreakCollapseAndSequenceWrapIsContinuous() throws {
    var decoder = ExperimentalHandwritingDecoder()
    decoder.consume(try handwritingSample(0, sequence: UInt64(UInt32.max), timestamp: 100))
    decoder.consume(try handwritingSample(0, sequence: 0, timestamp: 200))
    #expect(decoder.text == "a" && decoder.discontinuities == 0)
    decoder.consume(try handwritingSample(0, sequence: 2, timestamp: 400))
    #expect(decoder.text == "aa" && decoder.discontinuities == 1)
    decoder.consume(try handwritingSample(1, sequence: 0, timestamp: 1))
    #expect(decoder.text == "aab" && decoder.discontinuities == 2)
    #expect(decoder.consume(try handwritingSample(2, sequence: 1, pipeline: 2)) == nil)
    #expect(decoder.text == "aab")
}

@Test func handwritingEditingGesturesChangePreviewAndPreserveRawTokens() throws {
    var decoder = ExperimentalHandwritingDecoder()
    let labels = [94, 94, 99, 7, 8, 87, 88, 88, 87, 19, 87, 94, 94, 87, 94, 87, 88, 87, 95, 97, 98]
    for (sequence, label) in labels.enumerated() {
        decoder.consume(try handwritingSample(label, sequence: UInt64(sequence)))
        if sequence == 7 { #expect(decoder.text == "hi ") }
        if sequence == 12 { #expect(decoder.text == "hi ") }
        if sequence == 14 { #expect(decoder.text == "hi") }
    }
    // ⇧ waits for the next letter, and 🤏 adds nothing.
    #expect(decoder.text == "hi \n")
    #expect(decoder.rawText == "⌫hi^_^t^⌫^⌫^_^⏎⇧🤏")
    #expect(decoder.discontinuities == 0)
}

@Test func anUpArrowCapitalizesTheNextLetterOnly() throws {
    var decoder = ExperimentalHandwritingDecoder()
    // ⇧ h i, space, ⇧ a: "Hi A". A blank between repeats, as the model emits them.
    for (sequence, label) in [97, 7, 8, 88, 97, 99, 0].enumerated() {
        decoder.consume(try handwritingSample(label, sequence: UInt64(sequence)))
    }
    #expect(decoder.text == "Hi A")
}

@Test func tentativeHandwritingBoundarySeparatesRepeatedLettersWithoutPrintingCarets() throws {
    var decoder = ExperimentalHandwritingDecoder()
    for (sequence, label) in [11, 87, 87, 11, 96, 14].enumerated() {
        decoder.consume(try handwritingSample(label, sequence: UInt64(sequence)))
    }
    #expect(decoder.text == "ll o")
    #expect(decoder.rawText == "l^l o")
}
