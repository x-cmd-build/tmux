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

## Windows support (DEFERRED — not in v0.1.0)

tmux 3.7 does **not officially support Windows**. The
`configure.ac`'s CMSG_DATA check (looking for `CMSG_DATA` in
`<sys/socket.h>`) fails on MinGW because Windows uses the Winsock
`WSA_CMSG_DATA` macro family instead.

The MSYS2 community port of tmux ships local patches that work around
this, but those patches are not yet upstream in tmux 3.7. As a
result, **v0.1.0 of `x-cmd-build/tmux` does not ship a Windows
build**.

A future release (v0.2.0) will either:

1. Wait for upstream tmux to merge Windows portability fixes
   (track <https://github.com/tmux/tmux/issues>), or
2. Carry a local patch under `patches/` that adds the necessary
   feature-test macros (`_WIN32_WINNT=0x0601`, `CMSG_DATA` macro
   shim) — see mneme#N for the patch design.

In the meantime, Windows users should run tmux under WSL (`wsl
--install` then `x eget x-cmd-build/tmux` inside WSL). The
Linux/musl-static binary runs unchanged inside WSL.

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
