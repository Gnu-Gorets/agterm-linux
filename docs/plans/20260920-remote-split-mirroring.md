# Mirror an origin's split layout to an attached viewer

## Overview

A session attached from another Mac reads the origin's panes once, at `zmx.attach`. After that nothing
about pane structure travels: a split the origin opens, closes, hides, re-axes, swaps or promotes never
reaches the viewer, and the presentation stream from #629/#630/#634 has no frame for it.

This plan adds one-way layout mirroring, origin to viewer, over the existing presentation stream.
The viewer follows which panes exist on the origin, which is primary, the axis, and shown versus hidden.

Terms: **origin** is the Mac owning the session and its daemons; **viewer** is the Mac that attached;
a **replica** is a viewer pane running ssh against one origin daemon; a **local pane** is a shell this
Mac opened on the attached row.

Decisions already taken (Eugene, 2026-09-20):

- a separate PR, after the context mirror (#634)
- one direction only; no viewer-to-origin command of any kind
- a local pane is never replaced or claimed, in either slot; ownership is decided per pane identity, never
  by slot or by `remoteHost`, which marks the whole row
- closing a replica on the viewer is a **dismissal** remembered per origin pane identity for that attached
  row: it survives reconnect, hide/show, axis change and swap; a genuinely new origin identity is
  eligible; closing and reattaching the row resets it
- divider ratio and keyboard focus stay local, preserved by surviving pane identity. Accepted consequence:
  when the origin hides its split the viewer maximizes ITS focused pane, which may differ from the
  origin's, so layouts match in structure and not pixel for pixel
- full scope in one plan

Rule that follows from "never replace a local pane" and is stated here so no executor invents it:
a replica takes whichever slot is free. Roles are mirrored only while BOTH viewer panes are replicas. With
a local pane in the primary slot and a free split slot, the origin's pane goes to the split slot; with
both slots held, it defers. A swap on the origin reorders two surviving replicas and never deletes one.

Out of scope: viewer-to-origin commands; mirroring ratio or focus; a confirmed whole-session removal
message (a vanished origin session stays an ordinary stream disconnect); flag, watermark and name;
reproducing a HIDDEN origin split at initial attach, which the first layout snapshot corrects instead.

## Context (from discovery)

- `agterm/Control/ControlServer+Zmx.swift:174-226` `attachRemoteSession` reads `remote.panes` and
  `remote.splitAxis` from `zmx.tree` once, builds the ssh commands through `paneCommand` (233), always
  SHOWS a reported second pane, sets `splitCommandWait = true`, and keeps the endpoint nowhere.
  `ControlRemoteSession` (`ControlPayloads.swift:114-143`) has `panes` and `splitAxis` and no visibility
  field.
- `agtermCore/Sources/agtermCore/RemotePresentationState.swift`: `RemoteBinding.localByRemotePane` and
  `RemotePresentationState.binding` are both `let`. The state exists on attached viewer rows only.
- `agterm/Control/ControlServer+Presentation.swift:99` `openPresentation` refuses a session unless
  `Session.allPanesBackedByZmx`, which is false while an existing split has no `splitSurface`
  (`Session.swift:200-201`). A reconnect during that window is refused before any snapshot.
- Readiness has no running owner today. `localAttachableSessions` (`ControlServer+Zmx.swift:129-159`) and
  `listZmxDaemons` run only on request. `ZmxForegroundResolver.refreshIfNeeded` is called from
  `buildTree`, and `ZmxRefreshGate.reconcileInterval = 30` (`ZmxLifecycle.swift:67`) is a cache-expiry
  check, not a timer. The presentation heartbeat runs every 10 seconds and refreshes no inventory.
  `ZmxClient` is `@MainActor` and its synchronous list defaults to a three-second timeout.
- `agtermCore/Sources/agtermCore/AppStore+Panes.swift`: `setSplitVisibility` (64) hides without closing
  and mints the split identity before the lazy surface starts; `swapPanes` (104); `closeSplit` (178) kills
  the daemon through the pane finalizer; `closePrimaryPane` (231) closes the WHOLE row when
  `splitSurface` is nil (233-235) and otherwise promotes the split, resetting ratio and focus.
- `agterm/agtermApp.swift:444` `handlePaneExit` routes a surface exit by CURRENT role.
  `RemoteSession.attachPaneCommand` (99) prints the disconnect line; with `commandWait` Ghostty holds the
  pane at its press-any-key prompt (`GhosttySurfaceView.swift:562`). Only a terminal ssh exit produces
  that hold; losing the presentation stream alone leaves the terminal running.
- `AppStore+RemotePresentation.swift:28-38` `applyRemoteStatus` records no owner for an origin pane with
  no local counterpart and sets `statusOwnerResolved = false`; nothing revisits it when a mapping appears.
- `RemotePresentationClient.apply` switches exhaustively over `PresentationFrame.Body`, so a new body kind
  must be handled in the same task that adds it. A frame that fails to decode calls `fail("bad frame")`
  and drops the link.
- `agtermTests/ControlServerRemotePresentationTests.swift:442-476` `bridgedPair` has no `zmxClient`; its
  origin is an unmounted `GhosttySurfaceView(backedByZmx: true)`, and `BridgeTransport` bypasses ssh for
  the presentation stream only.
- File limits: `Session.swift` is 999 of 1000 lines and `AppStore.swift` 985. Neither takes new lines.
  Extensions cannot add stored properties, so origin-side state needs its own owner. `agtermCore` is a
  library the `agterm-linux` fork consumes, so existing `public` symbols keep their shape.

## Development Approach

- **testing approach**: TDD. The reconciler is a pure function, so its cases are written first.
- complete each task fully before moving to the next; small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for the code it changes, success and error paths
- **CRITICAL: a task's targeted tests must pass before the next task starts.** Targeted means
  `swift test --filter` or `-only-testing:`; the full gates run once, in Task 14, after the docs
- every task leaves the package and the app target COMPILING
- **CRITICAL: update this plan file when scope changes during implementation**
- Swift work starts with the `swift-testing-expert`, `swift-concurrency` and `swiftui-expert` skills
- ask before splitting a long file; never raise a lint limit
- delegated agents get verbatim: "never execute `agterm`/`agtermctl` against the default socket, never
  launch or quit the app, static reading only"

## Testing Strategy

- **unit tests** (`agtermCore`, Swift Testing): reconciler cases, wire and client handling, origin source
  state and publication, viewer state, re-projection, read-back
- **hosted tests** (`agtermTests`, XCTest): stream admission, the readiness coordinator on a fake clock
  and probe, late replica launch through a recording launcher, the no-hold close, and one test running
  both roles in one process over the real `agtermctl zmx present` bridge
- app effects are asserted with spies, never only through reducer actions: the session stays in its
  store, no `remote.closed` and no stream stop on a primary replacement, no teardown of a local pane
- **XCUITest exemption**: `zmx.present` needs a second app as its peer; recorded in `control-api.md`
- two-Mac checks are manual and listed under Post-Completion

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep the plan in sync with the work done

## Solution Overview

The origin publishes its **membership**: the panes that exist, by stable identity, with primary, axis and
visibility. **Readiness** of each pane's daemon travels beside it and never delays membership, because a
confirmed removal must reach the viewer even when its replacement never starts.

Origin-side state (last published layout, membership revision, readiness observations) lives in
`PresentationHub` keyed by session, never in `RemotePresentationState`, which marks a row as a viewer.
A per-server **readiness coordinator** in the app target runs one coalesced inventory probe for the
sessions that have subscribers: at once on a membership change, and periodically while subscribed.
The invocation is built on the main actor and executed behind an explicit off-actor worker; its result
returns with the membership revision it was started under.

The viewer keeps the latest **desired layout** and runs a pure **reconciler**. It returns actions;
`AppStore` applies them in one row-preserving operation and the app target creates or tears down
surfaces through an injectable replica launcher.

Ownership per local pane is one of: replica of origin identity X, or local. A replica is removed only on a
confirmed origin removal while its mapping still owns that local pane. A local pane is never touched.

An origin pane that cannot attach is **deferred**, with the reason in read-back. Deferred panes attach
when a slot frees, which is a LOCAL lifecycle event and produces no origin frame, so the reconciler also
runs from pane close, promotion and swap on the viewer. A pending replica RESERVES its slot, so repeated
passes never queue the same attach twice, and a completing attach rechecks its token, identity and slot.

Stream loss keeps topology, mappings, dismissals and the desired layout, and clears the
current-snapshot eligibility: no new attach starts until a supported current snapshot arrives.

A STATUS that arrives for a deferred pane is retained as replaceable state and re-projected when its
mapping appears. A later origin value replaces or clears what was retained; stream loss and removal cancel
it; a local takeover wins. Notifications, asks and overlays are never replayed.

A HUD is not retained (Eugene, 2026-09-20). A HUD for an unmapped pane already shows session-wide
(`ControlServer+RemotePresentation.swift:143-148`). When the pane attaches later the panel stays
session-wide until the origin's next HUD update or snapshot places it normally. Accepted limitation: a
persistent HUD, one with no `--hide-after`, can stay session-wide indefinitely. The content is visible
either way.

## Technical Details

Wire, additive on protocol version 1:

- frame kind `layout` with a required `PresentationLayout` body: an origin that speaks the kind always
  sends a full layout, and there is no "clear" form
- `PresentationSnapshot.layout: PresentationLayout?`, a DEFAULTED initializer parameter like the ones
  beside it, absent from an older origin, meaning unsupported: the viewer changes nothing, reports layout
  as `unsupported`, and stays ineligible for new attaches
- `PresentationLayout { revision: Int, panes: [PresentationLayoutPane], primary: UUID, axis: String?,
  shown: Bool }`
- `PresentationLayoutPane { identity: UUID, daemon: String, ready: Bool }`
- the struct DECODES leniently and is validated by the client, so an invalid layout is dropped and logged
  while the link stays up. Rules, whole layout before any mutation: identities unique; `primary` in the
  set; one or two panes; each `daemon` decodes to its `identity` through
  `ZmxSupport.paneIdentity(fromDaemonName:)`; `axis` a known `SplitAxis` when two panes
- `"layout"` joins `PresentationHub.supportedKinds`
- the client applies a snapshot's layout BEFORE its status, HUD and context

Origin stream admission: a local live session is eligible when it has AT LEAST ONE existing surface and
every existing surface is zmx-backed; a split whose surface is not realized yet does not refuse it. A
session with no surface at all is refused, since "every existing surface" holds vacuously for it. An
attached viewer row and an ordinary non-live session stay refused.

Membership revision: ONE hub-wide counter that is never reused. The hub's per-session source state is
dropped with its last subscriber, so a recreated source takes a fresh number even when its pane set
equals the deleted one's; gaps from other sessions are harmless. A readiness result is accepted only when
its revision equals the source's current one. Ordering on the viewer comes from the frame envelope's
`rev`, never from `layout.revision`: a readiness update reuses the membership revision, and the first
supported snapshot of a NEW connection is accepted even when its `layout.revision` is lower than the
retained desired layout's, since the counter does not survive a hub or app restart. A queued replica
completion is checked against its connection scope (the client's launch count), never a bare revision.

Readiness probe: the invocation is built on the main actor with the endpoint AND the environment
preparation `ZmxClient.invoke` uses (`ZmxClient.swift:210-218`): `ZMX_DIR` set, `ZMX_SESSION` and
`ZMX_SESSION_PREFIX` removed, `list`, a bounded timeout, `mergesStderr` false. It is `Sendable` and runs
through the coordinator's injected probe; the production probe calls the nonisolated `ZmxClient.run` and
parses the listing. `nonisolated` alone does not leave the main actor, so the production adapter names an
explicit off-actor execution boundary. The client's private actor-owned runner is never pulled across.

Reconciler, pure and host-free:

- input: desired layout (or none), current panes `[(localIdentity, role, ownership)]`, dismissed origin
  identities, pending LOCAL panes, pending REPLICA reservations, `snapshotIsCurrent`, endpoint known
- output actions: `attach(origin:, slot:)`, `removeReplica(local:)`, `promote(local:)`, `swapReplicas`,
  `setAxis`, `setShown`, `defer(origin:, reason:)`, `installMapping(origin:, local:)`
- reasons: `slot-held-by-local-pane`, `daemon-not-ready`, `dismissed`, `stream-not-current`,
  `endpoint-unknown`

Viewer state, in `RemotePresentationState` (not `Session`):

- `binding` becomes `var`; `RemoteBinding` gains `endpoint: ControlZmxEndpoint?` through a NEW
  initializer, the existing one kept as it is; a nil endpoint defers every late attach with
  `endpoint-unknown` and never synthesizes the other Mac's executable or socket directory
- `desiredLayout`, `snapshotIsCurrent`, the accepted connection scope, `dismissed: Set<UUID>`,
  `deferred: [UUID: reason]`, `reservations: [slot: originIdentity]`
- retained `pendingStatus` per unmapped origin pane; no HUD is retained

Read-back on the viewer session node, inside `presentation`:

- `layout: "mirrored" | "unsupported"`, `deferred: [{pane, reason}]`, `dismissed: [pane]`
- `tree.changed` fires when any of these change

## What Goes Where

- **Implementation Steps** (`[ ]`): code, tests and docs in this repository
- **Post-Completion** (no checkboxes): two-Mac manual checks and the `agterm-linux` fork

## Implementation Steps

### Task 1: Layout model and the pure reconciler

**Files:**
- Create: `agtermCore/Sources/agtermCore/RemoteLayout.swift`
- Create: `agtermCore/Tests/agtermCoreTests/RemoteLayoutTests.swift`

- [ ] write failing cases first: origin adds a split on a free slot; origin removes the split; origin
      primary exit promotes the split
- [ ] write the failing swap cases: right after an origin swap BOTH replicas survive with their identities
      and the primary role follows the origin; swap A/B then close A removes viewer A and not B
- [ ] write failing cases for ownership and roles: a local right shell is never claimed; a local shell
      promoted to primary is never claimed; a PENDING local pane holds its slot; a local primary with a
      free split slot puts the origin pane in the split slot; both slots held defers
- [ ] write failing cases for deferral: B removed while C never becomes ready still removes B; C replaced
      by D while deferred attaches D only; a dismissed identity stays closed across axis, swap and a new
      snapshot while a new identity is eligible; no attach when the snapshot is not current or the
      endpoint is unknown; a reserved slot is never attached twice
- [ ] write the failing action-contract case for primary removal with an unrealized replacement: no
      action closes the row
- [ ] implement `RemoteLayout`, pane ownership and `RemoteLayoutReconciler.actions(...)` with the actions
      and reasons listed in Technical Details
- [ ] run `swift test --filter RemoteLayoutTests` - must pass before Task 2

### Task 2: Layout frame, snapshot field and client handling

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationFramesTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemotePresentationClientTests.swift`

- [ ] write failing round-trip cases for a one-pane and a two-pane `layout` frame and a snapshot carrying
      one; an old snapshot without the field decodes with none
- [ ] write failing validation cases, one per rule in Technical Details
- [ ] write failing client cases: a snapshot's layout reaches the effect BEFORE its status and HUD; an
      invalid layout FRAME and an invalid `snapshot.layout` are each dropped with no effect, the link
      stays up, and a following valid frame is applied
- [ ] add `PresentationLayout`, `PresentationLayoutPane`, the `layout` body kind, the DEFAULTED snapshot field and
      `PresentationLayout.validated()`
- [ ] add the defaulted `layout` closure to `RemotePresentationEffects` and the client branch, so the
      package compiles; add `"layout"` to `PresentationHub.supportedKinds`
- [ ] run the two suites - must pass before Task 3

### Task 3: Origin source state in the hub and membership publication

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Presentation.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationHubTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AppStorePresentationTests.swift`

- [ ] write failing hub tests: source state per session holds the last published layout, a membership
      revision from ONE hub-wide counter that advances only on a membership change, and readiness
      observations; it is dropped when the last subscriber of a session leaves
- [ ] write the failing recreation test: a session unsubscribes and resubscribes with the same pane set,
      gets a fresh revision, and an observation carrying the old revision is dropped
- [ ] write failing store tests: split create, close, hide, show, axis change, swap and primary promotion
      each publish one full layout; an unchanged layout publishes nothing; a late subscriber's snapshot
      carries the layout; a remote (attached) row publishes none
- [ ] add the source state to `PresentationHub`, `publishLayout`, and a `recordReadiness` that drops an
      observation for a stale revision or an identity no longer in the layout, and republishes the layout
      at the SAME membership revision when readiness changed
- [ ] add `presentationLayout(of:)`, include it in `presentationSnapshot(forSession:)`, and publish from
      one seam the pane operations share, with `ready` false until observed
- [ ] run the targeted suites - must pass before Task 4

### Task 4: Stream admission for an origin with a pending pane

**Files:**
- Modify: `agterm/Control/ControlServer+Presentation.swift`
- Modify: `agtermTests/ControlServerRemotePresentationTests.swift`

- [ ] write failing hosted tests: `zmx.present` is accepted for a live local session whose new split has
      no surface yet, and its snapshot reports the membership; it is still refused for an attached viewer
      row, for a session that is not live-backed, and for an ordinary session with NO surface at all
- [ ] write the failing reconnect test on the SNAPSHOT: a stream opened while C is unrealized carries a
      layout without B and with C `ready: false`. What the viewer does with it is asserted in Task 12
- [ ] replace the `allPanesBackedByZmx` gate in `openPresentation` with the eligibility rule in Technical
      Details, without changing `Session.swift`
- [ ] run the targeted tests - must pass before Task 5

### Task 5: Readiness coordinator on the origin

**Files:**
- Create: `agterm/Control/PresentationReadinessCoordinator.swift`
- Modify: `agterm/Control/ControlServer.swift` (910 lines; the stored coordinator and injected probe
  properties, which an extension cannot hold)
- Modify: `agterm/Control/ControlServer+Presentation.swift`
- Create: `agtermTests/PresentationReadinessCoordinatorTests.swift`

- [ ] write failing tests on a fake clock and an injected probe: a new split goes `ready: false` to
      `ready: true` with NO call to `zmx.tree` and no direct `recordReadiness`; one probe covers every
      subscribed session, never one per pane; a membership change triggers a probe at once
- [ ] write failing tests for failure handling: a failed or empty observation changes no membership and
      removes no pane; an already-ready pane whose daemon disappears reads `ready: false` again; the
      coordinator stops probing when no session is subscribed
- [ ] write the failing in-flight test: a session unsubscribes and resubscribes before its old probe
      completes, while another session keeps the coordinator alive, and the old result is rejected by its
      revision
- [ ] write the failing adapter test: the production probe's blocking runner is never invoked on the main
      thread, and its invocation carries the environment preparation listed in Technical Details
- [ ] implement the coordinator owned by `ControlServer` with the injected `Sendable` probe and the
      explicit off-actor boundary
- [ ] start it on the first subscriber and stop it on the last
- [ ] run `-only-testing:agtermTests/PresentationReadinessCoordinatorTests` - must pass before Task 6

### Task 6: Viewer state: updatable binding, endpoint, desired layout, dismissals

**Files:**
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationState.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePresentation.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemotePresentationStateTests.swift`
- Modify: `agtermTests/ControlServerZmxTests.swift`

- [ ] write failing tests: a mapping installed or removed in place leaves connection, mode and bridged
      flags untouched; the endpoint from attach is kept; the existing initializer still builds a binding
      with no endpoint
- [ ] make `binding` a `var`, add the new initializer with `endpoint`, and the single-mapping
      `install`/`remove`
- [ ] add `desiredLayout`, `snapshotIsCurrent`, the connection scope, `dismissed`, `deferred`,
      `reservations` and `pendingStatus`
- [ ] pass `tree.endpoint` into the binding in `attachRemoteSession`; initial attach stays as today and
      the first layout snapshot corrects visibility
- [ ] run the targeted tests - must pass before Task 7

### Task 7: Row-preserving reconcile operation and its local triggers

**Files:**
- Create: `agtermCore/Sources/agtermCore/AppStore+RemoteLayout.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePresentation.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AppStoreRemoteLayoutTests.swift`

- [ ] write failing tests: `applyRemoteLayout` stores the desired layout and applies the reconciler's
      actions in one operation; after primary removal with an unrealized replacement the session is still
      in its store; ratio and focus survive by pane identity, with a fallback only when that pane is gone
- [ ] write failing ordering tests: the first supported snapshot of a new connection is applied even when
      its `layout.revision` is LOWER than the retained desired layout's; a readiness update at the same
      membership revision is applied
- [ ] write failing tests for local triggers: closing, promoting or swapping a local pane re-runs the
      reconciler and attaches a deferred pane; a slot freed while the stream is down attaches nothing
      until a current snapshot arrives
- [ ] write failing tests for eligibility and dismissal: leaving `connected` and an old peer's missing
      layout both clear `snapshotIsCurrent` while keeping topology, mappings, dismissals and the desired
      layout; closing a replica whose origin pane still exists records the origin identity; a confirmed
      origin removal records nothing
- [ ] implement `applyRemoteLayout`, the reconcile operation, reservations and the three local triggers
- [ ] run `swift test --filter AppStoreRemoteLayoutTests` - must pass before Task 8

### Task 8: App target: late replica launcher

**Files:**
- Create: `agterm/Control/ControlServer+RemoteLayout.swift`
- Modify: `agterm/Control/ControlServer.swift` (the stored injectable launcher)
- Modify: `agterm/Control/ControlServer+RemotePresentation.swift`
- Create: `agtermTests/ControlServerRemoteLayoutTests.swift`

- [ ] write failing hosted tests with a recording replica launcher: a `layout` adding a ready pane asks
      the launcher for one surface built from the kept endpoint; repeated layout, readiness and local
      passes launch it ONCE; a completion whose connection scope, identity or slot owner changed is
      discarded; a nil endpoint launches nothing and reads `endpoint-unknown`
- [ ] add the injectable launcher and wire the `layout` effect, snapshot layout first
- [ ] implement attach against the store's reconcile actions and install the mapping on completion
- [ ] run the new hosted suite via `-only-testing:` - must pass before Task 9

### Task 9: App target: confirmed-removal close and primary replacement

**Files:**
- Modify: `agterm/Control/ControlServer+RemoteLayout.swift`
- Modify: `agterm/agtermApp.swift`
- Modify: `agtermTests/ControlServerRemoteLayoutTests.swift`

- [ ] write failing hosted tests for the close paths: a confirmed removal of the mapped replica closes it
      with no press-any-key hold; a terminal ssh exit keeps the hold and its disconnect line; losing the
      PRESENTATION stream alone leaves the terminal running with no hold; `commandWait` is unchanged for
      every other pane
- [ ] write the failing spy test for primary replacement: the session stays in its store, no
      `remote.closed`, no stream stop, no teardown of a local pane; callbacks from a removed surface are
      ignored
- [ ] implement removal against the store's reconcile actions, bypassing the hold only for the
      identity-matched replica the mapping still owns
- [ ] run the suite via `-only-testing:` - must pass before Task 10

### Task 10: Re-project a retained status when a mapping appears

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePresentation.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemotePresentationStateTests.swift`
- Modify: `agtermTests/ControlServerRemotePresentationTests.swift`

- [ ] write the failing test: a blocked status for a deferred pane resolves its owner when the pane
      attaches, with no new origin frame
- [ ] write failing invalidation tests: B deferred, blocked arrives, a newer clear arrives, B attaches,
      and nothing is shown; B deferred, the stream drops, B attaches after reconnect, and nothing old is
      replayed; a status set on THIS Mac after retention is never overridden; notifications, asks and
      overlays are never replayed
- [ ] write the failing HUD pins for the accepted limitation: a layout arrival neither recreates the
      session-wide fallback HUD nor restarts its timer; the origin's next HUD update places it on the
      pane; nil and disconnect cleanup and local-HUD precedence are unchanged
- [ ] retain, replace, cancel and re-project `pendingStatus` as specified in Solution Overview
- [ ] run the targeted tests - must pass before Task 11

### Task 11: Read-back, CLI tree row and `tree.changed`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePresentation.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTreeProjectionTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`

- [ ] write failing tests: `presentation` reports `layout`, `deferred` with each of the five reasons, and
      `dismissed`; `dismissed` and `slot-held-by-local-pane` stay distinguishable; `tree.changed` fires
      when any of them change and not otherwise; an older server's node decodes with the fields absent
- [ ] add the three optional fields to `ControlPresentationNode` as DEFAULTED initializer parameters,
      like the existing ones, and project them
- [ ] print them on the CLI tree row beside the existing presentation state
- [ ] run the targeted tests - must pass before Task 12

### Task 12: Two roles in one process, end to end

**Files:**
- Modify: `agtermTests/ControlServerRemotePresentationTests.swift`

- [ ] extend `bridgedPair` with an injected inventory probe on the origin and the recording replica
      launcher on the viewer, keeping the real presentation bridge
- [ ] origin opens a split after attach: the viewer launches the replica once the probe reports it ready
- [ ] origin closes the split: the viewer's replica closes with no hold
- [ ] a viewer reconnecting while C is unrealized drops its replica of B
- [ ] viewer holds a local right shell while the origin opens a split: deferred with its reason, then
      launched after the local shell exits
- [ ] viewer dismisses a replica, the stream reconnects: it stays closed and reads back as dismissed
- [ ] run the suite via `-only-testing:` - must pass before Task 13

### Task 13: Update documentation

**Files:**
- Modify: `.claude/rules/control-api.md`
- Modify: `ARCHITECTURE.md`
- Modify: `site/docs.html`
- Modify: `site/commands.html`
- Modify: `site/llms.txt`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`
- Modify: `plugins/agterm/skills/agterm/reference.md`
- Modify: `plugins/agterm/skills/agterm/examples.md`
- Modify: `agtermCore/Sources/agtermctlKit/ZmxCommands.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationState.swift`

- [ ] `control-api.md` Remote sessions owns the contract: membership versus readiness, stream admission,
      ownership by identity and the free-slot rule, deferral reasons, dismissal, topology kept on stream
      loss, the no-hold close, local ratio and focus with the hidden-split consequence, the HUD placement
      limitation; replace "a local split" wording where it now differs
- [ ] sweep for the construct, not the sites: grep every file in the block above for a sentence that
      lists what the stream mirrors or restores, phrases wrapped across a line break included, and tick
      this box only when each file is either edited or confirmed to carry no such sentence
- [ ] `site/commands.html` and `reference.md` gain the new read-back fields; `SKILL.md`'s description
      block stays under 1024 characters
- [ ] extend the existing XCUITest exemption at `control-api.md:1252` to name `layout`
- [ ] run the SwiftPM test that pins the description length

### Task 14: [Final] Verify acceptance criteria

**Files:**
- Modify: `docs/plans/20260920-remote-split-mirroring.md` (moved to `docs/plans/completed/`)

- [ ] every decision in Overview is implemented and has a test naming it
- [ ] every counterexample in Tasks 1, 7, 9 and 10 has a passing case
- [ ] an origin predating `layout` leaves the viewer's panes untouched and reads `unsupported`
- [ ] `Session.swift` and `AppStore.swift` gained no lines
- [ ] run `make build`
- [ ] run `cd agtermCore && swift test`
- [ ] run `make test-app`
- [ ] run `make lint` - zero findings
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification, two Macs:**

- open, close, hide, show, re-axis, swap and promote on the origin while attached; the viewer follows
- a local split on the viewer while the origin opens its own: deferred, then attached when freed
- dismiss a replica, drop the network, reconnect: it stays closed
- kill the origin's ssh path mid-session: the held disconnect line still appears
- drop only the presentation stream: terminals keep running, no hold

**External:**

- the `agterm-linux` fork consumes `agtermCore`. `RemoteBinding`'s existing initializer is kept, and
  `PresentationSnapshot.layout` and the three new `ControlPresentationNode` fields are defaulted
  parameters, so no change is expected there; a fork build confirms it

Smells pre-check: skipped — non-Go project
