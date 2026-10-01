#if KINESIS_DEV
import AppKit
import SwiftUI
import simd

// A developer tool, only in dev builds: the trained trackpad decoder, live. A white
// dot is the real finger on the trackpad. A blue dot starts where the finger lands
// and then moves only by what the decoder reads from the sEMG, so the two paths
// show how well it follows. Off the trackpad, a fingertip on the desk moves the blue
// dot alone. Train a model first with scripts/trackpad-train.py.

@MainActor final class TrackpadPreviewWindow {
    static let shared = TrackpadPreviewWindow()
    private var window: NSWindow?
    private var preview: TrackpadPreview?
    private var keys: Any?

    func open(model: BandModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let preview = TrackpadPreview(model: model)
        let window = PreviewNSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let picture = NSHostingView(rootView: TrackpadPreviewView(preview: preview))
        picture.frame = root.bounds
        picture.autoresizingMask = [.width, .height]
        root.addSubview(picture)
        let capture = TouchCaptureView(frame: root.bounds) { [weak preview] event, view in preview?.receive(event, in: view) }
        capture.autoresizingMask = [.width, .height]
        root.addSubview(capture)
        window.contentView = root
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(capture)
        NSApp.activate(ignoringOtherApps: true)
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let window, event.window === window, event.keyCode == 53 else { return event }
            self?.close()
            return nil
        }
        preview.start()
        self.window = window
        self.preview = preview
    }

    func owns(_ event: NSEvent) -> Bool {
        window != nil && event.window === window
    }

    func close() {
        preview?.stop()
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        window?.orderOut(nil)
        window = nil
        preview = nil
    }
}

private final class PreviewNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class TrackpadPreview: ObservableObject {
    /// Positions in millimeters on the trackpad, from its bottom left.
    @Published private(set) var finger: SIMD2<Double>?
    @Published private(set) var decoded: SIMD2<Double>?
    @Published private(set) var contact = 0.0
    @Published private(set) var trail: [SIMD2<Double>] = []
    @Published private(set) var fingerTrail: [SIMD2<Double>] = []
    /// Of the last 30 s of real slides over 20 mm/s: how often the decoded direction agreed, per axis.
    @Published private(set) var agreement: SIMD2<Double>?
    @Published private(set) var problem: String?
    @Published private(set) var trainedOn = 0
    /// Seconds of trackpad use the decoder learned from on this wearing.
    @Published private(set) var learned = 0.0
    private(set) var padSize = SIMD2<Double>(124, 76)

    private let model: BandModel
    private var started = false
    private var drift = DriftCorrection()
    private var lastFinger: (time: Double, position: SIMD2<Double>)?
    private var fingerVelocity = SIMD2<Double>.zero
    private var matches: [(time: Double, x: Bool?, y: Bool?)] = []
    private var lastPublish = 0.0

    init(model: BandModel) {
        self.model = model
    }

    func start() {
        problem = LiveTrackpad.shared.hold("preview", model: model) { [weak self] output in self?.decode(output) }
        guard problem == nil else { return }
        started = true
        openLog()
        trainedOn = LiveTrackpad.shared.trainedOn
        model.setAirCursorEnabled(false)
    }

    func stop() {
        guard started else { return }
        LiveTrackpad.shared.release("preview")
        started = false
        flushLog()
        log = nil
    }

    /// Every decoded frame, beside the real finger as this window sees it, to check the preview
    /// against the passive recording's view of the same touches. One file per session in the Lab folder.
    private var log: FileHandle?
    private var logLines = ""

    private func openLog() {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .timeSeparator(.omitted).dateSeparator(.dash))
        let url = PracticeWindow.folder.appendingPathComponent("preview-\(stamp).csv")
        FileManager.default.createFile(atPath: url.path, contents: Data("uptime,finger_x,finger_y,contact,velocity_x,velocity_y,decoded_x,decoded_y,raise\n".utf8))
        log = try? FileHandle(forWritingTo: url)
        _ = try? log?.seekToEnd()
    }

    private func flushLog() {
        defer { logLines = "" }
        guard let log, !logLines.isEmpty else { return }
        log.write(Data(logLines.utf8))
    }

    private func decode(_ output: TrackpadDecoder.Output) {
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            let f = finger.map { String(format: "%.2f,%.2f", $0.x, $0.y) } ?? ","
            let d = decoded.map { String(format: "%.2f,%.2f", $0.x, $0.y) } ?? ","
            logLines += String(format: "%.4f,", now) + f + String(format: ",%.3f,%.1f,%.1f,", output.contact, output.velocity.x, output.velocity.y)
                + d + String(format: ",%.3f\n", output.raise)
            if logLines.utf8.count > 20_000 { flushLog() }
        }
        let wasTouching = contact > 0.5
        contact += (output.contact - contact) * 0.3
        if contact > 0.5 {
            // A new touch starts where the real finger is, or in the middle off the trackpad.
            if !wasTouching || decoded == nil { decoded = finger ?? padSize / 2; trail = [] }
            if var point = decoded {
                let frame = LiveTrackpad.shared.frameSeconds
                point += drift.correct(output.velocity, frame: frame) * frame
                point = SIMD2(min(max(point.x, 0), padSize.x), min(max(point.y, 0), padSize.y))
                decoded = point
                if now - lastPublish > 0.03 { trail.append(point); if trail.count > 120 { trail.removeFirst() } }
            }
        }
        // Score direction against the real finger while it slides.
        if finger != nil, simd_length(fingerVelocity) > 20 {
            let x: Bool? = abs(fingerVelocity.x) > 20 ? (output.velocity.x > 0) == (fingerVelocity.x > 0) : nil
            let y: Bool? = abs(fingerVelocity.y) > 20 ? (output.velocity.y > 0) == (fingerVelocity.y > 0) : nil
            matches.append((now, x, y))
        }
        matches.removeAll { now - $0.time > 30 }
        if now - lastPublish > 0.25 {
            lastPublish = now
            learned = LiveTrackpad.shared.learned
            let xs = matches.compactMap(\.x), ys = matches.compactMap(\.y)
            if xs.count + ys.count > 20 {
                agreement = SIMD2(xs.isEmpty ? .nan : Double(xs.filter { $0 }.count) / Double(xs.count),
                                  ys.isEmpty ? .nan : Double(ys.filter { $0 }.count) / Double(ys.count))
            }
        }
    }

    func receive(_ event: NSEvent, in view: NSView) {
        let touches = event.touches(matching: .touching, in: view)
        guard let touch = touches.first, touches.count == 1 else {
            finger = nil
            lastFinger = nil
            fingerVelocity = .zero
            fingerTrail = []
            return
        }
        let millimeters = 25.4 / 72
        padSize = SIMD2(touch.deviceSize.width, touch.deviceSize.height) * millimeters
        let point = SIMD2(touch.normalizedPosition.x, touch.normalizedPosition.y) * padSize
        if let last = lastFinger, event.timestamp > last.time {
            let velocity = (point - last.position) / (event.timestamp - last.time)
            fingerVelocity += (velocity - fingerVelocity) * 0.3
        }
        lastFinger = (event.timestamp, point)
        finger = point
        fingerTrail.append(point)
        if fingerTrail.count > 120 { fingerTrail.removeFirst() }
    }
}

private struct TrackpadPreviewView: View {
    @ObservedObject var preview: TrackpadPreview

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.053, blue: 0.057).ignoresSafeArea()
            VStack(spacing: 24) {
                Text("decoder preview").font(KinesisType.title).tracking(-1.2).foregroundStyle(.white)
                Text(preview.problem ?? "white is your finger on the trackpad. blue is what the band reads. esc to close.")
                    .font(KinesisType.body).foregroundStyle(preview.problem == nil ? .white.opacity(0.6) : KinesisStyle.warning)
                pad
                HStack(spacing: 28) {
                    meter
                    if let agreement = preview.agreement {
                        Text(String(format: "direction right, last 30 s: left-right %@, up-down %@",
                                    percent(agreement.x), percent(agreement.y)))
                            .font(KinesisType.caption).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                    }
                }
                if preview.trainedOn > 0 {
                    Text("trained on \(preview.trainedOn) recordings, and learned from \(learnedText) of trackpad use on this wearing. 50 % is chance.")
                        .font(KinesisType.micro).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var learnedText: String {
        preview.learned < 60 ? "\(Int(preview.learned)) s" : "\(Int(preview.learned / 60)) min"
    }

    private func percent(_ value: Double) -> String {
        value.isNaN ? "-" : String(format: "%.0f%%", value * 100)
    }

    private var meter: some View {
        HStack(spacing: 10) {
            Text("touch").font(KinesisType.caption).foregroundStyle(.white.opacity(0.6))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08)).frame(width: 160, height: 8)
                Capsule().fill(KinesisStyle.accent).frame(width: 160 * preview.contact, height: 8)
                    .animation(.easeOut(duration: 0.1), value: preview.contact)
            }
        }
    }

    private var pad: some View {
        let width = 620.0
        let scale = width / preview.padSize.x
        let height = preview.padSize.y * scale
        func place(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: p.x * scale, y: height - p.y * scale) }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.05))
            RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12))
            Path { path in
                for (i, p) in preview.fingerTrail.enumerated() { i == 0 ? path.move(to: place(p)) : path.addLine(to: place(p)) }
            }.stroke(.white.opacity(0.35), lineWidth: 2)
            Path { path in
                for (i, p) in preview.trail.enumerated() { i == 0 ? path.move(to: place(p)) : path.addLine(to: place(p)) }
            }.stroke(KinesisStyle.accent.opacity(0.6), lineWidth: 2)
            if let finger = preview.finger {
                Circle().fill(.white).frame(width: 20, height: 20).position(place(finger))
            }
            if let decoded = preview.decoded, preview.contact > 0.5 {
                Circle().fill(KinesisStyle.accent).frame(width: 24, height: 24).position(place(decoded))
            }
        }
        .frame(width: width, height: height)
    }
}
#endif
