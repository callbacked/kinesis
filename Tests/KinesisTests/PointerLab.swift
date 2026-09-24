import AppKit
import Foundation
import KinesisCore
import simd
import Testing
@testable import Kinesis

// A developer tool, never part of the app: it replays arm movement through the real
// air cursor, one display frame at a time, and measures how the pointer moves.
// It runs only when KINESIS_LAB_INPUT is set. See scripts/pointer-lab.sh.
//
//   KINESIS_LAB_INPUT    a motion log from KINESIS_MOTION_LOG, or "scenarios"
//   KINESIS_LAB_OUT      where to write frames and presses (default: .build/pointer-lab)
//   KINESIS_LAB_REFRESH  display rates in Hz, or "vrr" for 48 to 144 Hz frame to frame (default: 100)
//   KINESIS_LAB_PACING   playback delays in seconds to compare, 0 for none (default: the app's)
//   KINESIS_LAB_DISPLAY  display size in points (default: 3440x1440)
//   KINESIS_LAB_WINDOW   seconds of the log to replay, as "from-to" (default: all)

private let environment = ProcessInfo.processInfo.environment

@Test(.enabled(if: environment["KINESIS_LAB_INPUT"] != nil))
@MainActor func pointerLab() throws {
    let input = environment["KINESIS_LAB_INPUT"]!
    let out = URL(fileURLWithPath: environment["KINESIS_LAB_OUT"] ?? ".build/pointer-lab")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let refreshes = (environment["KINESIS_LAB_REFRESH"] ?? "100").split(separator: ",").map(String.init)
    let pacings = (environment["KINESIS_LAB_PACING"] ?? "\(PointerPacer.playbackSeconds)").split(separator: ",").compactMap { Double($0) }
    let size = (environment["KINESIS_LAB_DISPLAY"] ?? "3440x1440").split(separator: "x").compactMap { Double($0) }
    let display = CGSize(width: size.first ?? 3440, height: size.last ?? 1440)
    let window = environment["KINESIS_LAB_WINDOW"].map { $0.split(separator: "-").compactMap { Double($0) } }

    let recordings: [(name: String, events: [LabEvent])] = input == "scenarios"
        ? LabScenario.all.map { ($0.name, $0.events()) }
        : [(URL(fileURLWithPath: input).deletingPathExtension().lastPathComponent, try LabEvent.load(input, window: window))]

    var summary: [String] = []
    print(LabReport.header)
    for recording in recordings {
        for refresh in refreshes {
            let baseline = LabRun(events: recording.events, refresh: refresh, pacing: 0, display: display).replay()
            for pacing in pacings {
                let report = pacing == 0 ? baseline : LabRun(events: recording.events, refresh: refresh, pacing: pacing, display: display).replay()
                let name = "\(recording.name)-\(refresh)hz-\(Int(pacing * 1000))ms"
                try report.frameTable.write(to: out.appendingPathComponent("\(name).frames.csv"), atomically: true, encoding: .utf8)
                try report.pressTable.write(to: out.appendingPathComponent("\(name).presses.csv"), atomically: true, encoding: .utf8)
                let line = report.line(recording: recording.name, refresh: refresh, pacing: pacing, lag: report.lag(behind: baseline))
                print(line)
                summary.append(line)
            }
        }
    }
    try ([LabReport.header] + summary).joined(separator: "\n").appending("\n")
        .write(to: out.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
    print("wrote \(out.path)")
}

/// One event as the band sent it and the Mac received it.
struct LabEvent {
    enum Kind { case gyro(SIMD3<Double>), orientation(SIMD4<Double>), gesture(finger: String, action: String, derived: String) }
    var at: Double
    var stamp: UInt64
    var kind: Kind

    static func load(_ path: String, window: [Double]?) throws -> [LabEvent] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var events: [LabEvent] = []
        for line in text.split(separator: "\n") {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let at = row["at"] as? Double, let stamp = (row["t"] as? NSNumber)?.uint64Value,
                  let event = row["event"] as? String else { continue }
            let values = (row["v"] as? [Double]) ?? []
            switch event {
            case "gyro" where values.count == 3: events.append(LabEvent(at: at, stamp: stamp, kind: .gyro(SIMD3(values[0], values[1], values[2]))))
            case "quat" where values.count == 4: events.append(LabEvent(at: at, stamp: stamp, kind: .orientation(SIMD4(values[0], values[1], values[2], values[3]))))
            case "gesture":
                events.append(LabEvent(at: at, stamp: stamp, kind: .gesture(finger: row["finger"] as? String ?? "", action: row["action"] as? String ?? "",
                                                                             derived: row["derived"] as? String ?? "unknown")))
            default: continue
            }
        }
        events.sort { $0.at < $1.at }
        guard let start = events.first?.at, let window, window.count == 2 else { return events }
        return events.filter { $0.at >= start + window[0] && $0.at <= start + window[1] }
    }
}

/// Scripted arm movement that arrives the way the band's radio link delivers it:
/// 128 Hz samples in batches every 15 ms, and now and then after 30 ms.
struct LabScenario: Sendable {
    var name: String
    /// Compass angle in degrees over time, and when pinches press and release.
    var seconds: Double
    var azimuth: @Sendable (Double) -> Double
    var presses: [Double] = []
    var releases: [Double] = []

    func events() -> [LabEvent] {
        var random = SplitMix(seed: 7)
        var samples: [LabEvent] = []
        let rate = 128.0
        let start = 1000.0
        for index in 0..<Int(seconds * rate) {
            let t = Double(index) / rate
            // A held arm sways a little, at 1 to 3 Hz.
            let sway = 0.08 * sin(2 * .pi * 1.7 * t) + 0.04 * sin(2 * .pi * 2.9 * t + 1)
            let aim = azimuth(t) + sway
            let turn = (azimuth(t + 1 / rate) - azimuth(t)) * rate + 0.08 * 2 * .pi * 1.7 * cos(2 * .pi * 1.7 * t)
            let stamp = UInt64(t * 1e6)
            samples.append(LabEvent(at: start + t, stamp: stamp, kind: .gyro(SIMD3(turn / AirPointer.gyroScale + random.noise(3), random.noise(3), random.noise(3)))))
            samples.append(LabEvent(at: start + t, stamp: stamp, kind: .orientation(bandQuaternion(azimuth: aim, elevation: 10))))
        }
        for (time, action) in presses.map({ ($0, "press") }) + releases.map({ ($0, "release") }) {
            samples.append(LabEvent(at: start + time, stamp: UInt64(time * 1e6), kind: .gesture(finger: "index", action: action, derived: "unknown")))
        }
        samples.sort { $0.at < $1.at }
        // The radio link: every sample waits for the next batch.
        var arrival = start
        var delivered: [LabEvent] = []
        for var sample in samples {
            while arrival < sample.at { arrival += random.unit() < 0.12 ? 0.030 : 0.015 }
            sample.at = arrival
            delivered.append(sample)
        }
        return delivered
    }

    /// Moves from `from` to `to` degrees over `seconds`, easing in and out like a reach.
    static func reach(_ t: Double, start: Double, seconds: Double, from: Double, to: Double) -> Double {
        let x = max(0, min(1, (t - start) / seconds))
        return from + (to - from) * x * x * (3 - 2 * x)
    }

    static let all: [LabScenario] = [
        // Steady sweeps at a slow, a medium, and a quick pace: shows choppiness.
        LabScenario(name: "sweeps", seconds: 7) { t in
            if t < 0.5 { return 0 }
            if t < 2.5 { return (t - 0.5) * 5 }
            if t < 3 { return 10 }
            if t < 4 { return 10 - (t - 3) * 15 }
            if t < 4.5 { return -5 }
            return -5 + (t - 4.5) * 1.5
        },
        // Slow aiming onto a target, the pinch's small nudge, then the press.
        LabScenario(name: "aim-click", seconds: 2.5, azimuth: { t in
            if t < 0.5 { return 0 }
            if t < 1.3 { return (t - 0.5) * 1.5 }
            if t < 1.45 { return 1.2 + (t - 1.3) * 2 }
            return 1.5
        }, presses: [1.45], releases: [1.75]),
        // A quick reach that slows onto the target, pinched while still slowing.
        LabScenario(name: "settle-click", seconds: 2.5, azimuth: { t in reach(t, start: 0.5, seconds: 0.7, from: 0, to: 12) },
                    presses: [1.22], releases: [1.45]),
        // Following something that moves, and pinching on the way.
        LabScenario(name: "track-click", seconds: 2.5, azimuth: { t in t < 0.5 ? 0 : (t - 0.5) * 12 },
                    presses: [1.4], releases: [1.6]),
        // Pinch, drag, let go.
        LabScenario(name: "drag", seconds: 2.5, azimuth: { t in reach(t, start: 0.8, seconds: 0.8, from: 0, to: 8) },
                    presses: [0.6], releases: [1.9]),
    ]
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func noise(_ amount: Double) -> Double { (unit() * 2 - 1) * amount }
}

/// Pointer controls that remember when everything happened.
@MainActor final class LabControls: MacControls {
    let clock: () -> Double
    let displaySize: CGSize
    var location: CGPoint
    var inFrame = false
    var frames: [(time: Double, point: CGPoint)] = []
    /// Moves posted between frames: before a press, all at once.
    var offFrameMoves: [(time: Double, from: CGPoint, to: CGPoint)] = []
    var presses: [(time: Double, before: CGPoint, point: CGPoint)] = []
    var releases: [Double] = []

    init(display: CGSize, clock: @escaping () -> Double) {
        displaySize = display
        location = CGPoint(x: display.width / 2, y: display.height / 2)
        self.clock = clock
    }

    var trusted: Bool { true }
    var cursorLocation: CGPoint? { location }
    func requestAccess() {}
    func post(_ action: MacAction) throws {}
    func moveCursor(to point: CGPoint, dragging button: CGMouseButton?) throws -> CGPoint {
        let clamped = CGPoint(x: max(0, min(displaySize.width - 1, point.x)), y: max(0, min(displaySize.height - 1, point.y)))
        if !inFrame { offFrameMoves.append((clock(), location, clamped)) }
        location = clamped
        return clamped
    }
    func mouseButton(_ button: CGMouseButton, down: Bool, clicks: Int, at point: CGPoint?) throws {
        if down { presses.append((clock(), location, point ?? location)) } else { releases.append(clock()) }
        if let point { location = point }
    }
}

@MainActor final class LabClock { var now = 0.0 }

struct LabRun {
    var events: [LabEvent]
    var refresh: String
    var pacing: Double
    var display: CGSize

    @MainActor func replay() -> LabReport {
        let clock = LabClock()
        clock.now = events.first?.at ?? 0
        let controls = LabControls(display: display) { clock.now }
        let connection = RecordedConnection()
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: "setupCompleted")
        let model = BandModel(defaults: defaults, connection: connection, controls: controls, sessionStore: SavedSessionStore(),
                              clock: { clock.now }, cursorPacing: pacing, cursorFrames: .manual)
        model.selectedAddress = "lab-band"
        model.developerMode = true
        model.connect()
        connection.send(.connected, at: clock.now)
        connection.send(.heartbeat, at: clock.now)
        connection.send(.handedness(.right), at: clock.now)
        model.toggleControls()

        var random = SplitMix(seed: 11)
        func frameLength() -> Double {
            if refresh == "vrr" { return 1 / (48 + random.unit() * 96) }
            return 1 / (Double(refresh) ?? 100)
        }
        var nextFrame = clock.now + frameLength()
        var armSpeed = 0.0
        var lastGyro: Double?
        var speeds: [(time: Double, speed: Double)] = []
        var aims: [(time: Double, azimuth: Double)] = []
        var approaches: [AirPointer.Approach] = []
        var sequence: UInt64 = 0
        for event in events {
            while nextFrame <= event.at {
                clock.now = nextFrame
                if !model.airCursorEnabled && model.canUseAirCursor { model.setAirCursorEnabled(true) }
                controls.inFrame = true
                model.cursorFrame()
                controls.inFrame = false
                controls.frames.append((clock.now, controls.location))
                nextFrame += frameLength()
            }
            clock.now = event.at
            switch event.kind {
            case .gyro(let raw):
                connection.send(.gyro(timestamp: event.stamp, values: raw), at: event.at)
                let dt = lastGyro.map { event.at - $0 } ?? 0
                lastGyro = event.at
                let rate = hypot(raw.x, raw.z) * AirPointer.gyroScale
                armSpeed += (rate - armSpeed) * (dt > 0 ? 1 - exp(-dt / 0.1) : 0)
                speeds.append((event.at, armSpeed))
            case .orientation(let q):
                connection.send(.orientation(timestamp: event.stamp, values: q), at: event.at)
                if let aim = ForearmAim(quaternion: q) {
                    let previous = aims.last?.azimuth ?? aim.azimuth
                    aims.append((event.at, previous + remainder(aim.azimuth - previous, 360)))
                }
            case .gesture(let finger, let action, let derived):
                if action == "press" { approaches.append(model.airPointer.approach) }
                sequence += 1
                connection.send(.gesture(BandGesture(sequence: sequence, timestampUs: event.stamp, finger: finger, action: action,
                                                     derivedAction: derived, receivedAt: event.at)), at: event.at)
            }
        }
        return LabReport(frames: controls.frames, offFrameMoves: controls.offFrameMoves, presses: controls.presses,
                         releases: controls.releases, speeds: speeds, aims: aims, approaches: approaches)
    }
}

struct LabReport {
    var frames: [(time: Double, point: CGPoint)]
    var offFrameMoves: [(time: Double, from: CGPoint, to: CGPoint)]
    var presses: [(time: Double, before: CGPoint, point: CGPoint)]
    var releases: [Double]
    var speeds: [(time: Double, speed: Double)]
    var aims: [(time: Double, azimuth: Double)]
    /// How the arm moved at each pinch, as the model judged it.
    var approaches: [AirPointer.Approach]

    /// The lag is against the same refresh rate with no playback delay.
    static let header = "recording        refresh pacing  moving  uneven p50/p90  stalls  +lag   presses  jump p50/p90/max pt  after p50/p90/max pt"

    /// How much later this run's pointer moves than another run's of the same input,
    /// in milliseconds: the delay that best lines up the two paths.
    func lag(behind baseline: LabReport) -> Double? {
        guard frames.count > 10, baseline.frames.count > 10 else { return nil }
        let grid = 0.001
        /// Where a path is at each of these rising times.
        func positions(_ frames: [(time: Double, point: CGPoint)], at times: [Double]) -> [CGPoint] {
            var index = 0
            return times.map { t in
                while index + 1 < frames.count && frames[index + 1].time <= t { index += 1 }
                return frames[index].point
            }
        }
        let start = max(frames.first!.time, baseline.frames.first!.time)
        let end = min(frames.last!.time, baseline.frames.last!.time) - 0.1
        guard end > start else { return nil }
        let times = stride(from: start, to: end, by: 0.004).map { $0 }
        let reference = positions(baseline.frames, at: times)
        var best = (shift: 0, error: Double.infinity)
        for shift in 0...80 {
            let mine = positions(frames, at: times.map { $0 + Double(shift) * grid })
            var error = 0.0
            for (p, point) in zip(mine, reference) { error += hypot(Double(p.x - point.x), Double(p.y - point.y)) }
            if error < best.error { best = (shift, error) }
        }
        return Double(best.shift) * grid * 1000
    }

    /// How fast each frame moved the pointer, in points a second, so frames of
    /// different lengths compare.
    var frameSpeeds: [Double] {
        zip(frames, frames.dropFirst()).map { (a, b) -> Double in
            let distance = hypot(Double(b.point.x - a.point.x), Double(b.point.y - a.point.y))
            return distance / max(1e-4, b.time - a.time)
        }
    }

    /// While the pointer moves faster than 60 points a second, how far each frame's speed
    /// is from its neighbours' average. A smooth glide is near 0. A frame that moves
    /// twice as far as the next is 0.5 or more.
    var unevenness: (p50: Double, p90: Double, stalls: Double, moving: Int) {
        let steps = frameSpeeds
        guard steps.count > 5 else { return (0, 0, 0, 0) }
        var uneven: [Double] = []
        var stalls = 0
        for index in 2..<(steps.count - 2) {
            let local = steps[(index - 2)...(index + 2)].reduce(0, +) / 5
            guard local > 60 else { continue }
            uneven.append(abs(steps[index] - local) / local)
            if steps[index] < 0.25 * local { stalls += 1 }
        }
        guard !uneven.isEmpty else { return (0, 0, 0, 0) }
        return (percentile(uneven, 0.5), percentile(uneven, 0.9), Double(stalls) / Double(uneven.count), uneven.count)
    }

    /// For each press: how far the press moved the pointer (a jump), and how far the
    /// pointer strayed from the press point over the next 0.4 s.
    var pressStats: [(time: Double, jump: Double, flushed: Double, after: Double, armSpeed: Double)] {
        presses.map { press in
            let jump = hypot(press.point.x - press.before.x, press.point.y - press.before.y)
            let flushed = offFrameMoves.filter { $0.time == press.time }.map { hypot($0.to.x - $0.from.x, $0.to.y - $0.from.y) }.reduce(0, +)
            let after = frames.filter { $0.time > press.time && $0.time <= press.time + 0.4 }
                .map { hypot($0.point.x - press.point.x, $0.point.y - press.point.y) }.max() ?? 0
            let speed = speeds.last { $0.time <= press.time }?.speed ?? 0
            return (press.time, jump, flushed, after, speed)
        }
    }

    func line(recording: String, refresh: String, pacing: Double, lag: Double?) -> String {
        let u = unevenness
        let stats = pressStats
        let jumps = stats.map(\.jump)
        let after = stats.map(\.after)
        func triple(_ xs: [Double]) -> String {
            xs.isEmpty ? "-" : String(format: "%.1f/%.1f/%.1f", percentile(xs, 0.5), percentile(xs, 0.9), xs.max()!)
        }
        return recording.padding(toLength: 16, withPad: " ", startingAt: 0) + " "
            + String(format: "%-7@ %4.0fms  %6d  %5.2f/%5.2f  %5.1f%%  %4@  %7d  ", refresh as NSString, pacing * 1000, u.moving, u.p50, u.p90, u.stalls * 100,
                     (lag.map { String(format: "%.0fms", $0) } ?? "-") as NSString, stats.count)
            + triple(jumps).padding(toLength: 21, withPad: " ", startingAt: 0) + triple(after)
    }

    var frameTable: String {
        let start = frames.first?.time ?? 0
        return "t,x,y\n" + frames.map { String(format: "%.4f,%.2f,%.2f", $0.time - start, $0.point.x, $0.point.y) }.joined(separator: "\n") + "\n"
    }

    var pressTable: String {
        let start = frames.first?.time ?? 0
        return "t,jump,flushed,after,arm_speed,approach\n" + zip(pressStats, approaches.map { "\($0)" } + Array(repeating: "-", count: max(0, pressStats.count - approaches.count))).map {
            String(format: "%.4f,%.2f,%.2f,%.2f,%.2f,", $0.time - start, $0.jump, $0.flushed, $0.after, $0.armSpeed) + $1
        }.joined(separator: "\n") + "\n"
    }
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted[Int((Double(sorted.count - 1) * p).rounded())]
}
