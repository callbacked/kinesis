import Foundation
import Testing
@testable import KinesisCore
@testable import Kinesis

// Synthetic ADC counts exercise the exact observed wire layout, never a live device.
func readingsConfiguration(encoding: UInt64 = 0) throws -> EMGConfiguration {
    let config = BandWire.field(1, 2048) + BandWire.field(2, 8) + BandWire.field(4, 16)
        + BandWire.field(5, 16) + BandWire.field(10, encoding)
    return try EMGConfiguration(response: BandWire.field(2, 1) + BandWire.field(6, BandWire.field(42, config)))
}

func readingsPayload(sequence: UInt64, timestamp: UInt64? = nil) -> Data {
    var samples = Data()
    for sample in 0..<16 {
        for channel in 0..<8 {
            let t = Double(sequence * 16 + UInt64(sample)) / 2048
            let envelope = 0.1 + 0.9 * pow(max(0, sin(t * 6)), 6)
            let value = UInt16(32768 + sin(t * Double(53 + channel * 8) * .pi * 2) * envelope * Double(100 + channel * 70))
            samples.append(UInt8(value & 255))
            samples.append(UInt8(value >> 8))
        }
    }
    return BandWire.field(1, sequence) + BandWire.field(2, timestamp ?? (1_000_000 + sequence * 7813)) + BandWire.field(3, samples)
}

@Test @MainActor func EMGHistoryIsBoundedAndTracksGapsWithoutJoiningRestarts() throws {
    let readings = EMGReadings()
    readings.configure(try readingsConfiguration())
    for sequence in 0..<300 { readings.receive(readingsPayload(sequence: UInt64(sequence)), at: Double(sequence) / 128) }
    #expect(readings.batches.count <= 128)
    #expect(readings.batches.last?.sequence == 299 && readings.missingBatches == 0)
    #expect(readings.revision < 70) // No more than twenty trace redraws per second.
    readings.receive(readingsPayload(sequence: 303), at: 3)
    #expect(readings.missingBatches == 3)
    readings.receive(readingsPayload(sequence: 0), at: 4)
    #expect(readings.batches.count == 1 && readings.missingBatches == 3)
    let samplesBeforeInvalid = readings.sampleFrames
    readings.receive(readingsPayload(sequence: 1).dropLast(), at: 4.5)
    #expect(readings.sampleFrames == samplesBeforeInvalid && readings.invalidFrames == 1)
    #expect(readings.batches.isEmpty && readings.issue != nil)
    readings.configure(try readingsConfiguration(encoding: 1))
    readings.receive(readingsPayload(sequence: 1), at: 5)
    #expect(readings.batches.isEmpty && readings.issue != nil)
    readings.reset()
    #expect(readings.configuration == nil && readings.frames == 0 && readings.missingBatches == 0)
}
