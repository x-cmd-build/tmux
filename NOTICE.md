# NOTICE

This archive (`tmux-<target>`) packages a build of **tmux 3.7** with the
wrapper build/packaging layer around it.

## Wrapper license (the archive structure, scripts, this NOTICE)

The wrapper files (`scripts/`, `.github/`, `README.md`, `README.cn.md`,
`NOTICE.md`, `LICENSE`, `SECURITY.md`, `AGENTS.md`, `docs/`) are:

    Copyright (c) 2026 x-cmd-build
    Licensed under the BSD 3-Clause License.

See `LICENSE` for the full text.

## Upstream license (the tmux binary, man page, example config)

`bin/tmux`, `man/man1/tmux.1`, and `example_tmux.conf` are derived from
**tmux 3.7**, vendored via `git archive` from
<https://github.com/tmux/tmux/releases/tag/3.7> (commit on tag `3.7`,
published 2026-06-26 by the tmux maintainers).

Upstream tmux is **ISC-Licensed**:

> Copyright (c) Various Authors
>
> Permission to use, copy, modify, and distribute this software for any
> purpose with or without fee is hereby granted, provided that the above
> copyright notice and this permission notice appear in all copies.
>
> THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
> WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
> MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
> ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
> WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER IN
> AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT
> OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

The full ISC text is reproduced verbatim in `upstream/tmux/COPYING`.

## Bundled runtime libraries

tmux links against two runtime libraries at build time:

- **libevent 2.x** — BSD 3-Clause (libevent contributors / Nick
  Mathewson and the libevent team). See
  <https://github.com/libevent/libevent>.
- **ncurses** — MIT-like permissive license. See
  <https://invisible-island.net/ncurses/>.

Both libraries are linked statically into the tmux binary on Linux and
macOS (`-Wl,-force_load` + `.a` archive on macOS).

## Windows support (shipped in v0.2.0)

v0.2.0 ships a Windows build via **MSYS2 + msys gcc** (option A from
[issue #1](https://github.com/x-cmd-build/tmux/issues/1)). Same
approach MSYS2's official tmux package uses. The output `tmux.exe`
links against `msys-2.0.dll` (the MSYS2 runtime), which is bundled
alongside `tmux.exe` in the release zip.

**Runtime requirements for end users**: nothing extra. Extract the
zip, `cd bin`, run `./tmux.exe` from cmd.exe / Windows Terminal.
The bundled `msys-2.0.dll` + `msys-event_core-2-1-7.dll` +
`msys-ncursesw6.dll` provide all dependencies.

**Why not native mingw-w64**: tmux 3.7b is deeply POSIX-dependent
(`<sys/queue.h>`, `<sys/tree.h>`, `<sys/wait.h>`, `<termios.h>`,
`<fnmatch.h>`, etc.). mingw-w64 ships only a small subset of POSIX
headers; a true native build needs ~200+ lines of patch. MSYS's
libc provides the full set, the same way MSYS2's tmux package
already does. See issue #1 for the full architectural discussion.

**v0.1.0 limitation**: v0.1.0 did not ship a Windows build; users on
Windows had to run tmux under WSL. v0.2.0 fixes this.

## Why this notice exists

The wrapper license (BSD-3-Clause) covers the build/packaging
infrastructure. The ISC license covers the tmux binary itself. Both
licenses are permissive and explicitly grant redistribution rights for
binary forms — `x eget x-cmd-build/tmux`, distro packages, embedded
use — provided that the corresponding `LICENSE` text accompanies the
binary (it does — see the `LICENSE` file in every release archive).

`x-cmd-build/tmux` carries no source modifications to tmux 3.7
(byte-for-byte upstream); vendoring is via `git archive` from the
official tag.

## Vendoring update

To refresh to a newer tmux upstream tag:

```sh
git rm -rf upstream/tmux
git archive --prefix=upstream/tmux/ <new-tag> | tar x
```

Then update `TMUX_VERSION` in `scripts/build.sh`, `smoke.sh`, and the
matrix comments. CI re-builds every matrix target on push.
