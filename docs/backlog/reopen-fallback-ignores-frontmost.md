---
worth: later
where: agtermCore/Sources/agtermCore/WindowLibrary.swift:537
added: 2026-08-05
---
# reopen fallback ignores which window was last frontmost

`reopen`'s fallback ignores which window was last frontmost once `frontmost` is nil, so a multi-window
user's last-window capture replays only when the exited window happened to be `windows.first`.

Deferred because #369 stays partly unfixed for multi-window use regardless of PR #370, and the fix
touches restore ordering.
