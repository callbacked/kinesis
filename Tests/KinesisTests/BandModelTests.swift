import AppKit
import Combine
import Foundation
import Testing
import KinesisCore
@testable import Kinesis

@MainActor final class RecordedConnection: BandConnection {
    private var onEvent: ((BandEvent) -> Void)?
    private var onEnd: ((Error?) -> Void)?
    var rawEMGMode = false
    var rawWriteError: Error?
    private(set) var motionRequests: [MotionStreams] = []
    private(set) var motionRestarts = 0
    func setMotionStreams(_ streams: MotionStreams) { motionRequests.append(streams) }
    func restartMotionStreams() { motionRestarts += 1 }
    func setRawEMGEnabled(_ enabled: Bool) throws {
        rawEMGMode = enabled
        if let rawWriteError { throw rawWriteError }
    }
    private(set) var requests: [String] = []
    var starts: Int { requests.count }
    private(set) var stops = 0
    var finishesOnStop = true
    private(set) var requestedHands: [BandHand] = []
    private(set) var ceremonyCompletions: [CeremonyCompletion] = []
    var handWriteError: Error?
    func setHandedness(_ hand: BandHand) throws {
        if let handWriteError { throw handWriteError }
        requestedHands.append(hand)
    }
    func resumeCeremony(_ completion: CeremonyCompletion) throws {
        ceremonyCompletions.append(completion)
    }
    func start(_ operation: BandOperation, onEvent: @escaping (BandEvent) -> Void,
               onEnd: @escaping (Error?) -> Void) throws {
        guard self.onEnd == nil else { throw KinesisError(message: "A band operation is already running") }
        switch operation {
        case .scan: requests.append("scan")
        case .connect(let address): requests.append("connect \(address)")
        case .enroll(let address): requests.append("enroll \(address ?? "scan")")
        }
        self.onEvent = onEvent
        self.onEnd = onEnd
    }
    func stop() {
        stops += 1
        if finishesOnStop { finish() }
    }
    func finish(error: Error? = nil) {
        let completion = onEnd
        onEnd = nil
        onEvent = nil
        completion?(error)
    }
    func send(_ payload: BandEvent.Payload, at time: Double = 100) {
        onEvent?(BandEvent(payload, at: time))
    }
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    // Counts its own turns, not the wall clock. When the machine stalls, the work this waits
    // for stalls with it, and a wall-clock deadline then expires before that work could run.
    var turns = 0
    while !condition(), turns < 2000 {
        try await Task.sleep(for: .milliseconds(5))
        turns += 1
    }
    #expect(condition())
}

@Test @MainActor func handSelectionUsesTheBandSettingAndPausesControlsUntilTheUserResumes() async throws {
    let defaults = MemoryDefaults()
    defaults.set("right", forKey: "bandHand")
    defaults.set(true, forKey: "setupCompleted")
    let connection = RecordedConnection()
    let controls = RecordingControls()
    let model = BandModel(defaults: defaults, connection: connection, controls: controls, sessionStore: SavedSessionStore(), clock: { 100 })
    model.selectedAddress = "test-band"
    model.connect()
    connection.send(.connected)
    connection.send(.heartbeat)
    model.selectHand(.left)
    #expect(connection.requestedHands.isEmpty)
    // The device wins over a stale illustration preference from a previous launch.
    connection.send(.handedness(.left))
    #expect(model.bandHand == .left && model.canChangeHand)
    #expect(defaults.string(forKey: "bandHand") == "left")
    model.toggleControls()
    #expect(model.controlsEnabled)
    model.selectHand(.right)
    #expect(connection.requestedHands == [.right])
    #expect(model.bandHand == .left && model.pendingHand == .right)
    #expect(!model.controlsEnabled && !model.canChangeHand)
    model.toggleControls()
    #expect(!model.controlsEnabled)
    connection.send(.handedness(.right))
    #expect(model.bandHand == .right && model.pendingHand == nil && model.canChangeHand)
    #expect(!model.controlsEnabled)
    #expect(defaults.string(forKey: "bandHand") == "right")
    model.selectHand(.left)
    connection.send(.handednessFailure("Rejected"))
    #expect(model.bandHand == .right && model.pendingHand == nil && !model.canChangeHand)
    #expect(model.handSettingError == "Rejected")
    #expect(defaults.string(forKey: "bandHand") == "right")
    connection.send(.handedness(.right))
    connection.handWriteError = KinesisError(message: "Write failed")
    model.selectHand(.left)
    #expect(model.bandHand == .right && model.pendingHand == nil && !model.canChangeHand)
    #expect(!model.handConfirmed && model.handSettingError == "Write failed")
    #expect(defaults.string(forKey: "bandHand") == "right")
    await model.shutdown()
}

@Test @MainActor func pausedSetupReceivesDialMovementThroughTheConnection() async throws {
    let defaults = MemoryDefaults()
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, sessionStore: SavedSessionStore(), clock: { 100 })
    model.selectedAddress = "test-band"
    var movement: [Double] = []
    let subscription = model.dialTurns.sink { movement.append($0) }
    model.connect()
    connection.send(.handedness(.right))
    connection.send(.connected)
    connection.send(.heartbeat)
    connection.send(.dialState(true))
    connection.send(.dialTurn(4.0))
    try await waitUntil { movement == [4.0] }
    #expect(model.showingSetup)
    #expect(!model.controlsEnabled)
    #expect(model.live)
    #expect(model.dialEngaged)
    #expect(movement == [4.0])
    connection.send(.dialState(false))
    connection.send(.dialTurn(20.0))
    connection.send(.battery(65))
    try await waitUntil { model.battery == 65 }
    #expect(!model.dialEngaged)
    #expect(movement == [4.0])
    subscription.cancel()
    await model.shutdown()
}

@Test @MainActor func gestureTotalSurvivesRelaunchWithoutCountingDuplicateOrStaleInput() async throws {
    let defaults = MemoryDefaults()
    defaults.set(73, forKey: "totalGestureCount")
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, sessionStore: SavedSessionStore(), clock: { 100 })
    model.selectedAddress = "test-band"
    model.connect()
    let swipe = BandGesture(sequence: 42, timestampUs: 12345, finger: "thumb", action: "left", receivedAt: 100)
    connection.send(.gesture(swipe))
    connection.send(.gesture(swipe))
    let stale = BandGesture(sequence: 43, timestampUs: 12346, finger: "thumb", action: "left", receivedAt: 100 - 5)
    connection.send(.gesture(stale), at: stale.receivedAt)
    connection.send(.battery(65))
    try await waitUntil { model.battery == 65 }
    #expect(model.totalGestureCount == 74)
    #expect(model.gestureCount == 1)
    #expect(defaults.integer(forKey: "totalGestureCount") == 74)
    await model.shutdown()
    let reopened = BandModel(defaults: defaults, connection: RecordedConnection(), sessionStore: SavedSessionStore(), clock: { 100 })
    #expect(reopened.totalGestureCount == 74)
    #expect(reopened.gestureCount == 0)
    await reopened.shutdown()
}

@Test @MainActor func automaticStartRequiresOptInAndACompletedSetup() async throws {
    let defaults = MemoryDefaults()
    let band = ["address": "test-band", "name": "Test Band"]
    defaults.set(try JSONSerialization.data(withJSONObject: band), forKey: "band")
    defaults.set(true, forKey: "setupCompleted")
    let paused = BandModel(defaults: defaults, connection: RecordedConnection(), sessionStore: SavedSessionStore(), clock: { 100 })
    paused.startAutomatically()
    #expect(!paused.wantsConnection)
    await paused.shutdown()

    defaults.set(true, forKey: "startsAutomatically")
    defaults.set(false, forKey: "setupCompleted")
    let setup = BandModel(defaults: defaults, connection: RecordedConnection(), sessionStore: SavedSessionStore(), clock: { 100 })
    setup.startAutomatically()
    #expect(!setup.wantsConnection)
    #expect(!setup.controlsEnabled)
    await setup.shutdown()

    defaults.set(true, forKey: "setupCompleted")
    let connection = RecordedConnection()
    let automatic = BandModel(defaults: defaults, connection: connection, sessionStore: SavedSessionStore(), clock: { 100 })
    automatic.startAutomatically()
    #expect(automatic.wantsConnection)
    connection.send(.connected)
    connection.send(.heartbeat)
    try await waitUntil { automatic.live }
    #expect(automatic.live)
    automatic.beginSetup()
    connection.send(.heartbeat)
    connection.send(.battery(65))
    try await waitUntil { automatic.battery == 65 }
    #expect(!automatic.controlsEnabled)
    await automatic.shutdown()
}

@Test @MainActor func reconnectClearsTheHeldDialAndAcceptsOnlyFreshGestures() async throws {
    let defaults = MemoryDefaults()
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, sessionStore: SavedSessionStore(), clock: { 100 })
    model.selectedAddress = "test-band"
    var movement: [Double] = []
    let subscription = model.dialTurns.sink { movement.append($0) }
    defer { subscription.cancel() }
    model.connect()
    connection.send(.handedness(.right))
    connection.send(.heartbeat)
    connection.send(.dialState(true))
    connection.send(.dialTurn(3))
    try await waitUntil { movement == [3] }
    connection.finish(error: KinesisError(message: "Disconnected test band"))
    try await waitUntil { connection.starts == 2 }
    #expect(!model.live && !model.dialEngaged && !model.controlsEnabled)
    connection.send(.handedness(.right))
    connection.send(.heartbeat)
    connection.send(.dialTurn(20))
    let stale = BandGesture(sequence: 1, timestampUs: 1000, finger: "thumb", action: "left", receivedAt: 95)
    connection.send(.gesture(stale), at: 95)
    let fresh = BandGesture(sequence: 1, timestampUs: 1000, finger: "thumb", action: "left", receivedAt: 100)
    connection.send(.gesture(fresh))
    connection.send(.battery(65))
    try await waitUntil { model.battery == 65 }
    #expect(model.live)
    #expect(movement == [3])
    #expect(model.gestureCount == 1 && model.totalGestureCount == 1)
    #expect(model.lastDirection == .left)
    #expect(!model.controlsEnabled)
    await model.shutdown()
}

@MainActor private final class RecordingControls: MacControls {
    var trusted = true
    var failure: Error?
    private(set) var actions: [MacAction] = []
    private(set) var clicks: [(CGMouseButton, Int)] = []
    /// The pointer, which the trackpad can move too.
    var location = CGPoint(x: 800, y: 500)
    let displaySize = CGSize(width: 1600, height: 1000)
    private(set) var cursorMoves: [CGPoint] = []
    var cursorLocation: CGPoint? { location }
    private(set) var drags: [CGMouseButton] = []
    func moveCursor(to point: CGPoint, dragging button: CGMouseButton?) throws -> CGPoint {
        if let failure { throw failure }
        cursorMoves.append(point)
        if let button { drags.append(button) }
        location = point
        return point
    }
    /// Presses only, as (button, click count), where each landed, and every press and release in order.
    private(set) var clickPoints: [CGPoint?] = []
    private(set) var buttonEvents: [(button: CGMouseButton, down: Bool)] = []
    func mouseButton(_ button: CGMouseButton, down: Bool, clicks: Int, at point: CGPoint?) throws {
        if let failure { throw failure }
        buttonEvents.append((button, down))
        if down {
            self.clicks.append((button, clicks))
            clickPoints.append(point)
        }
        if let point { location = point }
    }
    private(set) var accessRequests = 0
    func requestAccess() { accessRequests += 1 }
    func post(_ action: MacAction) throws {
        if let failure { throw failure }
        actions.append(action)
    }
}

@MainActor private final class TestClock { var now = 100.0 }

/// A live band with Mac controls on, and a way to hold the forearm at an aim.
/// 1600 points across 40 degrees: each degree moves the pointer 40 points.
@MainActor private final class CursorRig {
    let connection = RecordedConnection()
    let controls = RecordingControls()
    let clock = TestClock()
    let model: BandModel
    private(set) var stamp: UInt64 = 0

    init(hand: BandHand = .right) {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: "setupCompleted")
        // 40 points a degree both ways, and no slant.
        defaults.set(40.0, forKey: "pointerSpeed")
        defaults.set(try? JSONEncoder().encode(PointerReach(degreesAcrossWidth: 40, degreesAcrossHeight: 25)),
                     forKey: "pointerReach.cursor-test-band.right")
        let clock = clock
        model = BandModel(defaults: defaults, connection: connection, controls: controls,
                          sessionStore: SavedSessionStore(), clock: { clock.now }, cursorPacing: 0, cursorFrames: .timer(1.0 / 60))
        model.selectedAddress = "cursor-test-band"
        model.developerMode = true
        // The smallest dead zone, 0.1°: 4 points. The dead zone has its own tests.
        model.cursorSteadiness = 0
        model.connect()
        connection.send(.connected, at: clock.now)
        connection.send(.heartbeat, at: clock.now)
        connection.send(.handedness(hand), at: clock.now)
        model.toggleControls()
    }

    /// Turns the arm steadily to an aim over `seconds`, then holds it briefly.
    func sweep(to azimuth: Double, _ elevation: Double = 0, from start: (Double, Double), seconds: Double = 0.4,
               settle: Double = 0.2) async throws {
        let steps = Int(seconds * 128)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            clock.now += 1.0 / 128
            stamp += 7_812
            // The gyro turns at the sweep's rate, around an axis other than the forearm.
            let rate = hypot(azimuth - start.0, elevation - start.1) / seconds / AirPointer.gyroScale
            connection.send(.gyro(timestamp: stamp, values: SIMD3(rate, 0, 0)), at: clock.now)
            connection.send(.orientation(timestamp: stamp, values: bandQuaternion(azimuth: start.0 + (azimuth - start.0) * t,
                                                                               elevation: start.1 + (elevation - start.1) * t)),
                            at: clock.now)
            // Let display frames pass as the arm moves, so the pointer follows along.
            if step % 8 == 0 { try await Task.sleep(for: .milliseconds(17)) }
        }
        if settle > 0 { try await aim(azimuth, elevation, for: settle) }
    }

    /// Holds an aim at 128 Hz, then lets a few display frames pass.
    func aim(_ azimuth: Double, _ elevation: Double = 0, twist: Double = 0, for seconds: Double = 0.6) async throws {
        let end = clock.now + seconds
        while clock.now < end {
            clock.now += 1.0 / 128
            stamp += 7_812
            connection.send(.gyro(timestamp: stamp, values: .zero), at: clock.now)
            connection.send(.orientation(timestamp: stamp, values: bandQuaternion(azimuth: azimuth, elevation: elevation, twist: twist)),
                            at: clock.now)
        }
        try await Task.sleep(for: .milliseconds(60))
    }

    /// Nothing arrives for a while. In a dropout the band's clock moves on too;
    /// in a backlog only the Mac's does, and what arrives next is that late.
    func silence(_ seconds: Double, backlog: Bool = false) {
        clock.now += seconds
        if !backlog { stamp += UInt64(seconds * 1e6) }
    }

    func gesture(_ finger: String, _ action: String, derived: String = "unknown", synthetic: Bool = false) {
        connection.send(.gesture(BandGesture(sequence: 1, timestampUs: 1, finger: finger, action: action,
                                             derivedAction: derived, synthetic: synthetic, receivedAt: clock.now)),
                        at: clock.now)
    }

    var pointer: CGPoint { controls.location }
}

private func near(_ point: CGPoint, _ x: Double, _ y: Double) -> Bool { abs(point.x - x) < 5 && abs(point.y - y) < 5 }

@Test @MainActor func airCursorFollowsTheForearmAndOwnsPinchesUntilTurnedOff() async throws {
    let rig = CursorRig()
    let model = rig.model
    try await rig.aim(0)
    model.setAirCursorEnabled(true)
    #expect(model.airCursorEnabled)
    // Turning on moves nothing, and a still arm moves nothing.
    try await rig.aim(0)
    try await rig.aim(0)
    #expect(rig.controls.cursorMoves.isEmpty)
    // Left moves it left, and up moves it up.
    try await rig.sweep(to: 10, from: (0, 0))
    #expect(rig.pointer.x < 700 && abs(rig.pointer.y - 500) < 5)
    let afterLeft = rig.pointer
    try await rig.sweep(to: 10, 5, from: (10, 0))
    #expect(rig.pointer.y < afterLeft.y - 50 && abs(rig.pointer.x - afterLeft.x) < 5)
    // Twisting the wrist in place moves nothing.
    let moves = rig.controls.cursorMoves.count
    try await rig.aim(10, 5, twist: 60)
    #expect(rig.controls.cursorMoves.count == moves)
    // Pinches click once each; the band's other reports of the same contact do not.
    rig.gesture("index", "press")
    rig.gesture("index", "unknown", derived: "buttonPress")
    rig.gesture("index", "press", derived: "buttonHold")
    rig.gesture("index", "release")
    rig.gesture("index", "tap")
    rig.gesture("index", "doubletap")
    rig.gesture("middle", "press")
    rig.gesture("middle", "release")
    rig.gesture("middle", "tap")
    rig.gesture("index", "press", synthetic: true)
    #expect(rig.controls.clicks.map { $0.0 } == [.left, .right])
    #expect(rig.controls.clicks.allSatisfy { $0.1 == 1 })
    #expect(model.totalGestureCount == 2)
    // The dial stays off, and thumb swipes keep their shortcuts.
    rig.connection.send(.dialState(true), at: rig.clock.now)
    rig.connection.send(.dialTurn(20), at: rig.clock.now)
    rig.gesture("thumb", "left")
    #expect(rig.controls.actions == [.previousDesktop] && !model.dialEngaged)
    model.setAirCursorEnabled(false)
    let stopped = rig.controls.cursorMoves.count
    try await rig.sweep(to: 30, from: (10, 5))
    #expect(rig.controls.cursorMoves.count == stopped)
    // Pausing, leaving developer mode, and disconnecting each turn it off.
    model.setAirCursorEnabled(true)
    model.pause()
    #expect(!model.airCursorEnabled)
    model.toggleControls()
    model.setAirCursorEnabled(true)
    model.developerMode = false
    #expect(!model.airCursorEnabled)
    model.developerMode = true
    model.setAirCursorEnabled(true)
    rig.connection.send(.disconnected, at: rig.clock.now)
    #expect(!model.airCursorEnabled)
    await model.shutdown()
}

@Test @MainActor func slowAimingIsFinerThanAQuickFlickOverTheSameTurn() async throws {
    func travel(seconds: Double) async throws -> Double {
        let rig = CursorRig()
        try await rig.aim(0)
        rig.model.setAirCursorEnabled(true)
        try await rig.aim(0)
        try await rig.sweep(to: 6, from: (0, 0), seconds: seconds)
        await rig.model.shutdown()
        return 800 - rig.pointer.x
    }
    let slow = try await travel(seconds: 3), quick = try await travel(seconds: 0.12)
    // Six degrees at 40 points a degree is 240 points at the base scale.
    #expect(slow > 0 && slow < 160)
    #expect(quick > slow * 2)
}

@Test @MainActor func theTrackpadAndTheArmBothMoveTheSamePointer() async throws {
    let rig = CursorRig()
    try await rig.aim(0)
    rig.model.setAirCursorEnabled(true)
    try await rig.aim(0)
    rig.controls.location = CGPoint(x: 100, y: 100)
    try await rig.aim(0)
    #expect(rig.pointer == CGPoint(x: 100, y: 100))
    try await rig.sweep(to: -5, from: (0, 0))
    #expect(rig.pointer.x > 110 && abs(rig.pointer.y - 100) < 5)
    await rig.model.shutdown()
}

@Test(arguments: ["index", "middle"])
@MainActor func aPinchNeverStopsOrMovesThePointer(finger: String) async throws {
    let rig = CursorRig()
    try await rig.aim(0)
    rig.model.setAirCursorEnabled(true)
    try await rig.aim(0)
    try await rig.sweep(to: 5, from: (0, 0))
    // On target, and still a moment, as before a shot.
    try await rig.aim(5, for: 0.3)
    let aimed = rig.pointer
    // The pinch nudges the arm 0.3° over 0.15 s, as measured, and the band reports it after.
    try await rig.sweep(to: 5.3, from: (5, 0), seconds: 0.15, settle: 0)
    try await Task.sleep(for: .milliseconds(40))
    let twitched = rig.pointer
    #expect(twitched.x < aimed.x - 2)
    rig.gesture(finger, "press")
    #expect(rig.controls.clicks.map { $0.0 } == [finger == "index" ? .left : .right])
    // The press lands where the pointer is. Pressing where it aimed before the nudge
    // made the pointer jump back, and people saw it snap.
    let click = try #require(rig.controls.clickPoints.last ?? nil)
    #expect(click == twitched)
    // The pointer keeps following the arm through the pinch and its release.
    let moves = rig.controls.cursorMoves.count
    try await rig.sweep(to: 10, from: (5.3, 0))
    rig.gesture(finger, "release")
    try await rig.sweep(to: 12, from: (10, 0))
    #expect(rig.controls.cursorMoves.count > moves + 2 && rig.pointer.x < click.x - 50)
    await rig.model.shutdown()
}

@Test @MainActor func aPinchWhileMovingPressesWhereThePointerIsWithoutASnapBack() async throws {
    let rig = CursorRig()
    try await rig.aim(0)
    rig.model.setAirCursorEnabled(true)
    try await rig.aim(0)
    // Mid-sweep, the pinch arrives: the press must land where the pointer is now.
    try await rig.sweep(to: 6, from: (0, 0), seconds: 0.4, settle: 0)
    rig.gesture("index", "press")
    let press = try #require(rig.controls.clickPoints.last ?? nil)
    #expect(press.x < 750 && rig.pointer == press)
    // It keeps tracking: nothing is held back after the pinch.
    try await rig.sweep(to: 9, from: (6, 0), seconds: 0.2, settle: 0)
    try await Task.sleep(for: .milliseconds(40))
    #expect(rig.pointer.x < press.x - 30)
    await rig.model.shutdown()
}

@Test @MainActor func slowingDownIntoAPinchClicksInPlaceAndIgnoresTheSettle() async throws {
    let rig = CursorRig()
    try await rig.aim(0)
    rig.model.setAirCursorEnabled(true)
    try await rig.aim(0)
    // Quick toward the target, then slowing onto it, then the pinch: as measured.
    try await rig.sweep(to: 6, from: (0, 0), seconds: 0.3, settle: 0)
    try await rig.sweep(to: 7, from: (6, 0), seconds: 0.15, settle: 0)
    rig.gesture("index", "press")
    // The movement from before the pinch lands first, and the press where it ends.
    let press = try #require(rig.controls.clickPoints.last ?? nil)
    #expect(press.x < 750 && rig.pointer == press)
    // The arm drifts on half a degree as it settles. The pointer stays on the click.
    try await rig.sweep(to: 7.5, from: (7, 0), seconds: 0.2, settle: 0)
    try await Task.sleep(for: .milliseconds(40))
    #expect(abs(rig.pointer.x - press.x) < 3)
    await rig.model.shutdown()
}

@Test @MainActor func pinchMoveReleaseDragsAndTwoQuickPinchesDoubleClick() async throws {
    let rig = CursorRig()
    let model = rig.model
    try await rig.aim(0)
    model.setAirCursorEnabled(true)
    try await rig.aim(0)
    // Pinch, move, let go: a drag.
    rig.gesture("index", "press")
    try await rig.sweep(to: 8, from: (0, 0))
    rig.gesture("index", "release")
    #expect(rig.controls.buttonEvents.map(\.down) == [true, false])
    #expect(!rig.controls.drags.isEmpty && rig.controls.drags.allSatisfy { $0 == .left })
    #expect(rig.pointer.x < 700)
    // Two quick pinches in place: the second is a double-click.
    try await rig.aim(8, for: 0.3)
    rig.gesture("index", "press")
    rig.gesture("index", "release")
    rig.clock.now += 0.2
    rig.gesture("index", "press")
    rig.gesture("index", "release")
    #expect(rig.controls.clicks.suffix(2).map(\.1) == [1, 2])
    // A button is never left down: turning the cursor off lets go of it.
    rig.gesture("middle", "press")
    #expect(rig.controls.buttonEvents.last?.down == true)
    model.setAirCursorEnabled(false)
    #expect(rig.controls.buttonEvents.last.map { $0.down == false && $0.button == .right } == true)
    await model.shutdown()
}

@Test @MainActor func aLateReleaseStillLetsGoOfTheButton() async throws {
    let rig = CursorRig()
    try await rig.aim(0)
    rig.model.setAirCursorEnabled(true)
    try await rig.aim(0)
    rig.gesture("index", "press")
    // The link backs up while the pinch is held; the release arrives late.
    rig.silence(2, backlog: true)
    try await rig.aim(0, for: 0.2)
    rig.gesture("index", "release")
    #expect(rig.controls.buttonEvents.map(\.down) == [true, false])
    await rig.model.shutdown()
}

@Test @MainActor func optionParksThePointerWhileTheArmMoves() async throws {
    let rig = CursorRig()
    try await rig.aim(0)
    rig.model.setAirCursorEnabled(true)
    try await rig.aim(0)
    rig.model.setCursorRepositioning(true)
    try await rig.sweep(to: 25, -10, from: (0, 0))
    rig.gesture("index", "press")
    #expect(rig.model.cursorRepositioning && rig.controls.cursorMoves.isEmpty && rig.controls.clicks.isEmpty)
    rig.model.setCursorRepositioning(false)
    try await rig.aim(25, -10, for: 0.3)
    #expect(rig.controls.cursorMoves.isEmpty)
    try await rig.sweep(to: 20, -10, from: (25, -10))
    #expect(rig.pointer.x > 810)
    rig.model.setCursorRepositioning(true)
    rig.model.pause()
    #expect(!rig.model.cursorRepositioning && !rig.model.airCursorEnabled)
    await rig.model.shutdown()
}

@Test @MainActor func aGapInTheOrientationStreamNeverMakesThePointerJump() async throws {
    let rig = CursorRig()
    try await rig.aim(0)
    rig.model.setAirCursorEnabled(true)
    try await rig.aim(0)
    rig.silence(1)
    try await rig.aim(30)
    #expect(rig.controls.cursorMoves.isEmpty)
    try await rig.sweep(to: 26, from: (30, 0))
    #expect(rig.pointer.x > 810)
    await rig.model.shutdown()
}

@Test @MainActor func calibrationTakesTheAimBeforeEachPinchAndNeverClicks() async throws {
    let rig = CursorRig()
    let model = rig.model
    #expect(model.pointerCalibrated && model.pointerReach.degreesAcrossWidth == 40)
    model.resetPointerReach()
    #expect(!model.pointerCalibrated && model.pointerReach == .standard(for: .right))
    try await rig.aim(0)
    model.beginPointerCalibration()
    #expect(model.pointerCalibration?.step == .left)
    // Aim, pinch, and let the pinch nudge the arm two degrees before letting go.
    for (azimuth, elevation) in [(14.0, 10.0), (-14.0, 10.0), (0.0, 17.0), (0.0, 3.0)] {
        try await rig.aim(azimuth, elevation, for: 0.5)
        rig.gesture("index", "press")
        rig.gesture("index", "press", derived: "buttonHold")
        try await rig.aim(azimuth + 2, elevation - 2, for: 0.2)
        rig.gesture("index", "release")
    }
    // 28° between left and right is 70 % of the width: 40° across. 14° is 70 % of 20° up and down.
    #expect(model.pointerCalibration == nil && model.pointerCalibrated)
    #expect(abs(model.pointerReach.degreesAcrossWidth - 40) < 0.5 && abs(model.pointerReach.degreesAcrossHeight - 20) < 0.5)
    // Measured across this 1600-point display, 40° sets 40 points a degree.
    #expect(abs(model.cursorSpeed - 40) < 0.5)
    #expect(rig.controls.clicks.isEmpty && rig.controls.cursorMoves.isEmpty && rig.controls.actions.isEmpty)
    // Escape stops a calibration the same way it stops the cursor.
    model.beginPointerCalibration()
    model.setAirCursorEnabled(false)
    #expect(model.pointerCalibration == nil && abs(model.pointerReach.degreesAcrossWidth - 40) < 0.5)
    await model.shutdown()
}

@Test @MainActor func orientationStreamsOnlyWhileTheCursorCalibrationOrReadingsNeedIt() async throws {
    let rig = CursorRig()
    let model = rig.model
    let orientationOnly = { rig.connection.motionRequests.last?.orientation }
    #expect(orientationOnly() == false && rig.connection.motionRequests.allSatisfy(\.gyro))
    try await rig.aim(0)
    model.setAirCursorEnabled(true)
    #expect(orientationOnly() == true)
    model.setAirCursorEnabled(false)
    #expect(orientationOnly() == false)
    model.beginPointerCalibration()
    #expect(orientationOnly() == true)
    model.cancelPointerCalibration()
    #expect(orientationOnly() == false)
    model.setReadingsVisible(true)
    #expect(orientationOnly() == true)
    model.setReadingsVisible(false)
    #expect(orientationOnly() == false)
    await model.shutdown()
}

@Test @MainActor func dataThatArrivesLateIsNeverActedOn() async throws {
    let rig = CursorRig()
    let model = rig.model
    try await rig.aim(0)
    model.setAirCursorEnabled(true)
    try await rig.aim(0)
    // The link backs up: everything from here arrives two seconds after it happened.
    rig.silence(2, backlog: true)
    try await rig.aim(10, for: 1.2)
    rig.gesture("index", "press")
    #expect(rig.controls.cursorMoves.isEmpty && rig.controls.clicks.isEmpty)
    #expect(model.linkCongested)
    #expect(rig.connection.motionRestarts == 1)
    // Without the cursor, a late swipe sends no shortcut either.
    model.setAirCursorEnabled(false)
    rig.gesture("thumb", "left")
    #expect(rig.controls.actions.isEmpty)
    await model.shutdown()
}

@Test func arrivalDelayFollowsTheBandClockAndItsRestarts() {
    var delay = ArrivalDelay()
    // Transit time varies around 20 ms: that is not delay.
    #expect(delay.measure(band: 10, host: 1000.020) == 0)
    #expect(abs(delay.measure(band: 10.01, host: 1000.045) - 0.015) < 1e-4)
    // Four seconds of band time reach the Mac six seconds later.
    #expect(abs(delay.measure(band: 14, host: 1006.020) - 2) < 0.01)
    // The band restarted its clock: a fresh baseline, not a negative delay.
    #expect(delay.measure(band: 0.5, host: 1007) == 0)
    #expect(abs(delay.measure(band: 0.6, host: 1007.1)) < 0.001)
}

@Test @MainActor func afterDisconnectTheButtonSaysDisconnectingNotConnecting() async {
    let connection = RecordedConnection()
    connection.finishesOnStop = false
    let model = BandModel(defaults: MemoryDefaults(), connection: connection, controls: RecordingControls(),
                          sessionStore: SavedSessionStore(), clock: { 100 })
    model.selectedAddress = "test-band"
    model.connect()
    #expect(model.nextAction == .connecting)
    model.disconnect()
    #expect(model.nextAction == .disconnecting && model.nextAction.waits)
    connection.finish()
    #expect(!model.nextAction.waits)
    await model.shutdown()
}

@Test @MainActor func airCursorRejectsStaleClicksAndStopsWhenPermissionIsLost() async throws {
    let rig = CursorRig(hand: .left)
    try await rig.aim(0)
    rig.model.setAirCursorEnabled(true)
    rig.connection.send(.gesture(BandGesture(sequence: 1, timestampUs: 1, finger: "index", action: "press",
                                             receivedAt: rig.clock.now - 0.2)), at: rig.clock.now - 0.2)
    #expect(rig.controls.clicks.isEmpty)
    rig.controls.trusted = false
    try await rig.aim(10)
    try await waitUntil { !rig.model.controlsEnabled }
    #expect(!rig.model.airCursorEnabled && rig.controls.cursorMoves.isEmpty)
    await rig.model.shutdown()
}

@Test(arguments: [BandHand.right, .left], [DialTarget.volume, .brightness])
@MainActor func eachHandUsesTheSameDialDirectionForPracticeAndMacControls(hand: BandHand, target: DialTarget) async throws {
    let defaults = MemoryDefaults()
    let connection = RecordedConnection()
    let controls = RecordingControls()
    var now = 100.0
    let model = BandModel(defaults: defaults, connection: connection, controls: controls, sessionStore: SavedSessionStore(), clock: { now })
    model.selectedAddress = "test-band"
    model.dialTarget = target
    var practice: [Double] = []
    let subscription = model.dialTurns.sink { practice.append($0) }
    defer { subscription.cancel() }
    model.connect()
    connection.send(.connected)
    connection.send(.heartbeat)
    connection.send(.dialState(true))
    connection.send(.dialTurn(2))
    #expect(practice.isEmpty && controls.actions.isEmpty)
    connection.send(.handedness(hand))
    // Physical left-wrist testing found the gyro sign opposite to the right wrist.
    let increaseRotation = hand == .left ? -2.0 : 2.0
    connection.send(.dialTurn(increaseRotation))
    #expect(practice == [2])
    #expect(controls.actions.isEmpty)
    model.finishSetup(enableControls: true)
    now += 0.1
    connection.send(.dialState(false), at: now)
    connection.send(.dialState(true), at: now)
    connection.send(.dialTurn(increaseRotation), at: now)
    now += 0.1
    connection.send(.dialTurn(-increaseRotation), at: now)
    #expect(practice == [2, 2, -2])
    #expect(controls.actions == [target.action(increasing: true), target.action(increasing: false)])
    connection.send(.handednessFailure("Couldn't confirm hand"), at: now)
    now += 0.1
    connection.send(.dialTurn(20), at: now)
    #expect(practice == [2, 2, -2])
    #expect(controls.actions.count == 2)
    await model.shutdown()
}

@Test @MainActor func controlDispatchRequiresFreshInputAndStopsOnPauseOrPermissionLoss() async throws {
    let defaults = MemoryDefaults()
    defaults.set(true, forKey: "setupCompleted")
    let connection = RecordedConnection()
    let controls = RecordingControls()
    var now = 100.0
    let model = BandModel(defaults: defaults, connection: connection, controls: controls, sessionStore: SavedSessionStore(), clock: { now })
    model.selectedAddress = "test-band"
    model.connect()
    connection.send(.connected)
    connection.send(.heartbeat)
    func swipe(sequence: UInt64, at time: Double) {
        connection.send(.gesture(BandGesture(sequence: sequence, timestampUs: sequence * 1000,
                                             finger: "thumb", action: "up", receivedAt: time)), at: time)
    }
    swipe(sequence: 1, at: now)
    #expect(controls.actions.isEmpty)
    now = 101
    model.toggleControls()
    swipe(sequence: 2, at: 100.9)
    #expect(controls.actions.isEmpty)
    swipe(sequence: 3, at: now)
    swipe(sequence: 3, at: now)
    #expect(controls.actions == [.missionControl])
    now = 102
    model.mappings[.up] = .nextTab
    swipe(sequence: 4, at: now)
    #expect(controls.actions == [.missionControl, .nextTab])
    controls.trusted = false
    now = 103
    swipe(sequence: 5, at: now)
    #expect(controls.actions == [.missionControl, .nextTab])
    model.pause()
    controls.trusted = true
    now = 104
    swipe(sequence: 6, at: now)
    #expect(controls.actions == [.missionControl, .nextTab])
    model.toggleControls()
    controls.failure = KinesisError(message: "Test output unavailable")
    now = 105
    swipe(sequence: 7, at: now)
    #expect(!model.controlsEnabled)
    #expect(model.error == "Test output unavailable")
    #expect(controls.actions == [.missionControl, .nextTab])
    await model.shutdown()
}

@Test @MainActor func dialNeedsANewPinchAfterEnablingOrChangingSettings() async throws {
    let defaults = MemoryDefaults()
    defaults.set(true, forKey: "setupCompleted")
    let connection = RecordedConnection()
    let controls = RecordingControls()
    var now = 100.0
    let model = BandModel(defaults: defaults, connection: connection, controls: controls, sessionStore: SavedSessionStore(), clock: { now })
    model.selectedAddress = "test-band"
    model.connect()
    connection.send(.handedness(.right))
    connection.send(.connected)
    connection.send(.heartbeat)
    connection.send(.dialState(true))
    model.toggleControls()
    connection.send(.dialTurn(20))
    #expect(controls.actions.isEmpty)
    func pinchAndTurn() {
        now += 1
        connection.send(.dialState(false), at: now)
        connection.send(.dialState(true), at: now)
        connection.send(.dialTurn(2), at: now)
    }
    pinchAndTurn()
    #expect(controls.actions == [.volumeUp])
    model.dialTarget = .brightness
    now += 1
    connection.send(.dialTurn(20), at: now)
    #expect(controls.actions == [.volumeUp])
    pinchAndTurn()
    #expect(controls.actions == [.volumeUp, .brightnessUp])
    model.dialSensitivity = 2
    now += 1
    connection.send(.dialTurn(20), at: now)
    #expect(controls.actions == [.volumeUp, .brightnessUp])
    pinchAndTurn()
    #expect(controls.actions == [.volumeUp, .brightnessUp, .brightnessUp])
    model.beginSetup()
    pinchAndTurn()
    #expect(!model.controlsEnabled)
    #expect(controls.actions == [.volumeUp, .brightnessUp, .brightnessUp])
    await model.shutdown()
}

@Test @MainActor func automaticControlsWaitForAccessAndManualPausePersistsAcrossReconnect() async throws {
    let defaults = MemoryDefaults()
    defaults.set(true, forKey: "setupCompleted")
    defaults.set(true, forKey: "startsAutomatically")
    defaults.set(try JSONEncoder().encode(BandDevice(address: "test-band", name: "Test Band")), forKey: "band")
    let connection = RecordedConnection()
    let controls = RecordingControls()
    controls.trusted = false
    let model = BandModel(defaults: defaults, connection: connection, controls: controls, sessionStore: SavedSessionStore(), clock: { 100 })
    model.startAutomatically()
    #expect(!model.controlsEnabled)
    connection.send(.connected)
    connection.send(.heartbeat)
    #expect(model.live && !model.controlsEnabled)
    #expect(controls.accessRequests == 0)
    controls.trusted = true
    connection.send(.heartbeat)
    #expect(model.controlsEnabled)
    model.pause()
    connection.finish(error: KinesisError(message: "Test connection lost"))
    try await waitUntil { connection.starts == 2 }
    connection.send(.connected)
    connection.send(.heartbeat)
    #expect(model.live && !model.controlsEnabled)
    #expect(controls.actions.isEmpty)
    await model.shutdown()
}

@Test @MainActor func invalidBandSelectionDoesNotCreateANativeConnection() throws {
    let connection = NativeBandConnection()
    for _ in 0..<2 {
        do {
            try connection.start(.connect("not-a-device"), onEvent: { _ in
                Issue.record("Invalid selection emitted a band event")
            }, onEnd: { _ in
                Issue.record("Invalid selection started a connection")
            })
            Issue.record("Invalid device identifier was accepted")
        } catch {
            #expect(error.localizedDescription == "Choose a band before connecting")
        }
    }
}

@Test @MainActor func sleepAndWakeReconnectWithoutRestoringAHeldDial() async throws {
    let defaults = MemoryDefaults()
    defaults.set(true, forKey: "setupCompleted")
    let connection = RecordedConnection()
    let controls = RecordingControls()
    let notifications = NotificationCenter()
    var now = 100.0
    let model = BandModel(defaults: defaults, connection: connection, controls: controls,
                          workspaceNotifications: notifications, sessionStore: SavedSessionStore(), clock: { now })
    model.selectedAddress = "test-band"
    model.connect()
    connection.send(.handedness(.right))
    connection.send(.connected)
    connection.send(.heartbeat)
    model.toggleControls()
    connection.send(.dialState(true))
    connection.send(.dialTurn(2))
    #expect(controls.actions == [.volumeUp])
    notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
    try await waitUntil { !model.busy }
    #expect(!model.live && !model.dialEngaged)
    #expect(model.phase == "Mac is asleep")
    now = 200
    notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await waitUntil { connection.starts == 2 }
    connection.send(.connected, at: now)
    connection.send(.handedness(.right), at: now)
    connection.send(.heartbeat, at: now)
    connection.send(.dialTurn(20), at: now)
    #expect(model.live && model.controlsEnabled)
    #expect(controls.actions == [.volumeUp])
    connection.send(.dialState(true), at: now)
    connection.send(.dialTurn(2), at: now)
    #expect(controls.actions == [.volumeUp, .volumeUp])
    await model.shutdown()
}

@Test @MainActor func aScanInterruptedBySleepReturnsToDisconnectedAfterWake() async throws {
    let defaults = MemoryDefaults()
    let notifications = NotificationCenter()
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, workspaceNotifications: notifications, sessionStore: SavedSessionStore(), clock: { 100 })
    model.scan()
    #expect(model.busy && !model.wantsConnection)
    notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
    try await waitUntil { !model.busy }
    #expect(model.phase == "Mac is asleep")
    notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await waitUntil { model.phase == "Disconnected" }
    #expect(model.canScan && connection.starts == 1)
    await model.shutdown()
}

@Test @MainActor func theWatchdogReconnectsOnlyWhenAuthenticatedInputStops() async throws {
    let defaults = MemoryDefaults()
    let connection = RecordedConnection()
    var now = 100.0
    let model = BandModel(defaults: defaults, connection: connection, sessionStore: SavedSessionStore(), clock: { now })
    model.selectedAddress = "test-band"
    model.connect()
    connection.send(.connected)
    connection.send(.heartbeat)
    connection.send(.dialState(true))
    now = 109
    try await waitUntil { connection.starts == 2 }
    #expect(!model.live && !model.dialEngaged)
    connection.send(.connected, at: now)
    connection.send(.heartbeat, at: now)
    #expect(model.live)
    await model.shutdown()
}

@Test(arguments: [false, true]) @MainActor
func recoveryScanWaitsForShutdownAndPausesControls(streaming: Bool) async throws {
    let defaults = MemoryDefaults()
    let remembered = BandDevice(address: UUID().uuidString, name: "Meta Band")
    let discovered = BandDevice(address: UUID().uuidString, name: remembered.name, rssi: -40)
    defaults.set(try JSONEncoder().encode(remembered), forKey: "band")
    defaults.set(true, forKey: "setupCompleted")
    let connection = RecordedConnection()
    connection.finishesOnStop = false
    let controls = RecordingControls()
    let model = BandModel(defaults: defaults, connection: connection, controls: controls, sessionStore: SavedSessionStore(), clock: { 100 })
    model.connect()
    if streaming {
        connection.send(.handedness(.right))
        connection.send(.connected)
        connection.send(.heartbeat)
        model.toggleControls()
        connection.send(.dialState(true))
        #expect(model.live && model.controlsEnabled && model.dialEngaged)
        #expect(model.deviceLabel(remembered) == "Meta Band · connected")
    }

    #expect(model.canScan)
    model.scan()
    #expect(connection.stops == 1)
    #expect(connection.requests == ["connect \(remembered.address)"])
    #expect(model.busy && !model.wantsConnection && !model.canScan)
    #expect(!model.live && !model.controlsEnabled && !model.dialEngaged && !model.handConfirmed)
    #expect(model.phase == "Disconnecting before scan…")
    model.scan()
    #expect(connection.stops == 1)

    connection.finish(error: KinesisError(message: "Old connection closed"))
    #expect(connection.requests == ["connect \(remembered.address)", "scan"])
    #expect(model.busy && model.phase == "Finding your band…" && model.error == nil)
    connection.send(.devices([discovered]))
    connection.finish()
    #expect(model.devices == [discovered, remembered])
    #expect(model.selectedAddress == remembered.address)
    #expect(!model.busy && !model.wantsConnection && !model.controlsEnabled && model.canScan)
    await model.shutdown()
}

@Test(arguments: ["scan", "forget"]) @MainActor
func recoveryCancelsPendingReconnect(action: String) async throws {
    let defaults = MemoryDefaults()
    let remembered = BandDevice(address: UUID().uuidString, name: "Meta Band")
    defaults.set(try JSONEncoder().encode(remembered), forKey: "band")
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(), sessionStore: SavedSessionStore(), clock: { 100 })
    model.connect()
    connection.finish(error: KinesisError(message: "Connection lost"))
    #expect(model.wantsConnection && !model.busy && model.canScan)
    #expect(model.phase == "Reconnecting in 2s…")
    if action == "scan" {
        model.scan()
        connection.send(.devices([remembered]))
        connection.finish()
    } else {
        model.forgetBand()
        #expect(model.selectedAddress.isEmpty && defaults.data(forKey: "band") == nil)
    }
    #expect(!model.wantsConnection && !model.busy && model.canScan)
    // Leave the transport idle past the original retry so an uncancelled reconnect is observable.
    try await Task.sleep(for: .milliseconds(2200))
    let expected = ["connect \(remembered.address)"] + (action == "scan" ? ["scan"] : [])
    #expect(connection.requests == expected)
    #expect(model.phase == "Disconnected" && !model.wantsConnection && !model.busy)
    await model.shutdown()
}

@Test @MainActor func forgettingABandPreservesOtherPreferencesAndAllowsDiscoveryAfterRelaunch() async throws {
    let defaults = MemoryDefaults()
    let remembered = BandDevice(address: UUID().uuidString, name: "Meta Band", rssi: -35)
    defaults.set(try JSONEncoder().encode(remembered), forKey: "band")
    defaults.set(true, forKey: "startsAutomatically")
    defaults.set(true, forKey: "setupCompleted")
    defaults.set("left", forKey: "bandHand")
    defaults.set(73, forKey: "totalGestureCount")
    defaults.set(2.0, forKey: "dialSensitivity")
    let connection = RecordedConnection()
    connection.finishesOnStop = false
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(), sessionStore: SavedSessionStore(), clock: { 100 })
    var expectedPreferences = defaults.contents
    expectedPreferences.removeValue(forKey: "band")
    model.connect()
    connection.send(.connected)
    connection.send(.heartbeat)
    connection.send(.battery(65))
    model.toggleControls()
    model.forgetBand()
    #expect(connection.stops == 1)
    #expect(model.selectedAddress.isEmpty && model.devices.isEmpty && model.discoveredAddresses.isEmpty)
    #expect(model.battery == nil && model.error == nil)
    #expect(model.busy && !model.canScan && !model.wantsConnection && !model.controlsEnabled)
    let actualPreferences = defaults.contents
    #expect(NSDictionary(dictionary: actualPreferences).isEqual(to: expectedPreferences))
    connection.finish()
    #expect(!model.busy && model.canScan)
    await model.shutdown()

    let newConnection = RecordedConnection()
    let reopened = BandModel(defaults: defaults, connection: newConnection, controls: RecordingControls(), sessionStore: SavedSessionStore(), clock: { 100 })
    reopened.startAutomatically()
    #expect(newConnection.requests.isEmpty && !reopened.wantsConnection)
    #expect(reopened.selectedAddress.isEmpty && reopened.devices.isEmpty && reopened.canScan)
    #expect(reopened.startsAutomatically && !reopened.showingSetup && reopened.bandHand == .left)
    #expect(reopened.totalGestureCount == 73 && reopened.dialSensitivity == 2)
    let found = BandDevice(address: UUID().uuidString, name: remembered.name, rssi: -45)
    reopened.scan()
    newConnection.send(.devices([found]))
    newConnection.finish()
    #expect(newConnection.requests == ["scan"] && !reopened.wantsConnection)
    #expect(reopened.devices == [found] && reopened.selectedAddress == found.address)
    let saved = try JSONDecoder().decode(BandDevice.self, from: #require(defaults.data(forKey: "band")))
    #expect(saved == found)
    await reopened.shutdown()
}

@Test @MainActor func scanResultsDistinguishSameNamedDevicesWithoutReplacingTheRememberedSelection() async throws {
    let defaults = MemoryDefaults()
    let remembered = BandDevice(address: UUID().uuidString, name: "Meta Band", rssi: -35)
    let first = BandDevice(address: UUID().uuidString, name: remembered.name, rssi: -40)
    let second = BandDevice(address: UUID().uuidString, name: remembered.name, rssi: -50)
    defaults.set(try JSONEncoder().encode(remembered), forKey: "band")
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(), sessionStore: SavedSessionStore(), clock: { 100 })
    #expect(model.discoveredAddresses.isEmpty)
    #expect(model.deviceLabel(remembered) == "Meta Band · remembered")
    model.scan()
    connection.send(.devices([first, second]))
    connection.finish()
    #expect(model.devices == [first, second, remembered])
    #expect(model.discoveredAddresses == Set([first.address, second.address]))
    #expect(model.selectedAddress == remembered.address && !model.wantsConnection)
    #expect(model.deviceLabel(remembered) == "Meta Band · remembered · \(remembered.address)")
    #expect(model.deviceLabel(first) == "Meta Band · found in scan · \(first.address)")
    #expect(model.deviceLabel(second) == "Meta Band · found in scan · \(second.address)")
    let unchanged = try JSONDecoder().decode(BandDevice.self, from: #require(defaults.data(forKey: "band")))
    #expect(unchanged == remembered)

    model.selectedAddress = first.address
    let selected = try JSONDecoder().decode(BandDevice.self, from: #require(defaults.data(forKey: "band")))
    #expect(selected == first)
    model.scan()
    #expect(model.discoveredAddresses.isEmpty && model.devices == [first])
    connection.send(.devices([]))
    connection.finish()
    #expect(model.devices == [first] && model.selectedAddress == first.address)
    #expect(model.deviceLabel(first) == "Meta Band · remembered")
    #expect(model.error == "No band found. Put it in pairing mode, keep it nearby, and try again.")
    #expect(connection.requests == ["scan", "scan"])
    await model.shutdown()
}

@Test(arguments: ["disconnect", "forget", "sleep", "shutdown"]) @MainActor
func recoveryScanIsCancelledBeforeShutdownCompletes(action: String) async throws {
    let defaults = MemoryDefaults()
    let remembered = BandDevice(address: UUID().uuidString, name: "Meta Band")
    defaults.set(try JSONEncoder().encode(remembered), forKey: "band")
    let connection = RecordedConnection()
    connection.finishesOnStop = false
    let notifications = NotificationCenter()
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          workspaceNotifications: notifications, sessionStore: SavedSessionStore(), clock: { 100 })
    model.connect()
    model.scan()
    #expect(model.busy && model.phase == "Disconnecting before scan…")
    connection.finishesOnStop = true
    switch action {
    case "disconnect": model.disconnect()
    case "forget": model.forgetBand()
    case "sleep":
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await waitUntil { !model.busy }
        #expect(model.phase == "Mac is asleep" && !model.canScan)
        model.scan()
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitUntil { model.phase == "Disconnected" }
    case "shutdown":
        await model.shutdown()
        #expect(!model.canScan)
        model.scan()
    default: Issue.record("Unexpected recovery cancellation action")
    }
    #expect(connection.requests == ["connect \(remembered.address)"])
    #expect(!model.busy && !model.wantsConnection && !model.controlsEnabled)
    await model.shutdown()
}

@MainActor final class SavedSessionStore: MetaSessionStoring {
    var saved: MetaSession?
    private(set) var saves = 0
    private(set) var deletions = 0
    func hasSavedSession() -> Bool { saved != nil }
    func saveSession(_ session: MetaSession) { saved = session; saves += 1 }
    func restoreSession() -> MetaSession? { saved }
    func deleteSession() { saved = nil; deletions += 1 }
}

private struct FakePairClient: BandPairClient {
    var pending = MetaPairClient.Pending(signature: Data([1]), receipt: "{}")
    var final = MetaPairClient.Final(signature: Data([2]), receipt: "{}", devicePublicKey: Data(repeating: 5, count: 64))
    var failure: Error?
    func pairRequest(_ data: CeremonyPairRequestData) async throws -> MetaPairClient.Pending {
        if let failure { throw failure }
        return pending
    }
    func pair(_ data: CeremonyPairData) async throws -> MetaPairClient.Final {
        if let failure { throw failure }
        return final
    }
}

@Test @MainActor func pairBandRunsLoginCeremonyReconnectAndDoneForAnUnclaimedBand() async throws {
    let defaults = MemoryDefaults()
    let remembered = BandDevice(address: "test-band", name: "Meta Band")
    defaults.set(try JSONEncoder().encode(remembered), forKey: "band")
    let connection = RecordedConnection()
    let client = FakePairClient()
    let store = SavedSessionStore()
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in client }, sessionStore: store, clock: { 100 })
    // A remembered band without a stored identity still needs claiming.
    #expect(model.showsPairAction && model.canPair && !model.hasBandIdentity)
    model.pairBand()
    // Without a saved session the sign-in sheet comes first; nothing runs.
    #expect(model.enrollmentStage == .login && connection.requests.isEmpty)
    #expect(!model.canPair && model.showsPairAction && model.pairProgressText == nil)
    model.enroll(session: MetaSession(accessToken: "token", userID: "1"))
    #expect(store.saved?.accessToken == "token")
    // The factory-fresh band goes straight to the ownership ceremony.
    #expect(connection.requests == ["enroll test-band"])
    #expect(model.enrollmentStage == .pairing && model.pairInProgress)
    #expect(model.pairProgressText == "claiming your band…")
    connection.send(.ceremonyStage("claiming the band"))
    #expect(model.enrollmentStage == .working("claiming the band"))
    #expect(model.pairProgressText == "claiming the band…")
    let identity = BandIdentityInfo(deviceCertificate: Data([1]), serial: "S", secondaryCertificate: Data([2]))
    connection.send(.ceremonyHTTP(.pairRequest(CeremonyPairRequestData(
        identity: identity, nonce: Data(repeating: 3, count: 16), appPublicKey: Data(repeating: 4, count: 64)))))
    try await waitUntil { connection.ceremonyCompletions.count == 1 }
    connection.send(.ceremonyHTTP(.pair(CeremonyPairData(receipt: "{\"a\":1}", signature: Data([9])))))
    try await waitUntil { connection.ceremonyCompletions.count == 2 }
    // Streams ready finish the ceremony; the pipeline reconnects to settle.
    connection.send(.connected)
    try await waitUntil { connection.requests == ["enroll test-band", "connect test-band"] }
    #expect(model.pairProgressText == "connecting to your band…" && model.enrollmentStage == .idle)
    // The settling connect completes the run: the band stays managed.
    connection.send(.connected)
    try await waitUntil { !model.pairInProgress }
    #expect(model.wantsConnection && !model.showsPairAction)
    #expect(model.hasSavedMetaSession && store.saved?.accessToken == "token")
    await model.shutdown()
}

@Test @MainActor func aSavedSessionClaimsAnUnclaimedBandStraightAway() async throws {
    let defaults = MemoryDefaults()
    let remembered = BandDevice(address: "test-band", name: "Meta Band")
    defaults.set(try JSONEncoder().encode(remembered), forKey: "band")
    let connection = RecordedConnection()
    let client = FakePairClient()
    let store = SavedSessionStore()
    store.saved = MetaSession(accessToken: "saved", userID: "7")
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in client }, sessionStore: store, clock: { 100 })
    #expect(model.hasSavedMetaSession)
    model.pairBand()
    // The saved session claims the band straight away; no sign-in sheet.
    #expect(model.enrollmentStage == .pairing && connection.requests == ["enroll test-band"])
    connection.send(.ceremonyStage("claiming the band"))
    #expect(model.enrollmentStage == .working("claiming the band"))
    connection.send(.connected)
    try await waitUntil { connection.requests == ["enroll test-band", "connect test-band"] }
    connection.send(.connected)
    try await waitUntil { !model.pairInProgress }
    #expect(model.wantsConnection && !model.showsPairAction)
    #expect(store.saved?.accessToken == "saved" && model.hasSavedMetaSession)
    await model.shutdown()
}

@Test @MainActor func pairBandRetriesAMismatchOnceThenEnrollsWithTheSavedSession() async throws {
    let defaults = MemoryDefaults()
    let band = "test-\(UUID().uuidString)"
    defer { BandIdentity.delete(for: band) }
    defaults.set(try JSONEncoder().encode(BandDevice(address: band, name: "Meta Band")), forKey: "band")
    try BandIdentity.generate(for: band)
    let connection = RecordedConnection()
    let client = FakePairClient()
    let store = SavedSessionStore()
    store.saved = MetaSession(accessToken: "saved", userID: "7")
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in client }, sessionStore: store, clock: { 100 })
    // A stored identity means the paired surface: no pairing action.
    #expect(model.hasBandIdentity && !model.showsPairAction)
    model.pairBand()
    #expect(connection.requests == ["connect \(band)"] && model.pairInProgress)
    // The band refuses the stored key: one retry drops the identity.
    connection.finish(error: BandIdentityMismatchError("band enrolled to a different key. forget the stored band identity to reconnect without it."))
    try await waitUntil { connection.requests == ["connect \(band)", "connect \(band)"] }
    #expect(model.pairInProgress && model.pairFailure == nil && model.error == nil)
    // The retry is rejected too: the pipeline claims the band instead.
    connection.finish(error: KinesisError(message: "The band rejected gesture setup. Try reconnecting."))
    try await waitUntil { connection.requests == ["connect \(band)", "connect \(band)", "enroll \(band)"] }
    #expect(model.enrollmentStage == .pairing)
    connection.send(.connected)
    try await waitUntil { connection.requests.count == 4 }
    #expect(connection.requests.last == "connect \(band)")
    connection.send(.connected)
    try await waitUntil { !model.pairInProgress }
    // The session survives; no sign-in ever appeared.
    #expect(store.saved?.accessToken == "saved" && model.hasSavedMetaSession)
    #expect(model.pairFailure == nil && model.error == nil)
    await model.shutdown()
}

@Test @MainActor func aPairFailureShowsOneLowercaseLineAndTheButtonRetries() async throws {
    let defaults = MemoryDefaults()
    let band = "test-\(UUID().uuidString)"
    defer { BandIdentity.delete(for: band) }
    defaults.set(try JSONEncoder().encode(BandDevice(address: band, name: "Meta Band")), forKey: "band")
    try BandIdentity.generate(for: band)
    let connection = RecordedConnection()
    let store = SavedSessionStore()
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: store, clock: { 100 })
    model.pairBand()
    #expect(connection.requests == ["connect \(band)"])
    // A plain failure ends the run with one lowercase line, no auto-retry.
    connection.finish(error: KinesisError(message: "The band took too long to respond. Try reconnecting."))
    try await waitUntil { !model.pairInProgress }
    #expect(model.pairFailure == "the band took too long to respond. try reconnecting.")
    #expect(model.enrollmentStage == .idle && model.canPair && model.showsPairAction)
    #expect(model.error == nil && connection.requests == ["connect \(band)"])
    // Pressing the button again retries the pipeline.
    model.pairBand()
    #expect(connection.requests == ["connect \(band)", "connect \(band)"] && model.pairFailure == nil)
    connection.send(.connected)
    try await waitUntil { !model.pairInProgress }
    #expect(model.wantsConnection)
    await model.shutdown()
}

@Test @MainActor func anOwnershipRejectionSurfacesTheDedicatedLineUnderThePairButton() async throws {
    let defaults = MemoryDefaults()
    let band = "test-\(UUID().uuidString)"
    defer { BandIdentity.delete(for: band) }
    defaults.set(try JSONEncoder().encode(BandDevice(address: band, name: "Meta Band")), forKey: "band")
    let connection = RecordedConnection()
    let store = SavedSessionStore()
    store.saved = MetaSession(accessToken: "saved", userID: "7")
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: store, clock: { 100 })
    model.pairBand()
    try await waitUntil { connection.requests == ["enroll \(band)"] }
    // The band reports 0x1042: its stored owner is a different meta account.
    connection.finish(error: BandProtocolError(OwnershipCeremony.failureMessage(0x1042)))
    try await waitUntil { !model.pairInProgress }
    #expect(model.pairFailure == OwnershipCeremony.failureMessage(0x1042))
    #expect(model.error == nil && model.enrollmentStage == .idle && model.showsPairAction)
    await model.shutdown()
}

@Test @MainActor func pairBandScansSelectsAndClaimsWhenNothingIsRemembered() async throws {
    let defaults = MemoryDefaults()
    let connection = RecordedConnection()
    let store = SavedSessionStore()
    store.saved = MetaSession(accessToken: "saved", userID: "7")
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: store, clock: { 100 })
    #expect(model.showsPairAction && model.canPair)
    model.pairBand()
    // Scanning is the claim-needing flow, so the hold-button hint shows.
    #expect(connection.requests == ["scan"] && model.pairProgressText == "finding your band…")
    #expect(model.showsHoldHint)
    let found = BandDevice(address: "found-band", name: "Meta Band", rssi: -40)
    connection.send(.devices([found]))
    #expect(model.selectedAddress == "found-band")
    connection.finish()
    // The found band has no stored identity: the ceremony claims it.
    try await waitUntil { connection.requests == ["scan", "enroll found-band"] }
    connection.send(.connected)
    try await waitUntil { connection.requests == ["scan", "enroll found-band", "connect found-band"] }
    connection.send(.connected)
    try await waitUntil { !model.pairInProgress }
    #expect(model.selectedAddress == "found-band" && model.wantsConnection)
    await model.shutdown()
}

@Test @MainActor func repeatedEmptyScansSurfaceTheHoldButtonHint() async throws {
    let defaults = MemoryDefaults()
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: SavedSessionStore(), clock: { 100 })
    model.pairBand()
    connection.send(.devices([]))
    connection.finish()
    try await waitUntil { !model.pairInProgress }
    #expect(model.pairFailure == "no band found. put the band in pairing mode and pair again.")
    #expect(model.emptyScans == 1 && !model.showsHoldHint && model.canPair)
    // A second empty scan keeps the hold-button hint up.
    model.pairBand()
    connection.send(.devices([]))
    connection.finish()
    try await waitUntil { model.emptyScans == 2 }
    #expect(!model.pairInProgress && model.showsHoldHint && model.canPair)
    await model.shutdown()
}

@Test @MainActor func aPairRunReportsItsStagesTheSystemPairingRequestAndTheClaimBeat() async throws {
    let defaults = MemoryDefaults()
    defaults.set(try JSONEncoder().encode(BandDevice(address: "test-band", name: "Meta Band")), forKey: "band")
    defer { BandIdentity.delete(for: "test-band") }
    let connection = RecordedConnection()
    let store = SavedSessionStore()
    store.saved = MetaSession(accessToken: "token", userID: "1")
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: store, clock: { 100 })
    #expect(model.pairing.headline == "setup incomplete" && model.pairing.current == nil)
    model.pairBand()
    #expect(model.pairing.current == .claim && model.pairing.claimProgress == 0 && !model.pairing.offersOtherAccount)
    // macOS asks to pair before the band answers anything.
    connection.send(.systemPairingPending)
    #expect(model.awaitingSystemPairing && model.pairing.needsSystemPairing)
    #expect(model.phase == "Accept the Bluetooth request…")
    connection.send(.ceremonyStage("establishing trust"))
    #expect(model.pairing.claimProgress == 4)
    connection.send(.connected)
    #expect(!model.awaitingSystemPairing)
    try await waitUntil { connection.requests == ["enroll test-band", "connect test-band"] }
    // The settling reconnect is the last step of this run.
    #expect(model.pairing.current == .ready && !model.justPaired)
    connection.send(.connected)
    try await waitUntil { !model.pairInProgress }
    #expect(model.justPaired && model.pairing.current == nil && model.pairFailedStep == nil)
    await model.shutdown()
}

@Test @MainActor func aFailedPairRunRemembersWhereItStopped() async throws {
    let defaults = MemoryDefaults()
    let connection = RecordedConnection()
    let store = SavedSessionStore()
    store.saved = MetaSession(accessToken: "token", userID: "1")
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: store, clock: { 100 })
    model.pairBand()
    connection.send(.devices([]))
    connection.finish()
    try await waitUntil { !model.pairInProgress }
    #expect(model.pairFailedStep == .find && model.pairing.failed == .find)
    #expect(model.pairing.headline == "couldn’t find your band" && model.pairing.holdHint == .insist)
    // A claim that the band refuses fails at the claim step.
    model.pairBand()
    connection.send(.devices([BandDevice(address: "found-band", name: "Meta Band", rssi: -40)]))
    connection.finish()
    try await waitUntil { connection.requests == ["scan", "scan", "enroll found-band"] }
    #expect(model.pairFailedStep == nil)
    connection.finish(error: KinesisError(message: OwnershipCeremony.failureMessage(0x1042)))
    try await waitUntil { !model.pairInProgress }
    #expect(model.pairFailedStep == .claim && model.pairing.headline == "couldn’t claim your band")
    #expect(model.pairing.help?.url == PairingPresentation.factoryResetGuide && model.pairing.offersOtherAccount)
    // Another account means a fresh sign-in: the refused one is dropped and the sheet opens.
    model.switchMetaAccount()
    model.pairBand()
    #expect(!model.hasSavedMetaSession && store.saved == nil && model.enrollmentStage == .login)
    #expect(model.pairing.current == .signIn && model.pairFailure == nil)
    model.cancelEnrollment()
    await model.shutdown()
}

@Test @MainActor func cancelPairingEndsARunAtAnyStage() async throws {
    let defaults = MemoryDefaults()
    let connection = RecordedConnection()
    let store = SavedSessionStore()
    store.saved = MetaSession(accessToken: "token", userID: "1")
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: store, clock: { 100 })
    model.pairBand()
    #expect(model.pairing.current == .find && connection.requests == ["scan"])
    model.cancelPairing()
    try await waitUntil { !model.busy }
    #expect(!model.pairInProgress && model.pairFailure == nil && model.canPair && model.phase == "Disconnected")
    // Cancelling never costs the sign-in: the next run starts without a sheet.
    #expect(model.hasSavedMetaSession && store.saved != nil)
    await model.shutdown()
}

@Test @MainActor func bailingOutOfTheSignInLeavesAnIncompleteSetupNotALostBand() async throws {
    let defaults = MemoryDefaults()
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: SavedSessionStore(), clock: { 100 })
    model.pairBand()
    connection.send(.devices([BandDevice(address: "found-band", name: "Meta Band 00BC", rssi: -40)]))
    connection.finish()
    // The band is found and nothing is saved, so the sign-in sheet opens.
    try await waitUntil { model.enrollmentStage == .login }
    #expect(model.pairing.current == .signIn && model.pairing.bandName == "Meta Band 00BC")
    model.cancelEnrollment()
    // One card, and it says what is true: found, never claimed.
    #expect(model.showsPairAction && model.selectedAddress == "found-band" && !model.hasBandIdentity)
    #expect(model.pairing.headline == "setup incomplete" && model.pairing.dimsArtwork)
    #expect(model.pairing.bandName == "Meta Band 00BC" && model.pairing.buttonTitle == "pair band")
    await model.shutdown()
}

@Test @MainActor func lettingGoOfATurnIsNotATap() async throws {
    let defaults = MemoryDefaults()
    defaults.set(true, forKey: "setupCompleted")
    let connection = RecordedConnection()
    let controls = RecordingControls()
    var now = 100.0
    let model = BandModel(defaults: defaults, connection: connection, controls: controls, clock: { now })
    model.selectedAddress = "test-band"
    model.tapMappings[.indexTap] = .playPause
    model.connect()
    connection.send(.connected)
    connection.send(.heartbeat)
    connection.send(.handedness(.right))
    model.toggleControls()
    func tap(_ sequence: UInt64) {
        connection.send(.gesture(BandGesture(sequence: sequence, timestampUs: sequence, finger: "index", action: "press",
                                             derivedAction: "singleTap", synthetic: false, receivedAt: now)), at: now)
    }
    // A pinch that turned, held a while, then let go. The band reports that release as a tap.
    now = 101
    connection.send(.dialState(true), at: now)
    connection.send(.dialTurn(0.4), at: now)
    now = 103
    connection.send(.dialState(false), at: now)
    now = 103.1
    tap(1)
    #expect(!controls.actions.contains(.playPause))
    // A real tap, well after the turn, still works.
    now = 104.5
    tap(2)
    #expect(controls.actions.contains(.playPause))
    // A pinch that never turned is just a tap.
    now = 106
    connection.send(.dialState(true), at: now)
    now = 106.3
    connection.send(.dialState(false), at: now)
    now = 106.4
    tap(3)
    #expect(controls.actions.filter { $0 == .playPause }.count == 2)
    await model.shutdown()
}

@Test @MainActor func theBandPaneAlwaysOffersTheNextUsefulStep() async throws {
    let defaults = MemoryDefaults()
    defaults.set(true, forKey: "setupCompleted")
    let band = "test-\(UUID().uuidString)"
    defer { BandIdentity.delete(for: band) }
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: SavedSessionStore(), clock: { 100 })
    // Nothing remembered: pair. A run in flight: wait for it.
    #expect(model.nextAction == .pair && !model.inTransit)
    model.pairBand()
    #expect(model.nextAction == .pairing && model.nextAction.waits && model.inTransit)
    model.cancelPairing()
    try await waitUntil { !model.busy }
    #expect(model.nextAction == .pair)
    // A paired band: connect, then hand it the Mac, then take it back.
    defaults.set(try JSONEncoder().encode(BandDevice(address: band, name: "Meta Band")), forKey: "band")
    try BandIdentity.generate(for: band)
    let paired = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                           pairClient: { _ in FakePairClient() }, sessionStore: SavedSessionStore(), clock: { 100 })
    #expect(paired.nextAction == .connect)
    paired.connect()
    #expect(paired.nextAction == .connecting && paired.inTransit)
    connection.send(.connected)
    connection.send(.heartbeat)
    try await waitUntil { paired.live }
    #expect(paired.nextAction == .enableControls && !paired.inTransit)
    paired.toggleControls()
    #expect(paired.nextAction == .pauseControls)
    paired.disconnect()
    try await waitUntil { !paired.busy }
    #expect(paired.nextAction == .connect)
    await model.shutdown()
    await paired.shutdown()
}

@Test @MainActor func aPairedBandDisconnectedByHandCanConnectAgain() async throws {
    let defaults = MemoryDefaults()
    let band = "test-\(UUID().uuidString)"
    defer { BandIdentity.delete(for: band) }
    defaults.set(try JSONEncoder().encode(BandDevice(address: band, name: "Meta Band")), forKey: "band")
    try BandIdentity.generate(for: band)
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: SavedSessionStore(), clock: { 100 })
    model.connect()
    connection.send(.connected)
    connection.send(.heartbeat)
    try await waitUntil { model.live }
    model.disconnect()
    try await waitUntil { !model.busy }
    // The band page shows its connect button exactly in this state: a paired
    // band, nothing in flight, and no pairing surface.
    #expect(!model.live && !model.wantsConnection && !model.showsPairAction && model.hasBandIdentity)
    model.connect()
    #expect(connection.requests == ["connect \(band)", "connect \(band)"] && model.wantsConnection)
    await model.shutdown()
}

@Test @MainActor func forgetEverythingClearsTheBandIdentitySessionAndRememberedBand() async throws {
    let defaults = MemoryDefaults()
    let band = "test-\(UUID().uuidString)"
    defer { BandIdentity.delete(for: band) }
    defaults.set(try JSONEncoder().encode(BandDevice(address: band, name: "Meta Band")), forKey: "band")
    try BandIdentity.generate(for: band)
    let store = SavedSessionStore()
    store.saved = MetaSession(accessToken: "token", userID: "1")
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: store, clock: { 100 })
    model.connect()
    connection.send(.connected)
    connection.send(.heartbeat)
    try await waitUntil { model.live }
    #expect(model.hasBandIdentity && model.hasSavedMetaSession && !model.showsPairAction)
    model.forgetEverything()
    #expect(model.selectedAddress.isEmpty && model.devices.isEmpty && !model.live)
    #expect(!model.hasBandIdentity && !BandIdentity.exists(for: band))
    #expect(!model.hasSavedMetaSession && store.saved == nil)
    #expect(!model.wantsConnection && !model.controlsEnabled)
    #expect(defaults.data(forKey: "band") == nil)
    try await waitUntil { !model.busy }
    // Back to the unpaired surface with the one button.
    #expect(model.showsPairAction && model.canPair)
    await model.shutdown()
}

@Test @MainActor func switchingAccountsForcesTheSignInSheetOnTheNextPair() async throws {
    let defaults = MemoryDefaults()
    defaults.set(try JSONEncoder().encode(BandDevice(address: "test-band", name: "Meta Band")), forKey: "band")
    let connection = RecordedConnection()
    let store = SavedSessionStore()
    store.saved = MetaSession(accessToken: "old", userID: "1")
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: store, clock: { 100 })
    #expect(model.hasSavedMetaSession)
    model.switchMetaAccount()
    #expect(!model.hasSavedMetaSession && store.saved == nil && store.deletions == 1)
    // The next pair press starts at the sign-in sheet, not the old account.
    model.pairBand()
    #expect(model.enrollmentStage == .login && connection.requests.isEmpty && model.pairInProgress)
    await model.shutdown()
}

@Test @MainActor func switchingAccountsMidCeremonyRestartsAtTheSignInSheet() async throws {
    let defaults = MemoryDefaults()
    defaults.set(try JSONEncoder().encode(BandDevice(address: "test-band", name: "Meta Band")), forKey: "band")
    let connection = RecordedConnection()
    let store = SavedSessionStore()
    store.saved = MetaSession(accessToken: "old", userID: "1")
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: store, clock: { 100 })
    model.pairBand()
    #expect(connection.requests == ["enroll test-band"])
    let identity = BandIdentityInfo(deviceCertificate: Data([1]), serial: "S", secondaryCertificate: Data([2]))
    connection.send(.ceremonyHTTP(.pairRequest(CeremonyPairRequestData(
        identity: identity, nonce: Data(repeating: 3, count: 16), appPublicKey: Data(repeating: 4, count: 64)))))
    try await waitUntil { connection.ceremonyCompletions.count == 1 }
    // The escape hatch winds the ceremony down and asks for one sign-in.
    model.switchMetaAccount()
    #expect(store.saved == nil && !model.hasSavedMetaSession)
    try await waitUntil { !model.busy }
    #expect(model.enrollmentStage == .login && model.pairInProgress)
    // A fresh account session restarts the claim; the band binds to it.
    model.enroll(session: MetaSession(accessToken: "fresh", userID: "2"))
    #expect(store.saved?.accessToken == "fresh")
    try await waitUntil { connection.requests == ["enroll test-band", "enroll test-band"] }
    connection.send(.connected)
    try await waitUntil { connection.requests.count == 3 }
    connection.send(.connected)
    try await waitUntil { !model.pairInProgress }
    #expect(model.enrollmentStage == .idle && model.wantsConnection)
    await model.shutdown()
}

@Test @MainActor func anExpiredSessionMidCeremonyAsksForOneSignIn() async throws {
    let defaults = MemoryDefaults()
    defaults.set(try JSONEncoder().encode(BandDevice(address: "test-band", name: "Meta Band")), forKey: "band")
    let connection = RecordedConnection()
    let client = FakePairClient(failure: MetaSessionInvalidError(message: "your meta session expired. sign in to claim the band again."))
    let store = SavedSessionStore()
    store.saved = MetaSession(accessToken: "stale", userID: "7")
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in client }, sessionStore: store, clock: { 100 })
    model.pairBand()
    #expect(model.enrollmentStage == .pairing && connection.requests == ["enroll test-band"])
    let identity = BandIdentityInfo(deviceCertificate: Data([1]), serial: "S", secondaryCertificate: Data([2]))
    connection.send(.ceremonyHTTP(.pairRequest(CeremonyPairRequestData(
        identity: identity, nonce: Data(repeating: 3, count: 16), appPublicKey: Data(repeating: 4, count: 64)))))
    // The auth-class failure winds the connection down, then asks for one sign-in.
    try await waitUntil { model.enrollmentStage == .login }
    #expect(store.saved == nil && !model.hasSavedMetaSession && !model.busy && model.pairInProgress)
    // Signing in again saves the fresh session and restarts the ceremony:
    // the old state machine lived in the closed connection.
    model.enroll(session: MetaSession(accessToken: "fresh", userID: "7"))
    #expect(model.enrollmentStage == .pairing)
    #expect(connection.requests == ["enroll test-band", "enroll test-band"])
    #expect(store.saved?.accessToken == "fresh" && model.hasSavedMetaSession)
    await model.shutdown()
}

@Test @MainActor func theBandPageFollowsTheTwoActionStateMatrix() async throws {
    let defaults = MemoryDefaults()
    let store = SavedSessionStore()
    // First run: nothing remembered. The one button is the whole surface.
    let fresh = BandModel(defaults: defaults, connection: RecordedConnection(), controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: store, clock: { 100 })
    #expect(fresh.showsPairAction && fresh.canPair)
    await fresh.shutdown()

    // A remembered, unclaimed band still funnels into the button.
    defaults.set(try JSONEncoder().encode(BandDevice(address: "unclaimed", name: "Meta Band")), forKey: "band")
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(),
                          pairClient: { _ in FakePairClient() }, sessionStore: store, clock: { 100 })
    #expect(model.showsPairAction && !model.hasBandIdentity)
    // While a pair run is in flight the button stays with its progress.
    model.pairBand()
    #expect(model.pairInProgress && model.showsPairAction && !model.canPair)
    model.cancelEnrollment()
    #expect(!model.pairInProgress && model.canPair && model.showsPairAction)

    // An enrolled band shows the paired surface instead.
    let band = "test-\(UUID().uuidString)"
    defer { BandIdentity.delete(for: band) }
    defaults.set(try JSONEncoder().encode(BandDevice(address: band, name: "Meta Band")), forKey: "band")
    try BandIdentity.generate(for: band)
    let rejecting = RecordedConnection()
    let enrolled = BandModel(defaults: defaults, connection: rejecting, controls: RecordingControls(),
                             pairClient: { _ in FakePairClient() }, sessionStore: store, clock: { 100 })
    #expect(enrolled.hasBandIdentity && !enrolled.showsPairAction)
    // Connected and streaming: all pairing surfaces hide.
    enrolled.connect()
    #expect(!enrolled.showsPairAction)
    rejecting.send(.connected)
    rejecting.send(.heartbeat)
    try await waitUntil { enrolled.live }
    #expect(!enrolled.showsPairAction)
    // Disconnected but healthy stays paired. The band refusing this Mac
    // brings the pair button back for recovery.
    rejecting.finish(error: BandIdentityMismatchError("band enrolled to a different key. forget the stored band identity to reconnect without it."))
    #expect(!enrolled.bandRejectsIdentity)
    try await waitUntil { rejecting.starts == 2 }
    rejecting.finish(error: KinesisError(message: "The band rejected gesture setup. Try reconnecting."))
    try await waitUntil { enrolled.bandRejectsIdentity }
    enrolled.disconnect()
    try await waitUntil { !enrolled.busy }
    #expect(enrolled.showsPairAction && enrolled.canPair)
    // Forget band returns everything to the unpaired surface.
    enrolled.forgetEverything()
    #expect(enrolled.showsPairAction && !enrolled.hasBandIdentity && enrolled.selectedAddress.isEmpty)
    await enrolled.shutdown()
    await model.shutdown()
}

@Test @MainActor func anAcknowledgedSubscriptionWithoutDataShowsTheWristHintUntilFramesArrive() async throws {
    let defaults = MemoryDefaults()
    defaults.set(true, forKey: "setupCompleted")
    var now = 100.0
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, sessionStore: SavedSessionStore(), clock: { now })
    model.selectedAddress = "test-band"
    model.connect()
    connection.send(.connected)
    // The acknowledgement's own liveness and the periodic status replies must
    // not count as data: the band is subscribed, but nothing streams.
    connection.send(.heartbeat, at: 100.2)
    now += 9
    connection.send(.heartbeat, at: now)
    #expect(model.streamHint == nil)
    now += 1.5
    connection.send(.battery(80))
    #expect(model.streamHint == "subscribed but no data — is the band on your wrist and off the charger?")
    // Only fresh sensor frames clear the hint. Later silence must show it again.
    connection.send(.dataSeen, at: now)
    #expect(model.streamHint == nil)
    now += 20
    connection.send(.heartbeat, at: now)
    connection.send(.battery(81))
    #expect(model.streamHint == "sensor stream is quiet — is the band on your wrist and off the charger?")
    await model.shutdown()
}

@Test @MainActor func sensorSilenceRecoversOnceDespiteStatusTrafficAndRequiresSustainedRecovery() async throws {
    var now = 100.0
    let connection = RecordedConnection()
    let model = BandModel(defaults: MemoryDefaults(), connection: connection,
                          sessionStore: SavedSessionStore(), clock: { now })
    model.selectedAddress = "test-band"
    model.connect()
    connection.send(.connected, at: now)
    connection.send(.dataSeen, at: now)
    now += 11
    connection.send(.heartbeat, at: now)
    try await waitUntil { connection.starts == 2 }
    #expect(connection.stops == 1)

    // One brief sensor burst after reconnecting must not start a reconnect loop.
    connection.send(.connected, at: now)
    connection.send(.dataSeen, at: now)
    now += 11
    connection.send(.heartbeat, at: now)
    try await Task.sleep(for: .milliseconds(650))
    #expect(connection.starts == 2 && connection.stops == 1)
    #expect(model.streamHint != nil)

    // Thirty seconds of continuous sensor data restores the recovery budget.
    for _ in 0..<62 {
        now += 0.5
        connection.send(.dataSeen, at: now)
        connection.send(.heartbeat, at: now)
    }
    now += 11
    connection.send(.heartbeat, at: now)
    try await waitUntil { connection.starts == 3 }
    #expect(connection.stops == 2)
    await model.shutdown()
}

@Test @MainActor func sensorRecoveryIgnoresChargingAndStaleFrames() async throws {
    var now = 100.0
    let connection = RecordedConnection()
    let model = BandModel(defaults: MemoryDefaults(), connection: connection,
                          sessionStore: SavedSessionStore(), clock: { now })
    model.selectedAddress = "test-band"
    model.connect()
    connection.send(.connected, at: now)
    connection.send(.dataSeen, at: now)
    connection.send(.batteryStatus(BandBatteryStatus(level: 80, charging: true)), at: now)
    now += 11
    connection.send(.heartbeat, at: now)
    connection.send(.dataSeen, at: 100)
    try await Task.sleep(for: .milliseconds(650))
    #expect(connection.stops == 0 && model.streamHint != nil)
    connection.send(.batteryStatus(BandBatteryStatus(level: 80, charging: false)), at: now)
    try await waitUntil { connection.starts == 2 }
    await model.shutdown()
}

@Test @MainActor func chargingUsesTheReportedFlagEvenWhenBatteryPercentageIsFlat() async {
    let connection = RecordedConnection()
    let model = BandModel(defaults: MemoryDefaults(), connection: connection, sessionStore: SavedSessionStore(), clock: { 100 })
    model.selectedAddress = "test-band"
    model.connect()
    connection.send(.connected)
    connection.send(.battery(80))
    connection.send(.battery(81))
    #expect(model.chargeState == .unknown) // A rising level isn't a charger sensor.
    connection.send(.batteryStatus(BandBatteryStatus(level: 81, charging: true)))
    #expect(model.chargeState == .charging && model.battery == 81)
    connection.send(.battery(81))
    #expect(model.chargeState == .charging)
    connection.send(.batteryStatus(BandBatteryStatus(level: 81, charging: false)))
    #expect(model.chargeState == .onBattery)
    connection.send(.batteryStatus(BandBatteryStatus(level: 100, charging: false)))
    #expect(model.chargeState == .full)
    connection.send(.batteryStatus(BandBatteryStatus(level: 100, charging: true)))
    #expect(model.chargeState == .charging)
    connection.send(.batteryStatus(nil))
    connection.send(.battery(90))
    #expect(model.chargeState == .unknown && model.battery == 90)
    connection.send(.batteryStatus(BandBatteryStatus(level: 90, charging: true)))
    connection.send(.disconnected)
    #expect(model.chargeState == .unknown)
    await model.shutdown()
}

@Test @MainActor func developerModeControlsReadingsWithoutReconnectingAndFlushesRecording() async throws {
    let defaults = MemoryDefaults()
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, sessionStore: SavedSessionStore(), clock: { 100 })
    model.selectedAddress = "test-band"
    model.connect()
    connection.send(.connected)
    connection.send(.heartbeat)
    #expect(!model.developerMode && !connection.rawEMGMode)
    model.developerMode = true
    model.rawEMGEnabled = true
    #expect(connection.rawEMGMode && model.rawEMGChanging)
    #expect(connection.starts == 1 && connection.stops == 0)
    connection.send(.rawEMGState(true))
    #expect(model.rawEMGActive && !model.rawEMGChanging)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kinesis-emg-test-\(UUID()).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    model.startRawRecording(to: url)
    // Stop before the periodic flush. Both frames still have to reach disk, in order.
    connection.send(.rawEMGFrame(Data([1, 2, 3])))
    connection.send(.rawEMGFrame(Data([4, 5, 6])))
    model.developerMode = false
    #expect(!model.rawEMGEnabled && !connection.rawEMGMode && model.rawRecordingURL == nil)
    #expect(connection.starts == 1 && connection.stops == 0)
    connection.send(.rawEMGState(false))
    #expect(!model.rawEMGActive)
    await model.shutdown()
    #expect(model.rawRecordedFrames == 2)
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    let second = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
    #expect(first?["payload"] as? String == "010203")
    #expect(second?["payload"] as? String == "040506")
    #expect(!defaults.bool(forKey: "developerMode") && !defaults.bool(forKey: "rawEMGEnabled"))
}

@Test @MainActor func disabledDeveloperModeDoesNotRestoreAHiddenEMGSubscription() async {
    let defaults = MemoryDefaults()
    defaults.set(true, forKey: "rawEMGEnabled")
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, sessionStore: SavedSessionStore())
    #expect(!model.developerMode && !model.rawEMGEnabled && !connection.rawEMGMode)
    await model.shutdown()
}

@Test @MainActor func turningDeveloperModeOffDuringAnEMGRequestWaitsThenDisablesIt() async {
    let connection = RecordedConnection()
    let model = BandModel(defaults: MemoryDefaults(), connection: connection, sessionStore: SavedSessionStore(), clock: { 100 })
    model.selectedAddress = "test-band"
    model.connect()
    connection.send(.connected)
    connection.send(.heartbeat)
    model.developerMode = true
    model.rawEMGEnabled = true
    connection.rawWriteError = KinesisError(message: "Request in progress")
    model.developerMode = false
    #expect(model.rawEMGChanging && model.rawEMGError == nil)
    connection.rawWriteError = nil
    connection.send(.rawEMGFailure("Timed out"))
    #expect(!connection.rawEMGMode && model.rawEMGChanging)
    connection.send(.rawEMGState(false))
    #expect(!model.rawEMGActive && !model.rawEMGChanging && model.rawEMGError == nil)
    #expect(connection.starts == 1 && connection.stops == 0)
    await model.shutdown()
}

@Test @MainActor func aDroppedEMGSessionReconnectsWithReadingsOff() async throws {
    let connection = RecordedConnection()
    let model = BandModel(defaults: MemoryDefaults(), connection: connection, sessionStore: SavedSessionStore(), clock: { 100 })
    model.selectedAddress = "test-band"
    model.connect()
    connection.send(.connected)
    connection.send(.heartbeat)
    model.developerMode = true
    model.rawEMGEnabled = true
    connection.send(.rawEMGState(true))
    connection.finish(error: KinesisError(message: "The band dropped the combined subscription"))
    try await waitUntil { connection.starts == 2 }
    #expect(!model.rawEMGEnabled && !connection.rawEMGMode)
    #expect(model.developerMode && !model.rawEMGActive)
    await model.shutdown()
}

@Test @MainActor func theCursorPageLightsUpEachPointerActionOnceDone() async throws {
    let rig = CursorRig()
    let model = rig.model
    try await rig.aim(0)
    model.setAirCursorEnabled(true)
    try await rig.aim(0)
    // With the page closed, nothing is tracked.
    rig.gesture("index", "press")
    rig.gesture("index", "release")
    #expect(model.cursorSkills.isEmpty)
    model.setCursorPageVisible(true)
    #expect(model.wantedMotionStreams.orientation)
    rig.gesture("middle", "press")
    rig.gesture("middle", "release")
    rig.gesture("index", "press")
    try await rig.sweep(to: 3, from: (0, 0), seconds: 0.4, settle: 0.2)
    rig.gesture("index", "release")
    #expect(model.cursorSkills == [.rightClick, .click, .drag])
    // Two presses in place are a double-click.
    rig.gesture("index", "press")
    rig.gesture("index", "release")
    rig.gesture("index", "press")
    rig.gesture("index", "release")
    #expect(model.cursorSkills.contains(.doubleClick))
    // Opening the page again starts over.
    model.setCursorPageVisible(false)
    model.setCursorPageVisible(true)
    #expect(model.cursorSkills.isEmpty)
    await model.shutdown()
}

@Test @MainActor func speedIsTheSameOnEveryDisplayAndCarriesOverFromSensitivity() {
    let defaults = MemoryDefaults()
    defaults.set(2.0, forKey: "pointerSensitivity")
    defaults.set(2.2, forKey: "pointerFlickBoost")
    let model = BandModel(defaults: defaults, connection: RecordedConnection(), sessionStore: SavedSessionStore(), clock: { 100 })
    #expect(model.cursorSpeed == PointerReach.standardSpeed * 2)
    #expect(model.cursorFlickBoost == 2.2 && model.airPointer.tuning.fastFactor == 2.2)
    model.cursorFlickBoost = 1.2
    #expect(model.airPointer.tuning.fastFactor == 1.2)
    let fresh = BandModel(defaults: MemoryDefaults(), connection: RecordedConnection(), sessionStore: SavedSessionStore(), clock: { 100 })
    #expect(fresh.cursorSpeed == PointerReach.standardSpeed && fresh.cursorFlickBoost == PointerAcceleration.fastFactor)
}
