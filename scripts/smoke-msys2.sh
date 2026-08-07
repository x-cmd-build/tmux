#!/usr/bin/env bash
# Smoke test for Windows MSYS2 tmux build. Informational only — msys2
# bash has no tty for tmux to attach a pane to, so we can't run a real
# session test. We just confirm the binary launches and prints its
# version.
#
# Used by: .github/workflows/build-windows.yml after build-msys2.sh.

set -eu

BIN="${1:-upstream/tmux/tmux.exe}"

if [ ! -x "$BIN" ]; then
	echo "FAIL: $BIN not found or not executable"
	exit 1
fi

# tmux on Windows can't start a real server (no ConPTY in CI), but it
# can still parse flags. `-V` prints version and exits 0.
echo "==> $BIN -V"
if "$BIN" -V; then
	echo "==> OK: $BIN -V returned 0"
else
	echo "FAIL: $BIN -V exited non-zero (binary likely broken)"
	exit 1
fi
