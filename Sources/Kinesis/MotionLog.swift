import Foundation
import KinesisCore

/// A developer tool: when KINESIS_MOTION_LOG names a file, every gyro, orientation,
/// and gesture event is appended to it as JSON lines, for offline analysis of the
/// air cursor. It is off unless the variable is set, and it never runs in tests.
@MainActor final class MotionLog {
    static let shared = MotionLog(path: ProcessInfo.processInfo.environment["KINESIS_MOTION_LOG"])
    private let handle: FileHandle?
    /// While logging, every stream stays on: an analysis needs orientation even with the cursor off.
    var isOn: Bool { handle != nil }

    init(path: String?) {
        guard let path, !path.isEmpty else { handle = nil; return }
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func record(_ event: BandEvent) {
        guard let handle else { return }
        var row: [String: Any] = ["at": event.receivedAt]
        switch event.payload {
        case .gyro(let timestamp, let values):
            row["event"] = "gyro"; row["t"] = timestamp; row["v"] = [values.x, values.y, values.z]
        case .orientation(let timestamp, let values):
            row["event"] = "quat"; row["t"] = timestamp; row["v"] = [values.x, values.y, values.z, values.w]
        case .gesture(let gesture):
            row["event"] = "gesture"; row["t"] = gesture.timestampUs
            row["finger"] = gesture.finger; row["action"] = gesture.action; row["derived"] = gesture.derivedAction
        default:
            return
        }
        guard var data = try? JSONSerialization.data(withJSONObject: row) else { return }
        data.append(0x0a)
        handle.write(data)
    }
}
