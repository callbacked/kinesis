import Foundation

struct PinchDial {
    /// A tap is over in well under this. Only a pinch that outlasts it is a hold, so
    /// neither press of a double tap arms the dial.
    static let armDelay = 0.18

    private(set) var engaged = false
    private var pressedAt: [String: Double] = [:]
    /// A press can only become a pinch if motion was already flowing when it began.
    private var indexCanArm = false
    private var lastGyroAt: Double?
    private var lastDeviceTime: UInt64?
    private var bias = SIMD3<Double>.zero
    private var integral = SIMD3<Double>.zero
    private var axis: Int?

    mutating func tick(now: Double) {
        if let lastGyroAt, now - lastGyroAt >= 0.35 {
            pressedAt.removeAll()
            release()
        }
        for (finger, time) in pressedAt where now - time >= 10 {
            pressedAt.removeValue(forKey: finger)
            if finger == "index" { release() }
        }
        if !engaged, indexCanArm, let pressed = pressedAt["index"], now - pressed >= Self.armDelay,
           let lastGyroAt, now - lastGyroAt < 0.35 {
            release()
            engaged = true
        }
    }

    mutating func gesture(_ gesture: BandGesture, now: Double) {
        tick(now: now)
        guard !gesture.synthetic, ["index", "middle"].contains(gesture.finger) else { return }
        let finger = gesture.finger
        let press = gesture.action == "press" || gesture.derivedAction == "buttonPress"
        let released = gesture.action == "release" || ["buttonRelease", "buttonHoldRelease"].contains(gesture.derivedAction)
        if press, pressedAt[finger] == nil {
            pressedAt[finger] = now
            if finger == "index" { indexCanArm = lastGyroAt.map { now - $0 < 0.35 } ?? false }
        }
        if released {
            pressedAt.removeValue(forKey: finger)
            if finger == "index" {
                indexCanArm = false
                release()
            }
        }
    }

    mutating func gyro(timestamp: UInt64, values: SIMD3<Double>, now: Double) -> Double? {
        tick(now: now)
        let previous = lastDeviceTime
        lastDeviceTime = timestamp
        lastGyroAt = now
        guard let previous, timestamp > previous, timestamp - previous <= 50_000 else {
            if engaged {
                pressedAt.removeValue(forKey: "index")
                release()
            }
            return nil
        }
        let dt = Double(timestamp - previous) / 1e6
        if pressedAt.isEmpty, (0..<3).allSatisfy({ abs(values[$0] - bias[$0]) < 45 }) {
            bias += (values - bias) * (1 - exp(-dt / 2))
        }
        // Observed 0.07 gyro scale; this remains a relative, experimental estimate.
        let delta = (values - bias) * (0.07 * dt)
        guard engaged else { return nil }
        integral += delta
        if axis == nil, let dominant = (0..<3).max(by: { abs(integral[$0]) < abs(integral[$1]) }), abs(integral[dominant]) >= 0.25 {
            axis = dominant
            return integral[dominant]
        }
        return axis.map { delta[$0] }
    }

    private mutating func release() {
        engaged = false
        integral = .zero
        axis = nil
    }
}
