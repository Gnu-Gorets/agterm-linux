---
worth: yes
where: agterm/Views/SplitRatioAccessor.swift:restoreDivider
added: 2026-09-14
---
# fresh split seeds the mounted frames instead of the default ratio on macOS 27

`SplitRatioAccessorTests.testAFreshSplitSeedsTheDefaultRatioRatherThanTheMountedFrames` fails on macOS 27
(26A428, Xcode 26.6): the primary pane ends at width 320 where the default ratio puts it at 200. It passed
on the same Mac on macOS 26.6.2 (local xcresult of 2026-09-13) and passes on CI's `macos-26` image, and
the same class fails identically on master, so it is the OS, not a change.

The run logs `It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out`, so
macOS 27 appears to enter `SplitProbeView.layout()` inside the split's own layout pass: `restoreDivider`
sets the divider and marks `restored`, and the enclosing pass then re-applies the mounted position over
it. A real fresh split would show the uneven mount instead of 50/50 on that OS. Surfaced during #609,
which touches no AppKit code. Needs its own repro against an isolated Debug instance; do not narrow the
test.
