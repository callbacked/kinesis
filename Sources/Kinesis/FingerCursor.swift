#if KINESIS_DEV
import AppKit
import OSLog
import SwiftUI

/// A developer toy, only in dev builds: the trained trackpad decoder moves the real
/// pointer, from sEMG alone, while it believes a fingertip is on the desk. It never
/// clicks. Escape turns it off. Use it on the desk, not on the trackpad, or both move
/// the pointer. A deliberate finger raise clicks, when the model has a click detector.
/// Holding Control also counts as touching: a clutch, to try the decoded
/// direction on a surface whose touch the decoder hasn't learned. While it runs, it saves
/// the band's sEMG and gyro and when Control was held to Lab/desk: a fingertip is on the
/// desk while Control is down, so those are desk touch labels for training later.
@MainActor final class FingerCursor: ObservableObject {
    static let shared = FingerCursor()

    @Published private(set) var on = false
    @Published private(set) var problem: String?

    /// Points per millimeter of decoded finger travel. A Mac trackpad's middle speed is about
    /// 10, but the decoder is noisy enough on a desk that 10 threw the pointer around.
    static let gain = 6.0
    /// Decoded speeds under this, in mm/s, are noise and move nothing. With a fingertip still
    /// on the desk, the decoded speed hummed at 40 to 50 mm/s on 2026-09-30, before smoothing.
    static let deadZone = 35.0

    private weak var model: BandModel?
    private var contact = 0.0
    private var velocity = SIMD2<Double>.zero
    private var leftover = SIMD2<Double>.zero
    private var clutch = false
    /// Frames since the last click.
    private var sinceClick = Int.max / 2
    private var lastClick: (time: Double, point: CGPoint, count: Int)?
    private var clickCount = 1
    private var raiseArmed = true
    /// When the finger was last on the surface, or Control held.
    private var pointedAt = -Double.infinity
    private var drift = DriftCorrection()
    private var monitors: [Any] = []
    private var files: RecordingFiles?
    private var started = Date()
    private let log = Logger(subsystem: "local.callbacked.kinesis", category: "finger cursor")
    /// For the log, every 2 s: frames, summed touch and speed, frames with Control held, and moves sent.
    private var tally = (frames: 0, contact: 0.0, speed: 0.0, clutched: 0, moves: 0, clicks: 0, since: 0.0)

    func setOn(_ value: Bool, model: BandModel) {
        guard value != on else { return }
        if value {
            guard !model.modelControlsUnavailable else {
                problem = "finish the band model operation before starting the finger cursor."
                return
            }
            problem = LiveTrackpad.shared.hold("finger cursor", model: model) { [weak self] output in self?.decode(output) }
            log.info("on: \(self.problem ?? "started", privacy: .public), trusted \(AXIsProcessTrusted())")
            guard problem == nil else { return }
            self.model = model
            model.setAirCursorEnabled(false)
            startRecording(model)
            let flags: (NSEvent) -> Void = { [weak self] event in self?.setClutch(event.modifierFlags.contains(.control)) }
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(monitor) }
            on = true
        } else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            setClutch(false)
            stopRecording(model)
            LiveTrackpad.shared.release("finger cursor")
            contact = 0
            velocity = .zero
            on = false
        }
    }

    func stop() {
        if on, let model { setOn(false, model: model) }
    }

    /// A left click where the pointer is. Two raises within the Mac's double-click time make a
    /// double click: macOS only counts it when the second click says it is the second.
    private func click() {
        guard let location = CGEvent(source: nil)?.location else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastClick, now - last.time <= NSEvent.doubleClickInterval,
           hypot(location.x - last.point.x, location.y - last.point.y) <= 4 {
            clickCount = last.count + 1
        } else {
            clickCount = 1
        }
        lastClick = (now, location, clickCount)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            event?.post(tap: .cghidEventTap)
        }
        tally.clicks += 1
        log.info("click at \(location.x, format: .fixed(precision: 0)), \(location.y, format: .fixed(precision: 0))")
    }

        private func setClutch(_ held: Bool) {
        guard held != clutch else { return }
        clutch = held
        LiveTrackpad.shared.setDeskTouch(held)
        var record = Data()
        record.put(ProcessInfo.processInfo.systemUptime)
        record.put(UInt8(held ? 1 : 0))
        files?.append(record, to: "clutch.bin")
    }

    /// The same record layouts as the passive recorder, so the trainer reads them alike.
    private func startRecording(_ model: BandModel) {
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        files = try? RecordingFiles(folder: PracticeWindow.folder.appendingPathComponent("desk/\(stamp)", isDirectory: true),
                                    files: ["emg.bin", "gyro.bin", "clutch.bin"])
        started = Date()
        model.rawEMGListeners["desk"] = { [weak self] batch, arrived in
            var record = Data()
            record.put(arrived)
            record.put(batch.timestampUs)
            record.put(batch.sequence)
            for value in batch.values { record.put(value) }
            self?.files?.append(record, to: "emg.bin")
        }
        model.gyroListeners["desk"] = { [weak self] values, stamp, arrived in
            var record = Data()
            record.put(arrived)
            record.put(stamp)
            record.put(values.x)
            record.put(values.y)
            record.put(values.z)
            self?.files?.append(record, to: "gyro.bin")
        }
    }

    private func stopRecording(_ model: BandModel) {
        model.rawEMGListeners["desk"] = nil
        model.gyroListeners["desk"] = nil
        files?.close(meta: ["started": started.formatted(.iso8601), "seconds": Date().timeIntervalSince(started),
                            "hand": "\(model.bandHand)", "surface": "desk",
                            "formats": ["clutch.bin": "f64 time, u8 1 when Control went down (a fingertip on the desk), 0 when it came up"]])
        files = nil
    }

    private func decode(_ output: TrackpadDecoder.Output) {
        let now = ProcessInfo.processInfo.systemUptime
        tally.frames += 1
        tally.contact += output.contact
        tally.speed += (output.velocity.x * output.velocity.x + output.velocity.y * output.velocity.y).squareRoot()
        if clutch { tally.clutched += 1 }
        if now - tally.since > 2 {
            let n = Double(max(1, tally.frames))
            log.info("\(self.tally.frames) frames, touch \(self.tally.contact / n, format: .fixed(precision: 2)), speed \(self.tally.speed / n, format: .fixed(precision: 0)) mm/s, control held \(self.tally.clutched), moves \(self.tally.moves), clicks \(self.tally.clicks)")
            tally = (0, 0, 0, 0, 0, 0, now)
        }
        sinceClick += 1
        // One click per raise: after a click, the detector has to drop under 0.5 before the
        // next can fire, however long the raise lasts. Two quick raises make a double click.
        let frame = LiveTrackpad.shared.frameSeconds
        if contact > 0.6 || clutch { pointedAt = now }
        if let raise = LiveTrackpad.shared.raise {
            let rising = min(0.5, raise.threshold)
            if output.raise < rising { raiseArmed = true }
            // Only while pointing, or just after: a raise lifts the finger off the surface, but a
            // raise-like motion while typing or resting must never click.
            if raiseArmed, output.raise > raise.threshold, sinceClick > raise.lockout, now - pointedAt < 0.6 {
                click()
                sinceClick = 0
                raiseArmed = false
            }
            // A raise moves the forearm too: hold the pointer still while one happens, and just
            // after a click, so the click lands where the pointer was.
            if output.raise > rising || Double(sinceClick) * frame < 0.2 {
                velocity = .zero
                return
            }
        }
        contact += (output.contact - contact) * 0.3
        // Light smoothing, about 30 ms. Heavier lags so much that it points the wrong way
        // after a turn: at 0.2, a fifth of frames lost their direction on 2026-09-30.
        guard contact > 0.6 || clutch else { velocity = .zero; return }
        velocity += (drift.correct(output.velocity, frame: frame) - velocity) * 0.5
        let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
        guard speed > Self.deadZone else { return }
        // Decoded "along the finger, away" is up on the screen.
        leftover += SIMD2(velocity.x, -velocity.y) * frame * Self.gain
        let step = leftover.rounded(.towardZero)
        guard step != .zero, let location = CGEvent(source: nil)?.location else { return }
        leftover -= step
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: location.x + step.x, y: location.y + step.y), mouseButton: .left)?
            .post(tap: .cghidEventTap)
        tally.moves += 1
    }
}

/// The menu bar's switch for the finger cursor.
struct FingerCursorMenu: View {
    let model: BandModel
    @ObservedObject private var cursor = FingerCursor.shared

    var body: some View {
        Toggle("finger cursor (decoder)", isOn: Binding(get: { cursor.on }, set: { cursor.setOn($0, model: model) }))
        if cursor.on { Text("hold control while you slide on the desk. raise a finger to click") }
        if let problem = cursor.problem { Text(problem) }
    }
}
#endif
