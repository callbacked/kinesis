#if KINESIS_DEV
import AppKit
import SwiftUI
import simd
import Combine
import Foundation
import KinesisCore
import os
import Carbon

// A developer tool, only in dev builds: records training data while the Mac is used
// normally. The band's raw sEMG and gyro, every trackpad contact system-wide, and when
// each key goes down and up, with which side of the keyboard it is on: the band hand's,
// the other hand's, or the space bar. Which key is saved only with "include typing" on,
// for deliberate typing research. It records only while the band is on and
// connected, not charging, and the Mac is in use, and it pauses by itself otherwise.
// The trackpad comes from Apple's private MultitouchSupport framework, the only way
// to see contacts outside this app's windows, palms included.

/// Every contact on the Mac's trackpads, system-wide, from a background thread.
final class SystemTrackpad: @unchecked Sendable {
    /// One frame: the framework's timestamp in seconds, and its raw contact records,
    /// `contactBytes` each. Called on the framework's thread.
    typealias Handler = @Sendable (Double, Data) -> Void
    static let contactBytes = 96

    private typealias DeviceList = @convention(c) () -> Unmanaged<CFArray>
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias BuiltIn = @convention(c) (UnsafeMutableRawPointer?) -> Bool

    /// The framework calls back on its own thread while start and stop run on the main one.
    private static let handler = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private var devices: [AnyObject] = []
    private var current: Handler?
    private var stop: Stop?

    /// False when the framework or its functions are missing.
    func start(_ handler: @escaping Handler) -> Bool {
        guard let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let list = dlsym(library, "MTDeviceCreateList"), let register = dlsym(library, "MTRegisterContactFrameCallback"),
              let start = dlsym(library, "MTDeviceStart"), let stop = dlsym(library, "MTDeviceStop") else { return false }
        Self.handler.withLock { $0 = handler }
        current = handler
        self.stop = unsafeBitCast(stop, to: Stop.self)
        let callback: Callback = { _, contacts, count, timestamp, _ in
            let bytes = contacts.map { Data(bytes: $0, count: Int(max(0, count)) * SystemTrackpad.contactBytes) } ?? Data()
            SystemTrackpad.handler.withLock { $0 }?(timestamp, bytes)
            return 0
        }
        devices = unsafeBitCast(list, to: DeviceList.self)().takeRetainedValue() as [AnyObject]
        // Only the Mac's own trackpad: a Magic Mouse or another trackpad would mix its
        // contacts into the labels. A Mac with none built in uses what it has.
        if let builtIn = dlsym(library, "MTDeviceIsBuiltIn").map({ unsafeBitCast($0, to: BuiltIn.self) }) {
            let own = devices.filter { builtIn(Unmanaged.passUnretained($0).toOpaque()) }
            if !own.isEmpty { devices = own }
        }
        for device in devices {
            let pointer = Unmanaged.passUnretained(device).toOpaque()
            unsafeBitCast(register, to: Register.self)(pointer, callback)
            unsafeBitCast(start, to: Start.self)(pointer, 0)
        }
        return !devices.isEmpty
    }

    /// Starts over with a fresh device list. After the Mac sleeps, the old devices can go quiet.
    func restart() -> Bool {
        guard let current else { return false }
        stopAll()
        return start(current)
    }

    func stopAll() {
        for device in devices { stop?(Unmanaged.passUnretained(device).toOpaque()) }
        devices = []
        Self.handler.withLock { $0 = nil }
    }
}

/// Appends little-endian records to the files of one recording, off the main thread.
final class RecordingFiles: @unchecked Sendable {
    let folder: URL
    private let queue = DispatchQueue(label: "kinesis.passive.files")
    private var handles: [String: FileHandle] = [:]
    private var failed = false

    /// True once a write failed, as on a full disk: the rest of this recording is lost.
    var hasFailed: Bool { queue.sync { failed } }

    init(folder: URL, files: [String] = ["emg.bin", "touches.bin", "keysides.bin", "gyro.bin", "pointer.bin", "clicks.bin"]) throws {
        self.folder = folder
        // A new folder every time: files of an earlier recording are never truncated.
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for name in files {
            let url = folder.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handles[name] = try FileHandle(forWritingTo: url)
        }
    }

    func append(_ data: Data, to name: String) {
        queue.async {
            guard !self.failed, let handle = self.handles[name] else { return }
            // A full disk or a removed volume ends the recording, never the app.
            do { try handle.write(contentsOf: data) } catch { self.failed = true }
        }
    }

    /// Rewrites the summary while recording, so a crash still leaves a usable one.
    func writeMeta(_ meta: [String: Any]) {
        let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        queue.async { try? data?.write(to: self.folder.appendingPathComponent("meta.json"), options: .atomic) }
    }

    func close(meta: [String: Any]) {
        let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        queue.async {
            for handle in self.handles.values { try? handle.close() }
            self.handles = [:]
            try? data?.write(to: self.folder.appendingPathComponent("meta.json"), options: .atomic)
        }
    }
}

extension Data {
    mutating func put<T>(_ value: T) {
        Swift.withUnsafeBytes(of: value) { append(contentsOf: $0) }
    }
}

@MainActor final class PassiveRecorder: ObservableObject {
    static let shared = PassiveRecorder()

    enum Status: Equatable {
        case off
        case recording
        case paused(String)
    }

    /// What the recording holds, counted as it records.
    struct Tally: Equatable {
        var seconds = 0.0
        /// Time with fingers touching the trackpad, and with exactly one finger sliding:
        /// the data a single-finger decoder learns from.
        var touching = 0.0
        var sliding = 0.0
        var twoFingers = 0.0
        /// Three or more fingers: Mission Control and space swipes.
        var threeFingers = 0.0
        var palm = 0.0
        var keys = 0

        static func + (a: Tally, b: Tally) -> Tally {
            Tally(seconds: a.seconds + b.seconds, touching: a.touching + b.touching, sliding: a.sliding + b.sliding,
                  twoFingers: a.twoFingers + b.twoFingers, threeFingers: a.threeFingers + b.threeFingers,
                  palm: a.palm + b.palm, keys: a.keys + b.keys)
        }
    }

    @Published private(set) var on = UserDefaults.standard.bool(forKey: "passiveRecording")
    /// Off unless chosen: save which key, not only its side. For deliberate typing research.
    @Published var includeTyping = UserDefaults.standard.bool(forKey: "passiveIncludeTyping") {
        didSet {
            UserDefaults.standard.set(includeTyping, forKey: "passiveIncludeTyping")
            // A new stretch starts, so its files match the choice from now on.
            if status == .recording { closeSegment() }
        }
    }
    @Published private(set) var status = Status.off
    @Published private(set) var today = Tally()
    @Published private(set) var total = Tally()
    /// Over the last 10 s: sEMG samples a second (2048 is all of them) and trackpad frames a second.
    @Published private(set) var emgRate = 0.0
    @Published private(set) var trackpadRate = 0.0
    @Published private(set) var warning: String?

    /// A minute without the keyboard or trackpad is a break. After two, the band's raw
    /// sEMG turns off to save its battery.
    static let idle = 60.0
    static let rest = 120.0
    /// With sEMG asked for, this long without any means the band isn't sending it:
    /// off the wrist, or stuck.
    static let silentBand = 5.0
    static let minimumFreeSpace: Int64 = 3_000_000_000
    /// A fingertip's contact size stays under this. A palm is bigger.
    static let palmSize: Float = 2.0

    private weak var model: BandModel?
    private let trackpad = SystemTrackpad()
    private var files: RecordingFiles?
    private var segment = Tally()
    private var segmentStarted = Date()
    private var previous = Tally()        // today's recordings before this launch
    private var previousTotal = Tally()
    private var lastInput = -Double.infinity
    private var keyMonitors: [Any] = []
    private var ticker: AnyCancellable?
    private var holding = false
    private var holdingSince = 0.0
    private var lastEMG = -Double.infinity
    private var trackpadStarted = false
    private var clockCheck: [String: Double] = [:]
    private var emgTimes: [(Double, Int)] = []
    private var trackpadTimes: [Double] = []
    private var lastFrame: (time: Double, finger: SIMD2<Float>?)?
    private var ticks = 0
    private var lastTouch = -Double.infinity
    private var wakeObserver: Any?
    /// Which wearing of the band this is. It goes up when the band charges, stops sending
    /// sEMG for 30 s (off the wrist), stays disconnected for a minute, or when nothing was
    /// recorded for 10 minutes. Starting a new one too often only makes a test stricter.
    private var wearing = UserDefaults.standard.integer(forKey: "passiveWearing")
    private var newWearing = false
    private var disconnectedSince: Double?
    /// Until then, recording pauses: a folder couldn't be made, or a write failed.
    private var cantSaveUntil = -Double.infinity
    /// Trackpad time counted since the last tick, published once a second.
    private var unpublished = Tally()
    /// Keep the user's preference while excluding an experimental band model session from learning.
    func bandModeChanged() { evaluate() }

    private init() {}

    static var root: URL { PracticeWindow.folder.appendingPathComponent("passive", isDirectory: true) }

    func attach(_ model: BandModel) {
        self.model = model
        loadTallies()
        if on { begin() }
    }

    func setOn(_ value: Bool) {
        guard value != on else { return }
        on = value
        UserDefaults.standard.set(value, forKey: "passiveRecording")
        value ? begin() : end()
    }

    /// Closes the recording in progress, when Kinesis quits.
    func shutdown() {
        if on { end() }
        LiveTrackpad.shared.shutdown()
    }

    private func begin() {
        guard let model else { return }
        trackpadStarted = trackpad.start { [weak self] timestamp, contacts in
            let now = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in self?.receiveTrackpad(timestamp, contacts, at: now) }
        }
        let keyDown: (NSEvent, Bool) -> Void = { [weak self] event, local in self?.receiveKey(event, local: local) }
        // Pointer activity with no finger on the trackpad comes from a mouse. Training leaves it out.
        let pointerTypes: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel, .leftMouseDown, .rightMouseDown]
        let pointer: (NSEvent) -> Void = { [weak self] event in self?.receivePointer(event.timestamp) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: pointerTypes, handler: pointer) { keyMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: pointerTypes, handler: { pointer($0); return $0 }) { keyMonitors.append(monitor) }
        // Every press and release, trackpad or not: the labels for clicks and taps.
        let clickTypes: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        let click: (NSEvent) -> Void = { [weak self] event in self?.receiveClick(event) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clickTypes, handler: click) { keyMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clickTypes, handler: { click($0); return $0 }) { keyMonitors.append(monitor) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartTrackpad() }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp], handler: { keyDown($0, false) }) { keyMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp], handler: { keyDown($0, true); return $0 }) { keyMonitors.append(monitor) }
        model.rawEMGListeners["passive"] = { [weak self] batch, arrived in self?.receiveEMG(batch, at: arrived) }
        model.gyroListeners["passive"] = { [weak self] values, stamp, arrived in self?.receiveGyro(values, stamp, at: arrived) }
        ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.evaluate() }
        evaluate()
    }

    private func end() {
        trackpad.stopAll()
        trackpadStarted = false
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors = []
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        model?.rawEMGListeners["passive"] = nil
        model?.gyroListeners["passive"] = nil
        ticker = nil
        closeSegment()
        release()
        if let model { LiveTrackpad.shared.setTeaching(false, wearing: wearing, model: model) }
        status = .off
        warning = nil
        writeStatus()
    }

    /// Once a second: record, or pause and say why.
    private func evaluate() {
        guard on, let model else { return }
        let now = ProcessInfo.processInfo.systemUptime
        emgTimes.removeAll { now - $0.0 > 10 }
        trackpadTimes.removeAll { now - $0 > 10 }
        emgRate = Double(emgTimes.reduce(0) { $0 + $1.1 }) / 10
        trackpadRate = Double(trackpadTimes.count) / 10
        let free = (try? Self.root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        let silent = holding && now - holdingSince > Self.silentBand && now - lastEMG > Self.silentBand
        if model.chargeState.isCharging || (holding && now - max(holdingSince, lastEMG) > 30) { newWearing = true }
        if model.live { disconnectedSince = nil } else {
            if disconnectedSince == nil { disconnectedSince = now }
            if let since = disconnectedSince, now - since > 60 { newWearing = true }
        }
        let reason: String? =
            model.modelControlsUnavailable ? "the band model is in use or needs recovery" :
            !trackpadStarted ? "the trackpad can't be read" :
            !model.live ? "the band isn't connected" :
            model.chargeState.isCharging ? "the band is charging" :
            !model.developerMode ? "developer mode is off" :
            free < Self.minimumFreeSpace ? "the disk is almost full" :
            now < cantSaveUntil ? "kinesis can't save recordings right now" :
            now - lastInput > Self.idle ? "you're away from the Mac" :
            // A fingertip on the desk moves the pointer with no trackpad under it: the
            // trackpad would label every desk slide "not touching".
            FingerCursor.shared.on ? "the finger cursor is on" :
            silent ? "no sEMG from the band. is it on your wrist?" : nil
        if let reason {
            if status == .recording { closeSegment() }
            status = .paused(reason)
            LiveTrackpad.shared.setTeaching(false, wearing: wearing, model: model)
            // A silent band keeps its hold, so sEMG returns on its own when the band does.
            if now - lastInput > Self.rest || !model.live || model.chargeState.isCharging { release() }
        } else {
            hold()
            if files == nil {
                // Coming back from a pause: a fresh trackpad reader, in case the old one went quiet.
                restartTrackpad()
                openSegment()
                guard files != nil else { return }
            }
            if files?.hasFailed == true {
                // A write failed, as on a full disk: end this stretch and try again in a minute.
                closeSegment()
                cantSaveUntil = now + 60
                return
            }
            status = .recording
            LiveTrackpad.shared.setTeaching(true, wearing: wearing, model: model)
            unpublished.seconds += 1
            segment = segment + unpublished
            today = today + unpublished
            total = total + unpublished
            unpublished = Tally()
        }
        warning = status == .recording && now - holdingSince > 10 && emgRate > 0 && emgRate < 1500
            ? String(format: "weak radio: %.0f%% of sEMG arrives", emgRate / 20.48) : nil
        ticks += 1
        if ticks % 5 == 0 { writeStatus() }
        if ticks % 30 == 0, let files { files.writeMeta(meta()) }
    }

    private func hold() {
        guard !holding, let model else { return }
        holding = true
        holdingSince = ProcessInfo.processInfo.systemUptime
        model.holdRawEMG("passive recording", true)
    }

    private func release() {
        guard holding, let model else { return }
        holding = false
        model.holdRawEMG("passive recording", false)
    }

    private func openSegment() {
        let day = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let time = Date.now.formatted(.iso8601.time(includingFractionalSeconds: false).timeSeparator(.omitted))
        var names = ["emg.bin", "touches.bin", "keysides.bin", "gyro.bin", "pointer.bin", "clicks.bin"]
        if includeTyping { names.append("keystrokes.bin") }
        var folder = Self.root.appendingPathComponent("\(day)/\(time)", isDirectory: true)
        for n in 2..<100 where FileManager.default.fileExists(atPath: folder.path) {
            folder = Self.root.appendingPathComponent("\(day)/\(time)-\(n)", isDirectory: true)
        }
        files = try? RecordingFiles(folder: folder, files: names)
        guard files != nil else {
            cantSaveUntil = ProcessInfo.processInfo.systemUptime + 60
            return
        }
        let lastEnd = UserDefaults.standard.double(forKey: "passiveLastEnd")
        if newWearing || lastEnd == 0 || Date().timeIntervalSince1970 - lastEnd > 600 {
            wearing += 1
            UserDefaults.standard.set(wearing, forKey: "passiveWearing")
            newWearing = false
        }
        segment = Tally()
        segmentStarted = Date()
        clockCheck = [:]
        lastFrame = nil
        files?.writeMeta(meta())
    }

    private func closeSegment() {
        guard let files else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "passiveLastEnd")
        files.close(meta: meta())
        self.files = nil
    }

    private func meta() -> [String: Any] {
        ["started": segmentStarted.formatted(.iso8601), "seconds": segment.seconds, "wearing": wearing,
         "touching": segment.touching, "sliding": segment.sliding, "twoFingers": segment.twoFingers,
         "threeFingers": segment.threeFingers,
         "palm": segment.palm, "keys": segment.keys,
         "hand": model.map { "\($0.bandHand)" } ?? "?", "clockCheck": clockCheck,
         "formats": ["emg.bin": "f64 arrival, u64 band µs, u64 sequence, 128 × u16 (16 samples × 8 channels)",
                     "touches.bin": "f64 framework time, f64 arrival, i32 count, count × 96-byte MultitouchSupport contacts",
                     "keysides.bin": "f64 time, u8 side (0 the band hand's side of the keyboard, 1 the other hand's, 2 space, 3 other keys), u8 1 for press 0 for release, u8 1 if a repeat",
                     "keystrokes.bin": "only with include typing on: f64 time, u16 macOS key code, u8 1 for press 0 for release, u8 1 if a repeat. Secure fields such as passwords never reach it",
                     "pointer.bin": "f64 time the pointer moved, scrolled, or clicked with no finger on the trackpad: a mouse",
                     "clicks.bin": "f64 time, u8 kind (0 left down, 1 left up, 2 right down, 3 right up), u8 1 if a finger was on the trackpad",
                     "gyro.bin": "f64 arrival, u64 band µs, 3 × f64 raw counts"]]
    }

    /// Adds up the recordings already on disk, today's and all of them.
    private func loadTallies() {
        let day = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        var today = Tally(), total = Tally()
        let metas = (FileManager.default.enumerator(at: Self.root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.lastPathComponent == "meta.json" }
        for url in metas {
            guard let data = try? Data(contentsOf: url),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let tally = Tally(seconds: meta["seconds"] as? Double ?? 0, touching: meta["touching"] as? Double ?? 0,
                              sliding: meta["sliding"] as? Double ?? 0, twoFingers: meta["twoFingers"] as? Double ?? 0,
                              threeFingers: meta["threeFingers"] as? Double ?? 0,
                              palm: meta["palm"] as? Double ?? 0, keys: meta["keys"] as? Int ?? 0)
            total = total + tally
            if url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == day { today = today + tally }
        }
        self.today = today
        self.total = total
    }

    /// A small file Claude or a script can read to check on the recording.
    private func writeStatus() {
        var row: [String: Any] = ["updated": Date.now.formatted(.iso8601), "on": on,
                                  "emgRate": emgRate, "trackpadRate": trackpadRate,
                                  "today": ["seconds": today.seconds, "touching": today.touching, "sliding": today.sliding,
                                            "twoFingers": today.twoFingers, "threeFingers": today.threeFingers,
                                            "palm": today.palm, "keys": today.keys],
                                  "totalSeconds": total.seconds, "totalSliding": total.sliding]
        switch status {
        case .off: row["status"] = "off"
        case .recording: row["status"] = "recording"
        case .paused(let reason): row["status"] = "paused: " + reason
        }
        if let warning { row["warning"] = warning }
        if let files { row["segment"] = files.folder.path }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        try? data.write(to: Self.root.appendingPathComponent("status.json"), options: .atomic)
    }

    private func receiveTrackpad(_ timestamp: Double, _ contacts: Data, at arrived: Double) {
        trackpadTimes.append(arrived)
        // Contacts that touch: state 3 is making touch, 4 is touching.
        var fingers: [SIMD2<Float>] = []
        var palms = 0
        contacts.withUnsafeBytes { raw in
            for k in 0..<(contacts.count / SystemTrackpad.contactBytes) {
                let base = k * SystemTrackpad.contactBytes
                let state = raw.loadUnaligned(fromByteOffset: base + 20, as: Int32.self)
                guard state == 3 || state == 4 else { continue }
                if raw.loadUnaligned(fromByteOffset: base + 48, as: Float.self) >= Self.palmSize {
                    palms += 1
                } else {
                    fingers.append(SIMD2(raw.loadUnaligned(fromByteOffset: base + 68, as: Float.self),
                                         raw.loadUnaligned(fromByteOffset: base + 72, as: Float.self)))
                }
            }
        }
        if !fingers.isEmpty || palms > 0 {
            lastInput = arrived
            lastTouch = arrived
        }
        LiveTrackpad.shared.receiveTrackpad(at: arrived, fingers: fingers, palms: palms)
        if clockCheck["trackpad"] == nil { clockCheck["trackpad"] = arrived - timestamp }
        guard status == .recording, let files else { return }
        if let last = lastFrame, timestamp > last.time, timestamp - last.time < 0.1 {
            let dt = timestamp - last.time
            var add = Tally()
            if palms > 0 { add.palm = dt }
            if !fingers.isEmpty { add.touching = dt }
            if fingers.count == 2 { add.twoFingers = dt }
            if fingers.count >= 3 { add.threeFingers = dt }
            if fingers.count == 1, palms == 0, let before = last.finger {
                let distance = Double(simd_length(fingers[0] - before))
                if distance / dt > 10 { add.sliding = dt }
            }
            unpublished = unpublished + add
        }
        lastFrame = (timestamp, fingers.count == 1 ? fingers[0] : nil)
        var record = Data()
        record.put(timestamp)
        record.put(arrived)
        record.put(Int32(contacts.count / SystemTrackpad.contactBytes))
        record.append(contacts)
        files.append(record, to: "touches.bin")
    }

    private func restartTrackpad() {
        guard on else { return }
        trackpadStarted = trackpad.restart()
    }

    private func receivePointer(_ time: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTouch > 0.3 else { return }
        lastInput = max(lastInput, now)
        guard status == .recording, let files else { return }
        var record = Data()
        record.put(time)
        files.append(record, to: "pointer.bin")
    }

    private func receiveClick(_ event: NSEvent) {
        let kind: UInt8 = switch event.type {
        case .leftMouseDown: 0
        case .leftMouseUp: 1
        case .rightMouseDown: 2
        default: 3
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard status == .recording, let files else { return }
        var record = Data()
        record.put(event.timestamp)
        record.put(kind)
        record.put(UInt8(now - lastTouch < 0.3 ? 1 : 0))
        files.append(record, to: "clicks.bin")
    }

    /// A key pressed or released: its side of the keyboard, and with "include typing" on,
    /// which key. `local` is a key typed in Kinesis's own windows.
    private func receiveKey(_ event: NSEvent, local: Bool) {
        let pressed = event.type == .keyDown
        if pressed { lastInput = max(lastInput, event.timestamp) }
        guard status == .recording, let files else { return }
        if pressed, !event.isARepeat {
            segment.keys += 1
            today.keys += 1
            total.keys += 1
        }
        var side = Data()
        side.put(event.timestamp)
        side.put(Self.side(of: event.keyCode, hand: model?.bandHand ?? .right).rawValue)
        side.put(UInt8(pressed ? 1 : 0))
        side.put(UInt8(event.isARepeat ? 1 : 0))
        files.append(side, to: "keysides.bin")
        // Which key never comes from Kinesis's own windows, as its Meta sign-in, or while
        // any app has secure input on, as a password field does.
        guard includeTyping, !local, !IsSecureEventInputEnabled() else { return }
        var record = Data()
        record.put(event.timestamp)
        record.put(UInt16(event.keyCode))
        record.put(UInt8(pressed ? 1 : 0))
        record.put(UInt8(event.isARepeat ? 1 : 0))
        files.append(record, to: "keystrokes.bin")
    }

    private nonisolated static let left: Set<UInt16> = [0, 1, 2, 3, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 48, 50,
                                                        53, 55, 56, 57, 58, 59, 63]
    private nonisolated static let right: Set<UInt16> = [4, 16, 22, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
                                                         41, 42, 43, 44, 45, 46, 47, 51, 54, 60, 61, 62, 115, 116, 117, 119, 121,
                                                         123, 124, 125, 126]

    enum KeySide: UInt8 {
        case bandHand = 0, otherHand = 1, space = 2, other = 3
    }

    /// Which side of a US keyboard a key sits on, by the hand that usually types it.
    nonisolated static func side(of keyCode: UInt16, hand: BandHand) -> KeySide {
        if keyCode == 49 { return .space }
        let bandSide = hand == .left ? left : right
        let otherSide = hand == .left ? right : left
        if bandSide.contains(keyCode) { return .bandHand }
        if otherSide.contains(keyCode) { return .otherHand }
        return .other
    }

    private func receiveEMG(_ batch: EMGBatch, at arrived: Double) {
        lastEMG = arrived
        emgTimes.append((arrived, batch.values.count / 8))
        guard status == .recording, let files else { return }
        var record = Data()
        record.put(arrived)
        record.put(batch.timestampUs)
        record.put(batch.sequence)
        for value in batch.values { record.put(value) }
        files.append(record, to: "emg.bin")
    }

    private func receiveGyro(_ values: SIMD3<Double>, _ stamp: UInt64, at arrived: Double) {
        guard status == .recording, let files else { return }
        var record = Data()
        record.put(arrived)
        record.put(stamp)
        record.put(values.x)
        record.put(values.y)
        record.put(values.z)
        files.append(record, to: "gyro.bin")
    }
}

/// The menu bar's control for passive recording, readable at a glance.
struct PassiveRecorderMenu: View {
    @ObservedObject private var recorder = PassiveRecorder.shared

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    var body: some View {
        Toggle("record while I work", isOn: Binding(get: { recorder.on }, set: { recorder.setOn($0) }))
        Toggle("include typing", isOn: $recorder.includeTyping)
        switch recorder.status {
        case .off:
            if recorder.total.seconds > 0 { Text("\(duration(recorder.total.seconds)) recorded so far") }
        case .recording:
            Text("● recording · \(duration(recorder.today.seconds)) today · \(duration(recorder.total.seconds)) in all")
            Text("today: one-finger slides \(duration(recorder.today.sliding)) · two fingers \(duration(recorder.today.twoFingers)) · three \(duration(recorder.today.threeFingers))")
            Text(String(format: "sEMG %.0f%% · trackpad %.0f/s", recorder.emgRate / 20.48, recorder.trackpadRate))
            if let problem = LiveTrackpad.shared.problem {
                Text("decoder: \(problem)")
            } else if LiveTrackpad.shared.learned > 0 {
                Text("decoder: learned from \(duration(LiveTrackpad.shared.learned)) of trackpad use on this wearing")
            }
        case .paused(let reason):
            Text("paused: \(reason)")
            if recorder.today.seconds > 0 { Text("\(duration(recorder.today.seconds)) today · \(duration(recorder.total.seconds)) in all") }
        }
        if let warning = recorder.warning { Text("⚠︎ \(warning)") }
    }
}
#endif
