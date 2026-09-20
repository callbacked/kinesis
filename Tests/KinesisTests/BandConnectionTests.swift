import CoreBluetooth
import Foundation
import Testing
@testable import Kinesis

@Test @MainActor func aPairingThatWentWrongGetsAdviceThatFitsItsCause() {
    func advice(_ code: CBATTError.Code) -> String {
        NativeBandConnection.explainingPairing(NSError(domain: CBATTErrorDomain, code: code.rawValue)).localizedDescription
    }
    // The request was accepted and macOS still refused the pairing: after a factory reset
    // the band's old entry is in the way, and only the person can remove it.
    #expect(advice(.insufficientEncryption) == NativeBandConnection.stalePairingAdvice)
    #expect(NativeBandConnection.stalePairingAdvice.contains("System Settings › Bluetooth"))
    // The request was missed or declined.
    #expect(advice(.insufficientAuthentication).contains("accept the Bluetooth request"))
    #expect(advice(.insufficientAuthorization).contains("accept the Bluetooth request"))
    // Anything else is passed on as it is.
    let other = NSError(domain: CBATTErrorDomain, code: CBATTError.invalidHandle.rawValue)
    #expect((NativeBandConnection.explainingPairing(other) as NSError) == other)
    let timeout = NSError(domain: CBErrorDomain, code: CBError.connectionTimeout.rawValue)
    #expect((NativeBandConnection.explainingPairing(timeout) as NSError) == timeout)
}

@Test @MainActor func aStalePairingOffersTheWayToBluetoothSettings() {
    var input = PairingInput()
    input.failure = NativeBandConnection.stalePairingAdvice.lowercased()
    input.failedStep = .claim
    let stale = PairingPresentation(input)
    #expect(stale.help?.title == "open bluetooth settings" && stale.help?.url == NativeBandConnection.bluetoothSettings)
    #expect(stale.headline == "couldn’t claim your band" && !stale.offersOtherAccount)
}
