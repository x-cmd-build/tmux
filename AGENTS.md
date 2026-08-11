# x-cmd-build/tmux — agent notes

> **Public-facing agent note** for `x-cmd-build/tmux`.
>
> Full design / audit / decision docs live in the private
> **`x-cmd-build/mneme`** design HQ (mirrors `ljh-sh/mneme` patterns).

## TL;DR for AI agents

- **What**: portable tmux 3.7b (latest stable as of 2026-08-06), 5-platform
  CI build. Resolves x-cmd/x-cmd#397 (tmux version was pinned to `0.1`
  while x eget actually pulled tmux 3.2a — version numbers misaligned
  with upstream).
- **Windows**: v0.2.2+ ships tmux.exe built via MSYS2 + msys gcc; loads
  Git Bash's `msys-2.0.dll` (no longer bundled in our zip). The
  `tmux.cmd` wrapper at zip root locates Git Bash via registry and
  injects `usr/bin` into the process PATH so tmux.exe finds Git
  Bash's DLL via standard Win32 DLL search. **Requires Git for
  Windows** (hard dep — matches upstream MSYS2's distribution model);
  use **POSIX-style paths only** (`/c/Users/<user>/.tmux/socket`).
  See [issue #1](https://github.com/x-cmd-build/tmux/issues/1) for
  the original MSYS2 build, [issue #5](https://github.com/x-cmd-build/tmux/issues/5)
  for the path-1/path-2 analysis, and
  [issue #6](https://github.com/x-cmd-build/tmux/issues/6) for the
  v0.2.2 re-architecture.
- **Source**: vendored under `upstream/tmux/` via `git archive` from
  <https://github.com/tmux/tmux/releases/tag/3.7>.
- **Build**: GitHub Actions only (`build-and-test.yml` + `release.yml` +
  `build-windows.yml`). **No local builds** (per `feedback-ci-only-no-local-dev`).
- **All CI is dispatch-only** (no push / pull_request triggers). Use
  `gh workflow run <wf>` to invoke.
- **Do NOT modify**: anything under `upstream/tmux/`.
- **All build flags**: see `build-review.md` §2 (once published).

## Issue & PR conventions

- **Public issues**: end-user bug reports / install problems
  (e.g. x-cmd/x-cmd#397).
- **Design / audit / roadmap**: GitHub issues on
  [`x-cmd-build/mneme`](https://github.com/x-cmd-build/mneme) (private,
  but issues can be opened by collaborators).

## License

- **Wrapper code** (scripts, workflows, docs): BSD 3-Clause
- **Vendored tmux 3.7**: ISC — see `NOTICE.md` and
  `upstream/tmux/COPYING`

## Vendoring update

```sh
git rm -rf upstream/tmux
git archive --prefix=upstream/tmux/ <new-tag> | tar x
```

Then update `TMUX_VERSION` in `scripts/build.sh` + `smoke.sh` and the
matrix comments. CI re-builds every matrix target on push.
