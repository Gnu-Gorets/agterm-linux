---
worth: yes
where: README.md:465
added: 2026-08-07
---
# the GUI PATH caveat never names agtermctl itself

The caveat merged in #392 warns that a custom command resolves binaries against the launchd `PATH`, but
says only "a bare Homebrew or other non-default binary". It sits directly beside three examples whose
first word is a bare `agtermctl`, and `CLIInstall.installPath` is `/usr/local/bin/agtermctl`
(`agterm/CLIInstaller.swift:5`) — a directory that reaches `PATH` only through `path_helper`. Deriving
that from the caveat needs both facts, and neither appears on any of the three surfaces.

A reader who follows the advice on the shipped `Lazygit` line wraps only `lazygit` in an absolute path or
`zsh -lc`, and still gets exit 127.

One clause per surface, prose only, no test touched:

- `README.md:465`
- `agtermCore/Sources/agtermCore/ConfigPaths.swift:62-66`
- `site/docs.html:1942-1949`

Something like "— including `agtermctl` itself, which **Help ▸ Install Command Line Tool…** puts in
`/usr/local/bin`".

Surfaced reviewing #392; not raised with the contributor, whose scope was adding the caveat at all.
