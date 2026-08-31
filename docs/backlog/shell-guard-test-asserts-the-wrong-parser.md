---
worth: no
where: cookbook/two-agent-chat/test_peer_chat.py:138
added: 2026-08-31
---
# peer-chat shell-guard test asserts the post-write parser, not the live one

`test_live_shell_blocks_an_older_composer` carries the screen the #505 review asked for, an older `›`
above a live `!` shell prompt, but asserts `codex_prompt_text` rather than `live_prompt_text`. Dropping
the `any(CODEX_SHELL_PROMPT_RE.match(line) for line in block)` clause from `codex_live_prompt_text` leaves
all 44 tests green.

Filed as `no` so the next review stops here rather than re-deriving it. The obvious fix does not work:
adding `assertIsNone(live_prompt_text(codex, screen))` to that test passes with or without the clause,
because `trailing_input_block` puts the `!` row last and `CODEX_PROMPT_RE` is anchored on `›`/`»`, so the
final row cannot match either way. The named failure behind the guard, a message typed into shell mode,
is prevented by that anchor rather than by the clause.

The only screen the clause actually decides is a `!` transcript row directly above a live column-zero
`›`, where the `›` row is the real composer, so the clause is fail-closed conservatism rather than a
shell-execution guard. Pinning it needs that screen specifically, and it protects a defensive branch with
no user-visible defect behind it. The test's name also reads correctly for what it does assert: a live
shell prompt invalidates the older composer.

Surfaced reviewing PR #505.
