#!/usr/bin/env bash
# Build tmux on MSYS2 / mingw64. Mirrors the official MSYS2 PKGBUILD
# verbatim (https://github.com/msys2/MSYS2-packages/blob/master/tmux/PKGBUILD)
# — no source patches, no header shims, no configure flag invention.
#
# Why a separate script: build.sh is a single multi-OS dispatcher. The
# MSYS2 branch grew shims + flags that diverge from the upstream
# PKGBUILD and that divergence is what's failing. This script is
# PKGBUILD-shape, nothing more. If MSYS2 ships tmux 3.7b, this script
# should build it.
#
# Used by: .github/workflows/build-windows.yml (dispatch-only).
#
# PKGBUILD source of truth:
#   makedepends: ncurses-devel libevent-devel autotools gcc
#   depends:     ncurses libevent           (runtime DLLs)
#   prepare:     ./autogen.sh
#   build:       ./configure --build=${CHOST} --enable-sixel
#                --prefix=/usr --sysconfdir=/etc --localstatedir=/var
#                CPPFLAGS="${CPPFLAGS} -I/usr/include/ncursesw -U_XOPEN_SOURCE"
#                && make
#   package:     make DESTDIR=${pkgdir} install
#
# Differences from PKGBUILD:
#   - We don't `make install` to /usr (would clobber pacman's tmux).
#     We build into a local prefix then package.ps1 zips it.
#   - We use out-of-tree build dir (PKGBUILD builds in-tree, but that
#     pollutes the vendored source with .o files).
#   - We don't run `check` (no test suite in 3.7b).
#   - We do run `smoke-msys2.sh` after build (informational only —
#     msys2 bash has no tty for tmux to attach to).

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="${TMUX_SRC:-$ROOT/upstream/tmux}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build-msys2}"

# Defensive: refuse to run if not in a mingw64 shell. The CI workflow
# already sets msystem=MINGW64 via msys2/setup-msys2@v2, but a human
# running locally might forget.
case "${MSYSTEM:-unknown}" in
	MINGW64|UCRT64|CLANG64) ;;
	*)	echo "error: MSYSTEM must be MINGW64/UCRT64/CLANG64 (got '${MSYSTEM:-unset}')" >&2
		echo "       start a 'MinGW64' shell from the MSYS2 launcher, or use:" >&2
		echo "         MSYSTEM=MINGW64 /usr/bin/bash --login scripts/build-msys2.sh" >&2
		exit 1
		;;
esac

# Defensive: confirm the MSYS2 mingw64 toolchain is on PATH (not msys gcc).
if ! command -v gcc >/dev/null 2>&1; then
	echo "error: gcc not on PATH (is this a mingw64 shell?)" >&2
	exit 1
fi

# Defensive: confirm PKGBUILD's makedepends are installed. The CI
# workflow installs them; this catches a human running locally without
# `pacman -S`.
for pkg in ncurses-devel libevent-devel autotools; do
	if ! pacman -Qq "$pkg" >/dev/null 2>&1; then
		echo "error: missing makedepend '$pkg' — run: pacman -S $pkg" >&2
		exit 1
	fi
done

[ -f "$SRC/configure.ac" ] \
	|| { echo "error: $SRC/configure.ac not found (vendoring incomplete?)" >&2; exit 1; }
[ -x "$SRC/autogen.sh" ] \
	|| { echo "error: $SRC/autogen.sh not found (PKGBUILD needs it for autoreconf)" >&2; exit 1; }

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# Clean stale state from prior builds (defensive idempotency).
( cd "$SRC" && find . -maxdepth 2 \
		\( -name Makefile -o -name 'config.h' -o -name 'config.status' \
		-o -name 'config.log' -o -name 'stamp-h1' -o -name 'stamp-h2' \
		-o -name 'libtool' -o -name '*.o' -o -name 'cmd-parse.c' \
		-o -name 'tmux' -o -name 'tmux.exe' \) \
	-delete 2>/dev/null || true )

mkdir -p "$BUILD_DIR"

# -------------------------------------------------------------------
# Step 1: ./autogen.sh  (PKGBUILD prepare())
#
# autogen.sh runs autoreconf -fi. It also runs aclocal, libtoolize,
# automake. The PKGBUILD depends on `autotools` makedepend for these.
# -------------------------------------------------------------------
echo "==> autogen.sh (autoreconf -fi + aclocal + libtoolize + automake)"
( cd "$SRC" && ./autogen.sh )

# -------------------------------------------------------------------
# Step 2: ./configure  (PKGBUILD build())
#
# VERBATIM from PKGBUILD — do NOT add flags, do NOT remove flags.
#   --build=${CHOST}      : CHOST is set by MSYS2 env (e.g. x86_64-w64-mingw32)
#   --enable-sixel        : upstream opt-in for sixel graphics
#   --prefix=/usr         : where MSYS2's tmux lives
#   --sysconfdir=/etc     : /etc/tmux.conf
#   --localstatedir=/var  : /var/run/tmux
#   CPPFLAGS appended:
#     -I/usr/include/ncursesw  : wide-char ncurses headers
#     -U_XOPEN_SOURCE          : undefine _XOPEN_SOURCE — bypasses tmux's
#                                broken CMSG_DATA fallback check
# -------------------------------------------------------------------
echo "==> configure (PKGBUILD flags, no additions, no removals)"
( cd "$BUILD_DIR" && \
	CPPFLAGS="${CPPFLAGS:-} -I/usr/include/ncursesw -U_XOPEN_SOURCE" \
		"$SRC/configure" \
			--build="${CHOST:-x86_64-w64-mingw32}" \
			--enable-sixel \
			--prefix=/usr \
			--sysconfdir=/etc \
			--localstatedir=/var \
			--srcdir="$SRC" )

# -------------------------------------------------------------------
# Step 3: make  (PKGBUILD build())
#
# Note: MSYS2's autotools tries to regen Makefile when timestamps drift
# (the "newly created file is older than distributed" check). We
# override AUTOMAKE/AUTOCONF/ACLOCAL/AUTOHEADER to `true` so the regen
# recipe is a no-op. Same trick build.sh uses for other platforms.
# -------------------------------------------------------------------
echo "==> make -j$JOBS"
make -C "$BUILD_DIR" -j"$JOBS" \
	AUTOMAKE=true AUTOCONF=true ACLOCAL=true AUTOHEADER=true

# -------------------------------------------------------------------
# Step 4: verify the binary
# -------------------------------------------------------------------
[ -x "$BUILD_DIR/tmux.exe" ] \
	|| { echo "error: $BUILD_DIR/tmux.exe not produced" >&2; exit 1; }

echo "==> built:"
ls -la "$BUILD_DIR/tmux.exe"
file "$BUILD_DIR/tmux.exe" 2>/dev/null || true

# Print the runtime DLL deps so package.ps1 knows what to bundle.
echo "==> runtime DLL deps:"
# ldd on Windows-msys2 shows .dll names; we just need the basenames.
ldd "$BUILD_DIR/tmux.exe" 2>/dev/null \
	| awk '/=> *[^ ]+\.(dll|DLL)/ {print $3}' \
	| xargs -I{} basename {} \
	| sort -u \
	|| true
