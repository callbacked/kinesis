import Foundation

/// The four things a person sees happen while a band is paired.
enum PairStep: Int, CaseIterable, Identifiable, Sendable {
    case find, signIn, claim, ready
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .find: "find"
        case .signIn: "sign in"
        case .claim: "claim"
        case .ready: "ready"
        }
    }
}

/// Everything the pairing surface needs from the model, as plain values.
@MainActor
struct PairingInput: Equatable {
    var route = PairRoute.none
    var stage = EnrollmentStage.idle
    var failure: String?
    var failedStep: PairStep?
    var emptyScans = 0
    var hasRememberedBand = false
    var claimedThisRun = false
    var awaitingSystemPairing = false
    var hasSavedSession = false
    var canPair = true
}

/// What the pairing surface shows. Pure: the same input always reads the same,
/// so every state can be tested and rendered without a band.
@MainActor
struct PairingPresentation: Equatable {
    enum HoldHint: Equatable { case none, prompt, insist }

    let current: PairStep?
    let completed: Set<PairStep>
    let failed: PairStep?
    let headline: String
    let detail: String
    let buttonTitle: String
    let buttonEnabled: Bool
    let working: Bool
    let holdHint: HoldHint
    /// 0...4 while the claim runs, for its four quiet ticks.
    let claimProgress: Int?
    let offersAccountSwitch: Bool
    let needsSystemPairing: Bool
    /// A guide worth opening for this failure, such as Meta's factory reset steps.
    let help: Help?

    struct Help: Equatable {
        let title: String
        let url: URL
    }

    static let factoryResetGuide = URL(string: "https://www.meta.com/help/ai-glasses/1481163499576351/")!

    static let holdInstruction = "hold the band’s button for 3 seconds, until its light flashes."
    static let systemPairingHeadline = "macOS wants to pair"
    static let systemPairingDetail = "accept the bluetooth pairing request from macOS. it can hide in the top right corner of your main display."

    init(_ input: PairingInput) {
        let current = Self.step(for: input)
        self.current = current
        working = current != nil
        failed = current == nil && input.failure != nil ? (input.failedStep ?? .find) : nil
        let reached = current ?? failed
        completed = Set(PairStep.allCases.filter { step in reached.map { step.rawValue < $0.rawValue } ?? false })
        needsSystemPairing = working && input.awaitingSystemPairing
        offersAccountSwitch = input.route == .enrolling && input.hasSavedSession
        buttonEnabled = input.canPair && !working

        var claim: Int?
        switch current {
        case .find? where input.route == .scanning:
            headline = "looking for your band"
            detail = Self.holdInstruction
        case .find?:
            headline = needsSystemPairing ? Self.systemPairingHeadline : "connecting to your band"
            detail = needsSystemPairing ? Self.systemPairingDetail : "keep it close and on your wrist."
        case .signIn?:
            headline = "sign in with meta"
            detail = "one sign-in claims your band for this Mac."
        case .claim?:
            let (index, text) = Self.claimStage(input.stage.workingText)
            claim = index
            headline = needsSystemPairing ? Self.systemPairingHeadline : "claiming your band"
            detail = needsSystemPairing ? Self.systemPairingDetail : text
        case .ready?:
            headline = needsSystemPairing ? Self.systemPairingHeadline : "almost there"
            detail = needsSystemPairing ? Self.systemPairingDetail : "reconnecting with your band’s new key."
        case nil:
            if let failure = input.failure {
                let missing = failed == .find && input.emptyScans > 0
                headline = missing ? "couldn’t find your band" : Self.failureHeadline(failed ?? .find)
                detail = missing ? Self.holdInstruction + " keep it within arm’s reach, then try again." : failure
            } else if input.hasRememberedBand {
                headline = "pair it again"
                detail = "your band no longer recognizes this Mac. pairing again takes about a minute."
            } else {
                headline = "pair your band"
                detail = "kinesis finds your band, signs you in with meta once, and claims it for this Mac."
            }
        }
        claimProgress = claim
        help = current == nil && input.failure?.contains("factory reset") == true
            ? Help(title: "how to factory reset", url: Self.factoryResetGuide) : nil
        buttonTitle = working ? "pairing…" : input.failure != nil ? "try again" : "pair band"
        if input.route == .scanning { holdHint = .prompt }
        else if current == nil, input.emptyScans > 0 { holdHint = .insist }
        else { holdHint = .none }
    }

    private static func step(for input: PairingInput) -> PairStep? {
        switch input.route {
        case .none: nil
        case .scanning: .find
        case .connecting: input.claimedThisRun ? .ready : .find
        case .enrolling: input.stage == .login ? .signIn : .claim
        }
    }

    private static func failureHeadline(_ step: PairStep) -> String {
        switch step {
        case .find: "couldn’t connect"
        case .signIn: "couldn’t sign in"
        case .claim: "couldn’t claim your band"
        case .ready: "couldn’t reconnect"
        }
    }

    /// The session reports its ceremony in its own words; people get plainer ones.
    private static func claimStage(_ text: String?) -> (Int, String) {
        switch text {
        case "reading the band identity": (1, "reading your band’s identity.")
        case "claiming the band": (2, "asking meta to make it yours.")
        case "confirming ownership": (3, "confirming with your band.")
        case "establishing trust": (4, "trading keys with this Mac.")
        case let text?: (2, text + ".")
        case nil: (0, "connecting to your band.")
        }
    }
}
