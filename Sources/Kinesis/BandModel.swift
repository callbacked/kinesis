import AppKit
import Combine
import Foundation
import KinesisCore
import OSLog
import simd

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
        didSet { saveBand(); refreshIdentity(); setAirCursorEnabled(false); loadPointerReach() }
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
    @Published var developerMode = false {
        didSet {
            defaults.set(developerMode, forKey: "developerMode")
            if !developerMode { rawEMGEnabled = false; setAirCursorEnabled(false) }
        }
    }
    @Published private(set) var airCursorEnabled = false {
        didSet { if airCursorEnabled != oldValue { updateMotionStreams() } }
    }
    /// The readings page shows orientation, so it needs that stream while it is open.
    @Published private(set) var readingsVisible = false {
        didSet { if readingsVisible != oldValue { updateMotionStreams() } }
    }
    @Published private(set) var cursorRepositioning = false
    @Published var cursorSensitivity = 1.0 {
        didSet { defaults.set(cursorSensitivity, forKey: "pointerSensitivity") }
    }
    @Published var cursorSteadiness = 0.5 {
        didSet {
            defaults.set(cursorSteadiness, forKey: "pointerStillness")
            airPointer.steadiness = cursorSteadiness
        loadPointerReach()
        updateMotionStreams()
        }
    }
    var canUseAirCursor: Bool { developerMode && live && controlsEnabled && handConfirmed && pendingHand == nil }
    /// How far the forearm turns to cross the screen: measured by calibration, or the standard reach.
    @Published private(set) var pointerReach = PointerReach.standard(for: .right)
    @Published private(set) var pointerCalibrated = false
    /// Non-nil while the three calibration targets are on screen.
    @Published private(set) var pointerCalibration: PointerCalibration? {
        didSet { if (pointerCalibration == nil) != (oldValue == nil) { updateMotionStreams() } }
    }
    @Published private(set) var pointerCalibrationProblem: String?
    /// The last half second of raw, on-time aim, so a calibration pinch can use the aim from just before it.
    private var recentAims: [(time: Double, aim: ForearmAim)] = []
    private var calibrationPinchDown = false
    private var airPointer = AirPointer()
    private var cursorNeedsAnchor = true
    private var cursorMotionResumesAt = -Double.infinity
    private var cursorLastOrientation = -Double.infinity
    /// Where this app put the pointer over the last half second, so a click can land
    /// where the arm aimed just before the pinch nudged it.
    private var cursorTrail: [(time: Double, point: CGPoint)] = []
    /// How far back a click looks: the forearm starts to move as the pinch closes,
    /// before the band reports it.
    static let clickLookback = 0.15
    /// The mouse button a pinch is holding down, so moving drags and letting go releases.
    private var heldButton: (button: CGMouseButton, finger: String, clicks: Int)?
    private var lastPress: (time: Double, point: CGPoint, button: CGMouseButton, clicks: Int)?
    /// Two presses this close in time and space are a double-click, as with a trackpad.
    static let doubleClickTime = 0.45
    static let doubleClickDistance = 6.0
    private var cursorTicker: FrameTicker?
    private var cursorPacer: PointerPacer
    /// Tests run the pointer on a 60 Hz timer that their fake clock is written around.
    private let cursorFramesFromDisplay: Bool
    private var cursorLastFrame: Double?
    /// True while the band's data reaches the Mac late: a congested or blocked radio link.
    @Published private(set) var linkCongested = false
    /// Input later than this is never acted on: no click, shortcut, dial step, or pointer move.
    static let lateInput = 0.3
    private var motionDelay = ArrivalDelay()
    private var linkDelay = 0.0
    private var linkDelayAt = -Double.infinity
    private var linkLateSince: Double?
    private var linkOnTimeSince: Double?
    private var lastMotionRestart = -Double.infinity
    private var cursorPressedFingers: Set<String> = []
    private var cursorArmedAt = Double.infinity
    @Published var rawEMGEnabled = false {
        didSet {
            guard rawEMGEnabled != oldValue else { return }
            defaults.set(rawEMGEnabled, forKey: "rawEMGEnabled")
            if !rawEMGEnabled { stopRawRecording() }
            let deferringDisable = rawEMGChanging && !rawEMGEnabled
            rawEMGError = nil
            rawEMGChanging = live
            do { try connection.setRawEMGEnabled(rawEMGEnabled) }
            catch {
                if deferringDisable {
                    rawDisablePending = true
                } else {
                    rawEMGChanging = false
                    rawEMGError = error.localizedDescription
                }
            }
        }
    }
    @Published private(set) var rawEMGActive = false
    @Published private(set) var rawEMGChanging = false
    @Published private(set) var rawEMGError: String?
    let readings = EMGReadings()
    let motion = MotionReadings()
    var rawEMGFrames: Int { readings.frames }
    var rawEMGBytes: Int { readings.bytes }
    @Published private(set) var rawEMGRate = 0.0
    @Published private(set) var rawEMGSampleRate = 0.0
    @Published private(set) var rawEMGByteRate = 0.0
    @Published private(set) var rawRecordingURL: URL?
    @Published private(set) var rawRecordedFrames = 0
    /// One lowercase line in the connection surface when a subscription was
    /// acknowledged but no data frames followed.
    @Published private(set) var streamHint: String?
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
    @Published private(set) var charging: Bool?
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
    /// When the subscription acknowledgement arrived, waiting for the first frame.
    private var subscribedAt: Double?
    private var lastSensorAt: Double?
    private var sensorHealthySince: Double?
    // Carry this budget across reconnects. An off-wrist band must not loop just
    // because status replies continue while sensors are asleep.
    private var sensorRecoveryUsed = false
    private var sensorRecoveryPending = false
    private var rateAt = 0.0
    private var rateFrames = 0
    private var rateSamples = 0
    private var rateBytes = 0
    private var recorder: RawEMGRecorder?
    private var rawDisablePending = false
    private var recordingTask: Task<Void, Never>?
    private var recordingID = UUID()
    private var pendingRawLines: [String] = []
    private let rawTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let hexNibbles = Array("0123456789abcdef".map(String.init))

    var bandName: String { devices.first { $0.address == selectedAddress }?.name ?? "Neural Band" }
    enum ChargeState { case unknown, onBattery, charging, full
        var isCharging: Bool { self == .charging }
    }
    var chargeState: ChargeState {
        if charging == true { return .charging }
        if battery == 100 { return .full }
        return charging == false ? .onBattery : .unknown
    }
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
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         cursorPacing: Double = PointerPacer.batchSeconds,
         cursorFramesFromDisplay: Bool = true) {
        self.clock = clock
        cursorPacer = PointerPacer(seconds: cursorPacing)
        self.cursorFramesFromDisplay = cursorFramesFromDisplay
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
        developerMode = defaults.bool(forKey: "developerMode")
        let cursorSensitivity = defaults.double(forKey: "pointerSensitivity")
        if (0.25...4).contains(cursorSensitivity) { self.cursorSensitivity = cursorSensitivity }
        if defaults.object(forKey: "pointerStillness") != nil {
            let steadiness = defaults.double(forKey: "pointerStillness")
            if (0...1).contains(steadiness) { cursorSteadiness = steadiness }
        }
        airPointer.steadiness = cursorSteadiness
        rawEMGEnabled = developerMode && defaults.bool(forKey: "rawEMGEnabled")
        try? connection.setRawEMGEnabled(rawEMGEnabled)
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
        charging = nil
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
    /// A clean slate on Kinesis's side: the band, its key, and the Meta sign-in. Two things
    /// stay out of reach, and the reminder names them: the band's own claim, and this Mac's
    /// Bluetooth entry. No call removes that entry. The unpublished IOBluetooth one reports
    /// success for the band and leaves the entry where it is.
    func forgetEverything() {
        cancelEnrollment()
        stopRawRecording()
        let address = selectedAddress
        if !address.isEmpty { forgetBand() }
        BandIdentity.delete(for: address)
        sessionStore.deleteSession()
        hasSavedMetaSession = false
        pairFailure = nil
        pairFailedStep = nil
        emptyScans = 0
        celebration?.cancel()
        justPaired = false
        connectionLog.notice("Forgot the band, its identity, and the Meta session")
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
        sensorRecoveryUsed = false
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
        subscribedAt = nil
        streamHint = nil
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

    func setAirCursorEnabled(_ enabled: Bool) {
        if !enabled { cancelPointerCalibration(); releaseHeldButton() }
        guard !enabled || (canUseAirCursor && pointerCalibration == nil) else { return }
        guard enabled != airCursorEnabled else { return }
        airCursorEnabled = enabled
        cursorRepositioning = false
        // Start from wherever the pointer is.
        cursorNeedsAnchor = true
        cursorTrail = []
        cursorMotionResumesAt = -.infinity
        cursorTicker?.stop()
        cursorTicker = nil
        cursorPacer.clear()
        cursorLastFrame = nil
        if enabled {
            // One move per display frame. The orientation arrives at 128 Hz.
            cursorTicker = FrameTicker(fromDisplay: cursorFramesFromDisplay, timerInterval: cursorFramesFromDisplay ? 1.0 / 120 : 1.0 / 60) { [weak self] in
                self?.flushCursorMovement()
            }
        }
        cursorPressedFingers = Set(pinchedFinger.map { [$0] } ?? [])
        cursorArmedAt = enabled ? clock() : .infinity
        router.reset()
        resetDial()
        dialEngaged = false
        dialTurned = false
        dialEndedAt = clock()
        if controlsEnabled { gate.arm(at: clock()) }
        lastAction = enabled ? "Air cursor on · Escape to stop" : "Air cursor off"
    }

    func setCursorRepositioning(_ repositioning: Bool) {
        let active = airCursorEnabled && repositioning
        guard active != cursorRepositioning else { return }
        cursorRepositioning = active
        cursorPressedFingers.removeAll()
        pinchedFinger = nil
        // Like lifting a mouse: movement while Option is down is dropped.
        steadyCursor(until: clock() + 0.12)
    }

    /// Posts this frame's share of the movement, or all of it before a press.
    private func flushCursorMovement(all: Bool = false) {
        let now = clock()
        let frame = cursorLastFrame.map { max(0, min(0.1, now - $0)) } ?? 0
        cursorLastFrame = now
        guard airCursorEnabled, canUseAirCursor, now - cursorLastOrientation <= 0.15 else { cursorPacer.clear(); return }
        guard controls.trusted else { pause(); return }
        guard let movement = airPointer.movement() else { return }
        // A pinch, Option, or the first frame drops what moved meanwhile, like lifting
        // a mouse. The first frame after a hold drops the settling that came with it.
        guard !cursorRepositioning, now >= cursorMotionResumesAt, !cursorNeedsAnchor else {
            if !cursorRepositioning, now >= cursorMotionResumesAt { cursorNeedsAnchor = false }
            cursorPacer.clear()
            return
        }
        // Stillness and acceleration are already in the movement, sample by sample.
        let scale = pointerReach.pointsPerDegree(display: controls.displaySize, sensitivity: cursorSensitivity)
        let moved = pointerReach.screenDegrees(movement) * scale
        cursorPacer.add(moved)
        guard let location = controls.cursorLocation, let delta = cursorPacer.take(frame: all ? nil : frame) else { return }
        do {
            if cursorTrail.isEmpty { cursorTrail.append((now, location)) }
            let posted = try controls.moveCursor(to: CGPoint(x: location.x + delta.x, y: location.y + delta.y),
                                                 dragging: heldButton?.button)
            cursorTrail.append((now, posted))
            cursorTrail.removeAll { now - $0.time > 0.5 }
        } catch {
            self.error = error.localizedDescription
            pause()
        }
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
        setAirCursorEnabled(false)
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
        airPointer.discard()
        cursorNeedsAnchor = true
        motionDelay.reset()
        linkDelay = 0
        linkDelayAt = -.infinity
        linkLateSince = nil
        linkOnTimeSince = nil
        linkCongested = false
        lastSensorAt = nil
        sensorHealthySince = nil
        sensorRecoveryPending = false
        handConfirmed = false
        pendingHand = nil
        handSettingError = nil
        subscribedAt = nil
        streamHint = nil
        charging = nil
        readings.reset()
        motion.reset()
        rawEMGActive = false
        rawEMGChanging = false
        rawDisablePending = false
        rawEMGError = nil
        rawEMGRate = 0
        rawEMGSampleRate = 0
        rawEMGByteRate = 0
        rateAt = clock()
        rateFrames = 0
        rateSamples = 0
        rateBytes = 0
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
        // Readings are opt-in again after a dropped session; an unsupported
        // combined subscription must never create a reconnect loop.
        rawEMGEnabled = false
        charging = nil
        rawEMGActive = false
        rawEMGChanging = false
        rawDisablePending = false
        stopRawRecording()
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
        MotionLog.shared.record(event)
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
        case .battery(let value):
            battery = value
        case .batteryStatus(let status):
            if let status { battery = status.level }
            charging = status?.charging
        case .handedness(let hand):
            guard wantsConnection, !sleeping else { return }
            bandHand = hand
            loadPointerReach()
            defaults.set(hand.rawValue, forKey: "bandHand")
            handConfirmed = true
            pendingHand = nil
            handSettingError = nil
        case .handednessFailure(let message):
            setAirCursorEnabled(false)
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
            if heartbeat == nil { subscribedAt = now }
            if case .enroll = activeOperation, enrollmentStage.isRunning {
                // Streams ready after the ceremony: the band now trusts the
                // new key. Finishing winds the ceremony connection down and
                // starts the settling reconnect.
                finishEnrollment()
            } else if case .connect = activeOperation, pairRoute == .connecting {
                completePairing()
            }
            rawEMGChanging = rawEMGEnabled
            if controlsEnabled { gate.arm(at: now) }
        case .disconnected: live = false; charging = nil; suspendActions()
        case .rawEMGFrame(let payload):
            guard wantsConnection, !sleeping else { return }
            readings.receive(payload, at: now)
            markDataArrived(at: event.receivedAt)
            receivedInput()
            recordRawFrame(payload, at: now)
        case .rawEMGConfiguration(let configuration):
            readings.configure(configuration)
        case .rawEMGState(let active):
            rawDisablePending = false
            rawEMGActive = active
            rawEMGChanging = false
            rawEMGError = nil
            // Developer mode may have been disabled while an enable was in flight.
            if active != rawEMGEnabled {
                do {
                    try connection.setRawEMGEnabled(rawEMGEnabled)
                    rawEMGChanging = true
                } catch { rawEMGError = error.localizedDescription }
            }
        case .rawEMGFailure(let message):
            rawEMGChanging = false
            rawEMGError = message
            if rawDisablePending {
                rawDisablePending = false
                do {
                    try connection.setRawEMGEnabled(false)
                    rawEMGChanging = true
                } catch { rawEMGError = error.localizedDescription }
            } else if !developerMode {
                error = message
            }
        case .ceremonyStage(let text):
            guard case .enroll = activeOperation, enrollmentStage.isRunning else { return }
            enrollmentStage = .working(text)
        case .ceremonyHTTP(let request):
            guard case .enroll = activeOperation, enrollmentStage.isRunning else { return }
            performCeremony(request)
        case .heartbeat:
            if abs(now - event.receivedAt) < 0.6 { receivedInput() }
        case .dataSeen:
            markDataArrived(at: event.receivedAt)
        case .gesture(let message):
            guard wantsConnection, !sleeping, now - message.receivedAt <= 0.35, now - message.receivedAt >= -0.1 else { return }
            markDataArrived(at: message.receivedAt)
            receivedInput()
            guard pendingHand == nil else { return }
            // Gestures share one pipe with motion, so they are exactly as late as the
            // motion around them. A pinch from seconds ago must not click now.
            if linkIsLate(at: now) {
                if heldButton?.finger == message.finger { releaseHeldButton() }
                connectionLog.notice("Dropped a \(message.finger, privacy: .public) \(message.action, privacy: .public) that arrived \(self.linkDelay, privacy: .public)s late")
                return
            }
            if pointerCalibration != nil {
                receiveCalibrationGesture(message, now: now)
                return
            }
            if let label = message.gestureLabel, lastGesture != label { lastGesture = label }
            if airCursorEnabled {
                guard !cursorRepositioning else { return }
                if message.finger != "thumb" {
                    receiveCursorGesture(message, now: now)
                    return
                }
            }
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
            if airCursorEnabled { steadyCursor(until: now + 0.12) }
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
            guard !airCursorEnabled, pointerCalibration == nil else { return }
            guard live, pendingHand == nil, abs(now - event.receivedAt) <= 0.35, !linkIsLate(at: now) else { resetDial(); return }
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
            guard !airCursorEnabled, pointerCalibration == nil else { return }
            guard live, handConfirmed, dialEngaged, abs(now - event.receivedAt) <= 0.35, rotation.isFinite else { return }
            guard !linkIsLate(at: now) else { resetDial(); dialEngaged = false; return }
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
        case .orientation(let timestamp, let values):
            guard let aim = ForearmAim(quaternion: values) else { return }
            let delay = measureLinkDelay(band: timestamp, host: event.receivedAt)
            if developerMode { motion.receiveAim(aim, delay: delay, at: event.receivedAt) }
            // A late sample is where the arm was, not where it is. Skipping it pauses
            // the pointer, and the gap re-anchors it when fresh data returns.
            guard delay <= Self.lateInput else { return }
            recentAims.append((event.receivedAt, aim))
            recentAims.removeAll { event.receivedAt - $0.time > 0.6 }
            if !airPointer.receive(aim, at: event.receivedAt) { cursorNeedsAnchor = true }
            cursorLastOrientation = event.receivedAt
        case .motionStreams:
            break
        case .gyro(let timestamp, let values):
            let delay = measureLinkDelay(band: timestamp, host: event.receivedAt)
            if delay <= Self.lateInput { airPointer.receiveGyro(values, at: event.receivedAt) }
            if developerMode { motion.receiveGyro(values, at: event.receivedAt) }
        }
        maxDeliveryDelay = max(maxDeliveryDelay, now - event.receivedAt)
        evaluateStreamHint(at: now)
    }

    /// Status replies prove the link is alive, not that its sensors are flowing.
    private func evaluateStreamHint(at now: Double) {
        guard busy, !sensorRecoveryPending, let lastData = lastSensorAt ?? subscribedAt,
              now - lastData >= 10 else { return }
        if streamHint == nil {
            connectionLog.notice("No sensor frames for \(now - lastData, privacy: .public)s; charging: \(String(describing: self.charging), privacy: .public)")
        }
        streamHint = lastSensorAt == nil
            ? "subscribed but no data — is the band on your wrist and off the charger?"
            : "sensor stream is quiet — is the band on your wrist and off the charger?"
    }

    private func receivedInput() {
        guard wantsConnection, !sleeping, !sensorRecoveryPending else { return }
        let now = clock()
        if let heartbeat { maxInputGap = max(maxInputGap, now - heartbeat) }
        heartbeat = now
        if !live { live = true }
        if phase != "Connected" { phase = "Connected" }
        if automaticStartPending && controls.trusted { toggleControls() }
    }

    private func receiveCursorGesture(_ message: BandGesture, now: Double) {
        guard canUseAirCursor, !message.synthetic, ["index", "middle"].contains(message.finger),
              message.receivedAt >= cursorArmedAt, now - message.receivedAt <= 0.1 else { return }
        let actions = [message.action, message.derivedAction]
        if actions.contains(where: { ["release", "buttonRelease", "buttonHoldRelease"].contains($0) }) {
            if cursorPressedFingers.remove(message.finger) != nil {
                if airPointer.approach != .tracking { airPointer.guardClick(at: message.receivedAt) }
                if heldButton?.finger == message.finger { releaseHeldButton() }
            }
            if pinchedFinger == message.finger { pinchedFinger = nil }
            return
        }
        // One complete click at pinch onset. Ignore its hold, tap and double-tap
        // reports, which describe the same contact and would otherwise click again.
        guard actions.contains(where: { ["press", "buttonPress"].contains($0) }),
              !actions.contains("buttonHold"), cursorPressedFingers.insert(message.finger).inserted else { return }
        guard controls.trusted else { pause(); return }
        // Movement from before the pinch lands before the press, not after it.
        flushCursorMovement(all: true)
        // Held still or settling onto a target: absorb the drift that follows the pinch.
        // Tracking something that moves: hold nothing back.
        let approach = airPointer.approach
        if approach != .tracking { airPointer.guardClick(at: message.receivedAt) }
        pinchedFinger = message.finger
        let button: CGMouseButton = message.finger == "index" ? .left : .right
        // One button at a time, like a trackpad.
        if heldButton != nil { releaseHeldButton() }
        // Held still, the press lands where the pointer was just before the pinch nudged
        // the arm. Otherwise it lands where the pointer is: looking back while moving
        // would yank the pointer to where it was 0.15 s ago.
        let aimedAt = approach == .still ? cursorTrail.last { $0.time <= message.receivedAt - Self.clickLookback }?.point : nil
        let point = aimedAt ?? controls.cursorLocation
        var clicks = 1
        if let lastPress, let point, lastPress.button == button, now - lastPress.time <= Self.doubleClickTime,
           hypot(point.x - lastPress.point.x, point.y - lastPress.point.y) <= Self.doubleClickDistance {
            clicks = min(3, lastPress.clicks + 1)
        }
        do {
            try controls.mouseButton(button, down: true, clicks: clicks, at: point)
            heldButton = (button, message.finger, clicks)
            if let point { lastPress = (now, point, button, clicks) }
            lastAction = button == .left ? (clicks > 1 ? "Double click" : "Left click") : "Right click"
            recognizedGesture = .tap(message.finger == "index" ? .indexTap : .middleTap)
            gestureCount += 1
            totalGestureCount += 1
            defaults.set(totalGestureCount, forKey: "totalGestureCount")
        } catch {
            self.error = error.localizedDescription
            pause()
        }
    }

    /// Lets go of a button a pinch holds. Never leaves one stuck down: this runs when
    /// the pinch ends, when the cursor turns off, and when the link falls behind.
    private func releaseHeldButton() {
        guard let held = heldButton else { return }
        heldButton = nil
        do { try controls.mouseButton(held.button, down: false, clicks: held.clicks, at: nil) }
        catch { self.error = error.localizedDescription }
    }

    /// Measures one motion sample's delay, and tracks whether the link is congested:
    /// late for a second running, and clear again after two seconds on time.
    private func measureLinkDelay(band timestamp: UInt64, host: Double) -> Double {
        let delay = motionDelay.measure(band: Double(timestamp) / 1e6, host: host)
        linkDelay = delay
        linkDelayAt = host
        if delay > Self.lateInput {
            linkOnTimeSince = nil
            let since = linkLateSince ?? host
            linkLateSince = since
            if !linkCongested, host - since >= 1 {
                linkCongested = true
                releaseHeldButton()
                connectionLog.notice("Band data is arriving \(delay, privacy: .public)s late; the radio link is congested")
                // Experiment: switching the motion streams off and on may clear the band's backlog.
                if host - lastMotionRestart >= 20 {
                    lastMotionRestart = host
                    connection.restartMotionStreams()
                }
            }
        } else {
            linkLateSince = nil
            let since = linkOnTimeSince ?? host
            linkOnTimeSince = since
            if linkCongested, host - since >= 2 {
                linkCongested = false
                connectionLog.notice("Band data is on time again")
            }
        }
        return delay
    }

    /// True when the latest motion showed a late link. Without recent motion the delay is unknown, so not late.
    private func linkIsLate(at now: Double) -> Bool {
        now - linkDelayAt <= 0.5 && linkDelay > Self.lateInput
    }

    // MARK: - motion streams

    /// Orientation is half of the link's load, and only the air cursor, its
    /// calibration, and the readings page use it. The gyro stays on for the dial.
    var wantedMotionStreams: MotionStreams {
        MotionStreams(gyro: true, orientation: airCursorEnabled || pointerCalibration != nil || readingsVisible || MotionLog.shared.isOn)
    }

    private func updateMotionStreams() {
        connection.setMotionStreams(wantedMotionStreams)
    }

    func setReadingsVisible(_ visible: Bool) {
        readingsVisible = visible
    }

    // MARK: - pointer calibration

    private var pointerReachKey: String { "pointerReach.\(selectedAddress).\(bandHand.rawValue)" }

    private func loadPointerReach() {
        let saved = defaults.data(forKey: pointerReachKey).flatMap { try? JSONDecoder().decode(PointerReach.self, from: $0) }
        pointerReach = saved.flatMap { $0.isValid ? $0 : nil } ?? .standard(for: bandHand)
        pointerCalibrated = saved?.isValid == true
    }

    /// Shows the three targets. Pinches aim at them instead of clicking until it ends.
    func beginPointerCalibration() {
        guard canUseAirCursor else { return }
        setAirCursorEnabled(false)
        pointerCalibrationProblem = nil
        calibrationPinchDown = pinchedFinger != nil
        resetDial()
        dialEngaged = false
        pointerCalibration = PointerCalibration()
        lastAction = "Calibrating the air cursor · Escape to stop"
    }

    func cancelPointerCalibration() {
        guard pointerCalibration != nil else { return }
        pointerCalibration = nil
        lastAction = "Calibration cancelled"
    }

    /// Forgets this band's calibration and goes back to the standard reach.
    func resetPointerReach() {
        defaults.removeObject(forKey: pointerReachKey)
        loadPointerReach()
    }

    private func receiveCalibrationGesture(_ message: BandGesture, now: Double) {
        guard !message.synthetic, message.finger == "index" else { return }
        let actions = [message.action, message.derivedAction]
        if actions.contains(where: { ["release", "buttonRelease", "buttonHoldRelease"].contains($0) }) {
            calibrationPinchDown = false
            return
        }
        guard actions.contains(where: { ["press", "buttonPress"].contains($0) }), !calibrationPinchDown else { return }
        calibrationPinchDown = true
        // The aim a moment before the pinch: the pinch itself nudges the forearm.
        let window = recentAims.filter { (0.1...0.3).contains(message.receivedAt - $0.time) }
        guard !window.isEmpty, now - (recentAims.last?.time ?? -.infinity) <= 0.3 else {
            pointerCalibrationProblem = "no fresh motion from the band. keep it close, then pinch again."
            return
        }
        // Average the compass angle around the first sample, so the seam at ±180° can't split it.
        let first = window[0].aim.azimuth
        let azimuth = first + window.map { remainder($0.aim.azimuth - first, 360) }.reduce(0, +) / Double(window.count)
        let elevation = window.map(\.aim.elevation).reduce(0, +) / Double(window.count)
        guard var calibration = pointerCalibration else { return }
        let reach = calibration.record(ForearmAim(azimuth: azimuth, elevation: elevation))
        pointerCalibrationProblem = calibration.problem
        if let reach {
            pointerCalibration = nil
            pointerReach = reach
            pointerCalibrated = true
            if let data = try? JSONEncoder().encode(reach) { defaults.set(data, forKey: pointerReachKey) }
            lastAction = String(format: "Air cursor calibrated: %.0f° across, %.0f° up and down", reach.degreesAcrossWidth, reach.degreesAcrossHeight)
            connectionLog.notice("Pointer calibrated: \(reach.degreesAcrossWidth, privacy: .public)° across, \(reach.degreesAcrossHeight, privacy: .public)° up and down, up tilt \(reach.upTilt, privacy: .public), across tilt \(reach.acrossTilt, privacy: .public)")
        } else {
            pointerCalibration = calibration
        }
    }

    private func steadyCursor(until time: Double) {
        // Hold the pointer still through a pinch, and drop what the pinch's twitch moved.
        cursorMotionResumesAt = max(cursorMotionResumesAt, time)
        cursorNeedsAnchor = true
    }

    /// Sensor frames are flowing, so the no-data hint no longer applies.
    private func markDataArrived(at time: Double) {
        guard wantsConnection, !sleeping, !sensorRecoveryPending, abs(clock() - time) < 0.6,
              time >= (lastSensorAt ?? time) else { return }
        if lastSensorAt.map({ time - $0 > 1 }) ?? true {
            sensorHealthySince = time
        }
        lastSensorAt = time
        // A brief burst after reconnecting is not a recovered stream. Require
        // sustained data before allowing another automatic sensor recovery.
        if let sensorHealthySince, time - sensorHealthySince >= 30 { sensorRecoveryUsed = false }
        subscribedAt = nil
        streamHint = nil
    }

    /// One buffered jsonl line per frame. Sensor payload and timestamps only.
    private func recordRawFrame(_ payload: Data, at time: Double) {
        guard rawRecordingURL != nil else { return }
        var hex = String()
        hex.reserveCapacity(payload.count * 2)
        for byte in payload {
            hex += Self.hexNibbles[Int(byte >> 4)]
            hex += Self.hexNibbles[Int(byte & 15)]
        }
        let line: [String: Any] = ["t": rawTimestamp.string(from: Date()), "uptime": time,
                                   "channel": 5, "kind": "0x0200020a", "bytes": payload.count, "payload": hex]
        if let data = try? JSONSerialization.data(withJSONObject: line), let text = String(data: data, encoding: .utf8) {
            pendingRawLines.append(text)
        }
    }

    /// Start capturing raw frames to a user-chosen file. Replaces any running capture.
    func startRawRecording(to url: URL) {
        stopRawRecording()
        do { recorder = try RawEMGRecorder(url: url) }
        catch {
            self.error = "could not write to \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        recordingID = UUID()
        rawRecordingURL = url
        rawRecordedFrames = 0
        connectionLog.notice("Raw emg capture started")
    }

    func stopRawRecording() {
        flushRawRecording(closing: true)
        recorder = nil
        rawRecordingURL = nil
    }

    private func flushRawRecording(closing: Bool = false) {
        guard let recorder, closing || !pendingRawLines.isEmpty else { return }
        let lines = pendingRawLines
        pendingRawLines.removeAll(keepingCapacity: true)
        let previous = recordingTask
        let id = recordingID
        recordingTask = Task { [weak self] in
            await previous?.value
            do {
                try await recorder.append(lines)
                if let self, self.recordingID == id { self.rawRecordedFrames += lines.count }
            } catch {
                if let self, self.recordingID == id {
                    self.error = "EMG recording failed: \(error.localizedDescription)"
                    self.stopRawRecording()
                }
            }
            if closing {
                do { try await recorder.close() }
                catch {
                    if let self, self.recordingID == id { self.error = "Couldn't finish the EMG recording: \(error.localizedDescription)" }
                }
            }
        }
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
        flushRawRecording()
        let now = clock()
        let elapsed = now - rateAt
        if elapsed >= 1 {
            rawEMGRate = Double(rawEMGFrames - rateFrames) / elapsed
            rawEMGSampleRate = Double(readings.sampleFrames - rateSamples) / elapsed
            rawEMGByteRate = Double(rawEMGBytes - rateBytes) / elapsed
            rateAt = now
            rateFrames = rawEMGFrames
            rateSamples = readings.sampleFrames
            rateBytes = rawEMGBytes
        }
        evaluateStreamHint(at: now)
        guard wantsConnection, busy, !sleeping else { return }
        // One watchdog, and at most one stop per recovery. The link is dead when
        // nothing at all arrives. Sensors are stalled when status replies still
        // arrive but motion does not; that recovery is budgeted, because an
        // off-wrist band legitimately goes quiet and must not reconnect forever.
        if !sensorRecoveryPending {
            let linkSilence = now - (heartbeat ?? started)
            let linkDead = linkSilence > (heartbeat == nil ? 50 : 8)
            var sensorsStalled = false
            if case .connect = activeOperation, !sensorRecoveryUsed, charging != true, let lastSensorAt {
                sensorsStalled = now - lastSensorAt > 10
            }
            if linkDead || sensorsStalled {
                if !linkDead { sensorRecoveryUsed = true }
                sensorRecoveryPending = true
                if live {
                    live = false
                    suspendActions()
                }
                phase = "Reconnecting…"
                connectionLog.notice("\(linkDead ? "No band input" : "No sensor frames", privacy: .public) for \(linkDead ? linkSilence : now - (self.lastSensorAt ?? now), privacy: .public)s; reconnecting once")
                connection.stop()
            }
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
        stopRawRecording()
        await recordingTask?.value
        disconnect()
        let deadline = ContinuousClock.now + .seconds(8)
        while busy && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }
}
