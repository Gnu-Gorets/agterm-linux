---
worth: yes
where: .claude/rules/settings.md:105
added: 2026-08-05
---
# settings capture-site docs name only applicationWillTerminate

`.claude/rules/settings.md:105` names `applicationWillTerminate` as the capture site. PR #370 adds a
second one in `WindowAccessor`'s `willClose`, and `windows.md`'s scene-lifecycle bullet does not mention
it either.

Fix is one sentence naming both sites and the `isTerminating` skip. This file owns that contract, so it
is the right place for it.
