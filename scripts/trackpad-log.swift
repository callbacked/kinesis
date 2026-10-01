// Logs every contact on the Mac's trackpads, without Kinesis, for pairing with a band
// capture made by another tool while Kinesis is quit. Same reader as the passive recorder:
// Apple's private MultitouchSupport framework, palms included.
//
//     swift scripts/trackpad-log.swift captures/trackpad.jsonl 120
//
// One JSON line per trackpad frame: "unix" is wall-clock seconds, matching the "ts" of
// other captures; each contact is [id, state, size, x mm, y mm]. State 3 is making touch
// and 4 is touching. A size of 2 or more is a palm.
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, let seconds = Double(arguments[2]) else {
    print("usage: swift scripts/trackpad-log.swift OUTPUT.jsonl SECONDS")
    exit(2)
}
FileManager.default.createFile(atPath: arguments[1], contents: nil)
guard let file = FileHandle(forWritingAtPath: arguments[1]) else {
    print("can't write \(arguments[1])")
    exit(1)
}

typealias DeviceList = @convention(c) () -> Unmanaged<CFArray>
typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
typealias Register = @convention(c) (UnsafeMutableRawPointer?, Callback) -> Void
typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void

guard let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
      let list = dlsym(library, "MTDeviceCreateList"), let register = dlsym(library, "MTRegisterContactFrameCallback"),
      let start = dlsym(library, "MTDeviceStart") else {
    print("MultitouchSupport isn't available")
    exit(1)
}

nonisolated(unsafe) var output: FileHandle? = file
nonisolated(unsafe) var frames = 0
let lock = NSLock()

let callback: Callback = { _, contacts, count, timestamp, _ in
    var fingers: [[Double]] = []
    if let contacts {
        for k in 0..<Int(max(0, count)) {
            let base = contacts.advanced(by: k * 96)
            fingers.append([Double(base.load(fromByteOffset: 16, as: Int32.self)), Double(base.load(fromByteOffset: 20, as: Int32.self)),
                            Double(base.load(fromByteOffset: 48, as: Float.self)),
                            Double(base.load(fromByteOffset: 68, as: Float.self)), Double(base.load(fromByteOffset: 72, as: Float.self))])
        }
    }
    let row: [String: Any] = ["unix": Date().timeIntervalSince1970, "uptime": ProcessInfo.processInfo.systemUptime,
                              "framework": timestamp, "contacts": fingers]
    if let data = try? JSONSerialization.data(withJSONObject: row) {
        lock.lock()
        output?.write(data + Data([0x0a]))
        frames += 1
        lock.unlock()
    }
    return 0
}

let devices = unsafeBitCast(list, to: DeviceList.self)().takeRetainedValue() as [AnyObject]
for device in devices {
    let pointer = Unmanaged.passUnretained(device).toOpaque()
    unsafeBitCast(register, to: Register.self)(pointer, callback)
    unsafeBitCast(start, to: Start.self)(pointer, 0)
}
print("logging \(devices.count) trackpad(s) for \(Int(seconds)) s to \(arguments[1])")
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
lock.lock()
try? output?.close()
output = nil
print("\(frames) frames")
lock.unlock()
exit(0)
