---
worth: later
where: cookbook/annotate-claude-replies/README.md:19
added: 2026-08-07
---
# annotate-claude-replies README says every note quotes and attributes

"What it does" tells the reader "Each one quotes the lines it points at and names the reply it landed on",
and the worked example below it shows a quoted line with a section heading. Since PR #387 that no longer
covers every note: a file-level note renders as `## Note N — on the whole reply set`, with neither a quote
nor a section attribution.

Deferred rather than asked of the contributor: the README is p4elkin's (#364), PR #387 does not touch it,
and there is no behavior defect behind the wording — before that PR a file-level note was dropped entirely,
so the case the README omits now works strictly better than it documents.

Fix: one clause under the example — a note on the file as a whole comes back without a quote, as
`## Note N — on the whole reply set`.
