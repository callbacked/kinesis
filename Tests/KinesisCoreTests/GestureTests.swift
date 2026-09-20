import Foundation
import Testing
@testable import KinesisCore

private func gesture(_ sequence: Int, time: Double = 100, action: String = "left", derived: String = "unknown", finger: String = "thumb", synthetic: Bool = false) -> BandGesture {
    BandGesture(sequence: UInt64(sequence), timestampUs: UInt64(sequence * 1000), finger: finger,
                action: action, derivedAction: derived, synthetic: synthetic, receivedAt: time)
}

@Test func oneSwipeProducesOneActionAcrossRawDerivedAndRepeatedMessages() throws {
    var router = GestureRouter()
    let raw = gesture(1)
    #expect(router.gesture(from: raw, now: 100.01) == .swipe(.left))
    #expect(router.gesture(from: raw, now: 100.02) == nil)
    #expect(router.gesture(from: gesture(2, time: 100.03, action: "unknown", derived: "buttonLeft"), now: 100.04) == nil)
    #expect(router.gesture(from: gesture(3, time: 100.5), now: 100.51) == .swipe(.left))
}

@Test func derivedFirstAndAllFourDirectionsWork() throws {
    var router = GestureRouter()
    #expect(router.gesture(from: gesture(1, action: "unknown", derived: "buttonRight"), now: 100) == .swipe(.right))
    #expect(router.gesture(from: gesture(2, time: 100.02, action: "right"), now: 100.03) == nil)
    #expect(router.gesture(from: gesture(3, time: 101, action: "up"), now: 101) == .swipe(.up))
    #expect(router.gesture(from: gesture(4, time: 102, action: "down"), now: 102) == .swipe(.down))
    #expect(router.gesture(from: gesture(5, time: 103, action: "left"), now: 103) == .swipe(.left))
}

@Test func stalePartialSyntheticAndWrongFingerEventsCannotControlMac() throws {
    var router = GestureRouter()
    #expect(router.gesture(from: gesture(1), now: 101) == nil)
    #expect(router.gesture(from: gesture(2, time: 102), now: 100) == nil)
    #expect(router.gesture(from: gesture(3, action: "partialLeft"), now: 100) == nil)
    #expect(router.gesture(from: gesture(4, finger: "index"), now: 100) == nil)
    #expect(router.gesture(from: gesture(5, synthetic: true), now: 100) == nil)
    #expect(router.gesture(from: gesture(6), now: 100.02) == .swipe(.left))
}

@Test func reconnectCanRestartSequenceWithoutReplayingStaleInput() throws {
    var router = GestureRouter()
    #expect(router.gesture(from: gesture(1), now: 100) == .swipe(.left))
    router.reset()
    #expect(router.gesture(from: gesture(1), now: 200) == nil)
    #expect(router.gesture(from: gesture(1, time: 200), now: 200) == .swipe(.left))
}

@Test func enablingDoesNotReplayOldInputAndPausingIsImmediate() {
    var gate = ActionGate()
    #expect(gate.allows(eventTime: 100, now: 100, live: true, trusted: true) == false)
    gate.arm(at: 100.1)
    #expect(gate.allows(eventTime: 100, now: 100.2, live: true, trusted: true) == false)
    #expect(gate.allows(eventTime: 100.2, now: 100.2, live: true, trusted: true) == true)
    #expect(gate.allows(eventTime: 100.3, now: 100.3, live: true, trusted: true) == false)
    gate.pause()
    #expect(gate.allows(eventTime: 101, now: 101, live: true, trusted: true) == false)
}

@Test func permissionAndLiveConnectionAreRequiredAtDispatch() {
    var gate = ActionGate()
    gate.arm(at: 100)
    #expect(gate.allows(eventTime: 101, now: 101, live: false, trusted: true) == false)
    #expect(gate.allows(eventTime: 101, now: 101, live: true, trusted: false) == false)
    #expect(gate.allows(eventTime: 101, now: 102, live: true, trusted: true) == false)
    #expect(gate.allows(eventTime: 102, now: 102, live: true, trusted: true) == true)
}

@Test func doubleTapsAreRecognizedOnceAndPartialPinchesAreIgnored() throws {
    var router = GestureRouter()
    #expect(router.gesture(from: gesture(1, action: "doubletap", finger: "index"), now: 100) == .tap(.indexDoubleTap))
    #expect(router.gesture(from: gesture(2, time: 100.03, action: "unknown", derived: "doubleTap", finger: "index"), now: 100.04) == nil)
    #expect(router.gesture(from: gesture(3, time: 101, action: "unknown", derived: "doubleTap", finger: "middle"), now: 101) == .tap(.middleDoubleTap))
    #expect(router.gesture(from: gesture(4, time: 102, action: "partialClick", finger: "index"), now: 102) == nil)
    #expect(router.gesture(from: gesture(5, time: 103, action: "doubletap", finger: "middle", synthetic: true), now: 103) == nil)
}

@Test func dialReversalAndReleaseDoNotCarryOverOldMovement() {
    var dial = DialRouter()
    #expect(dial.turn(delta: 1, sensitivity: 1, now: 100) == 0)
    #expect(dial.turn(delta: -1, sensitivity: 1, now: 100.1) == 0)
    #expect(dial.turn(delta: -1, sensitivity: 1, now: 100.2) == -1)
    #expect(dial.turn(delta: 1, sensitivity: 1, now: 100.3) == 0)
    dial.reset()
    #expect(dial.turn(delta: 1, sensitivity: 1, now: 100.4) == 0)
    #expect(dial.turn(delta: .nan, sensitivity: 1, now: 100.5) == 0)
    #expect(dial.turn(delta: 600, sensitivity: 1, now: 100.6) == 1)
    #expect(dial.turn(delta: 0, sensitivity: 1, now: 100.7) == 0)
}

@Test func fractionalDialInputAccumulatesAcrossRateLimitAndSensitivityScales() throws {
    for sensitivity in [0.5, 1.0, 2.0, 4.0] {
        var dial = DialRouter()
        var gate = ActionGate(minimumInterval: 0)
        gate.arm(at: 100)
        var sent = 0
        for index in 0..<32 {
            let now = 100 + Double(index) * 0.04
            if gate.allows(eventTime: now, now: now, live: true, trusted: true) {
                sent += dial.turn(delta: 0.125, sensitivity: sensitivity, now: now)
            }
        }
        sent += dial.turn(delta: 0, sensitivity: sensitivity, now: 101.4)
        #expect(sent == Int(2 * sensitivity))
    }
}

@Test func releasingOrLosingMotionDiscardsPendingDialSteps() {
    var dial = DialRouter()
    #expect(dial.turn(delta: 2, sensitivity: 1, now: 100) == 1)
    #expect(dial.turn(delta: 2, sensitivity: 1, now: 100.01) == 0)
    dial.reset()
    #expect(dial.turn(delta: 0, sensitivity: 1, now: 100.1) == 0)
    #expect(dial.turn(delta: 2, sensitivity: 1, now: 100.2) == 1)
    #expect(dial.turn(delta: 2, sensitivity: 1, now: 100.21) == 0)
    #expect(dial.turn(delta: 0, sensitivity: 1, now: 101) == 0)
}

@Test func aFastDialFlickCannotSendABurstOrQueueMoreVolumeChanges() {
    var dial = DialRouter()
    #expect(dial.turn(delta: 20, sensitivity: 4, now: 100) == 1)
    #expect(dial.turn(delta: 0, sensitivity: 4, now: 100.1) == 0)
    #expect(dial.turn(delta: -20, sensitivity: 4, now: 100.2) == -1)
    #expect(dial.turn(delta: 0, sensitivity: 4, now: 100.3) == 0)
}

@Test func interleavedRawAndDerivedGesturesAreCountedOncePerGesture() {
    var router = GestureRouter()
    #expect(router.gesture(from: gesture(1, action: "left"), now: 100) == .swipe(.left))
    #expect(router.gesture(from: gesture(2, time: 100.01, action: "right"), now: 100.01) == .swipe(.right))
    #expect(router.gesture(from: gesture(3, time: 100.02, action: "unknown", derived: "buttonLeft"), now: 100.02) == nil)
    #expect(router.gesture(from: gesture(4, time: 100.03, action: "unknown", derived: "buttonRight"), now: 100.03) == nil)
    #expect(router.gesture(from: gesture(5, time: 100.04, action: "left"), now: 100.04) == .swipe(.left))
}

@Test func gestureIdentityIncludesTheFinger() {
    var router = GestureRouter()
    #expect(router.gesture(from: gesture(1, action: "tap", finger: "index"), now: 100) == .tap(.indexTap))
    #expect(router.gesture(from: gesture(1, action: "tap", finger: "middle"), now: 100) == .tap(.middleTap))
}

@Test func aMiddleHoldIsAGestureAndAnIndexHoldIsNot() {
    var router = GestureRouter()
    func hold(_ finger: String, sequence: UInt64) -> BandGesture {
        BandGesture(sequence: sequence, timestampUs: sequence, finger: finger, action: "press",
                    derivedAction: "buttonHold", synthetic: false, receivedAt: 100)
    }
    #expect(router.gesture(from: hold("middle", sequence: 1), now: 100) == .tap(.middleHold))
    // Holding the index finger is the dial, so it never fires an action of its own.
    #expect(router.gesture(from: hold("index", sequence: 2), now: 100) == nil)
    #expect(TapGesture.middleHold.label == "Middle hold" && TapGesture.middleHold.finger == "middle")
    #expect(TapGesture.indexDoubleTap.motion == "double tap" && TapGesture.middleTap.motion == "tap")
}
