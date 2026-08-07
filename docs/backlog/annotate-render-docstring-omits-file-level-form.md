---
worth: later
where: cookbook/annotate-claude-replies/annotate-render.py:4
added: 2026-08-07
---
# annotate-render docstring names only the line-note header form

The module docstring still says revdiff reports `## <file>:<line>[-<end>] (<type>)` and that "each note
here carries the quoted source line with it". PR #387 added a second header form — `## <file> (file-level)`,
with no line part — and a render path that emits no quoted line, so both statements are now incomplete.
The docstring is the file's only prose description of what `parse()` accepts.

Deferred rather than asked of the contributor: the change already carries the missing fact inline in the
comment at `:20-22` and guards it at `:77`, so anyone editing `parse()`/`render()` meets it before touching
the `source[start - 1 : end]` arithmetic. That leaves stale narrative with no defect behind it, in a recipe
published by a different contributor (p4elkin, #364).

Fix: one clause in the first paragraph — a file-level note arrives as `## <file> (file-level)` with no line
part and renders without a quote.
