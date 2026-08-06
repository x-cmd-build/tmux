# Security

## Reporting a vulnerability

Email <security@ljh.sh> (PGP key on request). Do NOT file a public
GitHub issue for suspected security issues.

## What we ship

This repo distributes **tmux 3.7** (vendored from
<https://github.com/tmux/tmux/releases/tag/3.7>) and a thin wrapper
build/packaging layer (BSD-3-Clause). The wrapper does not modify
upstream tmux source. See `NOTICE.md` for the license split.

## Source-level audits

A source-level security audit of vendored tmux 3.7 is published in
`AUDIT-2026-07-XX.md` (see the file in the source repo). It covers:

- All `cmd-*.c` and `alerts.c`/`arguments.c` input parsers (tmux's
  main attack surface — config files, command-line, paste buffer).
- The `control.c` / `control-notify.c` control-mode protocol parsers
  (used by `tmux -C`).
- The `tty.c` terminal-emulator code (key sequence parser, escape
  decoder — historically the source of multiple CVEs in screen/tmux).
- The `window-copy.c` copy-mode and search code (regex / UTF-8 paths).
- The `format.c` / `subtree.c` format-string parser (substitution API).

## Build hardening

All release binaries are built with:

- `-O2 -D_FORTIFY_SOURCE=2` (Linux/macOS)
- `-fstack-protector-strong` (default at `-O2` on modern toolchains)
- Statically linked libevent + ncurses on Linux/macOS (no runtime
  attacker-controlled library search)
- Windows: `/GUARD:CF` + `/DYNAMICBASE` + `/NXCOMPAT` (PE hardening
  flags)

## Self-containedness

| target                 | linkage                                       |
|------------------------|-----------------------------------------------|
| `x86_64-linux-musl`    | fully static — `ldd` reports *not a dynamic executable* |
| `aarch64-linux-musl`   | fully static — same                           |
| `aarch64-macos`        | static (`-Wl,-force_load`) — only `/usr/lib/libSystem.B.dylib` |
| `x86_64-macos`         | static (`-Wl,-force_load`) — same             |

A self-contained binary that depends only on the C library (Linux) or
the platform SDK (macOS) has a smaller attack surface than a
dynamically-linked build that can be subverted via `LD_PRELOAD` /
`DYLD_INSERT_LIBRARIES` / DLL hijacking.

## Known upstream CVEs

tmux 3.7 is the latest stable upstream release as of 2026-08-06. Track
the tmux CHANGES file for any post-3.7 fixes; we ship a vendored
refresh whenever a `3.7.x` or `3.8` patch is upstream.
