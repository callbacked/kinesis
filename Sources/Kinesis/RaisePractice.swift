#if KINESIS_DEV
import AppKit
import SwiftUI

// A developer tool, only in dev builds: records deliberate finger raises, the click
// gesture for the trackpad decoder. A word lights up: raise that finger high and put
// it back, or do nothing for "rest". The band's sEMG and gyro go to Lab/raises in the
// passive recorder's layouts, with cues.bin saying when each word lit up. The passive
// recordings supply the movements a raise must not be mistaken for: casual lifts.

@MainActor final class RaiseWindow {
    static let shared = RaiseWindow()
    private var window: NSWindow?
    private var session: RaiseSession?
    private var keys: Any?

    func open(model: BandModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let session = RaiseSession(model: model)
        let window = RaiseNSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.contentView = NSHostingView(rootView: RaiseView(session: session))
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window, weak session] event in
            guard let window, event.window === window, let session else { return event }
            switch event.keyCode {
            case 49: session.start()
            case 53: session.isRunning ? session.finish() : self?.close()
            default: return event
            }
            return nil
        }
        self.window = window
        self.session = session
    }

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

private final class RaiseNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class RaiseSession: ObservableObject {
    enum Kind: UInt8 {
        case rest = 0, index = 1, middle = 2

        var word: String {
            switch self {
            case .rest: "rest"
            case .index: "index"
            case .middle: "middle"
            }
        }
    }

    /// 24 of each finger and 16 rests, shuffled the same way every time: about 2 min 40 s.
    static let trials: [Kind] = {
        var kinds = Array(repeating: Kind.index, count: 24) + Array(repeating: Kind.middle, count: 24)
            + Array(repeating: Kind.rest, count: 16)
        var random = SeededRandom(seed: 7)
        kinds.shuffle(using: &random)
        return kinds
    }()
    /// Each trial: the word shows dim, then lights up. Raise when it lights up.
    static let ready = 1.0
    static let go = 1.5

    @Published private(set) var trial: Int?
    @Published private(set) var lit = false
    @Published private(set) var done = false
    @Published private(set) var problem: String?
    @Published private(set) var folder: URL?

    private let model: BandModel
    private var files: RecordingFiles?
    private var task: Task<Void, Never>?
    private var started = Date()

    init(model: BandModel) {
        self.model = model
    }

    /// From start until finish, including the settle before the first word.
    @Published private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        guard model.live, model.developerMode else {
            problem = "connect the band and turn on developer mode first."
            return
        }
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let folder = PracticeWindow.folder.appendingPathComponent("raises/\(stamp)", isDirectory: true)
        guard let files = try? RecordingFiles(folder: folder, files: ["emg.bin", "gyro.bin", "cues.bin"]) else {
            problem = "couldn’t save the recording."
            return
        }
        problem = nil
        done = false
        isRunning = true
        started = Date()
        self.files = files
        self.folder = folder
        model.setAirCursorEnabled(false)
        model.holdRawEMG("raise practice", true)
        model.rawEMGListeners["raises"] = { [weak self] batch, arrived in
            var record = Data()
            record.put(arrived)
            record.put(batch.timestampUs)
            record.put(batch.sequence)
            for value in batch.values { record.put(value) }
            self?.files?.append(record, to: "emg.bin")
        }
        model.gyroListeners["raises"] = { [weak self] values, stamp, arrived in
            var record = Data()
            record.put(arrived)
            record.put(stamp)
            record.put(values.x)
            record.put(values.y)
            record.put(values.z)
            self?.files?.append(record, to: "gyro.bin")
        }
        task = Task { [weak self] in
            // A short settle before the first word.
            try? await Task.sleep(for: .seconds(2))
            for (index, kind) in Self.trials.enumerated() {
                guard let self, !Task.isCancelled else { return }
                self.trial = index
                self.lit = false
                try? await Task.sleep(for: .seconds(Self.ready))
                if Task.isCancelled { return }
                self.lit = true
                var record = Data()
                record.put(ProcessInfo.processInfo.systemUptime)
                record.put(kind.rawValue)
                self.files?.append(record, to: "cues.bin")
                try? await Task.sleep(for: .seconds(Self.go))
            }
            self?.finish()
        }
    }

    func finish() {
        guard isRunning else { return }
        isRunning = false
        task?.cancel()
        trial = nil
        lit = false
        model.rawEMGListeners["raises"] = nil
        model.gyroListeners["raises"] = nil
        model.holdRawEMG("raise practice", false)
        files?.close(meta: ["started": started.formatted(.iso8601), "seconds": Date().timeIntervalSince(started),
                            "hand": "\(model.bandHand)",
                            "formats": ["cues.bin": "f64 time the word lit up, u8 kind (0 rest, 1 raise index, 2 raise middle)"]])
        files = nil
        done = true
    }

    fileprivate var current: Kind? { trial.map { Self.trials[$0] } }
}

private struct RaiseView: View {
    @ObservedObject var session: RaiseSession

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.053, blue: 0.057).ignoresSafeArea()
            VStack(spacing: 28) {
                if let trial = session.trial, let kind = session.current {
                    Text("\(trial + 1) of \(RaiseSession.trials.count)").font(KinesisType.micro).foregroundStyle(.white.opacity(0.5))
                    Text(kind.word).font(.system(size: 72, weight: .medium)).tracking(-1.5)
                        .foregroundStyle(session.lit ? (kind == .rest ? .white : KinesisStyle.accent) : .white.opacity(0.25))
                        .animation(.easeOut(duration: 0.08), value: session.lit)
                } else {
                    Text(session.done ? "raises saved" : "finger raises").font(KinesisType.title).tracking(-1.2).foregroundStyle(.white)
                    Text("rest your hand like on a trackpad. when a word lights up, raise that finger high and put it back. on rest, do nothing.")
                        .font(KinesisType.body).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).frame(maxWidth: 560)
                    Text(session.done ? "space to record again · esc to close" : "about 3 minutes. space to start · esc to close")
                        .font(KinesisType.caption).foregroundStyle(.white.opacity(0.45))
                }
                if let problem = session.problem {
                    Text(problem).font(KinesisType.caption).foregroundStyle(KinesisStyle.warning)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
