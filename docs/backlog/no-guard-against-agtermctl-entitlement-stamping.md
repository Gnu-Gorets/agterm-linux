---
worth: yes
where: project.yml:155
added: 2026-08-08
---
# nothing catches the build phase stamping entitlements onto agtermctl

Issue #396 / PR #398: the re-seal used to be one `codesign --force --deep --options runtime
--entitlements ... --sign -` pass, and `--deep` reaches `Contents/MacOS/agtermctl`, so the bundled CLI the
user symlinks onto their PATH carried all six TCC entitlements. #398 splits it into a `--deep` pass without
entitlements plus a non-deep pass with them.

Nothing asserts the outcome. Re-adding `--entitlements` to the `--deep` line, or collapsing the two passes
back into one, reproduces the bug with a fully green build - the only way to notice is running
`codesign -d --entitlements` by hand. That is exactly how it went unnoticed the first time.

The `build` job in `.github/workflows/ci.yml` already has a built Release `.app` before it runs
`scripts/test-app.sh`, so the guard is one line there or at the end of `scripts/build.sh`:

```sh
codesign -d --entitlements :- --xml "$APP/Contents/MacOS/agtermctl" 2>/dev/null |
  grep -q 'com.apple.security' && { echo "agtermctl carries entitlements" >&2; exit 1; }
```

`agtermCore`'s `swift test` is the wrong home, it is host-free and never sees a built bundle.
`agtermUITests` is wrong too: 7-minute suite, and CI does not run it.

Surfaced reviewing PR #398. Left off the contributor's branch because a CI change is not what he came to do.
