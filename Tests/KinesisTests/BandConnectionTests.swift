import CoreBluetooth
import Foundation
import Testing
@testable import Kinesis

@Test @MainActor func aRefusedReadIsPairingAndAnythingElseIsAFailure() {
    // After a factory reset macOS still holds the old bond. The band refuses it, the read
    // fails with a security error, and macOS asks to pair again. That is not yet a failure.
    for code in [CBATTError.insufficientEncryption, .insufficientAuthentication, .insufficientAuthorization] {
        let refused = NSError(domain: CBATTErrorDomain, code: code.rawValue)
        #expect(NativeBandConnection.isPairingError(refused))
        #expect(NativeBandConnection.explainingPairing(refused).localizedDescription.contains("accept the Bluetooth request"))
    }
    let other = NSError(domain: CBATTErrorDomain, code: CBATTError.invalidHandle.rawValue)
    #expect(!NativeBandConnection.isPairingError(other))
    #expect(!NativeBandConnection.isPairingError(NSError(domain: CBErrorDomain, code: CBError.connectionTimeout.rawValue)))
    #expect((NativeBandConnection.explainingPairing(other) as NSError) == other)
    // One open request, and room for macOS to ask a second time after its own 30 seconds.
    #expect(NativeBandConnection.pairingWindow > 30)
}
