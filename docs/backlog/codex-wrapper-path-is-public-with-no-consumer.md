---
worth: later
where: agtermCore/Sources/agtermCore/AgentHooksInstall.swift:293
added: 2026-08-19
---
# codexWrapperPath is public with nothing outside the module calling it

`codexWrapperPath(scriptDir:)` is `public` but its only caller is `codexHooksBlock` at `:303`, in the same
file. `internal` would serve it. Contrast `codexWrapperName` two lines up, whose `public` is earned by
`agterm/AgentHooksInstaller.swift:136`.

Against the standing rule that visibility is private by default and exported only when used outside the
package. Nothing is broken; the cost is that a reader has to grep to learn which of the two neighbouring
symbols is an app-target contract and which is not.

Worth doing whenever something else touches this file, and worth checking the rest of the enum's public
surface in the same pass rather than tightening one symbol alone.

Surfaced reviewing PR #461.
