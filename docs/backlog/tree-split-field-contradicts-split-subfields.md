---
worth: later
where: agtermCore/Sources/agtermCore/AppStore.swift:262
added: 2026-08-08
---
# tree reports split:false for a hidden split while splitRatio/splitFocused stay populated

`ControlSessionNode` builds `split: session.isSplit` but gates `splitRatio` and `splitFocused` on
`hasSplit`, so a split that was hidden with ⌘D reads as `split: false` with both split-only fields still
present. A caller filtering on `split` concludes there is no second pane while the same node describes its
ratio and which of the two panes holds focus, and the live shell behind it stays invisible to any script
that trusts the boolean.

Either spelling is defensible on its own. `split` meaning "shown side by side" matches
`session.split on|off`; `hasSplit` is what the sidebar icon, the dashboard's second cell and the Focus
Left/Right Pane items follow. What is wrong is reporting one of them as `split` while the neighbouring
fields answer the other.

Two shapes to pick from, neither done here:

- add a `hasSplit` (or `splitHidden`) field and leave `split` alone - additive, safe after the 1.x freeze;
- redefine `split` as `hasSplit` and expose visibility separately - cleaner to read, breaking.

Deferred rather than fixed inline because it is a semantic choice on a public read-back surface, not a
typo. #321 pins the control API to additive-only inside 1.x and carries an open item to audit the API for
anything worth regretting at the freeze, so this wants deciding before then rather than after.

Surfaced while investigating #402 (a Close Split action), which is unrelated: the same `hasSplit`
persistence is the premise of that request, but nothing there touches this field.
