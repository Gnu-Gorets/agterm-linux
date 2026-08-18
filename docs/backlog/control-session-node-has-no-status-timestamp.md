---
worth: yes
where: agtermCore/Sources/agtermCore/ControlProtocol.swift:546
added: 2026-08-18
---
# tree read-back exposes no status timestamp

`ControlSessionNode` carries `status`, `statusPane`, `statusBlink`, `statusColor` and `statusShape` but
nothing saying when the status was set, so anything outside the app that wants to reason about a stale
`active` glyph has to keep its own state between polls.

`Session.statusChangedAt` already exists and is stamped on every non-idle set in `AppStore+Status.swift`,
so this is one optional field on the node plus its docs surfaces, not new bookkeeping. It does not survive
restore, which is fine for the purpose and worth saying in the command reference.

Raised in discussion #456: the reporter runs an external sweeper that re-lights or clears rows whose agent
died, and it exists partly because the tree cannot answer "how old is this glyph". Offered to him there as
the alternative to an app-side expiry setting, so an issue may arrive for it.
