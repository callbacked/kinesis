import CoreBluetooth
import Foundation
import KinesisCore
import OSLog

struct KinesisError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum BandOperation { case scan, connect(String) }

@MainActor
protocol BandConnection {
    func start(_ operation: BandOperation, onEvent: @escaping (BandEvent) -> Void,
               onEnd: @escaping (Error?) -> Void) throws
    func stop()
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
    private var session: BandSession?
    private var onEvent: ((BandEvent) -> Void)?
    private var onEnd: ((Error?) -> Void)?
    private var operation: BandOperation?
    private var discovered: [UUID: BandDevice] = [:]
    private var outgoing = Data()
    private var timer: Timer?
    private var deadline = Double.infinity
    private var lastReadAt = 0.0
    private var lastStatusQuery = 0.0
    private var stopping = false
    private var disconnecting = false
    private var failure: Error?
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
        discovered.removeAll()
        self.onEvent = onEvent
        self.onEnd = onEnd
        if case .connect = operation {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Receive Neural Band controls")
        }
        deadline = now + 30
        lastReadAt = now
        lastStatusQuery = now
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        log.notice("Native band operation started")
    }

    func stop() {
        guard onEnd != nil, !stopping, !disconnecting else { return }
        stopping = true
        do {
            let bytes = try session?.stop() ?? Data()
            guard !bytes.isEmpty, channel != nil else { disconnect(); return }
            outgoing.append(bytes)
            deadline = now + 3
            try flushOutput()
        } catch { fail(error) }
    }

    private func emit(_ event: BandEvent) {
        guard !disconnecting, !stopping else { return }
        onEvent?(event)
    }

    private func tick() {
        guard onEnd != nil else { return }
        if now >= deadline {
            if disconnecting { finish(); return }
            if stopping { disconnect(); return }
            if let session {
                log.notice("Startup timed out: \(session.authenticatedPackets, privacy: .public) verified packets, streams enabled: \(session.streamsEnabled, privacy: .public), motion samples: \(session.motionMessages, privacy: .public)")
            }
            if case .scan = operation {
                emit(BandEvent(.devices(discovered.values.sorted { ($0.rssi ?? -127) > ($1.rssi ?? -127) })))
                disconnect()
            } else { fail(KinesisError(message: "The band took too long to respond. Try reconnecting.")) }
            return
        }
        guard !disconnecting else { return }
        if !stopping, let batteryCharacteristic, now >= nextBatteryRead {
            nextBatteryRead = now + 60
            peripheral?.readValue(for: batteryCharacteristic)
        }
        if !stopping, let session {
            for event in session.tick(at: now) { emit(event) }
            if session.streamsEnabled, now - lastReadAt >= 2, now - lastStatusQuery >= 2 {
                do {
                    outgoing.append(try session.queryStreamState())
                    lastStatusQuery = now
                    try flushOutput()
                } catch { fail(error) }
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
        } else {
            if case .scan = operation { deadline = now + 10 }
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
        case nil: break
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        central?.stopScan()
        central?.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === self.peripheral, !stopping, !disconnecting else { return }
        log.notice("Native Bluetooth connected")
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
        if !stopping && !disconnecting { failure = error ?? KinesisError(message: "The band disconnected") }
        finish()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard accepts(peripheral) else { return }
        if let error { fail(error); return }
        guard let services = peripheral.services, services.contains(where: { $0.uuid == serviceID }) else {
            fail(KinesisError(message: "This device doesn't expose the band input service")); return
        }
        log.info("Band services discovered")
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
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == batteryID {
                batteryCharacteristic = characteristic
                nextBatteryRead = now + 60
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
        if let error { fail(error); return }
        guard characteristic.uuid == psmID, let bytes = characteristic.value, bytes == Data([255, 0]) else {
            fail(KinesisError(message: "Unsupported band input channel")); return
        }
        log.info("Opening native L2CAP channel")
        peripheral.openL2CAPChannel(255)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard accepts(peripheral) else { return }
        if let error { fail(error); return }
        guard let channel else { fail(KinesisError(message: "Could not open the band input stream")); return }
        do {
            log.info("Native L2CAP channel opened")
            let session = try BandSession()
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
        lastReadAt = now
        let wasEnabled = session.streamsEnabled
        let wasAuthenticated = session.authenticatedPackets > 0
        let result = try session.feed(Data(buffer.prefix(count)), at: now)
        if !wasAuthenticated, session.authenticatedPackets > 0 { log.info("Native encrypted packet verified") }
        if !wasEnabled, session.streamsEnabled { log.notice("Band acknowledged gesture and motion subscription") }
        outgoing.append(result.outgoing)
        for event in result.events {
            if case .connected = event.payload {
                deadline = .infinity
                log.notice("Native band input subscription ready")
            }
            emit(event)
        }
        try flushOutput()
        if stopping, session.stopAcknowledged { disconnect() }
    }

    private func flushOutput() throws {
        guard let output = channel?.outputStream else { return }
        while !outgoing.isEmpty, output.hasSpaceAvailable {
            let count = outgoing.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: outgoing.count) }
            guard count >= 0, count <= outgoing.count else {
                throw output.streamError ?? KinesisError(message: "Could not write to the band")
            }
            guard count > 0 else { return }
            outgoing = Data(outgoing.dropFirst(count))
        }
    }

    private func fail(_ error: Error) {
        guard onEnd != nil, !disconnecting else { return }
        failure = error
        log.error("Native connection error: \(error.localizedDescription, privacy: .public)")
        disconnect()
    }

    private func disconnect() {
        guard !disconnecting else { return }
        disconnecting = true
        if stopping, let session {
            log.notice("Band streams stopped; acknowledged: \(session.stopAcknowledged, privacy: .public)")
        }
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
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if lease >= 0 { flock(lease, LOCK_UN); close(lease); lease = -1 }
        onEnd(failure)
        log.notice("Native band connection closed")
    }
}
