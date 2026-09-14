import AppKit
import Combine
import Foundation
import Testing
import KinesisCore
@testable import Kinesis

@MainActor private final class RecordedConnection: BandConnection {
    private var onEvent: ((BandEvent) -> Void)?
    private var onEnd: ((Error?) -> Void)?
    private(set) var starts = 0
    private(set) var requestedHands: [BandHand] = []
    var handWriteError: Error?
    func setHandedness(_ hand: BandHand) throws {
        if let handWriteError { throw handWriteError }
        requestedHands.append(hand)
    }
    func start(_ operation: BandOperation, onEvent: @escaping (BandEvent) -> Void,
               onEnd: @escaping (Error?) -> Void) throws {
        starts += 1
        self.onEvent = onEvent
        self.onEnd = onEnd
    }
    func stop() { finish() }
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
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition())
}

@Test @MainActor func handSelectionUsesTheBandSettingAndPausesControlsUntilTheUserResumes() async throws {
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("right", forKey: "bandHand")
    defaults.set(true, forKey: "setupCompleted")
    let connection = RecordedConnection()
    let controls = RecordingControls()
    let model = BandModel(defaults: defaults, connection: connection, controls: controls, clock: { 100 })
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, clock: { 100 })
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(73, forKey: "totalGestureCount")
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, clock: { 100 })
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
    let reopened = BandModel(defaults: defaults, connection: RecordedConnection(), clock: { 100 })
    #expect(reopened.totalGestureCount == 74)
    #expect(reopened.gestureCount == 0)
    await reopened.shutdown()
}

@Test @MainActor func automaticStartRequiresOptInAndACompletedSetup() async throws {
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let band = ["address": "test-band", "name": "Test Band"]
    defaults.set(try JSONSerialization.data(withJSONObject: band), forKey: "band")
    defaults.set(true, forKey: "setupCompleted")
    let paused = BandModel(defaults: defaults, connection: RecordedConnection(), clock: { 100 })
    paused.startAutomatically()
    #expect(!paused.wantsConnection)
    await paused.shutdown()

    defaults.set(true, forKey: "startsAutomatically")
    defaults.set(false, forKey: "setupCompleted")
    let setup = BandModel(defaults: defaults, connection: RecordedConnection(), clock: { 100 })
    setup.startAutomatically()
    #expect(!setup.wantsConnection)
    #expect(!setup.controlsEnabled)
    await setup.shutdown()

    defaults.set(true, forKey: "setupCompleted")
    let connection = RecordedConnection()
    let automatic = BandModel(defaults: defaults, connection: connection, clock: { 100 })
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, clock: { 100 })
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
    private(set) var accessRequests = 0
    func requestAccess() { accessRequests += 1 }
    func post(_ action: MacAction) throws {
        if let failure { throw failure }
        actions.append(action)
    }
}

@Test(arguments: [BandHand.right, .left], [DialTarget.volume, .brightness])
@MainActor func eachHandUsesTheSameDialDirectionForPracticeAndMacControls(hand: BandHand, target: DialTarget) async throws {
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let connection = RecordedConnection()
    let controls = RecordingControls()
    var now = 100.0
    let model = BandModel(defaults: defaults, connection: connection, controls: controls, clock: { now })
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "setupCompleted")
    let connection = RecordedConnection()
    let controls = RecordingControls()
    var now = 100.0
    let model = BandModel(defaults: defaults, connection: connection, controls: controls, clock: { now })
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "setupCompleted")
    let connection = RecordedConnection()
    let controls = RecordingControls()
    var now = 100.0
    let model = BandModel(defaults: defaults, connection: connection, controls: controls, clock: { now })
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "setupCompleted")
    defaults.set(true, forKey: "startsAutomatically")
    defaults.set(try JSONEncoder().encode(BandDevice(address: "test-band", name: "Test Band")), forKey: "band")
    let connection = RecordedConnection()
    let controls = RecordingControls()
    controls.trusted = false
    let model = BandModel(defaults: defaults, connection: connection, controls: controls, clock: { 100 })
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "setupCompleted")
    let connection = RecordedConnection()
    let controls = RecordingControls()
    let notifications = NotificationCenter()
    var now = 100.0
    let model = BandModel(defaults: defaults, connection: connection, controls: controls,
                          workspaceNotifications: notifications, clock: { now })
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let notifications = NotificationCenter()
    let connection = RecordedConnection()
    let model = BandModel(defaults: defaults, connection: connection, workspaceNotifications: notifications, clock: { 100 })
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let connection = RecordedConnection()
    var now = 100.0
    let model = BandModel(defaults: defaults, connection: connection, clock: { now })
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
