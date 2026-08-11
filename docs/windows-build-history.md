# Windows build — historical record

This page documents the **abandoned / experimental** Windows-build paths for
`x-cmd-build/tmux`, kept so future maintainers don't re-discover the same
blockers. The shipped v0.2.0 path (MSYS2 + msys gcc, `msys-2.0.dll` bundled)
is documented inline in `README.md` + `AGENTS.md`; this file is **only about
the alternatives that didn't ship**.

> Companion issue: [#4](https://github.com/x-cmd-build/tmux/issues/4)
> "Document v0.2.1+ Docker cross-compile experiments (historical record)".
> See also issues [#1](https://github.com/x-cmd-build/tmux/issues/1),
> [#2](https://github.com/x-cmd-build/tmux/issues/2),
> [#3](https://github.com/x-cmd-build/tmux/issues/3).

---

## Known runtime issue: `no suitable socket path` on bare Windows (issue #5)

tmux 3.7b has **two distinct failure paths** that both look like
"tmux won't start":

1. **`n == 0` → "no suitable socket path"** (`tmux.c:199-203`)
   Both `$TMUX_TMPDIR` and `/tmp` fail to `realpath()`. Bare cmd.exe
   has no MSYS2 install → `/tmp` mount target depends on env vars that
   aren't set → `realpath` returns NULL → both candidates dropped.

2. **Permissions check → "directory %s has unsafe permissions"**
   (`tmux.c:225-228`). Active because `TMUX_SOCK_PERM = 7` (default for
   non-cygwin host_os=msys; the `if IS_CYGWIN / -DTMUX_SOCK_PERM=0`
   block in `Makefile.am:78-82` doesn't fire). MSYS2 `noacl` mount
   mode makes `chmod 700` silently fail → directory reports 0755 →
   tmux refuses.

**Workarounds** (full discussion in issue #5):
- `-S <path>` (bypasses both paths)
- Set `TMPDIR` to a real existing directory
- Run inside Git Bash / MSYS2 shell
- v0.2.1 direction: combine `-DTMUX_SOCK_PERM=0` (build flag) +
  `tmux.c:make_label` env-var fallback patch

---

## Path A (shipped in v0.2.0): MSYS2 + msys gcc, on `windows-latest`

Quick recap for context — full build log lives in `AGENTS.md`.

- **Runner:** `windows-latest` GitHub Actions
- **Setup:** `msys2/setup-msys2@v2` with `MSYSTEM: MINGW64`
- **Compiler:** MSYS2's `gcc` (msys repo), **not** mingw-w64 gcc
- **Output:** `tmux.exe` linked against `msys-2.0.dll` (bundled, 3.3 MB)
- **Release asset:** `tmux-x86_64-windows.zip`, ~5 MB
- **License / size trade-off:** works on bare Windows (DLL bundled) but pulls
  the MSYS2 runtime into the binary.

This was the chosen path for v0.2.0 because MSYS2 ships tmux's POSIX headers
(`<sys/uio.h>` `<sys/ioctl.h>` `<termios.h>` `<fnmatch.h>` `<sys/queue.h>`
`<sys/tree.h>` `<sys/wait.h>` `<sys/un.h>` etc.) without shimming. The build
mirrors the upstream MSYS2 tmux PKGBUILD verbatim.

---

## Path B (abandoned): Docker cross-compile — native Windows, no msys-2.0.dll

**Goal:** produce `tmux.exe` that depends only on Windows native DLLs
(`KERNEL32`, `WS2_32`, etc.) — no MSYS2 runtime, smaller zip, no "needs
Git Bash installed" support burden.

**Approach:** Debian Bullseye + mingw-w64 toolchain in Docker, cross-compile
tmux 3.7b to `x86_64-w64-mingw32`. Same toolchain the GitHub Actions runner
would use if it ran on Linux.

**Artifacts (frozen, .experimental suffix):**

| File | What it is |
|------|------------|
| `docker.experimental/Dockerfile.windows-build` | Debian Bullseye + mingw-w64-x86_64 toolchain + MSYS2 base tarball unpacked under `/opt/msys2` |
| `docker.experimental/README.md` | full rationale + path B pivot suggestion |
| `scripts/build-windows-docker.sh.experimental` | local wrapper: `docker build` + `docker run` |
| `scripts/build-windows-in-docker.sh.experimental` | in-container build: toolchain check → build.sh → smoke → package → zip |

### Blockers hit

Cross-compiling ncurses 6.4 and libevent 2.1.12 from a non-MSYS2 host
(Debian Bullseye) to `x86_64-w64-mingw32` hit multiple subtle issues:

1. **ncurses 6.4** — `DWORD` undeclared in `lib_napms.c`. Workaround needs
   `--enable-term-driver` + `-D_WIN32` patch + `make install.libs` instead
   of `make install` (host's `strip` aborts on mingw PE binaries).
2. **host `strip`** — aborts on mingw PE binaries. Force `install.libs
   install.includes` target to skip progs install.
3. **tmux `c->flags`** — subtle struct visibility issues from the
   `sys/queue.h` shim interaction. Not fully resolved before deferral.
4. **shim headers** — must include tmux's vendored `compat/queue.h` and
   `compat/tree.h`, otherwise `TAILQ_HEAD`/`RB_HEAD` macros are undefined.
   Must also define `uid_t`/`gid_t` (mingw-w64 omits them).

Series of fixes were attempted but **the remaining blockers** (struct layout
+ macro expansion issues in tmux's own source when cross-compiled) were not
reached before the path was deferred.

### Why this matters for v0.2.1

Issue #2 discusses whether to pursue a v0.2.1 that drops `msys-2.0.dll`.
This Docker experiment was one attempt at that direction; it's recorded here
so the next attempt doesn't have to re-discover the cross-compile blockers.

If revived, the recommended pivot is **Path B'**: use `msys2/base` docker
image (x86_64 emulated on arm64 hosts) + run pacman inside it. That mirrors
the GitHub Actions setup exactly and avoids the source-build cross-compile
problems. The downstream `scripts/build-windows-in-docker.sh` would need to
be rewritten to invoke the build via a single MSYS2 bash shell call.

---

## Other paths considered but not started

- **mingw-w64 cross-compile from `ubuntu-latest` GitHub Actions runner**
  (no Docker, no MSYS2). Same cross-compile blockers as Path B; not tried
  separately because Docker was the iteration vehicle.
- **MSYS2 via Docker on Linux runner** (Path B' above). Would be the cleanest
  revival; deferred pending v0.2.0 ship + v0.2.1 user demand.