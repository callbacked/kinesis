#if KINESIS_LAB
import AppKit
import SwiftUI

// A developer tool, only in builds made with KINESIS_LAB=1: a full-screen practice
// field for the air cursor. Each run saves the band's motion, every pointer event,
// and every trial to its own folder, so a run can be read and replayed later with
// scripts/pointer-lab.sh.

/// The window that holds the practice field, over the display under the pointer.
@MainActor final class PracticeWindow {
    static let shared = PracticeWindow()
    private var window: NSWindow?
    private var monitor: Any?
    private var session: PracticeSession?

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kinesis/Lab", isDirectory: true)
    }

    func open(model: BandModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let session = PracticeSession(model: model) { [weak self] in self?.close() }
        let window = PracticeNSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.contentView = NSHostingView(rootView: PracticeView(session: session))
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let types: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                            .rightMouseDown, .rightMouseUp, .rightMouseDragged, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: types) { [weak window, weak session] event in
            guard let window, event.window === window, let session else { return event }
            if event.type == .keyDown {
                // Escape ends a run, or closes the lab between runs.
                if event.keyCode == 53 { session.escape() }
                return event
            }
            let height = window.contentView?.bounds.height ?? window.frame.height
            session.receive(event, at: CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y))
            return event
        }
        self.window = window
        self.session = session
    }

    func close() {
        session?.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.orderOut(nil)
        window = nil
        session = nil
    }
}

/// A borderless window that still takes clicks and keys.
private final class PracticeNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Fixed seeds, so every run of a mode shows the same targets and runs compare.
struct PracticeRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func unit() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

@MainActor final class PracticeSession: ObservableObject {
    enum Mode: String, CaseIterable, Codable {
        case targets, moving, drag

        var trials: Int {
            switch self {
            case .targets: 24
            case .moving: 15
            case .drag: 10
            }
        }

        var about: String {
            switch self {
            case .targets: "click each circle as it appears. they come in three sizes and three distances."
            case .moving: "click each circle while it moves, like a shooting game."
            case .drag: "pinch the dot, hold, and drop it inside the ring."
            }
        }

        /// How long a trial waits before it counts as a miss.
        var timeout: Double {
            switch self {
            case .targets: 10
            case .moving: 6
            case .drag: 15
            }
        }
    }

    enum Phase: Equatable { case idle, countdown(Int), running, done }

    /// A circle to click, or for a drag, the ring to drop into.
    struct Target {
        var start: CGPoint
        var velocity: CGVector
        var radius: Double
        var spawnedAt: Double
        var area: CGRect

        /// Where it is at a moment. A moving target bounces off the field's edges.
        func center(at time: Double) -> CGPoint {
            let elapsed = max(0, time - spawnedAt)
            func bounce(_ start: Double, _ speed: Double, _ low: Double, _ high: Double) -> Double {
                let span = high - low
                guard span > 0 else { return low }
                var travelled = (start - low + speed * elapsed).truncatingRemainder(dividingBy: 2 * span)
                if travelled < 0 { travelled += 2 * span }
                return low + (travelled <= span ? travelled : 2 * span - travelled)
            }
            return CGPoint(x: bounce(start.x, velocity.dx, area.minX + radius, area.maxX - radius),
                           y: bounce(start.y, velocity.dy, area.minY + radius, area.maxY - radius))
        }
    }

    /// One attempt, as saved to trials.jsonl.
    struct Trial: Codable {
        var mode: Mode
        var index: Int
        var spawnedAt: Double
        var endedAt: Double
        var seconds: Double
        /// The pointer when the target appeared.
        var from: CGPoint
        /// The target's center at the end: the click for targets, the drop for a drag.
        var target: CGPoint
        var radius: Double
        var hit: Bool
        var timedOut: Bool
        /// Where the click or the drop landed, and how far from the center.
        var point: CGPoint?
        var error: Double?
        var button: String?
        /// How far the pointer went, against the straight line to the target.
        var pathLength: Double
        var distance: Double
        /// For a drag: how far from the dot's center the pinch grabbed, and how many pinches it took.
        var grabError: Double?
        var attempts: Int?
    }

    struct Summary: Codable {
        var mode: Mode
        var startedAt: String
        var trials: Int
        var hits: Int
        var medianSeconds: Double?
        var medianError: Double?
        /// Straight distance over the pointer's path: 1 is a perfectly straight move.
        var medianStraightness: Double?
        /// Points per degree of arm turn, and the top acceleration factor.
        var speed: Double
        var flickBoost: Double
        var steadiness: Double
        var hand: String
        var reach: PointerReach
        /// False when the run used the default reach, which is what the defaults are tuned on.
        var calibrated: Bool
        var display: CGSize
        var refreshRate: Int
    }

    @Published var mode: Mode = .targets
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var target: Target?
    /// For a drag: where the dot is.
    @Published private(set) var dot: CGPoint?
    @Published private(set) var trials: [Trial] = []
    @Published private(set) var summary: Summary?
    @Published private(set) var folder: URL?
    @Published private(set) var problem: String?
    var bounds = CGSize(width: 1440, height: 900)

    private let model: BandModel
    private let onClose: () -> Void
    private var random = PracticeRandom(seed: 1)
    private var pointer = CGPoint.zero
    private var trialPath: [CGPoint] = []
    private var trialFrom = CGPoint.zero
    private var grabbed: CGVector?
    private var grabError: Double?
    private var attempts = 0
    private var events: FileHandle?
    private var started = Date()
    private var timeout: Task<Void, Never>?
    private var countdown: Task<Void, Never>?

    init(model: BandModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    var trialText: String { "\(min(trials.count + 1, mode.trials)) of \(mode.trials)" }

    /// The field targets appear in, clear of the edges and the top line of text.
    private var area: CGRect { CGRect(x: 60, y: 110, width: bounds.width - 120, height: bounds.height - 170) }

    func start() {
        problem = nil
        trials = []
        summary = nil
        random = PracticeRandom(seed: UInt64(Mode.allCases.firstIndex(of: mode)! + 1))
        started = Date()
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let folder = PracticeWindow.folder.appendingPathComponent("\(stamp)-\(mode.rawValue)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let events = folder.appendingPathComponent("pointer.jsonl")
            FileManager.default.createFile(atPath: events.path, contents: nil)
            self.events = try FileHandle(forWritingTo: events)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("trials.jsonl").path, contents: nil)
        } catch {
            problem = "couldn’t save the run: \(error.localizedDescription)"
            return
        }
        self.folder = folder
        model.setMotionLog(path: folder.appendingPathComponent("motion.jsonl").path)
        if !model.airCursorEnabled && model.canUseAirCursor { model.setAirCursorEnabled(true) }
        countdown = Task { [weak self] in
            for count in [3, 2, 1] {
                self?.phase = .countdown(count)
                try? await Task.sleep(for: .milliseconds(700))
                if Task.isCancelled { return }
            }
            self?.phase = .running
            self?.nextTrial()
        }
    }

    func escape() {
        if phase == .idle || phase == .done { onClose() } else { finish() }
    }

    /// Ends a run early or on close, and saves what it has.
    func stop() {
        if phase != .idle && phase != .done { finish() }
    }

    func close() { onClose() }

    /// Back to the menu to pick another mode.
    func reset() {
        phase = .idle
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func nextTrial() {
        guard trials.count < mode.trials else { return finish() }
        let time = now()
        trialFrom = pointer
        trialPath = [pointer]
        grabbed = nil
        grabError = nil
        attempts = 0
        let index = trials.count
        switch mode {
        case .targets:
            let radius = [40.0, 24, 14][index % 3]
            let reach = [350.0, 800, 1300][(index / 3) % 3]
            target = Target(start: place(awayFrom: pointer, by: reach, radius: radius), velocity: .zero, radius: radius, spawnedAt: time, area: area)
        case .moving:
            let speed = [180.0, 280, 400][index % 3]
            let angle = random.unit() * 2 * .pi
            let radius = 32.0
            let start = CGPoint(x: area.minX + radius + random.unit() * (area.width - 2 * radius),
                                y: area.minY + radius + random.unit() * (area.height - 2 * radius))
            target = Target(start: start, velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed), radius: radius, spawnedAt: time, area: area)
        case .drag:
            let start = place(awayFrom: pointer, by: 300, radius: 18)
            dot = start
            let ring = place(awayFrom: start, by: [400.0, 800, 1100][index % 3], radius: 44)
            target = Target(start: ring, velocity: .zero, radius: 44, spawnedAt: time, area: area)
        }
        timeout?.cancel()
        let limit = mode.timeout
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, let self, self.phase == .running else { return }
            self.record(hit: false, timedOut: true, point: nil, button: nil, at: self.now())
        }
    }

    /// A point `distance` from `origin` in a random direction, inside the field.
    private func place(awayFrom origin: CGPoint, by distance: Double, radius: Double) -> CGPoint {
        let field = area.insetBy(dx: radius, dy: radius)
        for _ in 0..<40 {
            let angle = random.unit() * 2 * .pi
            let point = CGPoint(x: origin.x + cos(angle) * distance, y: origin.y + sin(angle) * distance)
            if field.contains(point) { return point }
        }
        return CGPoint(x: field.minX + random.unit() * field.width, y: field.minY + random.unit() * field.height)
    }

    func receive(_ event: NSEvent, at point: CGPoint) {
        pointer = point
        write(event, at: point)
        guard phase == .running, let target else { return }
        trialPath.append(point)
        let time = event.timestamp
        switch (mode, event.type) {
        case (.targets, .leftMouseDown), (.targets, .rightMouseDown), (.moving, .leftMouseDown), (.moving, .rightMouseDown):
            let center = target.center(at: time)
            let hit = hypot(point.x - center.x, point.y - center.y) <= target.radius
            record(hit: hit, timedOut: false, point: point, button: event.type == .leftMouseDown ? "left" : "right", at: time)
        case (.drag, .leftMouseDown):
            attempts += 1
            guard let dot, hypot(point.x - dot.x, point.y - dot.y) <= 34 else { return }
            grabbed = CGVector(dx: dot.x - point.x, dy: dot.y - point.y)
            if grabError == nil { grabError = hypot(point.x - dot.x, point.y - dot.y) }
        case (.drag, .leftMouseDragged):
            if let grabbed { dot = CGPoint(x: point.x + grabbed.dx, y: point.y + grabbed.dy) }
        case (.drag, .leftMouseUp):
            guard grabbed != nil, let dot else { return }
            grabbed = nil
            let ring = target.center(at: time)
            if hypot(dot.x - ring.x, dot.y - ring.y) <= target.radius - 8 {
                record(hit: true, timedOut: false, point: dot, button: "left", at: time)
            }
        default:
            break
        }
    }

    private func record(hit: Bool, timedOut: Bool, point: CGPoint?, button: String?, at time: Double) {
        guard let target else { return }
        timeout?.cancel()
        let center = target.center(at: time)
        let path = zip(trialPath, trialPath.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.reduce(0, +)
        let startCenter = mode == .drag ? (dot ?? center) : target.center(at: target.spawnedAt)
        let trial = Trial(mode: mode, index: trials.count, spawnedAt: target.spawnedAt, endedAt: time, seconds: time - target.spawnedAt,
                          from: trialFrom, target: center, radius: target.radius, hit: hit, timedOut: timedOut, point: point,
                          error: point.map { hypot($0.x - center.x, $0.y - center.y) }, button: button, pathLength: path,
                          distance: hypot(startCenter.x - trialFrom.x, startCenter.y - trialFrom.y),
                          grabError: mode == .drag ? grabError : nil, attempts: mode == .drag ? attempts : nil)
        trials.append(trial)
        if let folder, let line = try? JSONEncoder().encode(trial),
           let handle = try? FileHandle(forWritingTo: folder.appendingPathComponent("trials.jsonl")) {
            handle.seekToEndOfFile()
            handle.write(line + Data([0x0a]))
            try? handle.close()
        }
        self.target = nil
        dot = nil
        nextTrial()
    }

    private func write(_ event: NSEvent, at point: CGPoint) {
        guard let events, phase != .idle else { return }
        let kind = switch event.type {
        case .mouseMoved: "move"
        case .leftMouseDown, .rightMouseDown: "down"
        case .leftMouseUp, .rightMouseUp: "up"
        default: "drag"
        }
        let button = [.rightMouseDown, .rightMouseUp, .rightMouseDragged].contains(event.type) ? "right" : "left"
        let line = String(format: "{\"t\":%.5f,\"x\":%.2f,\"y\":%.2f,\"type\":\"%@\",\"button\":\"%@\"}\n",
                          event.timestamp, point.x, point.y, kind, button)
        events.write(Data(line.utf8))
    }

    private func finish() {
        countdown?.cancel()
        timeout?.cancel()
        target = nil
        dot = nil
        model.setMotionLog(path: nil)
        try? events?.close()
        events = nil
        phase = .done
        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            return values.sorted()[values.count / 2]
        }
        let summary = Summary(
            mode: mode, startedAt: started.formatted(.iso8601), trials: trials.count, hits: trials.filter(\.hit).count,
            medianSeconds: median(trials.filter(\.hit).map(\.seconds)),
            medianError: median(trials.compactMap(\.error)),
            medianStraightness: median(trials.filter { $0.hit && $0.pathLength > 0 }.map { min(1, $0.distance / $0.pathLength) }),
            speed: model.cursorSpeed, flickBoost: model.cursorFlickBoost, steadiness: model.cursorSteadiness, hand: "\(model.bandHand)",
            reach: model.pointerReach, calibrated: model.pointerCalibrated, display: bounds,
            refreshRate: NSScreen.main?.maximumFramesPerSecond ?? 0)
        self.summary = summary
        if let folder {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(summary).write(to: folder.appendingPathComponent("summary.json"))
        }
    }
}

struct PracticeView: View {
    @ObservedObject var session: PracticeSession

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.05, green: 0.053, blue: 0.057).ignoresSafeArea()
                switch session.phase {
                case .idle: menu
                case .countdown(let count):
                    Text("\(count)").font(.system(size: 96, weight: .light)).foregroundStyle(.white.opacity(0.8))
                case .running: field
                case .done: results
                }
            }
            .onAppear { session.bounds = geometry.size }
            .onChange(of: geometry.size) { _, size in session.bounds = size }
        }
        .preferredColorScheme(.dark)
    }

    private var field: some View {
        TimelineView(.animation) { _ in
            let time = ProcessInfo.processInfo.systemUptime
            ZStack {
                if let target = session.target {
                    let center = target.center(at: time)
                    if session.mode == .drag {
                        Circle().stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                            .frame(width: target.radius * 2, height: target.radius * 2).position(center)
                    } else {
                        Circle().fill(KinesisStyle.accent.opacity(0.85))
                            .frame(width: target.radius * 2, height: target.radius * 2).position(center)
                    }
                }
                if let dot = session.dot {
                    Circle().fill(KinesisStyle.accent).frame(width: 36, height: 36).position(dot)
                }
                VStack(spacing: 4) {
                    Text("\(session.mode.rawValue) · \(session.trialText)").font(KinesisType.label).foregroundStyle(.white.opacity(0.7))
                    Text("esc ends the run").font(KinesisType.micro).foregroundStyle(.white.opacity(0.4))
                }
                .position(x: session.bounds.width / 2, y: 50)
            }
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("lab").font(KinesisType.title).tracking(-1.2)
            Text("practice with the air cursor. each run is saved for review.")
                .font(KinesisType.body).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 10) {
                ForEach(PracticeSession.Mode.allCases, id: \.self) { mode in
                    Button(mode.rawValue) { session.mode = mode }
                        .buttonStyle(KinesisButtonStyle(prominent: session.mode == mode))
                }
            }
            Text(session.mode.about).font(KinesisType.body).foregroundStyle(.white.opacity(0.8))
            if let problem = session.problem {
                Text(problem).font(KinesisType.caption).foregroundStyle(KinesisStyle.warning)
            }
            HStack(spacing: 14) {
                Button("start") { session.start() }.buttonStyle(KinesisButtonStyle(prominent: true))
                Button("close") { session.close() }.buttonStyle(.plain)
                    .font(KinesisType.caption).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 460, alignment: .leading)
        .padding(36)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("run saved").font(KinesisType.title).tracking(-1.2)
            if let summary = session.summary {
                VStack(alignment: .leading, spacing: 8) {
                    line("hits", "\(summary.hits) of \(summary.trials)")
                    if let seconds = summary.medianSeconds { line("typical time", String(format: "%.2f s", seconds)) }
                    if let error = summary.medianError { line("typical miss from center", String(format: "%.0f pt", error)) }
                    if let straightness = summary.medianStraightness { line("path straightness", String(format: "%.0f%%", straightness * 100)) }
                }
            }
            if let folder = session.folder {
                Text(folder.path).font(KinesisType.micro).foregroundStyle(.white.opacity(0.45)).textSelection(.enabled)
            }
            HStack(spacing: 14) {
                Button("again") { session.start() }.buttonStyle(KinesisButtonStyle(prominent: true))
                Button("other modes") { session.reset() }.buttonStyle(KinesisButtonStyle())
                Button("close") { session.close() }.buttonStyle(.plain)
                    .font(KinesisType.caption).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 460, alignment: .leading)
        .padding(36)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(KinesisType.body)
    }
}
#endif
