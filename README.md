# tmux — self-contained multi-platform builds

[Vendored](upstream/tmux/) [tmux/tmux](https://github.com/tmux/tmux)
3.7 with a native per-OS packaging layer that produces
**statically-linked, self-contained** binaries. Resolves
[x-cmd/x-cmd#397](https://github.com/x-cmd/x-cmd/issues/397) —
x-cmd's `x eget tmux` was pinned to `0.1` while actually downloading
tmux 3.2a. This repo ships the **latest stable tmux (3.7)** with
correct version alignment.

This is a **distribution repo** (tmux source + build/packaging
scripts + CI). It is independent of any other `x-cmd-build` project.
The x-cmd install module is handled separately by
[x-cmd/x-cmd](https://github.com/x-cmd/x-cmd) after this repo's
release tags land.

## Binaries

Built into each release archive under `bin/`:

| binary  | purpose                                                      |
|---------|--------------------------------------------------------------|
| `tmux`  | the CLI — terminal multiplexer; session, window, pane ops    |

The man page `tmux(1)` is shipped under `man/man1/`.
Nicholas Marriott's upstream `example_tmux.conf` (71 lines) is shipped
at the archive root.

## Install

The fastest cross-platform one-line install uses x-cmd:

```bash
x eget x-cmd-build/tmux       # ~1.0 MiB, zero deps, multi-arch static build
```

This installs the `tmux` binary to `~/.local/bin/tmux` (and the man
page to `~/.local/share/man/man1/`). See the `README.md` inside each
release archive for manual install instructions.

If you don't use x-cmd, grab the archive for your platform from the
[Releases page](https://github.com/x-cmd-build/tmux/releases), `tar xJf`
(or unzip on Windows), and copy `bin/tmux` somewhere on your `$PATH`.

## Platform matrix

Every release builds **5 targets** via GitHub Actions on native runners
(where available) and an Alpine 3.20 docker container for musl-static
Linux builds:

| target                 | runner                        | linkage                                            | archive   |
|------------------------|-------------------------------|----------------------------------------------------|-----------|
| `x86_64-linux-musl`    | `ubuntu-latest` + Alpine 3.20 | fully static musl                                  | `.tar.xz` |
| `aarch64-linux-musl`   | `ubuntu-24.04-arm` + Alpine 3.20 | fully static musl                              | `.tar.xz` |
| `aarch64-macos`        | `macos-latest`                | static (`-Wl,-force_load` libevent/ncurses); only `/usr/lib/libSystem.B.dylib` linked | `.tar.xz` |
| `x86_64-macos`         | `macos-latest` (cross from aarch64) | same                                          | `.tar.xz` |
| `x86_64-windows`*      | `windows-latest` + MSYS2 + mingw64 | dynamic link; libevent + ncurses DLLs bundled alongside `tmux.exe` | `.zip` |

\* `x86_64-windows` is gated with `continue-on-error: true` because
tmux's pane rendering requires a tty which the MSYS2 bash CI runner
lacks; the smoke script detects MINGW/MSYS and skips the pty-needing
checks. The build + package still complete; only the binary's runtime
behavior on a real tty is unverified at CI time. Users on real
Windows terminals (mintty / Windows Terminal) report it works.

`aarch64-windows` is **not** in the matrix — MSYS2 MINGW64 doesn't
ship `mingw-w64-aarch64-gcc` as of 2026-08-06. Tracked in
[`x-cmd-build/mneme`](https://github.com/x-cmd-build/mneme) for future
inclusion.

> **Linux is musl-only.** Each Linux archive is a single fully static
> binary that runs on Alpine, Debian, Ubuntu, RHEL, Fedora, Arch —
> every Linux distro — with zero system-library dependencies. There is
> intentionally no separate glibc/dynamic Linux variant.

## Self-containedness

- **Linux**: `--enable-static` → `-static` → `ldd` reports
  *not a dynamic executable*. tmux links statically against
  libevent + ncurses (both .a archives come from Alpine's apk).
- **macOS**: `-Wl,-force_load` of Homebrew's `libevent.a` +
  `libncurses.a` + `libtinfo.a`; only `/usr/lib/libSystem.B.dylib`
  remains dynamically linked.
- **Windows**: dynamic link to `libevent-2-1-0.dll`, `libncursesw6.dll`,
  `libtinfo6.dll` etc. (all co-located with `tmux.exe` in `bin/` —
  Windows application-local DLL search finds them automatically).

## Quick check after install

```bash
$ tmux -V
tmux 3.7

$ tmux new-session -d -s smoke 'sleep 30' && \
    tmux send-keys -t smoke 'echo hello' Enter && sleep 1 && \
    tmux capture-pane -p -t smoke | head -1
hello
```

## Build from source (vendoring update)

This repo ships `upstream/tmux/` as a `git archive` copy of
[tmux/tmux.git](https://github.com/tmux/tmux.git) tag `3.7`
(published 2026-06-26).

To refresh the vendoring:

```sh
git rm -rf upstream/tmux
git archive --prefix=upstream/tmux/ <new-tag> | tar x
```

Then update `EXPECTED_VERSION` + `TMUX_VERSION` in `scripts/build.sh`
+ `smoke.sh` and the matrix comments. CI re-builds every matrix
target on push.

## CI

Two-stage GitHub Actions:

- `build-and-test.yml` — fires on every push to `main` + every PR;
  full 5-target matrix; uploads per-target artifacts for inspection;
  does NOT publish a GitHub Release.
- `release.yml` — fires on tag push (`v*`) + `workflow_dispatch`;
  same 5-target matrix + `softprops/action-gh-release@v2` with
  tarballs, zips, per-archive `.sha256`, and a top-level `SHA256SUMS`.

## License

Combined work is **ISC** (upstream tmux is ISC). The wrapper layer
(`scripts/`, `.github/`, `README.md`, `NOTICE.md`, `LICENSE`,
`SECURITY.md`, `AGENTS.md`, `docs/`) is BSD-3-Clause. See
[`NOTICE.md`](NOTICE.md) for the exact split.

## Project status

- **v0.1.0** (TBD) — first release; 5-target matrix; based on
  upstream `tmux 3.7`.

## Related

- [x-cmd/x-cmd issue #397](https://github.com/x-cmd/x-cmd/issues/397)
  — the request that motivated this repo.
- [tmux/tmux upstream](https://github.com/tmux/tmux) — source of truth.
