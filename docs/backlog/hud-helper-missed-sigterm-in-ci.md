---
worth: maybe
where: agtermCore/Tests/agtermCoreTests/HudHelperTests.swift:Run.stop
added: 2026-10-18
---
# a hud.sh test helper kept painting after SIGTERM in CI

CI run 39101378893 (PR #771) hung `swift test` until the 600s watchdog. The `test-hang` artifact shows
`HudHelperTests.paintsWhicheverFramesTheHeaderCarries(style:)` in `Run.stop()`'s then-unbounded
`waitUntilExit`, with its `/bin/sh agterm/Resources/hud/hud.sh` child five minutes old and still ticking
(a fresh `sleep 0.08`), although the script traps TERM to exit. Not reproduced in 25 local runs.
`Run.stop()` now bounds the wait and records `hud.sh ignored SIGTERM` before falling back to removing the
body file, so a recurrence fails that test by name instead of hanging the suite.

The cause is open. One state that produces it: a shell that starts with TERM already ignored cannot trap
it, which `stopFailsAndStillEndsAHelperThatIgnoresTerm` reproduces on purpose. [Unverified] whether the CI
child inherited an ignored or blocked TERM. Production teardown does not depend on TERM: the app removes
the body file (`Session.discardHudBody`), and the helper also checks owner liveness.
