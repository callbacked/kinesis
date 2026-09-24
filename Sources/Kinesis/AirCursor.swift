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

/// A laser pointer from the forearm. The pointer is anchored: when the cursor
/// turns on or is re-anchored, the current aim maps to the current pointer
/// position. From then on each degree of aim moves the pointer a fixed number
/// of points, so pointing back to the same place brings it back to the same
/// place, even after it stopped at a screen edge.
struct AirPointer {
    /// Degrees of forearm turn that cross the main display at sensitivity 1.
    static let degreesAcrossScreen = 40.0
    /// Near straight up or down the compass angle is meaningless, so it holds still there.
    static let steepElevation = 75.0
    /// A gap this long in the orientation stream re-anchors instead of jumping.
    static let maximumGap = 0.5

    private var azimuthFilter = OneEuroFilter(minimumCutoff: 1.5, beta: 0.05)
    private var elevationFilter = OneEuroFilter(minimumCutoff: 1.5, beta: 0.05)
    private var unwrappedAzimuth: Double?
    private var lastRawAzimuth = 0.0
    private var lastTime: Double?
    private var smoothed: SIMD2<Double>?
    private var held: SIMD2<Double>?
    private var speed = 0.0
    private(set) var aim: ForearmAim?
    private var anchorAim: ForearmAim?
    private var anchorPoint = SIMD2<Double>.zero

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
    static let slowSpeed = 5.0
    static let fastSpeed = 30.0

    var isAnchored: Bool { anchorAim != nil }

    /// Takes one orientation sample. Returns false after a gap, when the pointer
    /// must be re-anchored before it moves again.
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
            anchorAim = nil
            let start = SIMD2(azimuthFilter.filter(sample.azimuth, dt: 0), elevationFilter.filter(sample.elevation, dt: 0))
            smoothed = start
            held = start
            speed = 0
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

    /// The current aim now points at this position.
    mutating func anchor(at point: SIMD2<Double>) {
        guard let aim else { return }
        anchorAim = aim
        anchorPoint = point
    }

    mutating func release() {
        anchorAim = nil
    }

    /// Where the pointer belongs for the current aim, in global display points
    /// with y growing downward. Not clamped to any display.
    func target(pointsPerDegree: Double) -> SIMD2<Double>? {
        guard let aim, let anchorAim, pointsPerDegree.isFinite, pointsPerDegree > 0 else { return nil }
        return anchorPoint + SIMD2(-(aim.azimuth - anchorAim.azimuth), -(aim.elevation - anchorAim.elevation)) * pointsPerDegree
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
