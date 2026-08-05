# backlog

- [ ] `.claude/rules/settings.md:105` - names only `applicationWillTerminate` as the capture site; PR #370
  adds a second one in `WindowAccessor`'s `willClose`, and `windows.md`'s scene-lifecycle bullet does not
  mention it either.
  Worth fixing: yes - one sentence naming both sites and the `isTerminating` skip, and this file owns that
  contract.
- [ ] `agtermCore/Sources/agtermCore/WindowLibrary.swift:537` - `reopen`'s fallback ignores which window
  was last frontmost once `frontmost` is nil, so a multi-window user's last-window capture replays only
  when the exited window happened to be `windows.first`.
  Worth fixing: later - #369 stays partly unfixed for multi-window use regardless of PR #370, and the fix
  touches restore ordering.
