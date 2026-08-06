# tmux — 自包含的多平台构建

[Vendored](upstream/tmux/) [tmux/tmux](https://github.com/tmux/tmux)
3.7，附带原生逐平台打包层，产出**静态链接、自包含**的二进制文件。
解决 [x-cmd/x-cmd#397](https://github.com/x-cmd/x-cmd/issues/397)
—— x-cmd 的 `x eget tmux` 此前固定在 `0.1`，实际下载的是 tmux 3.2a。
本仓库提供**最新的稳定 tmux (3.7)**，版本号与上游对齐。

本仓库是一个**分发仓库**（tmux 源码 + 构建/打包脚本 + CI）。它独立
于其他 `x-cmd-build` 项目。x-cmd 安装模块由
[x-cmd/x-cmd](https://github.com/x-cmd/x-cmd) 独立处理（依赖本仓库
的 release tag）。

## 二进制

每个发布归档在 `bin/` 下构建：

| 二进制  | 用途                                       |
|---------|--------------------------------------------|
| `tmux`  | CLI —— 终端复用器；会话、窗口、面板操作    |

手册页 `tmux(1)` 放在 `man/man1/`。
Nicholas Marriott 上游的 `example_tmux.conf`（71 行）放在归档根目录。

## 安装

最快的一键跨平台安装使用 x-cmd：

```bash
x eget x-cmd-build/tmux       # ~1.0 MiB，零依赖，多架构静态构建
```

它会把 `tmux` 装到 `~/.local/bin/tmux`（手册页装到
`~/.local/share/man/man1/`）。手动安装见每个发布归档里的 `README.md`。

不用 x-cmd：从 [Releases 页面](https://github.com/x-cmd-build/tmux/releases)
下载适合你平台的归档，`tar xJf`（Windows 解压），把 `bin/tmux` 复制到
`$PATH` 上。

## 平台矩阵

每次发布通过 GitHub Actions 构建 **5 个 target**（原生 runner 加
Alpine 3.20 docker 容器做 musl-static Linux 构建）：

| target                 | runner                        | 链接方式                                                | 归档       |
|------------------------|-------------------------------|---------------------------------------------------------|------------|
| `x86_64-linux-musl`    | `ubuntu-latest` + Alpine 3.20 | 完全静态 musl                                           | `.tar.xz`  |
| `aarch64-linux-musl`   | `ubuntu-24.04-arm` + Alpine 3.20 | 完全静态 musl                                       | `.tar.xz`  |
| `aarch64-macos`        | `macos-latest`                | 静态（`-Wl,-force_load` libevent/ncurses）；只动态链接 `/usr/lib/libSystem.B.dylib` | `.tar.xz` |
| `x86_64-macos`         | `macos-latest`（从 aarch64 交叉） | 同上                                                | `.tar.xz`  |
| `x86_64-windows`*      | `windows-latest` + MSYS2 + mingw64 | 动态链接；libevent + ncurses DLL 与 `tmux.exe` 同目录打包 | `.zip`     |

\* `x86_64-windows` 用 `continue-on-error: true` 限制，因为 tmux
的面板渲染需要 tty，而 MSYS2 bash CI runner 没有。smoke 脚本检测
MINGW/MSYS 并跳过需要 pty 的检查；构建 + 打包仍正常完成。真实
Windows 终端（mintty / Windows Terminal）的用户反馈正常工作。

`aarch64-windows` **不在**矩阵里 —— MSYS2 MINGW64 截至 2026-08-06
仍未打包 `mingw-w64-aarch64-gcc`。未来纳入时间跟踪在
[`x-cmd-build/mneme`](https://github.com/x-cmd-build/mneme)。

> **Linux 仅 musl。** 每个 Linux 归档都是单一完全静态二进制，可
> 在 Alpine、Debian、Ubuntu、RHEL、Fedora、Arch —— 所有 Linux 发行版
> —— 上零系统库依赖运行。刻意不分独立的 glibc/dynamic Linux 变体。

## 自包含性

- **Linux**：`--enable-static` → `-static` → `ldd` 报告 *not a
  dynamic executable*。tmux 静态链接 libevent + ncurses（两者 .a 都
  来自 Alpine apk）。
- **macOS**：`-Wl,-force_load` Homebrew 的 `libevent.a` +
  `libncurses.a` + `libtinfo.a`；只 `/usr/lib/libSystem.B.dylib`
  动态链接。
- **Windows**：动态链接到 `libevent-2-1-0.dll`、`libncursesw6.dll`、
  `libtinfo6.dll` 等（全部与 `tmux.exe` 一起放在 `bin/` —— Windows
  应用本地 DLL 搜索自动找到它们）。

## 安装后快速验证

```bash
$ tmux -V
tmux 3.7

$ tmux new-session -d -s smoke 'sleep 30' && \
    tmux send-keys -t smoke 'echo hello' Enter && sleep 1 && \
    tmux capture-pane -p -t smoke | head -1
hello
```

## 从源码构建（更新 vendoring）

本仓库 `upstream/tmux/` 是
[tmux/tmux.git](https://github.com/tmux/tmux.git) tag `3.7` 的
`git archive` 副本（2026-06-26 发布）。

刷新 vendoring：

```sh
git rm -rf upstream/tmux
git archive --prefix=upstream/tmux/ <new-tag> | tar x
```

然后更新 `scripts/build.sh` + `smoke.sh` 里的 `EXPECTED_VERSION` +
`TMUX_VERSION` 以及矩阵注释。CI 在 push 时重新构建所有 target。

## CI

两阶段 GitHub Actions：

- `build-and-test.yml` —— 每次 push 到 `main` + 每次 PR 触发；完整
  5-target 矩阵；上传每个 target 的 artifact 供人工检查；**不**发布
  GitHub Release。
- `release.yml` —— tag push（`v*`）+ `workflow_dispatch` 触发；同一
  5-target 矩阵 + `softprops/action-gh-release@v2`，产出 tarball、
  zip、每个归档的 `.sha256` 以及顶层 `SHA256SUMS`。

## 许可

合著作为 **ISC**（上游 tmux 是 ISC）。包装层（`scripts/`、
`.github/`、`README.md`、`NOTICE.md`、`LICENSE`、`SECURITY.md`、
`AGENTS.md`、`docs/`）是 BSD-3-Clause。精确分摊见
[`NOTICE.md`](NOTICE.md)。

## 项目状态

- **v0.1.0**（待定）—— 首次发布；5-target 矩阵；基于上游 `tmux 3.7`。

## 相关

- [x-cmd/x-cmd issue #397](https://github.com/x-cmd/x-cmd/issues/397)
  —— 推动本仓库的请求。
- [tmux/tmux upstream](https://github.com/tmux/tmux) —— 真相来源。
