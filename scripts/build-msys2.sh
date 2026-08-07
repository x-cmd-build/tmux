#!/usr/bin/env bash
# Build tmux on MSYS2 / mingw64. Verbatim MSYS2 PKGBUILD:
#   https://github.com/msys2/MSYS2-packages/blob/master/tmux/PKGBUILD
#
# No source patches, no header shims, no configure flag invention.
# In-tree build, same as PKGBUILD. We pre-clean stale .o / Makefile
# files to keep the vendored source idempotent.
#
# Used by: .github/workflows/build-windows.yml (dispatch-only).

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="${TMUX_SRC:-$ROOT/upstream/tmux}"

# ---- defensive checks ----
case "${MSYSTEM:-unknown}" in
	MINGW64|UCRT64|CLANG64) ;;
	*)	echo "error: MSYSTEM must be MINGW64/UCRT64/CLANG64 (got '${MSYSTEM:-unset}')" >&2
		echo "       start a 'MinGW64' shell from the MSYS2 launcher." >&2
		exit 1
		;;
esac

command -v gcc >/dev/null 2>&1 \
	|| { echo "error: gcc not on PATH (is this a mingw64 shell?)" >&2; exit 1; }

# Note: PKGBUILD's makedepends ('ncurses-devel' 'libevent-devel'
# 'autotools') are MSYS-repo package names (used when building in the
# MSYS shell, not MINGW64). The CI workflow runs in MINGW64, where
# headers + link libs come from the same package as runtime DLLs —
# mingw-w64-x86_64-ncurses, mingw-w64-x86_64-libevent, and
# mingw-w64-x86_64-libmangle (POSIX shim headers) are all installed
# by build-windows.yml. We don't re-verify here because pacman checks
# would need MINGW64-vs-MSYS-aware package name mapping.

[ -f "$SRC/configure.ac" ] \
	|| { echo "error: $SRC/configure.ac not found (vendoring incomplete?)" >&2; exit 1; }
[ -x "$SRC/autogen.sh" ] \
	|| { echo "error: $SRC/autogen.sh not found" >&2; exit 1; }

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# ---- pre-clean (idempotent re-builds; PKGBUILD builds in-tree so we
#      must remove stale build artefacts before each run) ----
( cd "$SRC" && find . -maxdepth 2 \
		\( -name Makefile -o -name 'config.h' -o -name 'config.status' \
		-o -name 'config.log' -o -name 'stamp-h1' -o -name 'stamp-h2' \
		-o -name 'libtool' -o -name '*.o' -o -name '*.lo' \
		-o -name 'cmd-parse.c' -o -name 'cmd-parse.h' \
		-o -name 'tmux' -o -name 'tmux.exe' \) \
	-delete 2>/dev/null || true )

# ---- PKGBUILD prepare() ----
echo "==> autogen.sh"
( cd "$SRC" && ./autogen.sh )

# ---- PKGBUILD build()  (VERBATIM configure flags) ----
echo "==> configure"
( cd "$SRC" && \
	CPPFLAGS="${CPPFLAGS:-} -I/usr/include/ncursesw -U_XOPEN_SOURCE" \
		./configure \
			--build="${CHOST:-x86_64-w64-mingw32}" \
			--enable-sixel \
			--prefix=/usr \
			--sysconfdir=/etc \
			--localstatedir=/var )

# ---- PKGBUILD build() make step ----
# AUTOMAKE=true AUTOCONF=true ACLOCAL=true AUTOHEADER=true:
#   MSYS2's autotools regen recipes (e.g. "$(AUTOMAKE) --foreign")
#   trigger when source timestamps drift from generated files. PKGBUILD
#   doesn't see this because it builds once. We override to `true` so
#   the regen becomes a no-op — without this, a CI re-run can fail with
#   "newly created file is older than distributed".
echo "==> make -j$JOBS"
make -C "$SRC" -j"$JOBS" \
	AUTOMAKE=true AUTOCONF=true ACLOCAL=true AUTOHEADER=true

# ---- verify ----
[ -x "$SRC/tmux.exe" ] \
	|| { echo "error: $SRC/tmux.exe not produced" >&2; exit 1; }

echo "==> built:"
ls -la "$SRC/tmux.exe"
file "$SRC/tmux.exe" 2>/dev/null || true

echo "==> runtime DLL deps:"
ldd "$SRC/tmux.exe" 2>/dev/null \
	| awk '/=> *[^ ]+\.(dll|DLL)/ {print $3}' \
	| xargs -I{} basename {} \
	| sort -u || true
