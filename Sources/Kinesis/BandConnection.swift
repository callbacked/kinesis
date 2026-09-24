import CoreBluetooth
import Foundation
import KinesisCore
import OSLog

struct KinesisError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum BandOperation {
    case scan, connect(String), enroll(String?)

    var isEnrollment: Bool {
        if case .enroll = self { return true }
        return false
    }
}

@MainActor
protocol BandConnection: AnyObject {
    func setRawEMGEnabled(_ enabled: Bool) throws
    func start(_ operation: BandOperation, onEvent: @escaping (BandEvent) -> Void,
               onEnd: @escaping (Error?) -> Void) throws
    func stop()
    func setHandedness(_ hand: BandHand) throws
    func resumeCeremony(_ completion: CeremonyCompletion) throws
}

extension BandConnection {
    /// Only the native connection runs an enrollment ceremony.
    func resumeCeremony(_ completion: CeremonyCompletion) throws {
        throw KinesisError(message: "This connection can't run an enrollment")
    }
}

/// CoreBluetooth and its L2CAP streams share the main run loop in common modes.
/// Reads are event driven, including while a menu is open or the window is dragged.
@MainActor
final class NativeBandConnection: NSObject, BandConnection,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate, @preconcurrency StreamDelegate {
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?
    private var batteryCharacteristic: CBCharacteristic?
    private var nextBatteryRead = 0.0
    private var nextBatteryStatusRead = 0.0
    private var rawEMGMode = false
    private var session: BandSession?
    private var onEvent: ((BandEvent) -> Void)?
    private var onEnd: ((Error?) -> Void)?
    private var operation: BandOperation?
    private var discovered: [UUID: BandDevice] = [:]
    private var outgoing = Data()
    private var timer: Timer?
    private var deadline = Double.infinity
    private var lastReadAt = 0.0
    private var lastSensorReadAt = 0.0
    private var lastStatusQuery = 0.0
    private var trafficMetricsAt = 0.0
    private var lastTickAt = 0.0
    private var maxTickGap = 0.0
    private var maxReadGap = 0.0
    private var readBytes = 0
    private var writtenBytes = 0
    private var previousMotionMessages = 0
    private var stopping = false
    private var disconnecting = false
    private var failure: Error?
    private var stage = "idle"
    private var inputReadStartedAt: Double?
    private var systemPairingNoted = false
    private var identityRejected: Set<String> = []
    private var lease: Int32 = -1
    private var activity: NSObjectProtocol?
    private let log = Logger(subsystem: "local.callbacked.kinesis", category: "bluetooth")
    private let serviceID = CBUUID(string: "FEB8")
    private let psmID = CBUUID(string: "2D41DA7C-82B6-42AA-B34E-E2E01DF8CC1A")
    private let batteryServiceID = CBUUID(string: "180F")
    private let batteryID = CBUUID(string: "2A19")
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func start(_ operation: BandOperation, onEvent: @escaping (BandEvent) -> Void,
               onEnd: @escaping (Error?) -> Void) throws {
        guard self.onEnd == nil else { throw KinesisError(message: "A band operation is already running") }
        if case .connect(let address) = operation, UUID(uuidString: address) == nil {
            throw KinesisError(message: "Choose a band before connecting")
        }
        if case .enroll(let address) = operation, let address, UUID(uuidString: address) == nil {
            throw KinesisError(message: "Choose a band before enrolling it")
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kinesis", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("band.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw KinesisError(message: "Could not open the band connection lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw KinesisError(message: "Another Kinesis connection is active")
        }
        lease = descriptor
        self.operation = operation
        stopping = false
        disconnecting = false
        failure = nil
        stage = "waiting for Bluetooth"
        discovered.removeAll()
        self.onEvent = onEvent
        self.onEnd = onEnd
        if case .connect = operation {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Receive Neural Band controls")
        }
        // Enrollment walks the full ownership ceremony over HTTP before the
        // startup flow, so its budget is larger than a plain connection's.
        deadline = now + (operation.isEnrollment ? 180 : 30)
        lastReadAt = now
        lastSensorReadAt = now
        lastStatusQuery = now
        trafficMetricsAt = now
        lastTickAt = now
        maxTickGap = 0
        maxReadGap = 0
        readBytes = 0
        writtenBytes = 0
        previousMotionMessages = 0
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        switch operation {
        case .scan: log.notice("Native band scan started")
        case .connect(let address):
            log.notice("Native band connection started for \(address, privacy: .private(mask: .hash))")
        case .enroll(let address):
            log.notice("Native band enrollment started for \(address ?? "the next band in pairing mode", privacy: .public)")
        }
    }

    func stop() {
        guard onEnd != nil, !stopping, !disconnecting else { return }
        stopping = true
        stage = "stopping streams"
        do {
            let bytes = try session?.stop() ?? Data()
            guard !bytes.isEmpty, channel != nil else { disconnect(); return }
            outgoing.append(bytes)
            deadline = now + 3
            try flushOutput()
        } catch { fail(error) }
    }

    func setRawEMGEnabled(_ enabled: Bool) throws {
        rawEMGMode = enabled
        if let session, !stopping, !disconnecting {
            outgoing.append(try session.setRawEMGEnabled(enabled, at: now))
            try flushOutput()
        }
    }

    func setHandedness(_ hand: BandHand) throws {
        guard let session, !stopping, !disconnecting else {
            throw KinesisError(message: "Connect the band before choosing a hand.")
        }
        outgoing.append(try session.setHandedness(hand, at: now))
        try flushOutput()
        log.notice("Requested band hand: \(hand.rawValue, privacy: .public)")
    }

    func resumeCeremony(_ completion: CeremonyCompletion) throws {
        guard let session, channel != nil, !stopping, !disconnecting else {
            throw KinesisError(message: "The band connection closed during the enrollment")
        }
        switch completion {
        case .pairRequest(let signature, let receipt):
            outgoing.append(try session.ceremonyPairRequestCompleted(signature: signature, receipt: receipt))
        case .pair(let signature, let receipt, let devicePublicKey):
            outgoing.append(try session.ceremonyPairCompleted(signature: signature, receipt: receipt,
                                                              devicePublicKey: devicePublicKey))
        }
        try flushOutput()
    }

    private func emit(_ event: BandEvent) {
        guard !disconnecting, !stopping else { return }
        if case .handedness(let hand) = event.payload {
            log.notice("Band hand confirmed: \(hand.rawValue, privacy: .public)")
        }
        switch event.payload {
        case .batteryStatus(let status):
            if let status {
                log.info("Battery status: \(status.level, privacy: .public)%, charging \(String(describing: status.charging), privacy: .public)")
            } else { log.info("Battery charging status unavailable") }
        case .rawEMGConfiguration(let config):
            log.notice("EMG configuration: \(config.channels, privacy: .public) channels at \(config.sampleRate, privacy: .public) Hz, encoding \(config.encoding, privacy: .public)")
        case .rawEMGState(let enabled):
            log.notice("EMG subscription confirmed: \(enabled, privacy: .public)")
        case .rawEMGFailure(let message):
            log.error("EMG subscription: \(message, privacy: .public)")
        case .rawEMGFrame:
            if session?.rawEMGFrames == 1 { log.notice("First EMG sensor payload received") }
        default: break
        }
        onEvent?(event)
    }

    private func tick() {
        guard onEnd != nil else { return }
        let time = now
        maxTickGap = max(maxTickGap, time - lastTickAt)
        lastTickAt = time
        if now >= deadline {
            if disconnecting { finish(); return }
            if stopping { disconnect(); return }
            if let session {
                log.notice("Startup timed out: \(session.authenticatedPackets, privacy: .public) verified packets, streams enabled: \(session.streamsEnabled, privacy: .public), motion samples: \(session.motionMessages, privacy: .public)")
            }
            if case .scan = operation {
                log.notice("Native band scan finished: \(self.discovered.count, privacy: .public) bands found")
                emit(BandEvent(.devices(discovered.values.sorted { ($0.rssi ?? -127) > ($1.rssi ?? -127) })))
                disconnect()
            } else { fail(KinesisError(message: "The band took too long to respond. Try reconnecting.")) }
            return
        }
        guard !disconnecting else { return }
        if !stopping, !systemPairingNoted, let started = inputReadStartedAt, now - started >= 1.5 {
            // This read answers in milliseconds on a bonded link. A slow one means
            // macOS is pairing, which waits on a request the user has to accept.
            systemPairingNoted = true
            deadline = max(deadline, now + 40)
            log.notice("Input channel read is waiting; macOS is likely asking to pair")
            emit(BandEvent(.systemPairingPending))
        }
        if !stopping, let batteryCharacteristic, now >= nextBatteryRead {
            nextBatteryRead = now + 60
            peripheral?.readValue(for: batteryCharacteristic)
        }
        if !stopping, let session {
            for event in session.tick(at: now) { emit(event) }
            if session.streamsEnabled, now >= nextBatteryStatusRead {
                nextBatteryStatusRead = now + 5
                do {
                    outgoing.append(try session.queryBatteryStatus(at: now))
                    try flushOutput()
                } catch { fail(error) }
            }
            if session.streamsEnabled, now - lastSensorReadAt >= 2, now - lastStatusQuery >= 2 {
                do {
                    outgoing.append(try session.queryStreamState())
                    lastStatusQuery = now
                    try flushOutput()
                } catch { fail(error) }
            }
            if session.streamsEnabled, time - trafficMetricsAt >= 10 {
                let motion = session.motionMessages - previousMotionMessages
                log.info("Band traffic: \(self.readBytes, privacy: .public) bytes read, \(self.writtenBytes, privacy: .public) written, \(self.outgoing.count, privacy: .public) queued; \(motion, privacy: .public) motion samples; sensor age \(time - self.lastSensorReadAt, privacy: .public)s; read gap max \(self.maxReadGap, privacy: .public)s; timer gap max \(self.maxTickGap, privacy: .public)s")
                trafficMetricsAt = time
                previousMotionMessages = session.motionMessages
                readBytes = 0
                writtenBytes = 0
                maxReadGap = 0
                maxTickGap = 0
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central, !disconnecting else { return }
        guard central.state == .poweredOn else {
            switch central.state {
            case .unauthorized: fail(KinesisError(message: "Allow Bluetooth access for Kinesis in System Settings"))
            case .unsupported: fail(KinesisError(message: "Bluetooth is unsupported on this Mac"))
            case .poweredOff: fail(KinesisError(message: "Turn Bluetooth on to connect your band"))
            case .resetting: if peripheral != nil { fail(KinesisError(message: "Bluetooth is restarting")) }
            default: break
            }
            return
        }
        guard peripheral == nil else { return }
        if case .connect(let address) = operation, let identifier = UUID(uuidString: address),
           let known = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            connect(known)
        } else if case .enroll(let address) = operation, let address, let identifier = UUID(uuidString: address),
                  let known = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            connect(known)
        } else {
            if case .scan = operation { deadline = now + 10 }
            stage = "scanning"
            central.scanForPeripherals(withServices: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, !stopping, !disconnecting else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        switch operation {
        case .scan:
            if name.lowercased().hasPrefix("meta band") {
                discovered[peripheral.identifier] = BandDevice(address: peripheral.identifier.uuidString, name: name, rssi: RSSI.intValue)
            }
        case .connect(let address):
            if peripheral.identifier == UUID(uuidString: address), self.peripheral == nil { connect(peripheral) }
        case .enroll(let address):
            guard self.peripheral == nil else { return }
            if let address {
                if peripheral.identifier == UUID(uuidString: address) { connect(peripheral) }
            } else if name.lowercased().hasPrefix("meta band") {
                connect(peripheral)
            }
        case nil: break
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        stage = "connecting"
        central?.stopScan()
        central?.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === self.peripheral, !stopping, !disconnecting else { return }
        log.notice("Native Bluetooth connected")
        stage = "discovering services"
        emit(BandEvent(.preparing))
        peripheral.delegate = self
        peripheral.discoverServices([serviceID, batteryServiceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral else { return }
        fail(error ?? KinesisError(message: "Could not connect to the band"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral else { return }
        if !stopping && !disconnecting { recordFailure(error ?? KinesisError(message: "The band disconnected")) }
        finish()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard accepts(peripheral) else { return }
        if let error { fail(error); return }
        guard let services = peripheral.services, services.contains(where: { $0.uuid == serviceID }) else {
            fail(KinesisError(message: "This device doesn't expose the band input service")); return
        }
        log.info("Band services discovered")
        stage = "discovering characteristics"
        for service in services {
            peripheral.discoverCharacteristics(service.uuid == serviceID ? [psmID] : [batteryID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard accepts(peripheral) else { return }
        if let error {
            if service.uuid == serviceID { fail(error) }
            return
        }
        if service.uuid == serviceID, service.characteristics?.contains(where: { $0.uuid == psmID }) != true {
            fail(KinesisError(message: "Band input channel is unavailable")); return
        }
        if service.uuid == serviceID {
            stage = "reading input channel"
            inputReadStartedAt = now
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == batteryID {
                batteryCharacteristic = characteristic
                nextBatteryRead = now + 60
                if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
            }
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard accepts(peripheral) else { return }
        if characteristic.uuid == batteryID {
            if error == nil, let bytes = characteristic.value, bytes.count == 1, let value = bytes.first, value <= 100 {
                emit(BandEvent(.battery(Int(value))))
            }
            return
        }
        inputReadStartedAt = nil
        if let error {
            let native = error as NSError
            log.error("Input channel read failed: \(native.domain, privacy: .public) \(native.code, privacy: .public)")
            fail(Self.explainingPairing(error)); return
        }
        guard characteristic.uuid == psmID, let bytes = characteristic.value, bytes == Data([255, 0]) else {
            fail(KinesisError(message: "Unsupported band input channel")); return
        }
        log.info("Opening native L2CAP channel")
        stage = "opening input channel"
        peripheral.openL2CAPChannel(255)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard accepts(peripheral) else { return }
        if let error { fail(error); return }
        guard let channel else { fail(KinesisError(message: "Could not open the band input stream")); return }
        do {
            log.info("Native L2CAP channel opened")
            stage = "handshaking"
            let identifier = peripheral.identifier.uuidString
            let session: BandSession
            if case .enroll = operation {
                // A fresh ceremony replaces the ownership record, so past
                // identity rejections no longer apply to the adopted key.
                identityRejected.remove(identifier)
                // A pairing-mode band runs the ownership ceremony with a fresh
                // app identity; the enrolled startup takes over after it.
                log.notice("Starting band ownership ceremony")
                session = try BandSession(ceremony: OwnershipCeremony(bandID: identifier), rawEMG: rawEMGMode)
            } else {
                // A stored identity authenticates enrolled bands; a band that
                // rejected the identity falls back to the legacy startup.
                let enrollment = identityRejected.contains(identifier) ? nil : BandIdentity.enrollment(for: identifier)
                if enrollment != nil { log.notice("Authenticating with the stored band identity") }
                session = try BandSession(enrollment: enrollment, rawEMG: rawEMGMode)
            }
            self.session = session
            self.channel = channel
            outgoing = try session.request()
            for stream in [channel.inputStream as Stream, channel.outputStream as Stream] {
                stream.delegate = self
                stream.schedule(in: .main, forMode: .common)
                stream.open()
            }
            try flushOutput()
        } catch { fail(error) }
    }

    private func accepts(_ peripheral: CBPeripheral) -> Bool {
        peripheral === self.peripheral && !stopping && !disconnecting
    }

    func stream(_ stream: Stream, handle eventCode: Stream.Event) {
        guard let channel, !disconnecting, stream === channel.inputStream || stream === channel.outputStream else { return }
        do {
            if eventCode.contains(.errorOccurred) {
                throw stream.streamError ?? KinesisError(message: "The band input stream failed")
            }
            if eventCode.contains(.endEncountered) {
                if stopping { disconnect(); return }
                throw KinesisError(message: "The band input stream ended")
            }
            if eventCode.contains(.hasBytesAvailable) { try readInput() }
            if eventCode.contains(.hasSpaceAvailable) { try flushOutput() }
        } catch { fail(error) }
    }

    private func readInput() throws {
        guard let input = channel?.inputStream, let session else { return }
        // A bounded read yields to the UI; Foundation sends another event for remaining bytes.
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = input.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { throw input.streamError ?? KinesisError(message: "Could not read band input") }
        guard count > 0 else { return }
        let time = now
        maxReadGap = max(maxReadGap, time - lastReadAt)
        lastReadAt = time
        readBytes += count
        let wasEnabled = session.streamsEnabled
        let wasAuthenticated = session.authenticatedPackets > 0
        let result = try session.feed(Data(buffer.prefix(count)), at: time)
        if !wasAuthenticated, session.authenticatedPackets > 0 { log.info("Native encrypted packet verified") }
        if !wasEnabled, session.streamsEnabled { log.notice("Band acknowledged gesture and motion subscription") }
        outgoing.append(result.outgoing)
        if !wasEnabled {
            log.info("Native startup read: \(count, privacy: .public) bytes, \(session.authenticatedPackets, privacy: .public) verified packets, \(result.outgoing.count, privacy: .public) reply bytes, \(self.outgoing.count, privacy: .public) queued bytes")
        }
        for event in result.events {
            if case .dataSeen = event.payload { lastSensorReadAt = time }
            if case .connected = event.payload {
                deadline = .infinity
                stage = "receiving input"
                log.notice("Native band input subscription ready")
            }
            emit(event)
        }
        try flushOutput()
        if stopping, session.stopAcknowledged { disconnect() }
    }

    private func flushOutput() throws {
        guard let output = channel?.outputStream else { return }
        let queued = outgoing.count
        while !outgoing.isEmpty, output.hasSpaceAvailable {
            let count = outgoing.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: outgoing.count) }
            guard count >= 0, count <= outgoing.count else {
                throw output.streamError ?? KinesisError(message: "Could not write to the band")
            }
            guard count > 0 else { return }
            writtenBytes += count
            outgoing = Data(outgoing.dropFirst(count))
        }
        if queued > 0, session?.streamsEnabled != true {
            log.info("Native startup write: \(queued - self.outgoing.count, privacy: .public) bytes written, \(self.outgoing.count, privacy: .public) queued bytes")
        }
    }

    private func fail(_ error: Error) {
        guard onEnd != nil, !disconnecting else { return }
        if error is BandIdentityMismatchError, let peripheral {
            identityRejected.insert(peripheral.identifier.uuidString)
            log.notice("Stored band identity rejected; reconnecting without it")
        }
        recordFailure(error)
        disconnect()
    }

    /// Seen once, after a factory reset: the band had a new identity key, macOS accepted the
    /// pairing request, and then dropped the pairing because the band's old entry was still in
    /// its list ("already paired, with a different irk. Unpair first"). No app can remove that
    /// entry. The advice stays a suggestion, because one sighting is not a rule.
    static let stalePairingAdvice = "macOS couldn't finish pairing with your band. If the band has an old entry under System Settings › Bluetooth, forget it there and pair again."
    static let bluetoothSettings = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!

    /// CoreBluetooth reports a system pairing that went wrong as an ATT security error. The
    /// raw text tells the user nothing they can act on, and the two causes need different advice.
    static func explainingPairing(_ error: Error) -> Error {
        let native = error as NSError
        guard native.domain == CBATTErrorDomain else { return error }
        switch native.code {
        case CBATTError.insufficientEncryption.rawValue:
            // The request was accepted, and the link still is not trusted: the stale entry.
            return KinesisError(message: stalePairingAdvice)
        case CBATTError.insufficientAuthentication.rawValue, CBATTError.insufficientAuthorization.rawValue:
            // The request was missed, declined, or timed out.
            return KinesisError(message: "macOS didn't finish pairing with your band. Pair again and accept the Bluetooth request when it appears. If none appears, restart your Mac.")
        default:
            return error
        }
    }

    private func recordFailure(_ error: Error) {
        failure = error
        let nativeError = error as NSError
        log.error("Native connection error during \(self.stage, privacy: .public): \(nativeError.domain, privacy: .public) \(nativeError.code, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    private func disconnect() {
        guard !disconnecting else { return }
        disconnecting = true
        if stopping, let session {
            log.notice("Band streams stopped; acknowledged: \(session.stopAcknowledged, privacy: .public)")
        }
        stage = "disconnecting"
        onEvent?(BandEvent(.disconnected))
        closeStreams()
        central?.stopScan()
        if let peripheral, peripheral.state != .disconnected {
            deadline = now + 2
            central?.cancelPeripheralConnection(peripheral)
        } else { finish() }
    }

    private func closeStreams() {
        if let channel {
            for stream in [channel.inputStream as Stream, channel.outputStream as Stream] {
                stream.delegate = nil
                stream.close()
                stream.remove(from: .main, forMode: .common)
            }
        }
        channel = nil
    }

    private func finish() {
        guard let onEnd else { return }
        self.onEnd = nil
        self.onEvent = nil
        closeStreams()
        timer?.invalidate()
        timer = nil
        central?.stopScan()
        central?.delegate = nil
        peripheral?.delegate = nil
        central = nil
        peripheral = nil
        batteryCharacteristic = nil
        session = nil
        outgoing.removeAll()
        operation = nil
        stage = "idle"
        inputReadStartedAt = nil
        systemPairingNoted = false
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if lease >= 0 { flock(lease, LOCK_UN); close(lease); lease = -1 }
        log.notice("Native band operation closed")
        onEnd(failure)
    }
}
