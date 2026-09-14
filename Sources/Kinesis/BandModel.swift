import AppKit
import Combine
import Foundation
import KinesisCore
import OSLog

@MainActor
final class BandModel: ObservableObject {
    let dialTurns = PassthroughSubject<Double, Never>()
    @Published private(set) var devices: [BandDevice] = []
    @Published var selectedAddress = "" {
        didSet { saveBand() }
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
    @Published var bandHand = BandHand.right {
        didSet { defaults.set(bandHand.rawValue, forKey: "bandHand") }
    }
    @Published private(set) var showingSetup = true
    @Published private(set) var accessibilityAllowed = false
    @Published private(set) var battery: Int?
    @Published private(set) var lastGesture = "Waiting for a gesture"
    @Published private(set) var lastDirection: SwipeDirection?
    @Published private(set) var gestureCount = 0
    @Published private(set) var totalGestureCount = 0
    @Published private(set) var recognizedGesture: RecognizedGesture?
    @Published private(set) var lastAction = "Controls are paused"
    @Published private(set) var dialEngaged = false
    @Published private(set) var pinchedFinger: String?
    @Published var tapMappings: [TapGesture: MacAction] = [.indexTap: .none, .indexDoubleTap: .playPause, .middleTap: .none, .middleDoubleTap: .mute] {
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
    private var router = GestureRouter()
    private var gate = ActionGate()
    private var dialGate = ActionGate(minimumInterval: 0)
    private var dialRouter = DialRouter()
    private var dialArmed = false
    private var lastDialAction = -Double.infinity
    private var heartbeat: Double?
    private var started = 0.0
    private var retry: Task<Void, Never>?
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
    var canScan: Bool { !busy && !wantsConnection }

    init(defaults: UserDefaults = .standard,
         connection: any BandConnection = NativeBandConnection(),
         controls: any MacControls = MacShortcuts(),
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        self.defaults = defaults
        self.started = clock()
        self.metricsAt = clock()
        self.connection = connection
        self.controls = controls
        accessibilityAllowed = controls.trusted
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
        ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        sleepObserver = workspaceNotifications.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true
                self.retry?.cancel()
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
        guard let band = devices.first(where: { $0.address == selectedAddress }),
              let data = try? JSONEncoder().encode(band) else { return }
        defaults.set(data, forKey: "band")
    }

    func scan() {
        guard canScan else { return }
        run(.scan)
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
        retry?.cancel()
        retry = nil
        pause()
        live = false
        phase = busy ? "Disconnecting…" : "Disconnected"
        connection.stop()
    }

    func toggleControls() {
        if controlsEnabled { pause(); return }
        guard !showingSetup else { return }
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
        if case .scan = command { phase = "Finding your band…" } else { phase = "Preparing…" }
        live = false
        heartbeat = nil
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
        if let failure, !quitting, error == nil {
            switch operation {
            case .scan: error = failure.localizedDescription
            case .connect: if wantsConnection { error = failure.localizedDescription }
            }
        }
        busy = false
        live = false
        suspendActions()
        if wantsConnection && !quitting && !sleeping {
            scheduleReconnect()
        } else {
            phase = sleeping ? "Mac is asleep" : "Disconnected"
        }
    }

    private func receive(_ event: BandEvent) {
        let now = clock()
        switch event.payload {
        case .devices(let discovered):
            // Preserve the remembered band if it isn't advertising during this scan.
            let remembered = devices.first { $0.address == selectedAddress }
            devices = discovered
            if let remembered, !devices.contains(where: { $0.address == remembered.address }) { devices.append(remembered) }
            if selectedAddress.isEmpty, let first = discovered.first { selectedAddress = first.address }
            if discovered.isEmpty { error = "No band found. Put it in pairing mode, keep it nearby, and try again." }
        case .battery(let value): battery = value
        case .preparing: phase = "Preparing…"
        case .connected:
            phase = "Connected"
            retries = 0
            error = nil
            if controlsEnabled { gate.arm(at: now) }
        case .disconnected: live = false; suspendActions()
        case .heartbeat:
            if abs(now - event.receivedAt) < 0.6 { receivedInput() }
        case .gesture(let message):
            guard wantsConnection, !sleeping, now - message.receivedAt <= 0.35, now - message.receivedAt >= -0.1 else { return }
            receivedInput()
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
                guard tap.finger != "index" || now - lastDialAction > 0.6 else { return }
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
            guard live, abs(now - event.receivedAt) <= 0.35 else { resetDial(); return }
            dialEngaged = engaged
            resetDial()
            if dialEngaged && controlsEnabled {
                dialArmed = true
                dialGate.arm(at: event.receivedAt)
            }
        case .dialTurn(let delta):
            guard live, dialEngaged, abs(now - event.receivedAt) <= 0.35, delta.isFinite else { return }
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
