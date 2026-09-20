import AppKit
import CryptoKit
import KinesisCore
import UniformTypeIdentifiers

enum IdentityImport {
    /// Developer import for the documented key extraction workflow: pick the
    /// raw 32-byte identity key file, then optionally the band identity record
    /// json. Key bytes are never logged.
    @MainActor
    static func run(model: BandModel) {
        let band = model.selectedAddress
        guard !band.isEmpty, !model.busy else {
            model.error = "choose a band before importing an identity."
            return
        }
        let keyPanel = NSOpenPanel()
        keyPanel.canChooseFiles = true
        keyPanel.canChooseDirectories = false
        keyPanel.allowsMultipleSelection = false
        keyPanel.message = "choose the 32-byte raw band identity key"
        keyPanel.prompt = "choose key"
        guard keyPanel.runModal() == .OK, let keyURL = keyPanel.url else { return }
        do {
            let raw = try Data(contentsOf: keyURL)
            guard raw.count == 32 else {
                model.error = "the identity key file must hold exactly 32 raw bytes."
                return
            }
            let privateKey = try P256.Signing.PrivateKey(rawRepresentation: raw)
            let recordPanel = NSOpenPanel()
            recordPanel.canChooseFiles = true
            recordPanel.canChooseDirectories = false
            recordPanel.allowsMultipleSelection = false
            recordPanel.allowedContentTypes = [.json]
            recordPanel.message = "optionally choose the band identity record json"
            recordPanel.prompt = "choose record"
            var bandKey: P256.Signing.PublicKey?
            if recordPanel.runModal() == .OK, let recordURL = recordPanel.url {
                let record = try BandIdentity.record(try Data(contentsOf: recordURL))
                guard record.privateKey.rawRepresentation == raw else {
                    model.error = "the identity record does not match the key file."
                    return
                }
                bandKey = record.bandPublicKey
            }
            try BandIdentity.save(privateKey, bandKey: bandKey, for: band)
            model.refreshIdentity()
        } catch {
            model.error = error.localizedDescription
        }
    }
}
