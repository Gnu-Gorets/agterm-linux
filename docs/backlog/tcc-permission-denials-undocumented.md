---
worth: later
where: docs/troubleshooting.md:128
added: 2026-08-08
---
# no user-facing note on the TCC prompts agterm can now raise

After PR #398 agterm carries all seven hardened-runtime resource-access entitlements, so a tool run inside a
session can raise a permission prompt with agterm's name on it for Automation, Camera, Contacts, Calendars,
Location and Photos, plus Bluetooth, Reminders, local network and speech recognition via usage string alone.

Nothing documents that. A grep across `README.md`, `ARCHITECTURE.md`, `docs/troubleshooting.md`, `site/` and
`plugins/agterm/skills/agterm/` for microphone, privacy, entitlement, usage string or "System Settings" found
nothing. A user who dismisses the Automation prompt the first time a tool runs `osascript` gets "Not
authorized to send Apple events" on every later run, macOS never re-prompts, and there is no note pointing at
System Settings ▸ Privacy & Security ▸ Automation ▸ agterm to reset it.

"Other common issues" in `docs/troubleshooting.md` already carries the same shape for notifications ("macOS
must also have granted permission (System Settings ▸ Notifications ▸ agterm)"), so one bullet alongside it
would match. `plugins/agterm/skills/agterm/troubleshooting.md` carries the same section and would need the
same line.

`worth: later` rather than `yes` because `NSMicrophoneUsageDescription` has shipped undocumented since it was
added and nobody has asked. Surfaced reviewing PR #398.
