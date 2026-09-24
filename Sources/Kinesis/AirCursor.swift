import CoreGraphics
import Foundation
import KinesisCore
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
    /// Observed scale, not a datasheet value: raw gyro counts to degrees per second.
    static let gyroScale = 0.07

    /// Honing in on a target passed hand tremor straight through at a 3 Hz floor. A
    /// 1.2 Hz floor calms slow aiming, and the steeper speed term keeps quick moves
    /// crisp: at 30°/s the cutoff is back near 5 Hz.
    private var azimuthFilter = OneEuroFilter(minimumCutoff: 1.2, beta: 0.12)
    private var elevationFilter = OneEuroFilter(minimumCutoff: 1.2, beta: 0.12)
    private var unwrappedAzimuth: Double?
    private var lastRawAzimuth = 0.0
    private var lastRawElevation = 0.0
    private var lastTime: Double?
    private(set) var aim: ForearmAim?
    /// Movement not yet taken, already scaled by stillness and acceleration.
    private var pending = SIMD2<Double>.zero
    /// The gate's view of speed: it rises with the gyro at once and falls over 150 ms,
    /// so the smoothing can finish a quick move after the arm has stopped.
    private var gateSpeed = 0.0
    private var gyroBias = SIMD3<Double>.zero
    private var lastGyroTime: Double?
    /// Degrees per second the aim is turning, from the gyro, without wrist twist.
    private(set) var speed = 0.0
    /// The last 200 ms of speed, to tell settling onto a target from tracking one.
    private var recentSpeeds: [(time: Double, speed: Double)] = []

    /// 0 is the most responsive and 1 the steadiest.
    var steadiness = 0.5

    /// Below `still.lowerBound` degrees per second the arm counts as held still and
    /// the pointer does not move; above `still.upperBound` it moves fully.
    ///
    /// Measured 2026-09-24 with the gyro smoothed over 100 ms, leaving out the twist
    /// around the forearm: holding still ran 0.5°/s typically and 0.9°/s at the 90th
    /// percentile, and slow, careful moves ran 1.2 to 1.8°/s typically. The orientation
    /// alone can't separate the two (1.7 against 1.8°/s), and a positional dead zone
    /// gave slow moves backlash: they felt like an arm that was asleep.
    var still: ClosedRange<Double> {
        let low = 0.5 + 0.7 * max(0, min(1, steadiness))
        return low...(low + 0.5)
    }

    /// After a pinch the forearm drifts 0.2 to 0.8° over 0.3 s at 2 to 4°/s, and the
    /// band's haptic buzz adds to it (measured 2026-09-24). Tracking something that
    /// moves ran faster, over 6°/s. So for a moment after a pinch or a release the
    /// stillness threshold rises to this, then fades back over 0.4 s, a little past the
    /// drift so the smoothing can finish inside the guard: the drift is absorbed and
    /// the pointer never freezes.
    static let clickGuard = 3.5...6.0
    static let clickGuardSeconds = 0.4
    private var clickGuardUntil = -Double.infinity
    /// The arm's speed when the guard began. Slowing on from there is still the settle.
    private var clickGuardSpeed = 0.0

    /// The stillness range at this moment, raised for a while after a pinch.
    func still(at time: Double) -> ClosedRange<Double> {
        let base = still
        let strength = max(0, min(1, (clickGuardUntil - time) / Self.clickGuardSeconds))
        guard strength > 0 else { return base }
        let guardLow = max(Self.clickGuard.lowerBound, clickGuardSpeed)
        let guardHigh = guardLow + (Self.clickGuard.upperBound - Self.clickGuard.lowerBound)
        let low = base.lowerBound + (guardLow - base.lowerBound) * strength
        let high = base.upperBound + (guardHigh - base.upperBound) * strength
        return low...max(high, low + 0.1)
    }

    /// How the arm was moving when a pinch came.
    enum Approach { case still, settling, tracking }

    /// People slow down into a click, as with a mouse: pinches made "while moving" came
    /// at 5 to 10°/s and falling from 13 to 24°/s 200 ms before (measured 2026-09-24).
    /// Tracking something that moves keeps its speed.
    var approach: Approach {
        if speed < 3 { return .still }
        let peak = recentSpeeds.map(\.speed).max() ?? speed
        return speed < 15 && speed < peak * 0.8 ? .settling : .tracking
    }

    /// A pinch or release happened: absorb the drift that follows it. A pinch made
    /// while slowing onto a target comes at up to 15°/s, so the guard starts at that
    /// speed: the arm slowing on after the pinch is the same settle and moves nothing,
    /// and speeding up again, as for a drag, gets through. The smoothing's lag is
    /// dropped too. It would otherwise carry the pointer on past the click.
    mutating func guardClick(at time: Double) {
        clickGuardUntil = time + Self.clickGuardSeconds
        clickGuardSpeed = speed
        guard let azimuth = unwrappedAzimuth else { return }
        azimuthFilter.reset()
        elevationFilter.reset()
        aim = ForearmAim(azimuth: azimuthFilter.filter(azimuth, dt: 0), elevation: elevationFilter.filter(lastRawElevation, dt: 0))
        pending = .zero
    }

    /// How much of the aim's movement reaches the pointer at this moment: 0 when held still, 1 when moving.
    func motion(at time: Double) -> Double {
        let range = still(at: time)
        // During a click guard the arm's own speed decides: the held-over speed that lets
        // the smoothing finish a flick would let it finish past the click instead.
        let judged = time < clickGuardUntil ? speed : gateSpeed
        let x = max(0, min(1, (judged - range.lowerBound) / (range.upperBound - range.lowerBound)))
        return x * x * (3 - 2 * x)
    }

    /// Takes one gyro sample in raw counts. Only its rate is used: the orientation
    /// says where the forearm points, and the gyro says whether it is moving.
    mutating func receiveGyro(_ raw: SIMD3<Double>, at time: Double) {
        guard (0..<3).allSatisfy({ raw[$0].isFinite }) else { return }
        let dt = lastGyroTime.map { time - $0 } ?? 0
        lastGyroTime = time
        guard dt > 0, dt < Self.maximumGap else { return }
        let corrected = raw * Self.gyroScale - gyroBias
        // The resting offset drifts. Learn it only while the arm is clearly still.
        if simd_length(corrected) < 0.8 { gyroBias += corrected * (1 - exp(-dt / 4)) }
        // Body +y is the forearm, so a rate around y is a twist, which never moves the pointer.
        let rate = (corrected.x * corrected.x + corrected.z * corrected.z).squareRoot()
        speed += (rate - speed) * (1 - exp(-dt / 0.1))
        gateSpeed = max(speed, gateSpeed * exp(-dt / 0.15))
        recentSpeeds.append((time, speed))
        recentSpeeds.removeAll { time - $0.time > 0.2 }
    }

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
            lastRawElevation = sample.elevation
            let start = SIMD2(azimuthFilter.filter(sample.azimuth, dt: 0), elevationFilter.filter(sample.elevation, dt: 0))
            pending = .zero
            aim = ForearmAim(azimuth: start.x, elevation: start.y)
            return false
        }
        // Keep the compass angle continuous across ±180°, and freeze it where it is undefined.
        if abs(sample.elevation) < Self.steepElevation {
            unwrappedAzimuth! += remainder(sample.azimuth - lastRawAzimuth, 360)
        }
        lastRawAzimuth = sample.azimuth
        lastRawElevation = sample.elevation
        let next = ForearmAim(azimuth: azimuthFilter.filter(unwrappedAzimuth!, dt: gap),
                              elevation: elevationFilter.filter(sample.elevation, dt: gap))
        if let previous = aim {
            // Scale each step by the speed at that moment, so a flick keeps its gain
            // even when the pointer is read a frame later.
            let step = SIMD2(next.azimuth - previous.azimuth, next.elevation - previous.elevation)
            pending += step * motion(at: time) * PointerAcceleration.factor(speed: speed)
        }
        aim = next
        return true
    }

    /// Degrees of movement since the last call, after stillness and acceleration:
    /// compass angle (positive is left) and elevation (positive is up). Nil until there is an aim.
    mutating func movement() -> SIMD2<Double>? {
        guard aim != nil else { return nil }
        defer { pending = .zero }
        return pending
    }

    /// Drops any movement not yet taken, such as the twitch of a pinch.
    mutating func discard() {
        pending = .zero
    }
}

/// Pointer acceleration: slow aiming moves the pointer less, for precision, and a
/// quick flick moves it more, for distance. Slow moves once ran at 0.35 and felt
/// numb; careful moves measured 1.2 to 1.8°/s and flicks over 30°/s.
enum PointerAcceleration {
    static let slowSpeed = 2.0
    static let fastSpeed = 30.0
    static let slowFactor = 0.6
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

/// How much forearm turn crosses the main display, left to right and top to bottom, and
/// how slanted the arm's natural across and up lines are. Stored in degrees, not points,
/// so it survives a change of display.
struct PointerReach: Codable, Equatable {
    var degreesAcrossWidth: Double
    var degreesAcrossHeight: Double
    /// Compass degrees per degree of elevation when the arm moves straight up. Positive
    /// means up drifts left. On 2026-09-24 a right arm moving "straight up" drifted 13°
    /// left, toward the body: an elbow doesn't hinge in a straight screen line.
    var upTilt = 0.0
    /// Elevation per compass degree when the arm moves straight to the right.
    var acrossTilt = 0.0

    /// Reach: the typical result of four calibrations on 2026-09-24, in two poses: 64°
    /// to 73° across and 27° to 32° up and down. Tilt: a little under the 13° measured,
    /// since arms differ. A left arm stays at zero until it has been measured.
    static func standard(for hand: BandHand) -> PointerReach {
        PointerReach(degreesAcrossWidth: 65, degreesAcrossHeight: 31, upTilt: hand == .right ? 0.18 : 0)
    }
    static let limits = 5.0...90.0
    static let tiltLimit = 0.6

    var isValid: Bool {
        Self.limits.contains(degreesAcrossWidth) && Self.limits.contains(degreesAcrossHeight)
            && abs(upTilt) <= Self.tiltLimit && abs(acrossTilt) <= Self.tiltLimit && abs(1 + upTilt * acrossTilt) > 0.5
    }

    init(degreesAcrossWidth: Double, degreesAcrossHeight: Double, upTilt: Double = 0, acrossTilt: Double = 0) {
        self.degreesAcrossWidth = degreesAcrossWidth
        self.degreesAcrossHeight = degreesAcrossHeight
        self.upTilt = upTilt
        self.acrossTilt = acrossTilt
    }

    /// Calibrations saved before the tilt existed have none.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        degreesAcrossWidth = try container.decode(Double.self, forKey: .degreesAcrossWidth)
        degreesAcrossHeight = try container.decode(Double.self, forKey: .degreesAcrossHeight)
        upTilt = try container.decodeIfPresent(Double.self, forKey: .upTilt) ?? 0
        acrossTilt = try container.decodeIfPresent(Double.self, forKey: .acrossTilt) ?? 0
    }

    /// Straightens an aim change (compass, positive left; elevation, positive up) into
    /// degrees along the screen: right and down. A move along the arm's natural up
    /// line comes out straight up, and one along its across line straight across.
    func screenDegrees(_ aim: SIMD2<Double>) -> SIMD2<Double> {
        let scale = 1 + upTilt * acrossTilt
        let right = -(aim.x - upTilt * aim.y) / scale
        let up = (acrossTilt * aim.x + aim.y) / scale
        return SIMD2(right, -up)
    }

    func pointsPerDegree(display: CGSize, sensitivity: Double) -> SIMD2<Double> {
        SIMD2(display.width / degreesAcrossWidth, display.height / degreesAcrossHeight) * sensitivity
    }
}

/// Four targets on the main display: left, right, top, and bottom of the center. The
/// wearer aims at each and pinches. Left to right gives the reach and slant across,
/// top to bottom the reach and slant up and down, and the two midpoints must agree.
struct PointerCalibration: Equatable {
    enum Step: Int, CaseIterable { case left, right, top, bottom }

    /// Where each target sits, as a fraction of the display from its top left.
    static func position(of step: Step) -> CGPoint {
        switch step {
        case .left: CGPoint(x: 0.15, y: 0.5)
        case .right: CGPoint(x: 0.85, y: 0.5)
        case .top: CGPoint(x: 0.5, y: 0.15)
        case .bottom: CGPoint(x: 0.5, y: 0.85)
        }
    }
    /// Each pair is 70 % of the display apart.
    static let span = 0.7

    private(set) var step = Step.left
    private(set) var aims: [ForearmAim] = []
    private(set) var problem: String?

    /// Records the aim for the current step. Returns the reach once all four are in.
    mutating func record(_ aim: ForearmAim) -> PointerReach? {
        problem = nil
        aims.append(aim)
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        step = next
        return nil
    }

    private mutating func finish() -> PointerReach? {
        let left = aims[0], right = aims[1], top = aims[2], bottom = aims[3]
        // Aim changes, compass first (positive is left) and elevation second.
        let across = SIMD2(remainder(right.azimuth - left.azimuth, 360), right.elevation - left.elevation)
        let upward = SIMD2(remainder(top.azimuth - bottom.azimuth, 360), top.elevation - bottom.elevation)
        var reach: PointerReach?
        if across.x >= 0 || upward.y <= 0 {
            problem = "the targets came out swapped. point at each target before you pinch."
        } else {
            let found = PointerReach(degreesAcrossWidth: simd_length(across) / Self.span,
                                     degreesAcrossHeight: simd_length(upward) / Self.span,
                                     upTilt: upward.x / upward.y, acrossTilt: across.y / -across.x)
            // Both pairs straddle the center, so their midpoints should be close.
            let middleAcross = SIMD2(left.azimuth + across.x / 2, left.elevation + across.y / 2)
            let middleUp = SIMD2(bottom.azimuth + upward.x / 2, bottom.elevation + upward.y / 2)
            let apart = SIMD2(remainder(middleAcross.x - middleUp.x, 360) / -across.x, (middleAcross.y - middleUp.y) / upward.y)
            if found.degreesAcrossWidth < PointerReach.limits.lowerBound || found.degreesAcrossHeight < PointerReach.limits.lowerBound {
                problem = "that was a very small movement. point your forearm at each target, not just your hand."
            } else if found.degreesAcrossWidth > PointerReach.limits.upperBound || found.degreesAcrossHeight > PointerReach.limits.upperBound {
                problem = "that was a very large movement. aim at the targets with small, comfortable turns."
            } else if !found.isValid {
                problem = "those moves were very slanted. keep your arm in one comfortable pose and aim again."
            } else if abs(apart.x) > 0.3 || abs(apart.y) > 0.3 {
                problem = "the two pairs didn’t line up. hold your arm the same way for all four."
            } else {
                reach = found
            }
        }
        guard let reach else {
            step = .left
            aims = []
            return nil
        }
        return reach
    }
}
