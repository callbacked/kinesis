import AppKit
import Combine
import Foundation
import Testing
import KinesisCore
@testable import Kinesis

@MainActor private final class RecordedConnection: BandConnection {
    private var onEvent: ((BandEvent) -> Void)?
    private var onEnd: ((Error?) -> Void)?
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    var expectedPreferences = try #require(defaults.persistentDomain(forName: suite))
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
    let actualPreferences = try #require(defaults.persistentDomain(forName: suite))
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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

@MainActor private final class SavedSessionStore: MetaSessionStoring {
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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

@Test @MainActor func theBandPaneAlwaysOffersTheNextUsefulStep() async throws {
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "kinesis-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
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
