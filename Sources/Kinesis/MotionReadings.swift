import Foundation
import SwiftUI

/// The motion side of the readings page: the last few seconds of gyro, and where
/// the forearm points. It takes every sample, and republishes at most 20 times a
/// second, so a 128 Hz stream never re-renders the page 128 times a second.
@MainActor final class MotionReadings: ObservableObject {
    struct Sample { let time: Double; let gyro: SIMD3<Double> }
    /// Seconds of gyro the graph shows.
    static let window = 3.0
    /// Observed scale, not a datasheet value: raw gyro counts to degrees per second.
    static let degreesPerSecondPerCount = 0.07

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var aim: ForearmAim?
    @Published private(set) var gyroRate = 0.0
    @Published private(set) var orientationRate = 0.0
    /// Seconds late, by the band's own clock.
    @Published private(set) var delay = 0.0
    private var latestDelay = 0.0

    private var pending: [Sample] = []
    private var latestAim: ForearmAim?
    private var lastPublish = -Double.infinity
    private var rateStart: Double?
    private var gyroCount = 0
    private var orientationCount = 0

    func receiveGyro(_ values: SIMD3<Double>, at time: Double) {
        guard (0..<3).allSatisfy({ values[$0].isFinite }) else { return }
        pending.append(Sample(time: time, gyro: values * Self.degreesPerSecondPerCount))
        gyroCount += 1
        publish(at: time)
    }

    func receiveAim(_ aim: ForearmAim, delay: Double, at time: Double) {
        latestAim = aim
        latestDelay = delay
        orientationCount += 1
        publish(at: time)
    }

    func reset() {
        samples = []
        pending = []
        aim = nil
        latestAim = nil
        gyroRate = 0
        orientationRate = 0
        delay = 0
        latestDelay = 0
        rateStart = nil
        gyroCount = 0
        orientationCount = 0
        lastPublish = -.infinity
    }

    private func publish(at time: Double) {
        let start = rateStart ?? time
        rateStart = start
        if time - start >= 1 {
            gyroRate = Double(gyroCount) / (time - start)
            orientationRate = Double(orientationCount) / (time - start)
            rateStart = time
            gyroCount = 0
            orientationCount = 0
        }
        guard time - lastPublish >= 0.05 else { return }
        lastPublish = time
        samples = (samples + pending).filter { time - $0.time <= Self.window }
        pending = []
        aim = latestAim
        delay = latestDelay
    }
}

/// Three gyro traces, and the forearm's compass angle and elevation.
struct MotionReadingsView: View {
    @ObservedObject var motion: MotionReadings
    let live: Bool

    private static let axes: [(String, Color)] = [("x", KinesisStyle.accent), ("y", KinesisStyle.ink.opacity(0.7)),
                                                  ("z", KinesisStyle.secondary.opacity(0.7))]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "motion")
                Spacer()
                ForEach(Self.axes, id: \.0) { axis in
                    HStack(spacing: 5) {
                        Capsule().fill(axis.1).frame(width: 10, height: 2)
                        Text(axis.0)
                    }
                }
            }.font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
            Canvas { context, size in
                let range = max(60, motion.samples.map { max(abs($0.gyro.x), abs($0.gyro.y), abs($0.gyro.z)) }.max() ?? 0) * 1.1
                let end = motion.samples.last?.time ?? 0
                var zero = Path()
                zero.move(to: CGPoint(x: 0, y: size.height / 2))
                zero.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(zero, with: .color(KinesisStyle.secondary.opacity(0.2)), lineWidth: 0.5)
                for (index, axis) in Self.axes.enumerated() {
                    var trace = Path()
                    var previous: Double?
                    for sample in motion.samples {
                        let point = CGPoint(x: (1 - (end - sample.time) / MotionReadings.window) * size.width,
                                            y: size.height / 2 * (1 - sample.gyro[index] / range))
                        // A gap in the stream breaks the line instead of bridging it.
                        if trace.isEmpty || (previous.map { sample.time - $0 > 0.1 } ?? true) { trace.move(to: point) }
                        else { trace.addLine(to: point) }
                        previous = sample.time
                    }
                    context.stroke(trace, with: .color(axis.1), lineWidth: 1)
                }
                context.draw(Text("±\(Int(range)) °/s").font(.system(size: 10)).foregroundStyle(KinesisStyle.secondary),
                             at: CGPoint(x: 0, y: 0), anchor: .topLeading)
            }
            .frame(height: 120)
            .overlay {
                if motion.samples.isEmpty {
                    Text(live ? "waiting for motion…" : "connect your band to see its motion.")
                        .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                }
            }
            .accessibilityLabel("Gyro traces for three axes, degrees per second.")
            HStack(spacing: 24) {
                Readout(symbol: "safari", value: motion.aim.map { String(format: "%.0f°", $0.azimuth) } ?? "–", label: "forearm compass")
                Readout(symbol: "arrow.up.right", value: motion.aim.map { String(format: "%.0f°", $0.elevation) } ?? "–", label: "forearm elevation")
                Readout(symbol: "waveform.path", value: String(format: "%.0f / %.0f", motion.gyroRate, motion.orientationRate), label: "gyro / orientation Hz")
                Readout(symbol: "hourglass", value: motion.delay < 1 ? String(format: "%.0f ms", motion.delay * 1000) : String(format: "%.1f s", motion.delay),
                        label: "arrival delay")
                Spacer(minLength: 0)
            }
            Text("gyro scale is observed, not calibrated. compass angle is relative: the band has no magnetometer, so only elevation is absolute.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
