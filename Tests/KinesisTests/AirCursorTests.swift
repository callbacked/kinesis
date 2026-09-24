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

/// Feeds a steady aim for a while at 128 Hz, like the band does.
private func hold(_ pointer: inout AirPointer, _ aim: ForearmAim, from start: Double, for seconds: Double) -> Double {
    var time = start
    while time < start + seconds {
        time += 1.0 / 128
        pointer.receive(aim, at: time)
    }
    return time
}

@Test func thePointerIsALaserThatStaysInStepWithTheArm() throws {
    var pointer = AirPointer()
    pointer.steadiness = 0  // the smallest dead zone, 0.1°: 4 points here
    var time = hold(&pointer, ForearmAim(azimuth: 90, elevation: 10), from: 0, for: 0.5)
    #expect(pointer.target(pointsPerDegree: 40) == nil)  // not anchored yet
    pointer.anchor(at: SIMD2(800, 500))
    // Ten degrees left and five up: 400 points left and 200 points up.
    time = hold(&pointer, ForearmAim(azimuth: 100, elevation: 15), from: time, for: 1)
    let moved = try #require(pointer.target(pointsPerDegree: 40))
    #expect(abs(moved.x - 400) < 5 && abs(moved.y - 300) < 5)
    // Far past any screen edge and back: the same aim gives the same point.
    time = hold(&pointer, ForearmAim(azimuth: 160, elevation: 15), from: time, for: 1)
    time = hold(&pointer, ForearmAim(azimuth: 100, elevation: 15), from: time, for: 1)
    let back = try #require(pointer.target(pointsPerDegree: 40))
    #expect(abs(back.x - moved.x) < 5 && abs(back.y - moved.y) < 5)
}

@Test func thePointerIsContinuousAcrossTheCompassSeam() throws {
    var pointer = AirPointer()
    pointer.steadiness = 0
    var time = hold(&pointer, ForearmAim(azimuth: 178, elevation: 0), from: 0, for: 0.5)
    pointer.anchor(at: .zero)
    time = hold(&pointer, ForearmAim(azimuth: -178, elevation: 0), from: time, for: 1)
    // Four degrees further left, not 356 degrees right.
    let target = try #require(pointer.target(pointsPerDegree: 10))
    #expect(abs(target.x + 40) < 1.5)
}

@Test func aGapInTheStreamAsksForAFreshAnchorInsteadOfAJump() {
    var pointer = AirPointer()
    let time = hold(&pointer, ForearmAim(azimuth: 90, elevation: 0), from: 0, for: 0.5)
    pointer.anchor(at: .zero)
    let continuous = pointer.receive(ForearmAim(azimuth: 120, elevation: 0), at: time + 0.01)
    let afterGap = pointer.receive(ForearmAim(azimuth: 150, elevation: 0), at: time + 1)
    #expect(continuous && !afterGap)
    #expect(!pointer.isAnchored && pointer.target(pointsPerDegree: 10) == nil)
}

@Test func nearStraightUpTheCompassAngleHoldsStill() throws {
    var pointer = AirPointer()
    var time = hold(&pointer, ForearmAim(azimuth: 90, elevation: 80), from: 0, for: 0.5)
    pointer.anchor(at: .zero)
    time = hold(&pointer, ForearmAim(azimuth: -20, elevation: 80), from: time, for: 1)
    let target = try #require(pointer.target(pointsPerDegree: 10))
    #expect(abs(target.x) < 0.001)
}

/// Sway like a held arm: `amplitude` degrees at `hertz`, around a fixed aim.
private func sway(_ pointer: inout AirPointer, amplitude: Double, hertz: Double, from start: Double, for seconds: Double)
    -> (time: Double, spread: Double) {
    var time = start, low = Double.infinity, high = -Double.infinity
    while time < start + seconds {
        time += 1.0 / 128
        pointer.receive(ForearmAim(azimuth: 90 + amplitude * sin(2 * .pi * hertz * (time - start)), elevation: 0), at: time)
        let x = pointer.target(pointsPerDegree: 40)!.x
        low = min(low, x); high = max(high, x)
    }
    return (time, high - low)
}

@Test func swayInsideTheDeadZoneNeverMovesThePointer() {
    for steadiness in [0.5, 1.0] {
        var pointer = AirPointer()
        pointer.steadiness = steadiness
        let time = hold(&pointer, ForearmAim(azimuth: 90, elevation: 0), from: 0, for: 0.5)
        pointer.anchor(at: .zero)
        // A typical 2 Hz sway, a little smaller than the dead zone.
        let still = sway(&pointer, amplitude: pointer.slack * 0.9, hertz: 2, from: time, for: 3)
        #expect(still.spread < 0.5)
    }
}

@Test func steadinessCalmsSwayButAQuickMoveStillLands() throws {
    func run(steadiness: Double) -> (spread: Double, landing: Double) {
        var pointer = AirPointer()
        pointer.steadiness = steadiness
        var time = hold(&pointer, ForearmAim(azimuth: 90, elevation: 0), from: 0, for: 0.5)
        pointer.anchor(at: .zero)
        let swaying = sway(&pointer, amplitude: 0.5, hertz: 2, from: time, for: 3)
        time = hold(&pointer, ForearmAim(azimuth: 80, elevation: 0), from: swaying.time, for: 1)
        return (swaying.spread, pointer.target(pointsPerDegree: 40)!.x)
    }
    let quick = run(steadiness: 0), steady = run(steadiness: 1)
    #expect(steady.spread < 1 && quick.spread > 20)
    // Ten degrees right is 400 points. It lands within one dead zone of that.
    #expect(abs(quick.landing - 400) < 5 && abs(steady.landing - 400) < 40)
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
