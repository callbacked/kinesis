import Foundation
import Testing
@testable import KinesisCore

private func sample(sequence: UInt64 = 0, count: Int = 100, value: Float = -log(100)) throws -> BandInferenceSample {
    var data = Data()
    for _ in 0..<count {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return try BandInferenceSample(payload: BandWire.field(1, sequence) + BandWire.field(2, 1_000_000 + sequence * 156_250)
        + BandWire.field(3, data) + BandWire.field(7, 84_000) + BandWire.field(10, 3))
}

/// Response layouts match the observed RPC/Uniband schema, including omitted zero defaults.
private func reply(_ request: BandModelCapture.Request, readback: UInt64? = nil, code: UInt64 = 0) -> Data {
    let payload: Data
    switch request.operation {
    case .streams(let enabled):
        payload = BandWire.field(5, [3, 4, 6, 22, 23].reduce(into: Data()) { $0 += BandWire.field($1, ($1 == 3 || $1 == 6 || enabled) ? 1 : 0) })
    case .claim: payload = BandWire.field(14, BandWire.field(1, BandWire.field(1, 38)))
    case .info(let id):
        let name = id == 27 ? "data-collection" : "data-collection-model"
        payload = BandWire.field(14, BandWire.field(2, BandWire.field(4, UInt64(id)) + BandWire.field(3, Data(name.utf8))))
    case .write(let id, _):
        payload = BandWire.field(14, BandWire.field(3, BandWire.field(1, UInt64(id)) + BandWire.field(2, 1) + BandWire.field(3, code)))
    case .snapshot(let id):
        // A band in its normal mode, unless the test says otherwise.
        let v = readback ?? (id == 27 ? 0 : 2)
        let scalar = v == 0 ? Data() : BandWire.field(1, v)
        payload = BandWire.field(14, BandWire.field(3, BandWire.field(1, UInt64(id)) + BandWire.field(3, code)
            + BandWire.field(id == 27 ? 8 : 11, scalar)))
    case .read(let id, let value):
        let v = readback ?? value
        let scalar = v == 0 ? Data() : BandWire.field(1, v)
        payload = BandWire.field(14, BandWire.field(3, BandWire.field(1, UInt64(id)) + BandWire.field(3, code)
            + BandWire.field(id == 27 ? 8 : 11, scalar)))
    case .config: payload = BandWire.field(6, BandWire.field(46, BandWire.field(3, 2) + BandWire.field(5, 9)))
    }
    return BandWire.field(1, request.id) + BandWire.field(2, 1) + payload
}

private func prepare(_ capture: BandModelCapture, model: UInt64? = nil) throws {
    try capture.start(at: 0)
    var now = 0.0
    while let request = capture.next(at: now) {
        let readback: UInt64? = request.operation == .snapshot(28) ? model : nil
        #expect(capture.receive(channel: request.channel & 0x7fff, payload: reply(request, readback: readback), at: now + 0.01))
        now += 0.02
    }
}

/// Runs a restore to its end and returns the operations it sent.
private func restored(_ capture: BandModelCapture, from start: Double, dropping dropped: BandModelCapture.Operation? = nil) -> [BandModelCapture.Operation] {
    capture.restore(at: start)
    var seen: [BandModelCapture.Operation] = []
    var now = start
    var dropOnce = dropped
    while let request = capture.next(at: now) {
        seen.append(request.operation)
        if request.operation == dropOnce {
            dropOnce = nil
            now += 6       // no answer: the request times out
            continue
        }
        capture.receive(channel: request.channel & 0x7fff, payload: reply(request), at: now + 0.01)
        now += 0.02
    }
    return seen
}

@Test func restorationWritesBackTheBandsOwnModel() throws {
    let capture = BandModelCapture()
    try prepare(capture, model: 3)
    for i in 0..<5 { capture.receive(try sample(sequence: UInt64(i)), at: 1) }
    _ = capture.next(at: 1)
    #expect(restored(capture, from: 2) == [.write(28, 3), .write(27, 0), .read(28, 3), .read(27, 0), .config, .streams(false)])
    #expect(capture.status.restorationVerified)
}

@Test func aBandLeftInTheRecordingModelGoesBackToTheNormalOne() throws {
    let capture = BandModelCapture()
    try prepare(capture, model: 5)
    #expect(restored(capture, from: 2).prefix(2) == [.write(28, 2), .write(27, 0)])
}

@Test func oneLostRestoreAnswerIsTriedAgain() throws {
    let capture = BandModelCapture()
    try prepare(capture)
    let seen = restored(capture, from: 2, dropping: .write(28, 2))
    #expect(seen.prefix(2) == [.write(28, 2), .write(28, 2)])
    #expect(capture.status.phase == .finished && capture.status.restorationVerified)
}

@Test func inferenceDecodesItsOwnPipelineAndPreservesPayload() throws {
    let value = try sample(sequence: 12)
    #expect(value.pipeline == 3 && value.sequence == 12 && value.timestampUs == 2_875_000)
    #expect(value.latencyUs == 84_000)
    #expect(value.values.count == 100 && abs(value.values[17] + log(100)) < 0.00001)
    #expect(value.isTextDistribution)
    #expect(try BandInferenceSample(payload: value.payload).values == value.values)
    #expect(try !sample(count: 9).isTextDistribution)
    #expect(throws: BandProtocolError.self) { try sample(value: .nan) }
}

@Test func modelReadinessRequiresConfirmedConfigurationAndActualSamples() throws {
    let capture = BandModelCapture()
    try prepare(capture)
    #expect(capture.status.phase == .preparing)
    for i in 0..<5 { capture.receive(try sample(sequence: UInt64(i)), at: 1) }
    #expect(capture.next(at: 1) == nil)
    #expect(capture.status.phase == .ready)
    capture.restore(at: 2)
    var seen: [BandModelCapture.Operation] = []
    var now = 2.0
    while let request = capture.next(at: now) {
        seen.append(request.operation)
        capture.receive(channel: request.channel & 0x7fff, payload: reply(request), at: now + 0.01)
        now += 0.02
    }
    #expect(seen == [.write(28, 2), .write(27, 0), .read(28, 2), .read(27, 0), .config, .streams(false)])
    #expect(capture.status.phase == .finished && capture.status.restorationVerified)
    #expect(!capture.streamWanted && !capture.status.active)
}

@Test func restorationContinuesAfterBadReadbackButDoesNotClaimSuccess() throws {
    let capture = BandModelCapture()
    try prepare(capture)
    capture.restore(at: 1)
    var now = 1.0
    var off = false
    while let request = capture.next(at: now) {
        let wrong = request.operation == .read(28, 2) ? UInt64(5) : nil
        capture.receive(channel: request.channel & 0x7fff, payload: reply(request, readback: wrong), at: now + 0.01)
        if request.operation == .streams(false) { off = true }
        now += 0.02
    }
    #expect(off && capture.status.phase == .finished)
    #expect(!capture.status.restorationVerified)
    #expect(capture.status.problem?.contains("readback") == true)
}

@Test func cancellationBeforeMutationStillStopsSubscriptionAndIgnoresStaleReplies() throws {
    let capture = BandModelCapture()
    try capture.start(at: 0)
    let old = try #require(capture.next(at: 0))
    capture.restore(at: 0.1)
    let stop = try #require(capture.next(at: 0.1))
    #expect(stop.operation == .streams(false))
    #expect(!capture.receive(channel: old.channel, payload: reply(old), at: 0.11))
    #expect(capture.pending?.id == stop.id)
    capture.receive(channel: stop.channel, payload: reply(stop), at: 0.12)
    _ = capture.next(at: 0.13)
    #expect(capture.status.restorationVerified)
}

@Test func timeoutAfterModelWriteAttemptsRestorationWithBoundedFailure() throws {
    let capture = BandModelCapture()
    try capture.start(at: 0)
    var time = 0.0
    while let request = capture.next(at: time) {
        if request.operation == .write(28, 5) { break }
        capture.receive(channel: request.channel, payload: reply(request), at: time + 0.01)
        time += 0.02
    }
    let restoring = try #require(capture.next(at: time + 6))
    #expect(restoring.operation == .write(28, 2))
    #expect(capture.status.phase == .restoring)
    _ = capture.next(at: time + 50)
    #expect(capture.status.phase == .finished && !capture.status.restorationVerified)
}

@Test func recoveryOnANewConnectionChecksSchemaThenWritesAndReadsNormalSettings() throws {
    let capture = BandModelCapture()
    try capture.recoverNormalMode(at: 0)
    var seen: [BandModelCapture.Operation] = [], now = 0.0
    while let request = capture.next(at: now) {
        seen.append(request.operation)
        capture.receive(channel: request.channel, payload: reply(request), at: now + 0.01)
        now += 0.02
    }
    #expect(seen == [.claim, .info(27), .info(28), .write(28, 2), .write(27, 0),
                     .read(28, 2), .read(27, 0), .config, .streams(false)])
    #expect(capture.status.restorationVerified && !capture.status.active)
    #expect(!capture.streamWanted)
}

@Test(arguments: [true, false]) func recoveryNeverWritesAfterRejectedOrTimedOutSchemaCheck(rejected: Bool) throws {
    let capture = BandModelCapture()
    try capture.recoverNormalMode(at: 0)
    let claim = try #require(capture.next(at: 0))
    capture.receive(channel: claim.channel, payload: reply(claim), at: 0.01)
    let info = try #require(capture.next(at: 0.02))
    if rejected {
        capture.receive(channel: info.channel, payload: BandWire.field(1, info.id) + BandWire.field(2, 2), at: 0.03)
    }
    #expect(capture.next(at: 6) == nil)
    #expect(capture.status.phase == .finished && !capture.status.restorationVerified)
}
