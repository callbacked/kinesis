import Foundation
import IOBluetooth

/// macOS keeps its own pairing entry for the band. A band that was factory reset has a new
/// identity key, and macOS refuses to pair with it while the old entry exists. So forgetting
/// the band has to forget that entry too.
enum SystemPairing {
    /// Removes this Mac's pairing entries for the band with this name. True when none is
    /// left in the way, as far as the app can tell: there was none, or each one was removed.
    ///
    /// There is no public call for this. `remove` is the unpublished one that tools like
    /// blueutil rely on. If a future macOS drops it, this returns false, and the app asks
    /// the person to remove the entry themselves.
    static func remove(named name: String) -> Bool {
        let remove = Selector(("remove"))
        let entries = (IOBluetoothDevice.pairedDevices() ?? []).compactMap { $0 as? IOBluetoothDevice }.filter { $0.name == name }
        for entry in entries where entry.responds(to: remove) { entry.perform(remove) }
        return entries.allSatisfy { $0.responds(to: remove) }
    }
}
