# Live restore runtime verification

Date: 2026-08-30

The checks used the Debug app with `AGTERM_STATE_DIR=/tmp/agtr3` and the derived private zmx namespace
`/private/tmp/agterm-zmx-a53bf053842b803b`. Every app PID was matched to that state directory before
termination. The clean quit used `NSRunningApplication.terminate()` for PID 82590; a POSIX `SIGTERM` does
not run the Cocoa quit callbacks and was excluded from the results below.

| Case | Result |
| --- | --- |
| Captured replay | The snapshot stored the foreground argv. After the old daemon was killed, the marker grew from 1 to 2 and the daemon leader changed from 79657 to 85598. |
| Surviving daemon | The marker stayed at 1 and the daemon leader stayed at 80728. The attach payload did not run. |
| Failed replay | Removing `vanish-worker` before relaunch produced a shell with no foreground process. A command typed into that shell wrote `failed-ok`. |
| Denylisted replay | `deny-worker` remained at one marker byte. The new daemon had no foreground process and opened a shell. |
| Hidden split | The right pane stayed absent until the split was shown. Showing it grew the marker from 1 to 2 and created leader 86340, replacing leader 81113. |
| Closed window | Its snapshot had no `foregroundCommand`. Reopening the window kept the marker at 1, created leader 89948, and accepted a command that wrote `closed-ok`. |

After a replay command ended, the final login shell contained `_ghostty_precmd` and `_ghostty_preexec` in
its zsh hook arrays. A replay-created primary shell reported `/tmp/agtr3/osc7-dir` through OSC 7 to both
the control tree and its private zmx listing.

Teardown left no app process, zmx session, private namespace, or state directory.
