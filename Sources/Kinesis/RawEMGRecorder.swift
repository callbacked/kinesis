import Foundation

/// Sensor payloads only. The model serializes writes and the final close.
actor RawEMGRecorder {
    private let handle: FileHandle
    private var closed = false

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ lines: [String]) throws {
        guard !closed else { throw CocoaError(.fileWriteUnknown) }
        guard !lines.isEmpty else { return }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.joined(separator: "\n").appending("\n").utf8))
    }

    func close() throws {
        guard !closed else { return }
        closed = true
        try handle.close()
    }
}
