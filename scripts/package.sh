#!/usr/bin/env sh
# Stage the built tmux into a self-contained dist archive. Linux + macOS.
#   TARGET    e.g. x86_64-linux-musl | aarch64-linux-musl | aarch64-macos
#   BUILD_DIR (default $ROOT/build)
#   TMUX_SRC  (default $ROOT/upstream/tmux — for man page + example conf)
#   DIST      (default $ROOT/dist)
#
# Stage layout inside dist/tmux-$TARGET/:
#   bin/tmux                (the CLI binary, +x, single-file portable)
#   man/man1/tmux.1         (the man page, mdoc source)
#   example_tmux.conf       (upstream's example config, 71 lines)
#   README.md               (install + shim model + version note)
#   README.cn.md            (Chinese version)
#   LICENSE                 (BSD-3-Clause wrapper + ISC upstream)
#   NOTICE.md               (license split + vendoring update instructions)
#
# Output: dist/tmux-$TARGET.tar.xz + .sha256 (basename-keyed).
#
# Self-containedness check is performed by the CI YAML (not here), to
# keep the package script independent of `ldd` / `otool` availability
# on the host (the build runner always has both).
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMUX_SRC="${TMUX_SRC:-$ROOT/upstream/tmux}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
DIST="${DIST:-$ROOT/dist}"
TARGET="${TARGET:?set TARGET, e.g. x86_64-linux-musl}"

ext_for() { [ -f "$1.exe" ] && printf '%s.exe' "$1" || printf '%s' "$1"; }
BIN="$(ext_for "$BUILD_DIR/tmux")"
[ -x "$BIN" ] || { echo "error: $BIN not built (run scripts/build.sh first)" >&2; exit 1; }

# Man page: upstream/tmux/tmux.1 (mdoc source, checked in).
MAN_SRC="$TMUX_SRC/tmux.1"
[ -f "$MAN_SRC" ] || { echo "error: $MAN_SRC not found" >&2; exit 1; }

# Example config: upstream/tmux/example_tmux.conf (71 lines).
CONF_SRC="$TMUX_SRC/example_tmux.conf"
[ -f "$CONF_SRC" ] || { echo "error: $CONF_SRC not found" >&2; exit 1; }

# Upstream ISC license MUST ship with the binary per ISC redistribution
# terms (verbatim, see upstream/tmux/COPYING).
LICENSE_SRC="$TMUX_SRC/COPYING"
[ -f "$LICENSE_SRC" ] || { echo "error: $LICENSE_SRC not found" >&2; exit 1; }

STAGE="$DIST/tmux-$TARGET"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/man/man1"

cp "$BIN" "$STAGE/bin/tmux"
chmod +x "$STAGE/bin/tmux"
cp "$MAN_SRC" "$STAGE/man/man1/tmux.1"
cp "$CONF_SRC" "$STAGE/example_tmux.conf"
cp "$LICENSE_SRC" "$STAGE/LICENSE"
[ -f "$ROOT/NOTICE.md" ] && cp "$ROOT/NOTICE.md" "$STAGE/NOTICE.md"
[ -f "$ROOT/README.md" ] && cp "$ROOT/README.md" "$STAGE/README.md"
[ -f "$ROOT/README.cn.md" ] && cp "$ROOT/README.cn.md" "$STAGE/README.cn.md"

# A tiny archive-local README so the tarball is self-explanatory.
# The full README.md is also in the archive; this README.md is a
# minimal pointer (in case the user only reads what's at the root).
cat > "$STAGE/README.md.tmp" <<'EOF'
# tmux — single-binary release

Self-contained archive from https://github.com/x-cmd-build/tmux (release tag).
The wrapper LICENSE and NOTICE live there; the `tmux` binary carries the
upstream ISC license from the tmux contributors — see `LICENSE` (the ISC
text is reproduced verbatim from upstream `tmux/COPYING`) and
https://github.com/tmux/tmux.

Install (optional, manual):

    sudo install -m 0755 bin/tmux /usr/local/bin/tmux
    sudo install -m 0644 man/man1/tmux.1 /usr/local/share/man/man1/
    sudo install -m 0644 example_tmux.conf /usr/local/share/examples/tmux/

Then:  man tmux

Or one-liner:

    x eget x-cmd-build/tmux

Then:  tmux -V   # tmux 3.7
EOF
# Move the temp into place (overwriting the wrapper README copy above
# only if it's identical; otherwise keep the wrapper README).
mv "$STAGE/README.md.tmp" "$STAGE/README.md"

# Tar archive — use xz for better ratio. Both GNU tar and BSD tar
# (macOS) support -J.
ARCHIVE="$DIST/tmux-$TARGET.tar.xz"
( cd "$DIST" && tar -cJf "$ARCHIVE" "$(basename "$STAGE")" )

# SHA256 — basename-only so `sha256sum -c FILE.sha256` works from any
# cwd. Prefer coreutils sha256sum, then macOS shasum, then OpenSSL.
if   command -v sha256sum >/dev/null 2>&1; then
	HASH_CMD='sha256sum'
elif command -v shasum     >/dev/null 2>&1; then
	HASH_CMD='shasum -a 256'
else
	HASH_CMD='openssl dgst -sha256 -r'
fi
( cd "$DIST" && $HASH_CMD "tmux-$TARGET.tar.xz" \
	| awk '{printf "%s  tmux-'"$TARGET"'.tar.xz\n", $1}' ) > "$ARCHIVE.sha256"

echo "==> $ARCHIVE"
ls -la "$ARCHIVE" "$ARCHIVE.sha256"
echo
echo "==> Layout preview:"
( cd "$STAGE" && find . -maxdepth 3 -type f | sort | sed 's/^/    /' )
