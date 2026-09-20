import Foundation

public enum BandHand: String, CaseIterable, Identifiable, Sendable {
    case right, left
    public var id: String { rawValue }
}

public struct BandDevice: Codable, Identifiable, Hashable, Sendable {
    public let address: String
    public let name: String
    public let rssi: Int?
    public var id: String { address }
    public init(address: String, name: String, rssi: Int? = nil) {
        self.address = address
        self.name = name
        self.rssi = rssi
    }
}

public struct BandEvent: Sendable {
    public enum Payload: Sendable {
        case devices([BandDevice])
        case battery(Int)
        case preparing, connected, disconnected, heartbeat
        case gesture(BandGesture)
        case dialState(Bool)
        case dialTurn(Double)
        case handedness(BandHand)
        case handednessFailure(String)
        case ceremonyHTTP(CeremonyHTTPRequest)
        case ceremonyStage(String)
    }
    public let payload: Payload
    public let receivedAt: Double
    public init(_ payload: Payload, at receivedAt: Double = ProcessInfo.processInfo.systemUptime) {
        self.payload = payload
        self.receivedAt = receivedAt
    }
}

public struct BandGesture: Sendable {
    public let receivedAt: Double
    public let finger: String
    public let action: String
    public let derivedAction: String
    public let synthetic: Bool
    public let sequence: UInt64
    public let timestampUs: UInt64

    public init(sequence: UInt64, timestampUs: UInt64, finger: String, action: String,
                derivedAction: String = "unknown", synthetic: Bool = false,
                receivedAt: Double = ProcessInfo.processInfo.systemUptime) {
        self.sequence = sequence
        self.timestampUs = timestampUs
        self.finger = finger
        self.action = action
        self.derivedAction = derivedAction
        self.synthetic = synthetic
        self.receivedAt = receivedAt
    }

    public var gestureLabel: String? {
        guard !synthetic else { return nil }
        let names = ["singleTap": "tap", "doubleTap": "double tap", "buttonHold": "hold",
                     "buttonPress": "pinch", "buttonRelease": "release", "buttonHoldRelease": "release",
                     "buttonUp": "swipe up", "buttonDown": "swipe down",
                     "buttonLeft": "swipe left", "buttonRight": "swipe right",
                     "tap": "tap", "doubletap": "double tap", "press": "pinch", "release": "release",
                     "up": "swipe up", "down": "swipe down", "left": "swipe left", "right": "swipe right"]
        guard let label = names[derivedAction] ?? names[action] else { return nil }
        return "\(finger.capitalized) \(label)"
    }
}

public enum SwipeDirection: String, CaseIterable, Codable, Identifiable, Sendable {
    case left, right, up, down
    public var id: String { rawValue }
    public var label: String { "Swipe \(rawValue)" }
    public var symbol: String { "arrow.\(rawValue)" }
}

public struct GestureRouter: Sendable {
    private var seen: [String] = []
    private var last: [RecognizedGesture: (source: String, time: Double)] = [:]

    public init() {}

    public mutating func reset() { seen.removeAll(); last.removeAll() }

    public mutating func gesture(from message: BandGesture, now: Double) -> RecognizedGesture? {
        guard !message.synthetic,
              now - message.receivedAt >= -0.1, now - message.receivedAt <= 0.35 else { return nil }
        let derived: [String: SwipeDirection] = ["buttonLeft": .left, "buttonRight": .right,
                                                "buttonUp": .up, "buttonDown": .down]
        let gesture: RecognizedGesture
        let source: String
        if message.finger == "thumb",
           let direction = derived[message.derivedAction] ?? SwipeDirection(rawValue: message.action) {
            gesture = .swipe(direction)
            source = derived[message.derivedAction] == nil ? "raw" : "derived"
        } else {
            let actions = ["singleTap": "tap", "doubleTap": "doubletap"]
            let action = actions[message.derivedAction] ?? message.action
            guard let tap = TapGesture.allCases.first(where: { $0.finger == message.finger && $0.action == action }) else { return nil }
            gesture = .tap(tap)
            source = actions[message.derivedAction] == nil ? "raw" : "derived"
        }
        let identity = "\(message.sequence):\(message.timestampUs):\(message.finger):\(message.action):\(message.derivedAction)"
        guard !seen.contains(identity) else { return nil }
        seen.append(identity)
        if seen.count > 128 { seen.removeFirst() }
        if let last = last[gesture], last.source != source,
           abs(message.receivedAt - last.time) < 0.18 {
            return nil
        }
        last[gesture] = (source, message.receivedAt)
        return gesture
    }
}

public enum RecognizedGesture: Hashable, Sendable {
    case swipe(SwipeDirection), tap(TapGesture)
    public var label: String {
        switch self {
        case .swipe(let direction): direction.label
        case .tap(let tap): tap.label
        }
    }
}

public enum TapGesture: String, CaseIterable, Identifiable, Sendable {
    case indexTap, indexDoubleTap, middleTap, middleDoubleTap
    public var id: String { rawValue }
    public var finger: String { self == .indexTap || self == .indexDoubleTap ? "index" : "middle" }
    public var action: String { self == .indexTap || self == .middleTap ? "tap" : "doubletap" }
    public var label: String { "\(finger.capitalized) \(action == "tap" ? "tap" : "double tap")" }
}

public enum DialTarget: String, CaseIterable, Identifiable, Sendable {
    case none, volume, brightness
    public var id: String { rawValue }
    public var title: String { self == .none ? "No action" : rawValue.capitalized }
    public func action(increasing: Bool) -> MacAction {
        switch self {
        case .none: .none
        case .volume: increasing ? .volumeUp : .volumeDown
        case .brightness: increasing ? .brightnessUp : .brightnessDown
        }
    }
}

public struct DialRouter: Sendable {
    private var remainder = 0.0
    private var lastDispatch = -Double.infinity
    private var lastInput = -Double.infinity
    public init() {}
    public mutating func reset() {
        remainder = 0
        lastDispatch = -.infinity
        lastInput = -.infinity
    }
    public mutating func turn(delta: Double, sensitivity: Double, now: Double) -> Int {
        guard delta.isFinite, sensitivity.isFinite, now.isFinite, (0.5...4).contains(sensitivity) else { return 0 }
        if now - lastInput > 0.35 { reset() }
        lastInput = now
        if remainder * delta < 0 { remainder = 0 }
        // One media-key step per two degrees in the relative gyro estimate at 1×.
        // Limit output to one step and discard excess whole steps after a fast flick.
        remainder = min(2, max(-2, remainder + delta * sensitivity * 0.5))
        guard now - lastDispatch >= 0.08 else { return 0 }
        let steps = min(1, max(-1, Int(remainder.rounded(.towardZero))))
        guard steps != 0 else { return 0 }
        remainder.formTruncatingRemainder(dividingBy: 1)
        lastDispatch = now
        return steps
    }
}

public enum MacAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case none, previousDesktop, nextDesktop, missionControl, dismiss, previousWindow, nextWindow, previousTab, nextTab
    case playPause, mute, volumeUp, volumeDown, brightnessUp, brightnessDown
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: "No action"
        case .previousDesktop: "Previous desktop"
        case .nextDesktop: "Next desktop"
        case .missionControl: "Mission Control"
        case .dismiss: "Dismiss (Escape)"
        case .previousWindow: "Previous window"
        case .nextWindow: "Next window"
        case .previousTab: "Previous tab"
        case .nextTab: "Next tab"
        case .playPause: "Play / pause"
        case .mute: "Mute / unmute"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .brightnessUp: "Brightness up"
        case .brightnessDown: "Brightness down"
        }
    }
    public var shortcut: String {
        switch self {
        case .none: "—"
        case .previousDesktop: "⌃ ←"
        case .nextDesktop: "⌃ →"
        case .missionControl: "⌃ ↑"
        case .dismiss: "esc"
        case .previousWindow: "⇧ ⌘ `"
        case .nextWindow: "⌘ `"
        case .previousTab: "⌃ ⇧ ⇥"
        case .nextTab: "⌃ ⇥"
        case .playPause: "⏯"
        case .mute: "mute"
        case .volumeUp, .brightnessUp: "+"
        case .volumeDown, .brightnessDown: "−"
        }
    }
    public var keyCode: UInt16? {
        switch self {
        case .none, .playPause, .mute, .volumeUp, .volumeDown, .brightnessUp, .brightnessDown: nil
        case .previousDesktop: 123
        case .nextDesktop: 124
        case .missionControl: 126
        case .dismiss: 53
        case .previousWindow, .nextWindow: 50
        case .previousTab, .nextTab: 48
        }
    }
    public var usesCommand: Bool { self == .previousWindow || self == .nextWindow }
    public var usesControl: Bool { [.previousDesktop, .nextDesktop, .missionControl, .previousTab, .nextTab].contains(self) }
    public var usesShift: Bool { self == .previousWindow || self == .previousTab }
}

public struct ActionGate: Sendable {
    private var armedAt = Double.infinity
    private var lastAction = -Double.infinity
    private let minimumInterval: Double
    public init(minimumInterval: Double = 0.4) { self.minimumInterval = minimumInterval }
    public mutating func arm(at time: Double) { armedAt = time; lastAction = -.infinity }
    public mutating func pause() { armedAt = .infinity }
    public mutating func allows(eventTime: Double, now: Double, live: Bool, trusted: Bool) -> Bool {
        guard live, trusted, eventTime >= armedAt, now - eventTime <= 0.35,
              now - eventTime >= -0.1, now - lastAction >= minimumInterval else { return false }
        lastAction = now
        return true
    }
}
