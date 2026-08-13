---
worth: later
where: agterm/Ghostty/GhosttyCallbacks.swift:51
added: 2026-08-10
---
# GHOSTTY_ACTION_RENDER cannot fire on the embedded apprt, so renderNow is dead code

Instrumenting the `GHOSTTY_ACTION_RENDER` arm and `renderNow` and running a Debug instance through a
full session - launch, a `session type` that echoed output, a `--command` session ticking once a second,
window resizes, sleep and wake - produced **zero** RENDER callbacks and zero `renderNow` calls, while the
panes painted normally throughout. libghostty's renderer drives the layer itself in pinned `4dcb09ada`,
with the embedding API's RENDER action unused.

Confirmed from the pinned source, and it is structural rather than rare. `src/apprt/embedded.zig` does not
declare `must_draw_from_app_thread`, so the constant resolves false through the `@hasDecl` fallback at
`src/renderer/Thread.zig:26`. `Thread.drawFrame` then takes the `else` branch and calls
`self.renderer.drawFrame(false)` on the render thread instead of pushing `redraw_surface` to the app
mailbox, which is the only producer of that action. Nothing on the embedded apprt can emit it. The
`.render` at `src/Surface.zig:5783` is the crash-location enum, not this action.

So `renderNow` is dead in production, and the "demand-driven" account in `CLAUDE.md` and [[libghostty]] -
"Wakeup coalesces into one main-queue `ghostty_app_tick`; RENDER calls `renderNow`" - describes a path that
does not run. The cost is to whoever debugs a paint problem next: the documented mechanism is the first
place to look and it is not where the pixels come from. It also means the wakeup coalescing in
`GhosttyCallbacks.wakeup` is doing something narrower than the comment implies. The choice is deleting
`renderNow` and its arm or documenting them as a path the pinned build does not exercise, not silently
leaving both.

Two consequences beyond the dead code. The render thread's own `drawFrame` opens with
`if (!self.flags.visible) return` (`src/renderer/Thread.zig:495`), so the paint path does honour occlusion
even though `renderNow` never runs. agterm calls `ghostty_surface_set_occlusion` nowhere, so every hidden
deck pane keeps drawing whenever its own terminal changes. Measured on a live 63-surface instance that is
~5% of one core in total, which is why this stays `later`: too small to be worth a change on its own. It is
worth more as the "stop drawing" half of shrinking hidden panes' layer bounds, the only route to the ~4 GB
of IOSurface those panes hold that does not need a libghostty patch (discussion #196).

Surfaced while instrumenting the display-sleep surface-creation bug (#416, fixed in #417); the probes
were added for that and this fell out of the same log. Source confirmation and the occlusion angle came
from reviewing the #196 memory patch.
