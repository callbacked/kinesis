import AppKit
import simd
import Testing
@testable import Kinesis

/// The band's quaternion in wire order w, x, y, z, for a forearm turned `azimuth`
/// degrees left of the band's resting heading, raised `elevation` degrees, and
/// twisted `twist` degrees around its own length.
func bandQuaternion(azimuth: Double = 0, elevation: Double = 0, twist: Double = 0) -> SIMD4<Double> {
    let radians = { (degrees: Double) in degrees * .pi / 180 }
    let q = simd_quatd(angle: radians(azimuth), axis: SIMD3(0, 0, 1))
        * simd_quatd(angle: radians(elevation), axis: SIMD3(1, 0, 0))
        * simd_quatd(angle: radians(twist), axis: SIMD3(0, 1, 0))
    return SIMD4(q.real, q.imag.x, q.imag.y, q.imag.z)
}

@Test func theForearmAimFollowsTurningAndRaisingAndIgnoresTwisting() throws {
    let rest = try #require(ForearmAim(quaternion: bandQuaternion()))
    // At rest the band's +y, the forearm, lies along the world's +y.
    #expect(abs(rest.azimuth - 90) < 1e-9 && abs(rest.elevation) < 1e-9)
    let turned = try #require(ForearmAim(quaternion: bandQuaternion(azimuth: 30)))
    #expect(abs(turned.azimuth - 120) < 1e-9)  // counterclockwise from above is left
    let raised = try #require(ForearmAim(quaternion: bandQuaternion(elevation: 20)))
    #expect(abs(raised.elevation - 20) < 1e-9 && abs(raised.azimuth - 90) < 1e-9)
    // A twist of the wrist changes neither angle, in any pose.
    for (azimuth, elevation) in [(0.0, 0.0), (45.0, 15.0), (-60.0, -30.0)] {
        let aim = try #require(ForearmAim(quaternion: bandQuaternion(azimuth: azimuth, elevation: elevation)))
        let twisted = try #require(ForearmAim(quaternion: bandQuaternion(azimuth: azimuth, elevation: elevation, twist: 70)))
        #expect(abs(aim.azimuth - twisted.azimuth) < 1e-9 && abs(aim.elevation - twisted.elevation) < 1e-9)
    }
    // A negated quaternion is the same rotation.
    let negated = try #require(ForearmAim(quaternion: -bandQuaternion(azimuth: 30, elevation: 10)))
    #expect(abs(negated.azimuth - 120) < 1e-9 && abs(negated.elevation - 10) < 1e-9)
    #expect(ForearmAim(quaternion: SIMD4(2, 0, 0, 0)) == nil)
    #expect(ForearmAim(quaternion: SIMD4(.nan, 0, 0, 0)) == nil)
}

/// Feeds the pointer at 128 Hz, like the band does, and adds up the movement it
/// reports, in degrees: positive x is left, positive y is up.
private struct Feed {
    var pointer = AirPointer()
    var time = 0.0
    var moved = SIMD2<Double>.zero

    init(steadiness: Double = 0) { pointer.steadiness = steadiness }

    mutating func sample(_ aim: ForearmAim) {
        time += 1.0 / 128
        pointer.receive(aim, at: time)
        moved += pointer.movement() ?? .zero
    }

    /// Moves the aim in a straight line at a steady speed, then holds it for a moment.
    mutating func sweep(from start: ForearmAim, to end: ForearmAim, seconds: Double) {
        let steps = max(1, Int(seconds * 128))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            sample(ForearmAim(azimuth: start.azimuth + (end.azimuth - start.azimuth) * t,
                              elevation: start.elevation + (end.elevation - start.elevation) * t))
        }
        for _ in 0..<64 { sample(end) }
    }

    mutating func hold(_ aim: ForearmAim, seconds: Double) {
        for _ in 0..<Int(seconds * 128) { sample(aim) }
    }
}

@Test func movementIsHowFarTheAimTurnedAndNothingWhileItHolds() {
    var feed = Feed()
    feed.hold(ForearmAim(azimuth: 90, elevation: 10), seconds: 0.5)
    #expect(simd_length(feed.moved) < 1e-9)
    feed.moved = .zero
    feed.sweep(from: ForearmAim(azimuth: 90, elevation: 10), to: ForearmAim(azimuth: 100, elevation: 15), seconds: 0.5)
    // Within the smallest dead zone, 0.1°, of ten left and five up.
    #expect(abs(feed.moved.x - 10) < 0.15 && abs(feed.moved.y - 5) < 0.15)
}

@Test func movementIsContinuousAcrossTheCompassSeam() {
    var feed = Feed()
    feed.hold(ForearmAim(azimuth: 178, elevation: 0), seconds: 0.5)
    feed.sweep(from: ForearmAim(azimuth: 178, elevation: 0), to: ForearmAim(azimuth: 182, elevation: 0), seconds: 0.2)
    // The compass reads −178° at the end: four degrees further left, not 356 right.
    #expect(abs(feed.moved.x - 4) < 0.15)
}

@Test func aGapInTheStreamDropsTheMovementAcrossIt() {
    var feed = Feed()
    feed.hold(ForearmAim(azimuth: 90, elevation: 0), seconds: 0.5)
    feed.time += 1
    feed.hold(ForearmAim(azimuth: 130, elevation: 0), seconds: 0.5)
    #expect(simd_length(feed.moved) < 1e-9)
}

@Test func nearStraightUpTheCompassAngleHoldsStill() {
    var feed = Feed()
    feed.hold(ForearmAim(azimuth: 90, elevation: 80), seconds: 0.5)
    feed.sweep(from: ForearmAim(azimuth: 90, elevation: 80), to: ForearmAim(azimuth: -20, elevation: 80), seconds: 1)
    #expect(abs(feed.moved.x) < 1e-9)
}

@Test func swayInsideTheDeadZoneNeverMovesThePointer() {
    for steadiness in [0.3, 1.0] {
        var feed = Feed(steadiness: steadiness)
        feed.hold(ForearmAim(azimuth: 90, elevation: 0), seconds: 0.5)
        let slack = feed.pointer.slack
        // A 2 Hz sway, a little smaller than the dead zone, like a held arm.
        for _ in 0..<(3 * 128) {
            let t = feed.time + 1.0 / 128
            feed.sample(ForearmAim(azimuth: 90 + slack * 0.9 * sin(2 * .pi * 2 * t), elevation: 0))
        }
        #expect(simd_length(feed.moved) < 0.02)
    }
}

@Test func accelerationGivesPrecisionWhenSlowAndDistanceWhenFast() {
    #expect(PointerAcceleration.factor(speed: 0) == PointerAcceleration.slowFactor)
    #expect(PointerAcceleration.factor(speed: 1000) == PointerAcceleration.fastFactor)
    let speeds = stride(from: 0.0, through: 60, by: 1).map(PointerAcceleration.factor(speed:))
    #expect(zip(speeds, speeds.dropFirst()).allSatisfy { $0 <= $1 })
    // A slow move reports a low speed and a flick a high one.
    var slow = Feed(), fast = Feed()
    slow.hold(ForearmAim(azimuth: 90, elevation: 0), seconds: 0.5)
    fast.hold(ForearmAim(azimuth: 90, elevation: 0), seconds: 0.5)
    for _ in 0..<128 { slow.sample(ForearmAim(azimuth: 90 + 2 * slow.time.truncatingRemainder(dividingBy: 1), elevation: 0)) }
    var fastest = 0.0
    for step in 1...32 {
        fast.sample(ForearmAim(azimuth: 90 + 20 * Double(step) / 32, elevation: 0))
        fastest = max(fastest, fast.pointer.speed)
    }
    #expect(slow.pointer.speed < PointerAcceleration.slowSpeed && fastest > PointerAcceleration.fastSpeed)
}

@Test func calibrationMeasuresEachAxisAndRejectsAimsThatDontFit() {
    func run(_ center: ForearmAim, _ topLeft: ForearmAim, _ bottomRight: ForearmAim) -> (PointerReach?, String?) {
        var calibration = PointerCalibration()
        #expect(calibration.record(center) == nil && calibration.step == .topLeft)
        #expect(calibration.record(topLeft) == nil && calibration.step == .bottomRight)
        let reach = calibration.record(bottomRight)
        return (reach, calibration.problem)
    }
    // 25.2° apart across and 12.6° apart up and down, at 70 % of the display.
    let good = run(ForearmAim(azimuth: 90, elevation: 10), ForearmAim(azimuth: 102.6, elevation: 16.3), ForearmAim(azimuth: 77.4, elevation: 3.7))
    #expect(good.1 == nil)
    #expect(abs(good.0!.degreesAcrossWidth - 36) < 1e-9 && abs(good.0!.degreesAcrossHeight - 18) < 1e-9)
    // Across the compass seam it still measures the short way round.
    let seam = run(ForearmAim(azimuth: 180, elevation: 10), ForearmAim(azimuth: -167.4, elevation: 16.3), ForearmAim(azimuth: 167.4, elevation: 3.7))
    #expect(seam.0 != nil && abs(seam.0!.degreesAcrossWidth - 36) < 1e-9)
    let swapped = run(ForearmAim(azimuth: 90, elevation: 10), ForearmAim(azimuth: 77.4, elevation: 3.7), ForearmAim(azimuth: 102.6, elevation: 16.3))
    #expect(swapped.0 == nil && swapped.1?.contains("swapped") == true)
    let tiny = run(ForearmAim(azimuth: 90, elevation: 10), ForearmAim(azimuth: 91, elevation: 10.5), ForearmAim(azimuth: 89, elevation: 9.5))
    #expect(tiny.0 == nil && tiny.1?.contains("small") == true)
    let offCenter = run(ForearmAim(azimuth: 110, elevation: 10), ForearmAim(azimuth: 102.6, elevation: 16.3), ForearmAim(azimuth: 77.4, elevation: 3.7))
    #expect(offCenter.0 == nil && offCenter.1?.contains("center") == true)
    #expect(PointerReach.standard.isValid)
}

@Test @MainActor func cursorCrossesDisplayBoundariesButStaysOutOfGaps() {
    let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: -800, y: -200, width: 800, height: 600)]
    #expect(MacShortcuts.cursorPosition(from: CGPoint(x: 5, y: 100), delta: SIMD2(-20, 0), displays: displays)
            == CGPoint(x: -15, y: 100))
    #expect(MacShortcuts.cursorPosition(from: CGPoint(x: 5, y: 700), delta: SIMD2(-20, 0), displays: displays)
            == CGPoint(x: 0, y: 700))
    #expect(MacShortcuts.cursorPosition(from: CGPoint(x: 990, y: 790), delta: SIMD2(30, 30), displays: displays)
            == CGPoint(x: 999, y: 799))
}

@Test @MainActor func cursorClicksReleaseTheCorrectButtonAtTheSamePosition() throws {
    for button in [CGMouseButton.left, .right] {
        let position = CGPoint(x: -250, y: 120)
        let events = try MacShortcuts.clickEvents(button, count: 1, at: position)
        #expect(events.map(\.type) == (button == .left ? [.leftMouseDown, .leftMouseUp] : [.rightMouseDown, .rightMouseUp]))
        #expect(events.allSatisfy { $0.location == position && $0.getIntegerValueField(.mouseEventClickState) == 1 })
    }
}
