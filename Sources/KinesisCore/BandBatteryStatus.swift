import Foundation

/// BatteryInfoResp.batteryData, mapped from the SDK's serializer and consumer.
public struct BandBatteryStatus: Sendable, Equatable {
    public let level: Int
    public let charging: Bool?

    public init(level: Int, charging: Bool?) {
        self.level = level
        self.charging = charging
    }

    public init(response: Data) throws {
        let rpc = try ProtoFields(response)
        guard try rpc.requiredInteger(2) == 1 else { throw BandProtocolError("Battery status unavailable") }
        let response = try ProtoFields(rpc.bytes(3))
        let battery = try ProtoFields(response.bytes(1))
        let level = try battery.requiredInteger(1)
        guard level <= 100 else { throw BandProtocolError("Invalid battery level") }
        self.level = Int(level)
        if battery.contains(2) {
            let value = try battery.requiredInteger(2)
            guard value <= 1 else { throw BandProtocolError("Invalid charging flag") }
            charging = value == 1
        } else {
            charging = nil
        }
    }
}
