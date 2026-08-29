import AppKit
import agtermCore
import Foundation

/// The `zmx` command group: the daemon inventory and, later, the actions over it. Every command needs a
/// running instance by design — only one can join the live stores, the pending-close records, the checked
/// closed-window snapshots and the observed daemons into a single answer.
extension ControlServer {
    /// Observed daemons joined against the panes that claim them, with the restore status as a header.
    ///
    /// A failed listing is an error rather than an empty inventory: an empty namespace is a real answer and
    /// must not be indistinguishable from not having looked.
    func listZmxDaemons() -> ControlResponse {
        guard let client = zmxClient else {
            return ControlResponse(ok: false, error: ControlZmxError.unavailable)
        }
        guard let observed = client.listSessions() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        let walk = library.paneClaims()
        let result = ZmxInventory.join(observed: observed, claims: walk.claims,
                                       inventoryComplete: walk.complete)
        let inventory = ControlZmxInventory(restore: restoreStatus(), result: result)
        return ControlResponse(ok: true, result: ControlResult(zmx: inventory))
    }
}

/// Error strings shared by the zmx commands, so the CLI and the server cannot word the same refusal
/// differently.
public enum ControlZmxError {
    public static let unavailable = "zmx is unavailable in this instance"
}
