---
worth: no
where: cookbook/two-agent-chat/peer-chat.py:22
added: 2026-08-31
---
# peer-chat PROBE_TIMEOUT has no test and cannot usefully get one

`PROBE_TIMEOUT` went from 0.6 to 2.0 in #505 to stop a long body being typed and then refused before it
rendered, which strands the message unsent in the target composer. Setting it back to 0.5 leaves all 44
tests green: `wait_for_composed` and `wait_for_accepted` are never entered by the suite, and
`SendPreflightTests` raises `PromptBlocked` before any typing.

Filed as `no` so this is not re-opened each review. A test that drives `wait_for_composed` with a
`pane_text` mock returning non-matching content first and matching content later would pin the poll loop's
existence, not the window. With `time.sleep` patched the deadline is still wall-clock, so the mocked
second read lands well inside 0.5s and the test stays green after a revert of the constant. It would catch
a different regression, collapsing the loop to a single read, which is real but is not the defect the
constant guards.

Asserting the constant's value is a tautology. A wall-clock render budget against another program's TUI is
not meaningfully testable, and the loop around it is eight lines over `prompt_text` and
`composer_has_message`, both already covered.

Surfaced reviewing PR #505.
