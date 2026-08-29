import Foundation

// Nested `ControlResult` payloads, kept out of `ControlProtocol.swift` so that file stays inside the
// 1000-line limit.

/// The restore-mode policy, read by `restore.mode` and repeated as `zmx list`'s header.
///
/// Modes travel as raw strings even though the producer holds a typed `RestoreMode`. `RestoreMode`'s own
/// decoder is deliberately lossy — an unknown raw value becomes `.none` so a settings file written by a
/// newer build is not discarded — and reusing it here would make a stale CLI print a future mode as
/// `none`, the mode that reaps every daemon. Every other evolvable enum on a control node is projected
/// the same way.
public struct ControlRestoreStatus: Codable, Sendable, Equatable {
    /// What settings.json holds, and so what the NEXT launch will request.
    public let configured: String
    /// What THIS process requested at launch. Differs from `configured` once Settings changes mid-run.
    public let requestedAtLaunch: String
    /// What the launch actually got: `none` when live was requested but ineligible.
    public let active: String
    public let restartRequired: Bool
    /// Why live fell back, present ONLY when live was actually requested and refused. The launch decision
    /// carries a probed reason even under `none`/`rerun`, and reporting that would tell a rerun user their
    /// shell is unsupported for a mode they never asked for.
    public let unavailableReason: String?

    public init(configured: RestoreMode, requestedAtLaunch: RestoreMode, active: RestoreMode,
                unavailableReason: String?) {
        self.configured = configured.rawValue
        self.requestedAtLaunch = requestedAtLaunch.rawValue
        self.active = active.rawValue
        restartRequired = configured != requestedAtLaunch
        self.unavailableReason = requestedAtLaunch == .live && active != .live ? unavailableReason : nil
    }
}

/// `surface.cursor`'s payload, nested so a `row` could join it additively rather than by a rename.
///
/// There is no row: `tl_px_y` is the text BASELINE against an IME point at the cell bottom, leaving a term
/// no probe separates from the row, and `adjust-font-baseline = 30` was measured reporting row 5 for a caret
/// on row 4. `GhosttySurfaceView.readCursorColumn` owns why the horizontal twin is exact.
///
/// A column is a signal, not an assertion about content: past the prompt it proves the line is not empty,
/// AT the prompt it proves nothing, the caret having possibly moved back over text.
public struct ControlCursor: Codable, Sendable, Equatable {
    /// Zero-based, counted from the left edge of the grid.
    public let column: Int

    public init(column: Int) {
        self.column = column
    }
}
