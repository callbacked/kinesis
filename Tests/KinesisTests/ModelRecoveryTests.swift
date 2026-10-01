import Foundation
import Testing
import KinesisCore
@testable import Kinesis

@MainActor private func connectedModel(_ defaults: MemoryDefaults, connection: RecordedConnection, address: String = "test-band") -> BandModel {
    defaults.set(true, forKey: "setupCompleted")
    let model = BandModel(defaults: defaults, connection: connection, controls: RecordingControls(), sessionStore: SavedSessionStore(), clock: { 100 })
    model.selectedAddress = address
    model.developerMode = true
    model.connect()
    connection.send(.connected)
    connection.send(.heartbeat)
    connection.send(.handedness(.right))
    return model
}

@Test @MainActor func unfinishedModelSwitchSurvivesAppRecreationAndOnlyVerifiedRecoveryClearsIt() async throws {
    let defaults = MemoryDefaults(), connection = RecordedConnection()
    let original = connectedModel(defaults, connection: connection)
    try original.setModelCaptureEnabled(true)
    #expect(defaults.stringArray(forKey: "modelRecoveryBands") == ["test-band"])
    connection.send(.modelCaptureState(.init(phase: .ready, message: "ready")))
    await original.shutdown()

    let nextConnection = RecordedConnection()
    let recreated = connectedModel(defaults, connection: nextConnection)
    #expect(nextConnection.modelRecoveryRequests == 1 && nextConnection.modelCaptureRequests.isEmpty)
    #expect(recreated.modelCaptureStatus.phase == .restoring)
    recreated.toggleControls()
    #expect(!recreated.controlsEnabled)
    nextConnection.send(.modelCaptureState(.init(phase: .finished, message: "failed", problem: "bad readback")))
    #expect(recreated.modelRecoveryRequired)
    recreated.toggleControls()
    #expect(!recreated.controlsEnabled)
    recreated.disconnect()
    recreated.connect()
    nextConnection.send(.connected)
    nextConnection.send(.heartbeat)
    #expect(nextConnection.modelRecoveryRequests == 2)
    nextConnection.send(.modelCaptureState(.init(phase: .finished, message: "restored", restorationVerified: true)))
    #expect(!recreated.modelRecoveryRequired && defaults.stringArray(forKey: "modelRecoveryBands") == [])
    #expect(!recreated.controlsEnabled)
    recreated.toggleControls()
    #expect(recreated.controlsEnabled)
    await recreated.shutdown()
}

@Test @MainActor func recoveryMarkerIsSpecificToTheBandThatWasChanged() async {
    let defaults = MemoryDefaults(), connection = RecordedConnection()
    defaults.set(["different-band"], forKey: "modelRecoveryBands")
    let model = connectedModel(defaults, connection: connection)
    #expect(!model.modelRecoveryRequired && connection.modelRecoveryRequests == 0)
    model.toggleControls()
    #expect(model.controlsEnabled)
    #expect(defaults.stringArray(forKey: "modelRecoveryBands") == ["different-band"])
    await model.shutdown()
}

@Test @MainActor func recordingOwnershipBlocksControlsThroughoutPreparationAndCleanup() async throws {
    let connection = RecordedConnection(), model = connectedModel(MemoryDefaults(), connection: connection)
    let owner = UUID(), other = UUID()
    model.toggleControls()
    #expect(model.controlsEnabled)
    try model.acquireModelRecording(owner)
    model.toggleControls()
    model.setAirCursorEnabled(true)
    #expect(!model.controlsEnabled && !model.airCursorEnabled && !model.canChangeHand)
    #expect(throws: KinesisError.self) { try model.acquireModelRecording(other) }
    model.releaseModelRecording(other)
    #expect(model.modelRecordingOwner == owner)
    try model.setModelCaptureEnabled(true)
    connection.send(.modelCaptureState(.init(phase: .finished, message: "restored", restorationVerified: true)))
    model.toggleControls()
    #expect(!model.controlsEnabled && !model.modelRecoveryRequired)
    model.releaseModelRecording(owner)
    model.toggleControls()
    #expect(model.controlsEnabled)
    await model.shutdown()
}
