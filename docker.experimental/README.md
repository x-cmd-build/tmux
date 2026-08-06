# docker.experimental/ — Docker-based Windows build (EXPERIMENTAL)

This is an **experimental** local-build path for the Windows tmux
binary. It is **not** the source of truth — the GitHub Actions
workflow (`.github/workflows/build-and-test.yml`) using
`msys2/setup-msys2@v2` on `windows-latest` IS.

## Why this exists

While GitHub Actions is in major_outage (incident
2026-08-06T18:46:37Z), we needed a way to iterate on the Windows
build locally. This docker image is a Debian Bullseye + mingw-w64
toolchain + libevent/ncurses-from-source setup that mirrors the
GitHub Actions environment.

## Why it's experimental

The image source-builds libevent 2.1.12 and ncurses 6.4 from
tarballs. Cross-compiling these to x86_64-w64-mingw32 from a
non-MSYS2 host has multiple subtle issues:

- ncurses 6.4 cross-compile: `DWORD` is undeclared in `lib_napms.c`
  (need `--enable-term-driver` + `-D_WIN32` patch + an `install.libs`
  target instead of `install` because the host's strip can't process
  mingw PE binaries).
- The host's strip aborts on mingw PE binaries → use
  `make install.libs install.includes` to skip the progs install.
- tmux's `c->flags` access fails in cross-compile with subtle struct
  visibility issues from the sys/queue.h shim interaction.
- shim headers must include tmux's vendored compat/queue.h and
  compat/tree.h (otherwise TAILQ_HEAD/RB_HEAD macros are undefined).
- shim headers must define `uid_t`/`gid_t` (mingw-w64 omits them).

We attempted to fix these in series. The remaining blockers
(subtle struct layout / macro expansion issues in tmux's own source
when cross-compiled) were not reached before the user chose to
defer this path.

## What's needed to make it work

Two paths to completion:

**Path A (deferred):** drop the docker attempt and rely on the
existing MSYS2 GitHub Actions workflow (`.github/workflows/build-and-test.yml`).
This is the chosen path. The docker/ directory is kept as
historical context but not maintained.

**Path B (releng):** use `msys2/base` docker image (x86_64 emulated
on arm64 hosts) + run pacman inside it. This mirrors the GitHub
Actions setup exactly and avoids the source-build cross-compile
problems. The downstream `scripts/build-windows-in-docker.sh` would
need to be rewritten to invoke the build via a single MSYS2 bash
shell call (run via `docker exec` or by being the image's CMD).

## Files

- `Dockerfile.windows-build` — Debian Bullseye + toolchain +
  libevent/ncurses source build. (Broken; see above.)
- `../../scripts/build-windows-docker.sh.experimental` — local
  wrapper (builds image + runs build).
- `../../scripts/build-windows-in-docker.sh.experimental` — the
  in-container build script (currently broken for tmux compile).
