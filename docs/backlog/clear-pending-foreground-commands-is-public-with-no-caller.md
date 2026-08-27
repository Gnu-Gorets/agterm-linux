---
worth: maybe
where: agtermCore/Sources/agtermCore/Session.swift:638
added: 2026-08-27
---
# `clearPendingForegroundCommands()` is public with no production caller needing it

`ControlServer.clearRestoreCommands()` and `WindowAccessor`'s non-last-window `willClose` arm both called
this from the app target, which is what earned the `public`. PR #490 moved both onto
`clearCapturedForegroundCommands()`, so the only callers left are that same-module wrapper and
`SessionTests`, which reaches it through `@testable import agtermCore` and so does not need it exported.
The convention here is private by default, exported only where something outside the module calls it.

Held rather than done because the narrowing may be wrong to want. `.claude/rules/settings.md:170` says
anything that must cancel an armed replay clears the pending slots and never the persisted fields, which
makes a future app-target caller of the pending-only clear legitimate rather than a mistake. Narrowing now
would then be reverted by the next such caller.

Decide the direction before touching it: either the convention is held strictly and this becomes `func`,
or the pending-only clear stays exported as a deliberate app-target entry point and its doc line says so.
