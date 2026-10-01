#if KINESIS_DEV
import AppKit
import SwiftUI

// A developer tool, only in dev builds: records the band's raw sEMG while a finger
// moves on the Mac's trackpad. The trackpad measures the finger exactly, so each
// recording pairs muscle signals with true touch, lift, and slide, which is what a
// decoder that turns the band into a trackpad has to learn from.
// scripts/trackpad-check.py tests whether a recording carries that signal.

@MainActor final class TrackpadWindow {
    static let shared = TrackpadWindow()
    private var window: NSWindow?
    private var session: BandModelRecording?
    private var keys: Any?

    func open(model: BandModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let session = BandModelRecording(model: model)
        let window = TrackpadNSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let picture = NSHostingView(rootView: TrackpadView(session: session))
        picture.frame = root.bounds
        picture.autoresizingMask = [.width, .height]
        root.addSubview(picture)
        // On top of the picture, so every touch reaches it.
        let capture = TouchCaptureView(frame: root.bounds) { [weak session] event, view in session?.receive(event, in: view) }
        capture.autoresizingMask = [.width, .height]
        root.addSubview(capture)
        window.contentView = root
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(capture)
        NSApp.activate(ignoringOtherApps: true)
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window, weak session] event in
            guard let window, event.window === window, let session else { return event }
            switch event.keyCode {
            case 49: session.start()
            case 46: session.markMissed()
            case 53: session.isRunning ? session.finish() : self?.close()
            default: return event
            }
            return nil
        }
        self.window = window
        self.session = session
    }

    /// True for a key press in the recorder, which handles Escape itself.
    func owns(_ event: NSEvent) -> Bool {
        window != nil && event.window === window
    }

    func close() {
        session?.finish()
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        window?.orderOut(nil)
        window = nil
        session = nil
    }
}

private final class TrackpadNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Takes every trackpad touch, including fingers that only rest on it.
final class TouchCaptureView: NSView {
    private let handler: (NSEvent, NSView) -> Void

    init(frame: NSRect, handler: @escaping (NSEvent, NSView) -> Void) {
        self.handler = handler
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = true
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func touchesBegan(with event: NSEvent) { handler(event, self) }
    override func touchesMoved(with event: NSEvent) { handler(event, self) }
    override func touchesEnded(with event: NSEvent) { handler(event, self) }
    override func touchesCancelled(with event: NSEvent) { handler(event, self) }
    override func mouseDown(with event: NSEvent) { handler(event, self) }
    override func mouseUp(with event: NSEvent) { handler(event, self) }
}

private struct TrackpadView: View {
    @ObservedObject var session: BandModelRecording
    @ObservedObject private var model: BandModel

    init(session: BandModelRecording) {
        self.session = session
        model = session.model
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.053, blue: 0.057).ignoresSafeArea()
            VStack(spacing: 28) {
                if let index = session.cueIndex {
                    let cue = BandModelRecording.cues[index]
                    Text(cue.trial > 0 ? "\(cue.phase.uppercased()) · trial \(cue.trial) of 30" : "REST").font(KinesisType.micro).foregroundStyle(.white.opacity(0.5))
                    Text(cue.text).font(.system(size: 30)).tracking(-0.6).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        let left = max(0, session.cueEndsAt.timeIntervalSince(context.date))
                        ProgressView(value: 1 - left / cue.seconds).tint(KinesisStyle.accent).frame(width: 360)
                    }
                } else {
                    Text(session.done ? "recording saved" : session.isRunning ? session.phase == .restoring ? "finishing recording" : "preparing recording" : "trackpad recording").font(KinesisType.title).tracking(-1.2).foregroundStyle(.white)
                    Text(session.isRunning ? session.status : session.done ? "space to record again · esc to close" : "about four minutes. index finger on the trackpad. space to start · esc to close")
                        .font(KinesisType.body).foregroundStyle(.white.opacity(0.6))
                }
                if session.phase == .recording {
                    Text("one movement per GO · lift on REST · M marks a missed trial · Esc stops")
                        .font(KinesisType.micro).foregroundStyle(.white.opacity(0.5))
                }
                pad
                Text("sEMG frames \(model.rawRecordedFrames) · touches \(session.touchCount) · band model \(session.inferenceCount) · gaps \(session.inferenceGaps)")
                    .accessibilityIdentifier("trackpad-capture-counts")
                    .font(KinesisType.caption).monospacedDigit().foregroundStyle(.white.opacity(0.45))
                if let problem = session.problem {
                    Text(problem).font(KinesisType.caption).foregroundStyle(KinesisStyle.warning)
                }
                if let folder = session.folder, session.done {
                    Text(folder.path).font(KinesisType.micro).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// The trackpad, with a dot for each finger on it.
    private var pad: some View {
        let width = 420.0
        let height = width * session.padSize.height / max(1, session.padSize.width)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05))
            RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12))
            ForEach(Array(session.fingers.enumerated()), id: \.offset) { _, point in
                Circle().fill(KinesisStyle.accent).frame(width: 22, height: 22)
                    .position(x: point.x * width, y: (1 - point.y) * height)
            }
        }
        .frame(width: width, height: height)
    }
}
#endif
