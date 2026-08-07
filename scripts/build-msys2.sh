#!/usr/bin/env bash
# Build tmux in MSYS2's MSYS shell (msys gcc), verbatim PKGBUILD.
# Output: tmux.exe that links to msys-2.0.dll (just like MSYS2's
# official tmux package).
#
# Why MSYS shell (not MINGW64): tmux is deeply POSIX-dependent
# (fork, exec, pty, signals, termios, sys/queue.h, sys/tree.h, etc.).
# mingw-w64 ships only a small subset of POSIX headers; tmux 3.7b
# does not build natively on mingw-w64 without 200+ lines of patch.
# MSYS2's official tmux package is therefore built with msys gcc in
# the MSYS shell, not mingw-w64. The output binary links to
# msys-2.0.dll, which we bundle alongside tmux.exe in package.ps1.
#
# PKGBUILD source of truth:
#   https://github.com/msys2/MSYS2-packages/blob/master/tmux/PKGBUILD
#
# Used by: .github/workflows/build-windows.yml (dispatch-only).

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="${TMUX_SRC:-$ROOT/upstream/tmux}"

# ---- defensive checks ----
# PKGBUILD builds in MSYS shell (MSYSTEM=MSYS), not MINGW64. The MSYS
# shell provides a complete POSIX header set via its gcc + libc
# (newlib-based msys libc).
case "${MSYSTEM:-unknown}" in
	MSYS) ;;
	*)	echo "error: MSYSTEM must be MSYS (got '${MSYSTEM:-unset}')" >&2
		echo "       this build is msys-gcc based, not mingw-w64." >&2
		echo "       start a 'MSYS2 MSYS' shell from the launcher, or use:" >&2
		echo "         MSYSTEM=MSYS /usr/bin/bash --login scripts/build-msys2.sh" >&2
		exit 1
		;;
esac

command -v gcc >/dev/null 2>&1 \
	|| { echo "error: gcc not on PATH (is this an MSYS shell?)" >&2; exit 1; }

# PKGBUILD makedepends are MSYS-repo names. They're MSYS packages
# (not mingw-w64). CI installs them via build-windows.yml.
for pkg in gcc autoconf automake libtool pkg-config ncurses-devel libevent-devel make; do
	pacman -Qq "$pkg" >/dev/null 2>&1 \
		|| { echo "error: missing makedepend '$pkg' — run: pacman -S $pkg" >&2; exit 1; }
done

[ -f "$SRC/configure.ac" ] \
	|| { echo "error: $SRC/configure.ac not found (vendoring incomplete?)" >&2; exit 1; }

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# ---- pre-clean (idempotent re-builds; PKGBUILD builds in-tree) ----
( cd "$SRC" && find . -maxdepth 2 \
		\( -name Makefile -o -name 'config.h' -o -name 'config.status' \
		-o -name 'config.log' -o -name 'stamp-h1' -o -name 'stamp-h2' \
		-o -name 'libtool' -o -name '*.o' -o -name '*.lo' \
		-o -name 'cmd-parse.c' -o -name 'cmd-parse.h' \
		-o -name 'tmux' -o -name 'tmux.exe' \) \
	-delete 2>/dev/null || true )

# ---- PKGBUILD prepare() ----
# PKGBUILD runs ./autogen.sh. Our vendored copy ships configure but
# not autogen.sh (autogen.sh is the upstream GitHub tarball's
# autoreconf entry). Use autoreconf -fi directly — equivalent to
# autogen.sh on this project, idempotent.
echo "==> autoreconf -fi (PKGBUILD's autogen.sh equivalent)"
( cd "$SRC" && autoreconf -fi )

# ---- PKGBUILD build()  (VERBATIM configure flags) ----
# PKGBUILD:
#   ./configure --build=${CHOST} --enable-sixel
#               --prefix=/usr --sysconfdir=/etc --localstatedir=/var
#               CPPFLAGS="${CPPFLAGS} -I/usr/include/ncursesw -U_XOPEN_SOURCE"
#   make
#
# The -U_XOPEN_SOURCE in CPPFLAGS works in MSYS shell because msys
# winsock2.h exposes CMSG_DATA only when _XOPEN_SOURCE is undefined
# (it sets a default _XOPEN_SOURCE=500 in some headers). We
# explicitly undefine it so the AC_EGREP_CPP in configure.ac
# (line 605-617) finds CMSG_DATA and passes.
echo "==> configure (PKGBUILD verbatim)"
( cd "$SRC" && \
	CPPFLAGS="${CPPFLAGS:-} -I/usr/include/ncursesw -U_XOPEN_SOURCE" \
		./configure \
			--build="${CHOST:-x86_64-pc-msys}" \
			--enable-sixel \
			--prefix=/usr \
			--sysconfdir=/etc \
			--localstatedir=/var )

# ---- PKGBUILD build() make step ----
# AUTOMAKE=true AUTOCONF=true ACLOCAL=true AUTOHEADER=true:
# override autotools regen recipes to no-op (we just ran autoreconf,
# and CI re-runs can hit timestamp drift).
echo "==> make -j$JOBS"
make -C "$SRC" -j"$JOBS" \
	AUTOMAKE=true AUTOCONF=true ACLOCAL=true AUTOHEADER=true

# ---- verify ----
[ -x "$SRC/tmux.exe" ] \
	|| { echo "error: $SRC/tmux.exe not produced" >&2; exit 1; }

echo "==> built:"
ls -la "$SRC/tmux.exe"
file "$SRC/tmux.exe" 2>/dev/null || true

echo "==> runtime DLL deps (package.ps1 will bundle these):"
# Write full ldd output (paths + basenames) to a file package.ps1
# reads, so it can find each DLL regardless of which MSYS2 dir it
# lives in (libevent/ncurses DLLs may be in /usr/lib or /usr/bin
# depending on repo + version).
DLL_DEPS_FILE="$ROOT/dist-dll-deps.txt"
mkdir -p "$(dirname "$DLL_DEPS_FILE")"
ldd "$SRC/tmux.exe" 2>/dev/null \
	| awk '/=> *[^ ]+\.(dll|DLL)/ {print $3}' \
	| sort -u > "$DLL_DEPS_FILE" || true
cat "$DLL_DEPS_FILE"
