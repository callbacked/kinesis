import CoreGraphics
import Foundation
import simd

/// Where the forearm points, from the band's orientation quaternion.
///
/// Measured on 2026-09-24 with guided holds (see docs/cursor-orientation.md):
/// the quaternion arrives as w, x, y, z, rotates the band's body frame into a
/// world frame whose +z is up (gravity), and the band's body +y runs along the
/// forearm toward the hand. So the forearm's direction in the world gives a
/// compass angle around gravity and an elevation above the horizon, and
/// twisting the wrist changes neither.
struct ForearmAim: Equatable {
    /// Degrees around gravity. Positive is counterclockwise seen from above, which is to the left.
    var azimuth: Double
    /// Degrees above the horizon.
    var elevation: Double

    static let forearmAxis = SIMD3<Double>(0, 1, 0)

    /// Nil for a value that is not a unit quaternion.
    init?(quaternion values: SIMD4<Double>, axis: SIMD3<Double> = forearmAxis) {
        guard (0..<4).allSatisfy({ values[$0].isFinite }),
              (0.9...1.1).contains(simd_length_squared(values)) else { return nil }
        let orientation = simd_normalize(simd_quatd(real: values.x, imag: SIMD3(values.y, values.z, values.w)))
        let forearm = simd_normalize(orientation.act(axis))
        azimuth = atan2(forearm.y, forearm.x) * 180 / .pi
        elevation = asin(max(-1, min(1, forearm.z))) * 180 / .pi
    }

    init(azimuth: Double, elevation: Double) {
        self.azimuth = azimuth
        self.elevation = elevation
    }
}

/// The 1€ filter (Casiez, Roussel, and Vogel, 2012): heavy smoothing when the
/// value is nearly still, so tremor disappears, and light smoothing when it
/// moves fast, so a real movement is not delayed.
struct OneEuroFilter {
    var minimumCutoff: Double
    var beta: Double
    var derivativeCutoff = 1.0
    private var value: Double?
    private var derivative = 0.0

    init(minimumCutoff: Double, beta: Double) {
        self.minimumCutoff = minimumCutoff
        self.beta = beta
    }

    private static func smoothing(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func filter(_ raw: Double, dt: Double) -> Double {
        guard let previous = value, dt > 0 else {
            value = raw
            derivative = 0
            return raw
        }
        derivative += (((raw - previous) / dt) - derivative) * Self.smoothing(derivativeCutoff, dt)
        let cutoff = minimumCutoff + beta * abs(derivative)
        let next = previous + (raw - previous) * Self.smoothing(cutoff, dt)
        value = next
        return next
    }

    mutating func reset() {
        value = nil
        derivative = 0
    }
}

/// Moves the pointer by how the forearm's aim changes, like a mouse, not by where
/// it points. The first real sessions showed why: a laser mapping ties every spot on
/// screen to one arm position, so the bottom of the screen meant hitting the desk,
/// every bit of sway moved the pointer, and one scale was both too coarse for small
/// targets and too slow for crossing the screen. Relative movement with acceleration
/// keeps the arm in a small, comfortable zone.
struct AirPointer {
    /// Near straight up or down the compass angle is meaningless, so it holds still there.
    static let steepElevation = 75.0
    /// A gap this long in the orientation stream drops the movement across it.
    static let maximumGap = 0.5

    private var azimuthFilter = OneEuroFilter(minimumCutoff: 1.5, beta: 0.05)
    private var elevationFilter = OneEuroFilter(minimumCutoff: 1.5, beta: 0.05)
    private var unwrappedAzimuth: Double?
    private var lastRawAzimuth = 0.0
    private var lastTime: Double?
    private var smoothed: SIMD2<Double>?
    private var held: SIMD2<Double>?
    /// Degrees per second of the aim, smoothed.
    private(set) var speed = 0.0
    private(set) var aim: ForearmAim?
    /// The aim when movement was last taken.
    private var taken: SIMD2<Double>?

    /// 0 is the most responsive and 1 the steadiest.
    var steadiness = 0.5 {
        didSet {
            let cutoff = 3.0 - 1.5 * max(0, min(1, steadiness))
            azimuthFilter.minimumCutoff = cutoff
            elevationFilter.minimumCutoff = cutoff
        }
    }

    /// The radius, in degrees, of the circle the aim must leave before the pointer moves.
    /// A held arm sways by about 0.2° typically and up to 1°, mostly 1 to 3 times a second
    /// (measured 2026-09-24). Sway that slow can't be filtered out without lag, so the
    /// pointer follows it on a rope instead: nothing moves inside the circle.
    var slack: Double { 0.1 + 0.9 * max(0, min(1, steadiness)) }
    /// Below this speed in degrees per second the rope has its full slack. Above
    /// `fastSpeed` it has none, so a quick move lands exactly where the arm points.
    /// Half of all aiming ran under 2°/s in the first real session, so the slack
    /// has to let go early or fine moves feel stuck.
    static let slowSpeed = 2.0
    static let fastSpeed = 20.0

    /// Takes one orientation sample. Returns false after a gap, whose movement is dropped.
    @discardableResult
    mutating func receive(_ sample: ForearmAim, at time: Double) -> Bool {
        let gap = lastTime.map { time - $0 } ?? .infinity
        guard gap > 0 else { return true }
        lastTime = time
        if gap > Self.maximumGap || unwrappedAzimuth == nil {
            azimuthFilter.reset()
            elevationFilter.reset()
            unwrappedAzimuth = sample.azimuth
            lastRawAzimuth = sample.azimuth
            let start = SIMD2(azimuthFilter.filter(sample.azimuth, dt: 0), elevationFilter.filter(sample.elevation, dt: 0))
            smoothed = start
            held = start
            speed = 0
            taken = start
            aim = ForearmAim(azimuth: start.x, elevation: start.y)
            return false
        }
        // Keep the compass angle continuous across ±180°, and freeze it where it is undefined.
        if abs(sample.elevation) < Self.steepElevation {
            unwrappedAzimuth! += remainder(sample.azimuth - lastRawAzimuth, 360)
        }
        lastRawAzimuth = sample.azimuth
        let current = SIMD2(azimuthFilter.filter(unwrappedAzimuth!, dt: gap), elevationFilter.filter(sample.elevation, dt: gap))
        if let smoothed {
            let instant = simd_length(current - smoothed) / gap
            speed += (instant - speed) * (1 - exp(-gap * 2 * .pi * 4))
        }
        smoothed = current
        let fraction = max(0, min(1, (Self.fastSpeed - speed) / (Self.fastSpeed - Self.slowSpeed)))
        let radius = slack * fraction
        var rope = held ?? current
        let offset = current - rope, distance = simd_length(offset)
        if distance > radius { rope += offset * ((distance - radius) / distance) }
        held = rope
        aim = ForearmAim(azimuth: rope.x, elevation: rope.y)
        return true
    }

    /// Degrees the aim moved since the last call: compass angle (positive is left)
    /// and elevation (positive is up). Nil until there is an aim.
    mutating func movement() -> SIMD2<Double>? {
        guard let aim else { return nil }
        let now = SIMD2(aim.azimuth, aim.elevation)
        defer { taken = now }
        return taken.map { now - $0 }
    }

    /// Drops any movement not yet taken, such as the twitch of a pinch.
    mutating func discard() {
        taken = aim.map { SIMD2($0.azimuth, $0.elevation) }
    }
}

/// Pointer acceleration: slow aiming moves the pointer a little, for precision, and a
/// quick flick moves it a lot, for distance. In the first real session half of all
/// aiming ran under 2°/s and the fastest 5 % over 40°/s.
enum PointerAcceleration {
    static let slowSpeed = 3.0
    static let fastSpeed = 40.0
    static let slowFactor = 0.35
    static let fastFactor = 2.0

    /// The multiplier on the calibrated scale at this speed in degrees per second.
    static func factor(speed: Double) -> Double {
        guard speed.isFinite else { return slowFactor }
        let x = max(0, min(1, (speed - slowSpeed) / (fastSpeed - slowSpeed)))
        let eased = x * x * (3 - 2 * x)
        return slowFactor + (fastFactor - slowFactor) * eased
    }
}

/// How late the band's data reaches the Mac, measured with the band's own clock.
///
/// Measured on 2026-09-24: on a congested link the band's samples arrived up to
/// 12 seconds late, in bursts, while the link itself stayed up. Host arrival time
/// cannot see that, because a late sample is still new to the Mac. The smallest
/// gap between host time and band time is the transit time of an on-time sample;
/// anything above it is delay. The baseline creeps up by at most 0.5 ms a second,
/// which covers drift between the two clocks without ever excusing real delay.
struct ArrivalDelay {
    private var baseline: Double?
    private var lastBand: Double?
    private var lastHost: Double?

    mutating func measure(band: Double, host: Double) -> Double {
        guard band.isFinite, host.isFinite else { return 0 }
        // The band's clock restarted, so the old baseline no longer applies.
        if let lastBand, band < lastBand - 1 { reset() }
        let offset = host - band
        if let previous = baseline, let lastHost {
            baseline = min(previous + max(0, host - lastHost) * 0.0005, offset)
        } else {
            baseline = offset
        }
        lastBand = band
        lastHost = host
        return max(0, offset - (baseline ?? offset))
    }

    mutating func reset() {
        baseline = nil
        lastBand = nil
        lastHost = nil
    }
}

/// How much forearm turn crosses the main display, left to right and top to bottom.
/// Stored in degrees, not points, so it survives a change of display.
struct PointerReach: Codable, Equatable {
    var degreesAcrossWidth: Double
    var degreesAcrossHeight: Double

    /// The typical result of four calibrations on 2026-09-24, in two poses: 64° to 73°
    /// across and 27° to 32° up and down. People reach less up and down than across.
    static let standard = PointerReach(degreesAcrossWidth: 65, degreesAcrossHeight: 31)
    static let limits = 5.0...90.0

    var isValid: Bool { Self.limits.contains(degreesAcrossWidth) && Self.limits.contains(degreesAcrossHeight) }

    func pointsPerDegree(display: CGSize, sensitivity: Double) -> SIMD2<Double> {
        SIMD2(display.width / degreesAcrossWidth, display.height / degreesAcrossHeight) * sensitivity
    }
}

/// Three targets on the main display: the center, near the top left, and near the
/// bottom right. The wearer aims at each and pinches. The two corners give the reach
/// on each axis; the center checks that the corners were meant.
struct PointerCalibration: Equatable {
    enum Step: Int, CaseIterable { case center, topLeft, bottomRight }

    /// Where each target sits, as a fraction of the display from its top left.
    static func position(of step: Step) -> CGPoint {
        switch step {
        case .center: CGPoint(x: 0.5, y: 0.5)
        case .topLeft: CGPoint(x: 0.15, y: 0.15)
        case .bottomRight: CGPoint(x: 0.85, y: 0.85)
        }
    }
    /// The corners are 70 % of the display apart on each axis.
    static let span = 0.7

    private(set) var step = Step.center
    private(set) var aims: [ForearmAim] = []
    private(set) var problem: String?

    /// Records the aim for the current step. Returns the reach once all three are in.
    mutating func record(_ aim: ForearmAim) -> PointerReach? {
        problem = nil
        aims.append(aim)
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        step = next
        return nil
    }

    private mutating func finish() -> PointerReach? {
        let center = aims[0], topLeft = aims[1], bottomRight = aims[2]
        // The top left is to the left (a larger compass angle) and higher.
        let across = remainder(topLeft.azimuth - bottomRight.azimuth, 360)
        let down = topLeft.elevation - bottomRight.elevation
        let reach = PointerReach(degreesAcrossWidth: across / Self.span, degreesAcrossHeight: down / Self.span)
        // The center should sit near the middle of the two corners.
        let middle = ForearmAim(azimuth: bottomRight.azimuth + across / 2, elevation: bottomRight.elevation + down / 2)
        let offCenter = SIMD2(remainder(center.azimuth - middle.azimuth, 360) / max(across, 1),
                              (center.elevation - middle.elevation) / max(down, 1))
        if across <= 0 || down <= 0 {
            problem = "the corners came out swapped. point at each target before you pinch."
        } else if !reach.isValid {
            problem = reach.degreesAcrossWidth < PointerReach.limits.lowerBound || reach.degreesAcrossHeight < PointerReach.limits.lowerBound
                ? "that was a very small movement. point your forearm at each target, not just your hand."
                : "that was a very large movement. aim at the targets with small, comfortable turns."
        } else if abs(offCenter.x) > 0.3 || abs(offCenter.y) > 0.3 {
            problem = "the center didn’t line up with the corners. hold your arm the same way for all three."
        }
        guard problem == nil else {
            step = .center
            aims = []
            return nil
        }
        return reach
    }
}
