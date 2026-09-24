import Foundation

/// Dimensions reported by the band's Config.emg field. ADC calibration is unknown.
public struct EMGConfiguration: Equatable, Sendable {
    public let sampleRate: UInt64
    public let channels: UInt64
    public let adcBits: UInt64
    public let samplesPerBatch: UInt64
    public let encoding: UInt64

    public init(response: Data) throws {
        let response = try ProtoFields(response)
        guard try response.requiredInteger(2) == 1 else { throw BandProtocolError("The band rejected the EMG configuration read.") }
        let config = try ProtoFields(response.bytes(6))
        let emg = try ProtoFields(config.bytes(42))
        sampleRate = try emg.requiredInteger(1)
        channels = try emg.requiredInteger(2)
        adcBits = try emg.requiredInteger(4)
        samplesPerBatch = try emg.requiredInteger(5)
        encoding = try emg.requiredInteger(10)
    }

    /// The observed layout supported by the PoC; voltage calibration is unknown.
    public var isSupported: Bool {
        sampleRate == 2048 && channels == 8 && adcBits == 16 && samplesPerBatch == 16 && encoding == 0
    }
}

public struct EMGBatch: Sendable {
    public static let channelCount = 8
    public static let sampleCount = 16
    public static let sampleIntervalUs = 1_000_000.0 / 2048
    public static let durationUs = Double(sampleCount) * sampleIntervalUs
    public let sequence: UInt64
    public let timestampUs: UInt64
    /// Observed unsigned little-endian layout, interleaved by sample then channel.
    public let values: [UInt16]

    public init(payload: Data, configuration: EMGConfiguration) throws {
        guard configuration.isSupported else { throw BandProtocolError("This EMG format isn't supported by the readings view yet.") }
        let fields = try ProtoFields(payload)
        sequence = try fields.requiredInteger(1)
        timestampUs = try fields.requiredInteger(2)
        let bytes = try fields.bytes(3, count: 256)
        values = bytes.withUnsafeBytes { raw in
            (0..<128).map { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) }
        }
    }
}
