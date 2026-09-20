import Foundation
import Testing
@testable import Kinesis

@Test @MainActor func anIdlePairingSurfaceInvitesTheFirstPairOrARepair() {
    let fresh = PairingPresentation(PairingInput())
    #expect(fresh.current == nil && fresh.completed.isEmpty && fresh.failed == nil && !fresh.working)
    #expect(fresh.headline == "pair your band" && fresh.buttonTitle == "pair band" && fresh.buttonEnabled)
    #expect(fresh.holdHint == .none && fresh.claimProgress == nil && fresh.help == nil)
    #expect(fresh.bandName == nil && fresh.dimsArtwork)
    // A band that was found and never claimed is unfinished, not lost.
    let unfinished = PairingPresentation(PairingInput(hasRememberedBand: true, bandName: "Meta Band 00BC"))
    #expect(unfinished.headline == "setup incomplete" && unfinished.bandName == "Meta Band 00BC")
    #expect(unfinished.buttonTitle == "pair band" && unfinished.dimsArtwork)
    let distrusted = PairingPresentation(PairingInput(hasRememberedBand: true, bandName: "Meta Band 00BC", identityRejected: true))
    #expect(distrusted.headline == "pair it again")
}

@Test @MainActor func eachStageOfARunMarksItsStepAndTheOnesBehindIt() {
    let finding = PairingPresentation(PairingInput(route: .scanning, canPair: false))
    #expect(finding.current == .find && finding.completed.isEmpty && finding.holdHint == .prompt)
    #expect(finding.detail == PairingPresentation.holdInstruction)
    #expect(finding.working && !finding.buttonEnabled && finding.buttonTitle == "pairing…" && !finding.dimsArtwork)

    let connecting = PairingPresentation(PairingInput(route: .connecting, hasRememberedBand: true, canPair: false))
    #expect(connecting.current == .find && connecting.headline == "connecting to your band" && connecting.holdHint == .none)

    let signIn = PairingPresentation(PairingInput(route: .enrolling, stage: .login, canPair: false))
    #expect(signIn.current == .signIn && signIn.completed == [.find] && !signIn.offersAccountSwitch)

    let claim = PairingPresentation(PairingInput(route: .enrolling, stage: .working("confirming ownership"),
                                                 hasSavedSession: true, canPair: false))
    #expect(claim.current == .claim && claim.completed == [.find, .signIn])
    #expect(claim.claimProgress == 3 && claim.detail == "confirming with the band." && claim.offersAccountSwitch)
    // The ceremony connection is up before the session reports its first stage.
    #expect(PairingPresentation(PairingInput(route: .enrolling, stage: .pairing)).claimProgress == 0)

    // After a claim the reconnect is the last step, never a second "find".
    let settling = PairingPresentation(PairingInput(route: .connecting, claimedThisRun: true, canPair: false))
    #expect(settling.current == .ready && settling.completed == [.find, .signIn, .claim])
    #expect(settling.headline == "almost done")
}

@Test @MainActor func aPendingSystemPairingRequestTakesOverTheCopyAtAnyStage() {
    for input in [PairingInput(route: .connecting, awaitingSystemPairing: true),
                  PairingInput(route: .enrolling, stage: .pairing, awaitingSystemPairing: true),
                  PairingInput(route: .connecting, claimedThisRun: true, awaitingSystemPairing: true)] {
        let state = PairingPresentation(input)
        #expect(state.needsSystemPairing && state.headline == PairingPresentation.systemPairingHeadline)
        #expect(state.detail == PairingPresentation.systemPairingDetail)
    }
    // A stale flag with nothing in flight must not claim macOS is waiting.
    #expect(!PairingPresentation(PairingInput(awaitingSystemPairing: true)).needsSystemPairing)
}

@Test @MainActor func failuresNameTheirStageAndOfferTheRightWayForward() {
    let missing = PairingPresentation(PairingInput(failure: "no band found. put the band in pairing mode and pair again.",
                                                   failedStep: .find, emptyScans: 1))
    #expect(missing.failed == .find && missing.current == nil && missing.completed.isEmpty)
    #expect(missing.headline == "couldn’t find your band" && missing.holdHint == .insist)
    #expect(missing.detail.hasPrefix(PairingPresentation.holdInstruction) && missing.buttonTitle == "try again")
    #expect(missing.buttonEnabled && missing.help == nil)

    let timeout = PairingPresentation(PairingInput(failure: "the band took too long to respond. try reconnecting.",
                                                   failedStep: .find, hasRememberedBand: true))
    #expect(timeout.headline == "couldn’t connect" && timeout.detail == "the band took too long to respond. try reconnecting.")
    #expect(timeout.holdHint == .none)

    let wrongAccount = "this band belongs to a different meta account. factory reset the band (hold the button ~16 seconds), then pair again to claim it with this account."
    let refused = PairingPresentation(PairingInput(failure: wrongAccount, failedStep: .claim, hasRememberedBand: true))
    #expect(refused.failed == .claim && refused.completed == [.find, .signIn])
    #expect(refused.headline == "couldn’t claim your band" && refused.detail == wrongAccount)
    #expect(refused.help?.url == PairingPresentation.factoryResetGuide)

    // A failure with no recorded stage still marks one, so the stepper never looks idle.
    #expect(PairingPresentation(PairingInput(failure: "x")).failed == .find)
}
