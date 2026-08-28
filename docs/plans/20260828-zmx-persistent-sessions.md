# zmx-backed persistent sessions

## Overview

Add a global **restore mode** to agterm. In `live` mode every primary and split pane runs its shell inside
a `zmx attach` client, so the shell and whatever runs in it survive an app quit, crash or relaunch: the
daemon keeps the pty, and the next launch reattaches instead of respawning. This replaces the current
capture-the-foreground-argv-and-rerun-it mechanism, which restores a *command line*, not a session.

The mode is one setting with three values — `none`, `rerun` (today's behavior), `live` — and it is latched
per process at launch. There is no per-session flag, no per-session control command, and no way for one
session to opt out: restore that works only for sessions the user remembered to mark is not restore.

No libghostty patch. The multiplexer sits *inside* the pty as the surface's child, so libghostty still owns
a real pty with a real child, the C-callback contract is unchanged, and `GHOSTTY_REV` stays a plain
reproducibility pin. This supersedes `docs/plans/ideas/20260706-persistent-sessions.md`, whose opt-in
design and several factual claims are wrong (see Corrections below).

The eventual payoff beyond restore is remote teleport: a daemon broadcasts its pty output to **every**
attached client and takes input from any of them, so a second client — locally, or over ssh from another
machine — mirrors a live session. Nothing in this plan builds teleport, but every design decision here is
made so teleport needs no rework: pane identity is persisted and stable, and daemon names are derivable
from the tree.

## Corrections to the superseded plan

Established from source and runtime during design; each one changes a task.

1. **`command` and `initial_input` are not mutually exclusive in libghostty.** `embedded.zig:549-585`
   applies them in independent blocks. The exclusion is agterm's own policy at
   `GhosttySurfaceView.swift:562`, relaxed for wrapped surfaces in commit `495accd7`.
2. **The zig pin moved to 0.16.** `scripts/setup.sh:26` sets `ZIG_FORMULA="zig@0.16"`; zmx 0.7.0 builds
   with the compiler the ghostty build already installs. No new toolchain.
3. **Persistence is global, not per session.** No `session.persist` command, no `--persist` flag, no
   sidebar toggle. agterm has no `settings.*` control commands at all and this feature adds none.
4. **Role-derived daemon names are unsafe.** `<id>` / `<id>-split` breaks on split promotion: closing the
   primary promotes the split *surface* into the main slot, so the survivor keeps owning `-split` and a
   later split attaches a new pane to the survivor's own daemon. Identity must be persisted per pane.
5. **Shell integration is the load-bearing mechanism and the plan never examined it.** A set `command`
   stops ghostty detecting a shell, so `detect` injects nothing. A **forced** `shell-integration` value
   bypasses detection (`shell_integration.zig:43-52`) and for zsh and fish is environment-only, returning
   the command unchanged — which is why the wrapper works fork-free. Forced bash and nushell rewrite the
   command's own argv (`zmx --posix`) and cannot work through a wrapper.

## Context (from discovery)

Files and components involved:

- **Model / persistence (`agtermCore`):** `Session.swift`, `Snapshot.swift`, `AppStore.swift`,
  `AppStore+PendingClose.swift` (`softCloseSession`, `finalizePendingClose`), `WindowLibrary.swift`
  (`closeWindow` vs `removeWindow`), `AppSettings.swift`, `CommandRestore.swift`.
- **Surface / bridge (app target):** `agtermApp.swift` (`makeSurface`, split/overlay/scratch factories),
  `Ghostty/GhosttySurfaceView.swift` (config block, `isZmxWrapped`), `Ghostty/ZmxSpike.swift` (the spike
  gate, to be dissolved), `Ghostty/ForegroundProcess.swift`, `Ghostty/GhosttyResources.swift`,
  `AppDelegate.swift` (quit flush, launch).
- **Control (app + core):** `Control/ControlServer.swift` (`buildTree`), `ControlProtocol.swift`.
- **Settings:** `SettingsModel.swift`, the Settings window's restore section.
- **Build:** `scripts/setup.sh`, `project.yml` (the `agtermctl` post-build embed phase is the pattern).
- **Keep-in-sync:** `README.md`, `site/docs.html`, `site/index.html`,
  `plugins/agterm/skills/agterm/`, `.claude/rules/settings.md`, `.claude/rules/control-api.md`.

Already proven by the committed spike (`495accd7`):

- wrapping a primary pane fork-free, with the zsh integration reaching the inner shell (`cd` moves
  `tree.cwd`);
- clean quit and relaunch reattaching the same daemon with cwd and scrollback intact;
- Claude Code surviving a restart and answering a prompt after reattach, kitty keyboard mode intact;
- `initial_input` delivered through the attach client exactly once, and not replayed on a restored pane.

Dependencies: **zmx** (neurosnap/zmx, pinned `ZMX_REV`), built from source with the existing zig 0.16.

## Development Approach

- **Testing approach:** Regular (code first, then tests), but tests are a **required deliverable of every
  task**, listed as separate checklist items, and must pass before the next task starts.
- Bottom-up: host-free logic in `agtermCore` first, then app-target side effects, then build, then docs.
- Codex writes the code as sole writer in this worktree; Claude Code verifies each task before the next
  begins — reading the diff and **running the gates itself** rather than reading reported results.
- **CRITICAL: all gates pass before the next task starts** — `make build`, `swift test`, `make lint`.
- **CRITICAL: update this plan when scope changes during implementation.**

## Project Guardrails (HARD — verify before marking any task complete)

- **`agtermCore` stays host-free:** no `GhosttyKit`/`AppKit`/`Metal`, and no CoreGraphics geometry. Naming,
  budget, parsing, model, migration and mode resolution live there; the app target is the side-effect
  adapter.
- **Visibility:** `public` only where the app target or CLI actually calls it.
- **Comments:** lowercase except godoc; document the non-obvious *why* only. No test comments beyond a
  regression test's one-line reason.
- **File sizes:** sources under 1000 lines, tests under 2000. New logic goes in new files; if a touched
  file approaches the limit, stop and ask rather than raising the limit.
- **One writer per worktree.** Hand the worktree over explicitly before the other agent edits.
- **`CHANGELOG.md` is release-only — do not touch it here.**
- Never run a mutating `agtermctl` against the default socket; never launch, quit or install from the
  deployed app. Dev instances get an isolated `AGTERM_STATE_DIR` and a short socket path, and are stopped
  by SIGTERM to a known PID captured from `ps aux` — never `pkill`, never AppleScript quit, and never a
  clean quit unless the quit-time flush is what is under test.

## Testing Strategy

- **Unit tests (required per task):** every host-free piece is directly testable — mode migration and
  resolution, pane-identity promotion, name derivation, socket budget, shell-support decision, `zmx ls`
  parsing, orphan selection, the leader-pid parse. One test file per source file.
- **App-target logic** stays injectable: the zmx client is a struct of closures with a `.noop` for tests,
  so budget and resolution decisions are unit-testable without spawning processes.
- **XCUITest:** the control round-trip for the per-surface `backedByZmx` field, and a mode-off launch that
  leaves no wrapped surfaces. **Wrapping is bypassed under test** (keyed on the isolated
  `AGTERM_STATE_DIR`) so a test run can never orphan a daemon.
- **Manual e2e** (Post-Completion): reattach after clean quit, after SIGTERM, and after a reboot; undo
  inside the grace window; window close then reopen; window delete.

## Progress Tracking

- mark completed items `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document blockers with ⚠️ prefix

## Solution Overview

A wrapped pane's surface runs `zmx attach agterm-<pane-identity>` as its `config.command`, and zmx execs
the user's login shell as its child. Identity comes from a **persisted per-pane value** on the session, not
from the pane's current role, so promotion and re-splitting can never cross-wire two panes onto one daemon.
Only primary and split panes are wrapped; scratch, overlay and quick terminals are ephemeral and never are.

The integration environment is supplied per surface because ghostty cannot detect a shell behind the
wrapper: `ZDOTDIR` at the bundled zsh integration with any existing value preserved as
`GHOSTTY_ZSH_ZDOTDIR`, `SHELL` resolved from the password database, plus `ZMX_DIR` and
`ZMX_NO_DETACH_KEY=1`. Fish gets the equivalent `XDG_DATA_DIRS` treatment. Any other shell fails closed to
an ordinary unwrapped pane, logged and surfaced in Settings.

Lifecycle follows **semantic finalization**, never surface teardown — `TerminalSurface.teardown()` is shared
by window close, app quit, session close, split close and promotion, so a kill there would destroy live
shells on paths that should only detach:

| event | daemons |
|---|---|
| app quit | detach |
| window close (reopenable) | detach |
| window delete | kill every pane's daemon |
| session close | kill, but only when `finalizePendingClose` runs — never during the undo grace |
| undo inside the grace | nothing; the same objects come back |
| split close, split process exit | kill that pane's daemon only |
| primary exit with a split survivor | promotion moves the identity; nothing is killed |
| workspace delete | same finalization rule for every contained pane |
| launch | reap zero-client `agterm-*` daemons no persisted pane claims |

`ZMX_DIR` is a short `/tmp` path derived from the instance's `AGTERM_STATE_DIR`, so each instance has its
own daemon namespace and a dev instance can never reap the deployed app's sessions. Over the `sun_path`
budget, wrapping is bypassed rather than broken.

## Technical Details

- **Name:** `agterm-<12 hex of the pane identity>`; worst case ~25 bytes, and
  `ZMX_DIR=/tmp/agterm-zmx-<16 hex of the state dir hash>` keeps `<dir>/<name>` far under 104 bytes.
- **New model fields:** `Session.paneIdentity: UUID`, `Session.splitPaneIdentity: UUID?`, mirrored as
  `SessionSnapshot.paneIdentity: UUID?` / `splitPaneIdentity: UUID?` (Optional, no `Snapshot` version bump,
  missing → minted on load). Promotion assigns `paneIdentity = splitPaneIdentity` and clears the latter.
- **Settings:** `AppSettings.restoreMode: RestoreMode?` replacing `restoreRunningCommand: Bool?`;
  migration is legacy `true` → `.rerun`, `false`/absent → `.none`. `live` is never reached by migration.
- **Latching:** the effective mode is read once at launch into the app's ghostty state; the Settings picker
  writes the *next* launch's mode and says "Restart agterm to apply". Cleanup of a disabled instance's
  daemons runs at the next non-live launch, before any surface is created, so a crash after the toggle
  cannot leak them forever.
- **Stale replay state:** when `live` takes effect, captured foreground argv is stripped from open **and**
  closed window snapshots, so a later switch back to `rerun` cannot resurrect a pre-zmx capture. A pending
  `session.restore` override is retained but suspended, and reactivates only in `rerun`.
- **Control API:** no new command. `tree` gains `backedByZmx` per **surface** (splits can differ, and
  teleport addresses a pane); the session-level view is true only when every existing pane is backed.
- **`--command` sessions:** in `live` mode the command is typed into the wrapped shell rather than
  replacing it, so `wait-after-command` and close-on-exit do not apply. Documented as a mode limitation.
- **Build:** `ZMX_REV` pin in `setup.sh`; `zig build` with the existing `zig@0.16`; stage to
  `agterm/Resources/zmx/zmx` (gitignored); a `project.yml` post-build phase copies **and codesigns** the
  nested Mach-O before Xcode's outer re-sign, patterned on the existing `agtermctl` phase — not on the
  ghostty resource staging, since neither of those is a signed nested executable.

## What Goes Where

- **Implementation Steps** (`[ ]`): code, tests, in-repo docs, build wiring.
- **Post-Completion** (no checkboxes): manual reattach/crash/reboot verification and the dev-instance
  smoke test.

## Implementation Steps

### Task 1: Restore mode enum and settings migration (agtermCore)

**Files:**
- Create: `agtermCore/Sources/agtermCore/RestoreMode.swift`
- Create: `agtermCore/Tests/agtermCoreTests/RestoreModeTests.swift`
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`

- [ ] add `RestoreMode` (`none`, `rerun`, `live`) with a lossy decode that falls back to `.none`
- [ ] replace `AppSettings.restoreRunningCommand` with `restoreMode`, migrating legacy `true` → `.rerun`
      and `false`/absent → `.none` on decode
- [ ] keep the legacy key readable so an older `settings.json` still decodes without loss
- [ ] write tests for the migration (legacy true/false/absent, an unknown string, a round trip)
- [ ] run `swift test` — must pass before the next task

### Task 2: Persisted pane identity and promotion (agtermCore)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`, `Snapshot.swift`, `AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`, `SnapshotTests.swift`

- [ ] add `paneIdentity` and `splitPaneIdentity` to `Session`, minted on creation and on split
- [ ] mirror both as Optional snapshot fields with no version bump; mint on decode when absent
- [ ] make split promotion move `splitPaneIdentity` into `paneIdentity` and clear it, so a later split
      mints a fresh identity rather than reusing the survivor's
- [ ] write tests: promotion then re-split yields three distinct identities; a legacy snapshot decodes and
      mints; identity survives rename and `moveSession`
- [ ] run `swift test` — must pass before the next task

### Task 3: Daemon naming and socket budget (agtermCore)

**Files:**
- Create: `agtermCore/Sources/agtermCore/ZmxSessionName.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ZmxSessionNameTests.swift`

- [ ] derive `agterm-<12 hex>` from a pane identity, and the `/tmp/agterm-zmx-<hash>` dir from a state dir
- [ ] expose a budget check that reports whether `<dir>/<name>` fits `sun_path`
- [ ] move the equivalent logic out of `agterm/Ghostty/ZmxSpike.swift` rather than duplicating it
- [ ] write tests: derivation is stable and lowercase, distinct identities never collide, a long state dir
      is rejected by the budget check
- [ ] run `swift test` — must pass before the next task

### Task 4: Shell support decision and integration environment (agtermCore)

**Files:**
- Create: `agtermCore/Sources/agtermCore/ZmxShellSupport.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ZmxShellSupportTests.swift`

- [ ] map a login-shell path to supported (zsh, fish) or unsupported (everything else), with the reason
- [ ] build the integration environment for a supported shell from a resources dir and the current
      environment: zsh sets `ZDOTDIR` preserving any existing value as `GHOSTTY_ZSH_ZDOTDIR`; fish prepends
      to `XDG_DATA_DIRS` and sets `GHOSTTY_SHELL_INTEGRATION_XDG_DIR`
- [ ] always set `SHELL` to the resolved shell, so zmx cannot pick a different child than the one the
      environment was prepared for
- [ ] write tests for both shells, an unsupported shell, a preserved existing `ZDOTDIR`, and an empty
      `XDG_DATA_DIRS`
- [ ] run `swift test` — must pass before the next task

### Task 5: Mode latching and the Settings picker (app)

**Files:**
- Modify: `agterm/Ghostty/GhosttyApp.swift`, `agterm/SettingsModel.swift`, the Settings restore section
- Modify: `agterm/AppDelegate.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RestoreModeTests.swift`

- [ ] resolve the effective mode once at launch and use that value for every surface created in the process
- [ ] replace the restore checkbox with a three-way picker that writes the next launch's mode and states
      that a restart is required
- [ ] show why `live` is unavailable when the login shell is unsupported, rather than silently doing nothing
- [ ] write tests for the host-free part of the resolution (latched value wins over a later settings change)
- [ ] run `swift test` and `make build` — must pass before the next task

### Task 6: Wrap primary and split panes from the latched mode (app)

**Files:**
- Modify: `agterm/agtermApp.swift`, `agterm/Ghostty/GhosttySurfaceView.swift`
- Delete: `agterm/Ghostty/ZmxSpike.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ZmxSessionNameTests.swift`

- [ ] replace the `AGTERM_ZMX_PATH` gate with the latched mode plus the bundled binary path, keeping the
      env var as a development override only
- [ ] wrap the split pane too, using its own identity, and leave scratch, overlay and quick terminals alone
- [ ] keep the relaxed `initial_input` path and the skipped foreground capture from the spike commit
- [ ] set `isZmxWrapped` before the surface can be created, and note the ordering requirement where it is set
- [ ] write tests for the pure inputs the wrap decision consumes (mode, shell support, budget)
- [ ] run `swift test`, `make build`, `make lint` — must pass before the next task

### Task 7: zmx client and its parsers (app + agtermCore)

**Files:**
- Create: `agterm/Ghostty/ZmxClient.swift`
- Create: `agtermCore/Sources/agtermCore/ZmxListParser.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ZmxListParserTests.swift`

- [ ] add an injectable client (struct of closures, with a `.noop`) over `zmx ls` and `zmx kill`
- [ ] parse `zmx ls` into name, client count and session-leader pid in `agtermCore`
- [ ] select orphans: zero-client `agterm-*` daemons absent from a supplied known set
- [ ] write tests for the parser (healthy, zero-client, malformed and error lines) and for orphan selection
- [ ] run `swift test` — must pass before the next task

### Task 8: Semantic finalization — kill, detach and promotion (app + agtermCore)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift`, `AppStore.swift`,
  `WindowLibrary.swift`
- Modify: `agterm/AppDelegate.swift`, `agterm/Control/ControlServer+SessionActions.swift`

- [ ] kill a session's daemons only from `finalizePendingClose`, so an undo inside the grace window keeps
      the same live shells
- [ ] kill the split pane's daemon on an explicit split close or split process exit, and nothing on hide
- [ ] make `closeWindow` detach and `removeWindow` kill, and apply the finalization rule to workspace delete
- [ ] leave app quit detaching, and keep kill out of `TerminalSurface.teardown()` entirely
- [ ] write tests for the host-free decision — which identities a given lifecycle event finalizes
- [ ] run `swift test`, `make build`, `make lint` — must pass before the next task

### Task 9: Launch reap and the missing-daemon fallback (app + agtermCore)

**Files:**
- Modify: `agterm/AppDelegate.swift`
- Create: `agtermCore/Sources/agtermCore/ZmxReapPlan.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ZmxReapPlanTests.swift`

- [ ] build the known set from every window's persisted snapshot — open **and** closed windows — and run the
      reap only once that set is complete, never from live-restored sessions
- [ ] reap zero-client `agterm-*` daemons the known set does not claim, scoped to this instance's `ZMX_DIR`
- [ ] run the same cleanup at a non-live launch, so a mode change or a crash after one cannot leak daemons
- [ ] make a snapshot naming a daemon that no longer exists (every reboot) come back as a fresh shell in
      that pane, with no error and no orphaned identity
- [ ] write tests for the reap plan: multi-window known sets, a closed window's panes, an unclaimed daemon,
      and a claimed daemon with zero clients
- [ ] run `swift test`, `make build` — must pass before the next task

### Task 10: Foreground resolver for wrapped panes (app + agtermCore)

**Files:**
- Create: `agterm/Ghostty/ZmxForegroundResolver.swift`
- Modify: `agterm/Ghostty/ForegroundProcess.swift`, `agterm/Control/ControlServer.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ZmxLeaderParserTests.swift`

- [ ] resolve a wrapped pane's real foreground process past the `zmx attach` client via the daemon's
      session-leader pid, so `tree.foreground` stops reporting the wrapper
- [ ] leave the unwrapped path untouched
- [ ] write tests for the leader-pid parse and for the resolver picking the leader over the client
- [ ] run `swift test`, `make build` — must pass before the next task

### Task 11: Report backing per surface on the tree (app + agtermCore)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [ ] add `backedByZmx` to the surface node, describing the ACTUAL backing rather than the configured mode
- [ ] make the session-level view true only when every existing pane is backed
- [ ] write a control round-trip test for a wrapped and an unwrapped session
- [ ] run the targeted XCUITest with `-only-testing:` and `swift test` — must pass before the next task

### Task 12: Build, embed and codesign zmx (build)

**Files:**
- Modify: `scripts/setup.sh`, `project.yml`, `.gitignore`

- [ ] pin `ZMX_REV`, build it idempotently with the existing `zig@0.16`, stage `agterm/Resources/zmx/zmx`
- [ ] add a `project.yml` post-build phase that copies **and** codesigns the nested binary before Xcode's
      outer re-sign, patterned on the `agtermctl` phase
- [ ] gitignore the staged binary
- [ ] verify `codesign -dv` on the bundled binary and that the app resolves it at runtime
- [ ] run `make build` — must pass before the next task

### Task 13: Keep-in-sync documentation (docs)

**Files:**
- Modify: `README.md`, `site/docs.html`, `site/index.html`,
  `plugins/agterm/skills/agterm/{SKILL.md,reference.md,troubleshooting.md}`,
  `.claude/rules/settings.md`, `.claude/rules/control-api.md`

- [ ] document the three restore modes, the restart requirement, and the zsh/fish-only limitation
- [ ] document what a restore does **not** bring back: inline images, prompt-marker history, a
      program-changed palette, existing hyperlinks, and `--command` close-on-exit
- [ ] record `backedByZmx` in the control reference and the agent skill
- [ ] state the positioning and install facts unchanged; do not state a command count anywhere
- [ ] run `make lint` — must pass before the next task

### Task 14: Verify acceptance criteria

- [ ] verify every Overview requirement is implemented, including that no per-session escape exists
- [ ] verify the lifecycle table row by row in an isolated dev instance
- [ ] run `swift test`, `make test-app`, `make lint`, `make build`
- [ ] verify no daemon survives a full close-and-quit cycle that should have killed it

### Task 15: [Final] Update documentation and finalize

- [ ] update `CLAUDE.md` if new patterns emerged (the finalization seam, the latching rule)
- [ ] delete `docs/plans/ideas/20260706-persistent-sessions.md`, superseded by this plan
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**

- reattach after a clean quit, after SIGTERM to the app (the crash case), and after a machine reboot
- undo a session close inside the 3-second grace and confirm the same shell and scrollback return
- close a window, reopen it, and confirm the daemons were detached rather than killed; then delete a
  window and confirm they are gone
- run an agent (Claude Code) across a restart and confirm keyboard mode and colors survive the reattach
- live in `live` mode for several days against a **copied** state dir before pointing it at the real one

**Known limitations to accept or revisit:**

- bash and nushell cannot be wrapped fork-free; ghostty rewrites the command's argv for them. Generality
  would need an upstream `command-wrapper`-style API, which is also the thing that would make this
  simpler everywhere.
- a reattached screen is synthesized from zmx's terminal model, not replayed byte for byte.

Smells pre-check: skipped — non-Go project.
