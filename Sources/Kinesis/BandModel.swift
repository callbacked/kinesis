import AppKit
import Combine
import Foundation
import KinesisCore
import OSLog

@MainActor
enum EnrollmentStage: Equatable {
    case idle, login, pairing
    case working(String)
    case done
    case failed(String)

    var isRunning: Bool { self == .pairing || workingText != nil }
    var workingText: String? { if case .working(let text) = self { return text } else { return nil } }
    var failedText: String? { if case .failed(let message) = self { return message } else { return nil } }
}

/// Where the one-button pair pipeline currently is. `.none` means no pair
/// run is in flight.
@MainActor
enum PairRoute: Equatable {
    case none, scanning, connecting, enrolling
}

@MainActor
final class BandModel: ObservableObject {
    let dialTurns = PassthroughSubject<Double, Never>()
    @Published private(set) var devices: [BandDevice] = []
    @Published private(set) var discoveredAddresses: Set<String> = []
    @Published var selectedAddress = "" {
        didSet { saveBand(); refreshIdentity() }
    }
    @Published private(set) var phase = "Disconnected"
    @Published private(set) var busy = false
    @Published private(set) var wantsConnection = false
    @Published private(set) var live = false
    @Published private(set) var controlsEnabled = false
    @Published var startsAutomatically = false {
        didSet {
            defaults.set(startsAutomatically, forKey: "startsAutomatically")
            if !startsAutomatically { automaticStartPending = false }
        }
    }
    @Published private(set) var bandHand = BandHand.right
    @Published private(set) var pendingHand: BandHand?
    @Published private(set) var handConfirmed = false
    @Published private(set) var handSettingError: String?
    @Published private(set) var showingSetup = true
    @Published private(set) var accessibilityAllowed = false
    @Published private(set) var hasBandIdentity = false
    @Published private(set) var enrollmentStage: EnrollmentStage = .idle
    @Published private(set) var hasSavedMetaSession = false
    /// The band refused this Mac's stored identity on recent connect attempts.
    @Published private(set) var bandRejectsIdentity = false
    @Published private(set) var pairRoute: PairRoute = .none
    /// The one lowercase failure line shown when a pair run ends badly.
    @Published private(set) var pairFailure: String?
    /// Consecutive pair-flow scans that found nothing.
    @Published private(set) var emptyScans = 0
    /// The stage a failed pair run stopped at, so the surface can mark it.
    @Published private(set) var pairFailedStep: PairStep?
    /// macOS is waiting for the user to accept its Bluetooth pairing request.
    @Published private(set) var awaitingSystemPairing = false
    /// True for a few seconds after a claim lands, for the band page's success beat.
    @Published private(set) var justPaired = false
    @Published private(set) var battery: Int?
    @Published private(set) var lastGesture = "Waiting for a gesture"
    @Published private(set) var lastDirection: SwipeDirection?
    @Published private(set) var gestureCount = 0
    @Published private(set) var totalGestureCount = 0
    @Published private(set) var recognizedGesture: RecognizedGesture?
    @Published private(set) var lastAction = "Controls are paused"
    @Published private(set) var dialEngaged = false
    @Published private(set) var pinchedFinger: String?
    @Published var tapMappings: [TapGesture: MacAction] = [.indexTap: .none, .indexDoubleTap: .playPause, .middleTap: .none, .middleDoubleTap: .mute, .middleHold: .none] {
        didSet {
            defaults.set(Dictionary(uniqueKeysWithValues: tapMappings.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: "tapMappings")
        }
    }
    @Published var dialTarget = DialTarget.volume {
        didSet { defaults.set(dialTarget.rawValue, forKey: "dialTarget"); resetDial() }
    }
    @Published var dialSensitivity = 1.0 {
        didSet { defaults.set(dialSensitivity, forKey: "dialSensitivity"); resetDial() }
    }
    @Published var error: String?
    @Published var mappings: [SwipeDirection: MacAction] = [.left: .previousDesktop, .right: .nextDesktop, .up: .missionControl, .down: .dismiss] {
        didSet {
            defaults.set(Dictionary(uniqueKeysWithValues: mappings.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: "swipeMappings")
        }
    }

    private let clock: () -> Double
    private let defaults: UserDefaults
    private let connection: any BandConnection
    private let controls: any MacControls
    private let pairClient: @Sendable (MetaSession) -> any BandPairClient
    private let sessionStore: any MetaSessionStoring
    private let forgetSystemPairing: (String) -> Bool
    private var enrollSession: MetaSession?
    /// Set when a ceremony HTTP step failed with an auth-class error; the
    /// login sheet appears once the connection has wound down.
    private var pendingRelogin = false
    private var connectRejections = 0
    private var pairAttempts = 0
    private var activeOperation: BandOperation?
    private var router = GestureRouter()
    private var gate = ActionGate()
    private var dialGate = ActionGate(minimumInterval: 0)
    private var dialRouter = DialRouter()
    private var dialArmed = false
    private var lastDialAction = -Double.infinity
    /// Letting go of a turn looks like a tap to the band. These tell the two apart.
    private var dialTurned = false
    private var dialEndedAt = -Double.infinity
    private var heartbeat: Double?
    private var started = 0.0
    private var retry: Task<Void, Never>?
    private var scanPending = false
    private var claimedThisRun = false
    private var celebration: Task<Void, Never>?
    private var ticker: AnyCancellable?
    private var sleepObserver: AnyCancellable?
    private var wakeObserver: AnyCancellable?
    private var sleeping = false
    private var quitting = false
    private var automaticStartPending = false
    private var retries = 0
    private let connectionLog = Logger(subsystem: "local.callbacked.kinesis", category: "connection")
    private var metricsAt = 0.0
    private var maxDeliveryDelay = 0.0
    private var maxInputGap = 0.0

    var bandName: String { devices.first { $0.address == selectedAddress }?.name ?? "Neural Band" }
    var canScan: Bool { !quitting && !sleeping && (!busy || wantsConnection) }
    var canChangeHand: Bool { live && handConfirmed && pendingHand == nil }
    var handSettingStatus: String {
        if let handSettingError { return handSettingError }
        if pendingHand != nil { return "switching hands…" }
        if !live { return "connect your band to choose a hand." }
        if !handConfirmed { return "checking your band’s hand…" }
        return "\(bandHand.rawValue) hand · confirmed by your band"
    }

    /// The band page's two-action model: everything that isn't a usable
    /// paired band funnels into the one "pair band" action. Pairing surfaces
    /// hide while the band is connected, busy, or streaming.
    var showsPairAction: Bool {
        if pairRoute != .none || enrollmentStage != .idle || pairFailure != nil { return true }
        guard !busy, !live, !controlsEnabled else { return false }
        return selectedAddress.isEmpty || !hasBandIdentity || bandRejectsIdentity
    }

    var pairInProgress: Bool { pairRoute != .none }

    var canPair: Bool { !busy && !quitting && !sleeping && enrollmentStage == .idle }

    /// Inline progress shown next to the pair button.
    var pairProgressText: String? {
        switch pairRoute {
        case .none: return nil
        case .scanning: return "finding your band…"
        case .connecting: return "connecting to your band…"
        case .enrolling:
            if enrollmentStage == .login { return nil }
            return enrollmentStage.workingText.map { $0 + "…" } ?? "claiming your band…"
        }
    }

    /// The hold-button hint shows while a claim-needing pair run scans, and
    /// stays up once scans have come up empty twice in a row.
    var showsHoldHint: Bool { pairRoute == .scanning || emptyScans >= 2 }

    func deviceLabel(_ device: BandDevice) -> String {
        let status: String
        if device.address == selectedAddress && live {
            status = "connected"
        } else {
            status = discoveredAddresses.contains(device.address) ? "found in scan" : "remembered"
        }
        let duplicateName = devices.contains { $0.address != device.address && $0.name == device.name }
        return "\(device.name) · \(status)" + (duplicateName ? " · \(device.address)" : "")
    }

    init(defaults: UserDefaults = .standard,
         connection: any BandConnection = NativeBandConnection(),
         controls: any MacControls = MacShortcuts(),
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         pairClient: @escaping @Sendable (MetaSession) -> any BandPairClient = { MetaPairClient(session: $0) },
         sessionStore: any MetaSessionStoring = MetaSessionStore(),
         // Does nothing unless the app passes the real one: a test must never touch this Mac's pairings.
         forgetSystemPairing: @escaping (String) -> Bool = { _ in false },
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.forgetSystemPairing = forgetSystemPairing
        self.clock = clock
        self.defaults = defaults
        self.started = clock()
        self.metricsAt = clock()
        self.connection = connection
        self.controls = controls
        self.pairClient = pairClient
        self.sessionStore = sessionStore
        accessibilityAllowed = controls.trusted
        hasSavedMetaSession = sessionStore.hasSavedSession()
        startsAutomatically = defaults.bool(forKey: "startsAutomatically")
        bandHand = BandHand(rawValue: defaults.string(forKey: "bandHand") ?? "") ?? .right
        showingSetup = !defaults.bool(forKey: "setupCompleted")
        totalGestureCount = max(0, defaults.integer(forKey: "totalGestureCount"))
        if let data = defaults.data(forKey: "band"),
           let band = try? JSONDecoder().decode(BandDevice.self, from: data) {
            devices = [band]
            selectedAddress = band.address
        }
        if let saved = defaults.dictionary(forKey: "swipeMappings") as? [String: String] {
            for (key, value) in saved {
                if let direction = SwipeDirection(rawValue: key), let action = MacAction(rawValue: value) {
                    mappings[direction] = action
                }
            }
        }
        if let saved = defaults.dictionary(forKey: "tapMappings") as? [String: String] {
            for (key, value) in saved {
                if let tap = TapGesture(rawValue: key), let action = MacAction(rawValue: value) { tapMappings[tap] = action }
            }
        }
        if let saved = defaults.string(forKey: "dialTarget"), let target = DialTarget(rawValue: saved) { dialTarget = target }
        let sensitivity = defaults.double(forKey: "dialSensitivity")
        if (0.5...4).contains(sensitivity) { dialSensitivity = sensitivity }
        refreshIdentity()
        ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        sleepObserver = workspaceNotifications.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true
                self.retry?.cancel()
                self.scanPending = false
                self.live = false
                self.suspendActions()
                self.connection.stop()
            }
        }
        wakeObserver = workspaceNotifications.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                if !self.busy {
                    if self.wantsConnection { self.scheduleReconnect() }
                    else { self.phase = "Disconnected" }
                }
            }
        }
    }

    private func saveBand() {
        if selectedAddress.isEmpty {
            defaults.removeObject(forKey: "band")
            return
        }
        guard let band = devices.first(where: { $0.address == selectedAddress }),
              let data = try? JSONEncoder().encode(band) else { return }
        defaults.set(data, forKey: "band")
    }

    func scan() {
        guard canScan else { return }
        disconnect()
        if busy {
            scanPending = true
            phase = "Disconnecting before scan…"
        } else {
            run(.scan)
        }
    }

    func forgetBand() {
        guard !selectedAddress.isEmpty, !quitting else { return }
        disconnect()
        selectedAddress = ""
        devices.removeAll()
        discoveredAddresses.removeAll()
        battery = nil
        error = nil
    }

    func refreshIdentity() {
        hasBandIdentity = !selectedAddress.isEmpty && BandIdentity.exists(for: selectedAddress)
        // A different band or a restored identity makes past rejections stale.
        bandRejectsIdentity = false
        connectRejections = 0
    }

    /// The band page's low-emphasis reset: one confirmed step clears the
    /// remembered band, its stored identity, and the Meta session. The band
    /// stays enrolled server-side; pairing again rebinds it.
    /// A clean slate: the band, its key, the Meta sign-in, and this Mac's own Bluetooth
    /// pairing. False if macOS still holds the pairing, and the person has to remove it.
    @discardableResult func forgetEverything() -> Bool {
        cancelEnrollment()
        let address = selectedAddress
        let name = devices.first { $0.address == address }?.name
        if !address.isEmpty { forgetBand() }
        // No remembered band means no pairing of ours to remove.
        let unpaired = name.map(forgetSystemPairing) ?? true
        BandIdentity.delete(for: address)
        sessionStore.deleteSession()
        hasSavedMetaSession = false
        pairFailure = nil
        pairFailedStep = nil
        emptyScans = 0
        connectionLog.notice("Forgot the band, its identity, and the Meta session; system pairing removed: \(unpaired, privacy: .public)")
        return unpaired
    }

    /// The privacy escape hatch beside the pairing progress: drops the saved
    /// session so the band can bind to a different account. With a ceremony
    /// in flight it winds the connection down and asks for one fresh sign-in;
    /// otherwise the next pair press starts at the sign-in sheet.
    func switchMetaAccount() {
        sessionStore.deleteSession()
        hasSavedMetaSession = false
        pendingRelogin = false
        guard enrollmentStage.isRunning else { return }
        enrollmentStage = .login
        connection.stop()
        connectionLog.notice("Switching Meta accounts; asking for a fresh sign-in")
    }

    // MARK: pairing

    /// The pairing surface reads only this value.
    var pairing: PairingPresentation {
        PairingPresentation(PairingInput(
            route: pairRoute, stage: enrollmentStage, failure: pairFailure, failedStep: pairFailedStep,
            emptyScans: emptyScans, hasRememberedBand: !selectedAddress.isEmpty,
            bandName: selectedAddress.isEmpty ? nil : bandName, identityRejected: hasBandIdentity && bandRejectsIdentity,
            claimedThisRun: claimedThisRun, awaitingSystemPairing: awaitingSystemPairing,
            hasSavedSession: hasSavedMetaSession, canPair: canPair))
    }

    /// Stops a pair run at any stage. A run that never reached the band just ends.
    func cancelPairing() {
        guard pairRoute != .none || enrollmentStage != .idle else { return }
        if enrollmentStage != .idle { cancelEnrollment() }
        pairRoute = .none
        claimedThisRun = false
        disconnect()
    }

    /// The whole pipeline behind the band page's one button: scan when
    /// nothing is remembered, connect, and evaluate the band's response. A
    /// stored identity unlocks on connect. A mismatch, a persistent legacy
    /// rejection, or a factory-fresh band auto-enrolls with the saved Meta
    /// session (the sign-in sheet appears only without one) and reconnects.
    func pairBand() {
        guard !busy, !quitting, !sleeping, enrollmentStage == .idle else { return }
        disconnect()
        error = nil
        pairFailure = nil
        pairFailedStep = nil
        claimedThisRun = false
        pendingRelogin = false
        pairAttempts = 0
        if selectedAddress.isEmpty {
            pairRoute = .scanning
            run(.scan)
        } else if BandIdentity.exists(for: selectedAddress) {
            startPairConnect()
        } else {
            startPairEnrollment()
        }
    }

    private func startPairConnect() {
        pairAttempts += 1
        pairRoute = .connecting
        enrollmentStage = .idle
        run(.connect(selectedAddress))
    }

    private func startPairEnrollment() {
        pairRoute = .enrolling
        // A saved session claims the band straight away; only its absence
        // opens the sign-in sheet.
        if let session = sessionStore.restoreSession() {
            startEnrollment(with: session)
        } else {
            enrollmentStage = .login
        }
    }

    /// Once a band is on record, its stored identity decides the route: trust
    /// unlocks an enrolled band, anything else runs the ownership ceremony.
    private func routeForSelectedBand() {
        if BandIdentity.exists(for: selectedAddress) {
            startPairConnect()
        } else {
            startPairEnrollment()
        }
    }

    private func startEnrollment(with session: MetaSession) {
        enrollSession = session
        let target = selectedAddress.isEmpty ? nil : selectedAddress
        run(.enroll(target))
        enrollmentStage = .pairing
    }

    /// Called after the Meta sign-in sheet returns a user session. The session
    /// persists for future enrollments; claiming starts immediately.
    func enroll(session: MetaSession) {
        guard enrollmentStage == .login else { return }
        sessionStore.saveSession(session)
        hasSavedMetaSession = true
        startEnrollment(with: session)
    }

    func cancelEnrollment() {
        guard enrollmentStage != .idle else { return }
        let running = enrollmentStage.isRunning
        enrollmentStage = .idle
        enrollSession = nil
        pendingRelogin = false
        pairRoute = .none
        if running { disconnect() }
    }

    func finishEnrollment() {
        claimedThisRun = true
        enrollmentStage = .done
        enrollSession = nil
        disconnect()
        refreshIdentity()
        connectionLog.notice("Band enrollment completed")
    }

    func startAutomatically() {
        guard startsAutomatically, !showingSetup, !selectedAddress.isEmpty else { return }
        automaticStartPending = true
        connect()
    }

    func connect() {
        guard !selectedAddress.isEmpty, !busy, !quitting else { return }
        wantsConnection = true
        retries = 0
        saveBand()
        run(.connect(selectedAddress))
    }

    func disconnect() {
        wantsConnection = false
        scanPending = false
        retry?.cancel()
        retry = nil
        pause()
        live = false
        handConfirmed = false
        pendingHand = nil
        phase = busy ? "Disconnecting…" : "Disconnected"
        connection.stop()
    }

    func toggleControls() {
        if controlsEnabled { pause(); return }
        guard !showingSetup, pendingHand == nil else { return }
        accessibilityAllowed = controls.trusted
        guard accessibilityAllowed else {
            requestAccessibility()
            return
        }
        guard live else { return }
        automaticStartPending = false
        gate.arm(at: clock())
        resetDial()
        controlsEnabled = true
        error = nil
        lastAction = "Ready for your next gesture"
    }

    func pause() {
        automaticStartPending = false
        suspendActions()
        controlsEnabled = false
        lastAction = "Controls are paused"
    }

    func selectHand(_ hand: BandHand) {
        guard canChangeHand, hand != bandHand else { return }
        pause()
        router.reset()
        recognizedGesture = nil
        lastDirection = nil
        lastGesture = "Waiting for a gesture"
        pendingHand = hand
        handSettingError = nil
        do {
            try connection.setHandedness(hand)
        } catch {
            pendingHand = nil
            handConfirmed = false
            handSettingError = error.localizedDescription
        }
    }

    func beginSetup() {
        pause()
        showingSetup = true
    }

    func finishSetup(enableControls: Bool = false) {
        showingSetup = false
        defaults.set(true, forKey: "setupCompleted")
        if enableControls { toggleControls() }
    }

    func requestAccessibility() {
        lastAction = "Accessibility access needed"
        error = "Enable Kinesis in Accessibility. If it is already enabled, quit and reopen Kinesis to refresh macOS’s approval."
        controls.requestAccess()
    }

    private func resetDial() {
        dialArmed = false
        dialGate.pause()
        dialRouter.reset()
    }

    private func suspendActions() {
        gate.pause()
        resetDial()
        dialEngaged = false
        pinchedFinger = nil
    }

    private func run(_ command: BandOperation) {
        guard !busy else { return }
        busy = true
        error = nil
        activeOperation = command
        if case .scan = command {
            phase = "Finding your band…"
            discoveredAddresses.removeAll()
            devices.removeAll { $0.address != selectedAddress }
        } else if case .enroll = command {
            phase = "Enrolling…"
        } else { phase = "Preparing…" }
        live = false
        heartbeat = nil
        handConfirmed = false
        pendingHand = nil
        handSettingError = nil
        started = clock()
        router.reset()
        suspendActions()
        do {
            try connection.start(command, onEvent: { [weak self] event in
                self?.receive(event)
            }, onEnd: { [weak self] error in
                self?.connectionEnded(error, operation: command)
            })
        } catch {
            connectionEnded(error, operation: command)
        }
    }

    private func connectionEnded(_ failure: Error?, operation: BandOperation) {
        // While the pair pipeline owns the flow it makes the routing
        // decisions itself; interim failures never reach the error note.
        let routing = pairRoute != .none
        if let failure, !quitting, error == nil, !routing {
            switch operation {
            case .scan: error = failure.localizedDescription
            case .connect:
                if wantsConnection {
                    error = failure.localizedDescription
                    noteConnectRejection(failure)
                }
            case .enroll:
                error = failure.localizedDescription
                if enrollmentStage.isRunning { enrollmentStage = .failed(failure.localizedDescription) }
            }
        }
        // An expired session mid-ceremony waits for the connection to wind
        // down, then asks for one sign-in. The ceremony restarts afterwards:
        // its state machine lived in the closed connection.
        if case .enroll = operation, pendingRelogin, !quitting, !routing {
            pendingRelogin = false
            error = nil
            enrollmentStage = .login
        }
        activeOperation = nil
        enrollSession = nil
        awaitingSystemPairing = false
        busy = false
        live = false
        handConfirmed = false
        pendingHand = nil
        suspendActions()
        let shouldScan = scanPending && !quitting && !sleeping
        scanPending = false
        if routing {
            advancePairRoute(failure, operation: operation)
        } else if shouldScan {
            run(.scan)
        } else if wantsConnection && !quitting && !sleeping {
            scheduleReconnect()
        } else {
            phase = sleeping ? "Mac is asleep" : "Disconnected"
        }
    }

    /// The pair pipeline's decision after one connection attempt ends.
    private func advancePairRoute(_ failure: Error?, operation: BandOperation) {
        let step = pairing.current
        switch pairRoute {
        case .none:
            break
        case .scanning:
            pairRoute = .none
            if let failure { failPair(failure.localizedDescription, at: step); return }
            guard !selectedAddress.isEmpty else {
                emptyScans += 1
                phase = "Disconnected"
                pairFailure = "no band found. put the band in pairing mode and pair again."
                pairFailedStep = .find
                return
            }
            emptyScans = 0
            routeForSelectedBand()
        case .connecting:
            guard let failure else {
                // The connection stopped without a verdict (a manual stop or
                // a watchdog stall); the run is over either way.
                pairRoute = .none
                return
            }
            if isIdentityRejection(failure) {
                if pairAttempts < 2 {
                    // One rejection can be a flake; the retry drops the
                    // stored identity. A second rejection means the band
                    // needs re-enrolling.
                    startPairConnect()
                } else {
                    startPairEnrollment()
                }
            } else {
                pairRoute = .none
                failPair(failure.localizedDescription, at: step)
            }
        case .enrolling:
            if enrollmentStage == .login { return } // waiting for a sign-in
            if pendingRelogin {
                pendingRelogin = false
                enrollmentStage = .login
                return
            }
            if let message = enrollmentStage.failedText ?? failure?.localizedDescription {
                pairRoute = .none
                failPair(message, at: step)
                return
            }
            // The ceremony finished and the band streams with its new key;
            // reconnect to settle the band on the fresh identity.
            startPairConnect()
        }
    }

    private func failPair(_ message: String, at step: PairStep?) {
        pairFailure = message.lowercased()
        pairFailedStep = step ?? .find
        claimedThisRun = false
        enrollmentStage = .idle
        phase = "Disconnected"
    }

    private func isIdentityRejection(_ failure: Error) -> Bool {
        failure is BandIdentityMismatchError || failure.localizedDescription.hasPrefix("The band rejected")
    }

    /// Remember when a connect attempt ended with the band refusing this Mac:
    /// the EnableTrust proof was rejected, or the startup kept failing after
    /// the legacy fallback. Used by plain connects; the pair pipeline counts
    /// its own attempts.
    private func noteConnectRejection(_ failure: Error) {
        guard isIdentityRejection(failure) else {
            connectRejections = 0
            return
        }
        connectRejections += 1
        // One legacy-protocol rejection can be a flake; two in a row are not.
        if connectRejections >= 2 { bandRejectsIdentity = true }
    }

    /// A successful connect during a pair run: the band is usable, so the
    /// page moves to its paired surface and keeps the connection managed.
    private func completePairing() {
        if claimedThisRun { celebrate() }
        claimedThisRun = false
        pairFailedStep = nil
        pairRoute = .none
        pairFailure = nil
        enrollmentStage = .idle
        wantsConnection = true
        retries = 0
    }

    private func celebrate() {
        celebration?.cancel()
        justPaired = true
        celebration = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.justPaired = false
        }
    }

    private func receive(_ event: BandEvent) {
        let now = clock()
        switch event.payload {
        case .devices(let discovered):
            // Preserve the remembered band if it isn't advertising during this scan.
            let remembered = devices.first { $0.address == selectedAddress }
            discoveredAddresses = Set(discovered.map(\.address))
            devices = discovered
            if let remembered, !devices.contains(where: { $0.address == remembered.address }) { devices.append(remembered) }
            if selectedAddress.isEmpty, let first = discovered.first { selectedAddress = first.address }
            if discovered.isEmpty, pairRoute == .none {
                error = "No band found. Put it in pairing mode, keep it nearby, and try again."
            }
        case .battery(let value): battery = value
        case .handedness(let hand):
            guard wantsConnection, !sleeping else { return }
            bandHand = hand
            defaults.set(hand.rawValue, forKey: "bandHand")
            handConfirmed = true
            pendingHand = nil
            handSettingError = nil
        case .handednessFailure(let message):
            handConfirmed = false
            pendingHand = nil
            handSettingError = message
        case .preparing: phase = "Preparing…"
        case .systemPairingPending:
            awaitingSystemPairing = true
            phase = "Accept the Bluetooth request…"
        case .connected:
            phase = "Connected"
            retries = 0
            error = nil
            awaitingSystemPairing = false
            pairFailure = nil
            pairFailedStep = nil
            bandRejectsIdentity = false
            connectRejections = 0
            if case .enroll = activeOperation, enrollmentStage.isRunning {
                // Streams ready after the ceremony: the band now trusts the
                // new key. Finishing winds the ceremony connection down and
                // starts the settling reconnect.
                finishEnrollment()
            } else if case .connect = activeOperation, pairRoute == .connecting {
                completePairing()
            }
            if controlsEnabled { gate.arm(at: now) }
        case .disconnected: live = false; suspendActions()
        case .ceremonyStage(let text):
            guard case .enroll = activeOperation, enrollmentStage.isRunning else { return }
            enrollmentStage = .working(text)
        case .ceremonyHTTP(let request):
            guard case .enroll = activeOperation, enrollmentStage.isRunning else { return }
            performCeremony(request)
        case .heartbeat:
            if abs(now - event.receivedAt) < 0.6 { receivedInput() }
        case .gesture(let message):
            guard wantsConnection, !sleeping, now - message.receivedAt <= 0.35, now - message.receivedAt >= -0.1 else { return }
            receivedInput()
            guard pendingHand == nil else { return }
            if let label = message.gestureLabel, lastGesture != label { lastGesture = label }
            if !message.synthetic, ["index", "middle"].contains(message.finger) {
                let finger = message.finger
                let actions = [message.derivedAction, message.action]
                if actions.contains(where: { ["press", "hold", "buttonPress", "buttonHold"].contains($0) }), pinchedFinger != finger {
                    pinchedFinger = finger
                } else if actions.contains(where: { ["release", "buttonRelease", "buttonHoldRelease"].contains($0) }), pinchedFinger == finger {
                    pinchedFinger = nil
                }
            }
            guard let gesture = router.gesture(from: message, now: now) else { return }
            let action: MacAction
            switch gesture {
            case .swipe(let direction):
                lastDirection = direction
                action = mappings[direction] ?? .none
            case .tap(let tap):
                lastDirection = nil
                // Releasing a wrist turn must not also trigger an index-tap assignment.
                guard tap.finger != "index" || (now - lastDialAction > 0.6 && now - dialEndedAt > 0.7) else { return }
                action = tapMappings[tap] ?? .none
            }
            lastGesture = gesture.label
            recognizedGesture = gesture
            gestureCount += 1
            totalGestureCount += 1
            defaults.set(totalGestureCount, forKey: "totalGestureCount")
            guard controlsEnabled, action != .none,
                  gate.allows(eventTime: message.receivedAt, now: now, live: live, trusted: controls.trusted) else {
                return
            }
            dispatch(action)
        case .dialState(let engaged):
            guard live, pendingHand == nil, abs(now - event.receivedAt) <= 0.35 else { resetDial(); return }
            // A pinch that turned has just ended: the release is not a tap.
            if !engaged && dialTurned { dialEndedAt = now }
            dialTurned = false
            dialEngaged = engaged
            resetDial()
            if dialEngaged && controlsEnabled {
                dialArmed = true
                dialGate.arm(at: event.receivedAt)
            }
        case .dialTurn(let rotation):
            guard live, handConfirmed, dialEngaged, abs(now - event.receivedAt) <= 0.35, rotation.isFinite else { return }
            // The same intended turn produced the opposite gyro sign on the left wrist.
            let delta = bandHand == .left ? -rotation : rotation
            dialTurned = true
            dialTurns.send(delta)
            guard controlsEnabled, dialArmed, dialTarget != .none,
                  dialGate.allows(eventTime: event.receivedAt, now: now, live: live, trusted: controls.trusted) else { return }
            let steps = dialRouter.turn(delta: delta, sensitivity: dialSensitivity, now: now)
            guard steps != 0 else { return }
            lastDialAction = now
            lastGesture = steps > 0 ? "Wrist turn +" : "Wrist turn −"
            lastDirection = nil
            dispatch(dialTarget.action(increasing: steps > 0), count: abs(steps))
        }
        maxDeliveryDelay = max(maxDeliveryDelay, now - event.receivedAt)
    }

    private func receivedInput() {
        guard wantsConnection, !sleeping else { return }
        let now = clock()
        if let heartbeat { maxInputGap = max(maxInputGap, now - heartbeat) }
        heartbeat = now
        if !live { live = true }
        if phase != "Connected" { phase = "Connected" }
        if automaticStartPending && controls.trusted { toggleControls() }
    }

    private func scheduleReconnect() {
        retry?.cancel()
        retries += 1
        let delay = min(2 * retries, 10)
        phase = "Reconnecting in \(delay)s…"
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wantsConnection, !self.sleeping, !self.quitting else { return }
            self.run(.connect(self.selectedAddress))
        }
    }

    /// Perform one ownership HTTP exchange off the main thread and hand the
    /// reply back to the band session.
    private func performCeremony(_ request: CeremonyHTTPRequest) {
        guard let session = enrollSession else {
            connectionLog.error("Enrollment lost its account session; stopping")
            connection.stop()
            return
        }
        let client = pairClient(session)
        Task {
            do {
                let completion: CeremonyCompletion
                switch request {
                case .pairRequest(let data):
                    let pending = try await client.pairRequest(data)
                    completion = .pairRequest(signature: pending.signature, receipt: pending.receipt)
                case .pair(let data):
                    let final = try await client.pair(data)
                    completion = .pair(signature: final.signature, receipt: final.receipt,
                                       devicePublicKey: final.devicePublicKey)
                }
                try connection.resumeCeremony(completion)
            } catch {
                guard enrollmentStage.isRunning else { return }
                if error is MetaSessionInvalidError {
                    // The account session is gone: drop the saved copy and
                    // prompt for one fresh sign-in.
                    sessionStore.deleteSession()
                    hasSavedMetaSession = false
                    pendingRelogin = true
                }
                enrollmentStage = .failed(error.localizedDescription)
                connection.stop()
            }
        }
    }

    private func dispatch(_ action: MacAction, count: Int = 1) {
        do {
            for _ in 0..<count { try controls.post(action) }
            let label = action.title + (count > 1 ? " ×\(count)" : "")
            lastAction = "Sent: \(label)"
        } catch {
            self.error = error.localizedDescription
            pause()
        }
    }

    private func tick() {
        let allowed = controls.trusted
        if accessibilityAllowed != allowed { accessibilityAllowed = allowed }
        if !accessibilityAllowed && controlsEnabled { pause() }
        guard wantsConnection, busy, !sleeping else { return }
        let silentFor = clock() - (heartbeat ?? started)
        if silentFor > (heartbeat == nil ? 50 : 8) {
            if live {
                live = false
                suspendActions()
                phase = "Connection stalled. Reconnecting…"
                connectionLog.notice("No band input for \(silentFor, privacy: .public)s; reconnecting")
            }
            connection.stop()
        }
        if clock() - metricsAt >= 10 {
            connectionLog.info("Input gap max \(self.maxInputGap, privacy: .public)s; delivery delay max \(self.maxDeliveryDelay, privacy: .public)s")
            metricsAt = clock()
            maxInputGap = 0
            maxDeliveryDelay = 0
        }
    }

    func shutdown() async {
        quitting = true
        disconnect()
        let deadline = ContinuousClock.now + .seconds(8)
        while busy && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }
}
