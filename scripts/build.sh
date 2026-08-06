#!/usr/bin/env sh
# Build tmux on host (Linux glibc/musl, macOS) or cross-compile to MinGW
# from a POSIX shell. Out-of-tree build into BUILD_DIR (default ./build).
#
# Used by:
#   - .github/workflows/build-and-test.yml + release.yml on:
#       ubuntu-latest + Alpine docker     (x86_64-linux-musl)
#       ubuntu-24.04-arm + Alpine docker  (aarch64-linux-musl)
#       macos-14                          (aarch64-macos; cross to x86_64)
#       windows-latest + MSYS2/mingw64    (x86_64-windows)
#   - Local development on any POSIX host with autotools.
#
# Cross-compile: set TMUX_TARGET_ARCH + TMUX_TARGET_OS (or TMUX_TRIPLET)
# + TMUX_OS_HINT (darwin | msys).
#
# ====================================================================
# LINKAGE MODEL PER PLATFORM:
# ====================================================================
#   Linux (glibc + musl)        : --enable-static -> -static
#                                  tmux links against static libevent.a
#                                  and ncurses.a. Fully static binary;
#                                  `ldd` reports "not a dynamic executable".
#                                  Runs on every Linux distro.
#
#   macOS (aarch64 + x86_64)    : --enable-static is REJECTED by tmux's
#                                  configure ("static linking is not
#                                  supported on macOS"). We instead
#                                  force_load Homebrew's libevent.a +
#                                  libncurses.a + libtinfo.a into the
#                                  tmux binary. Only /usr/lib/libSystem.B.dylib
#                                  remains dynamically linked (Apple's
#                                  user-space is built this way).
#
#   Windows MSYS2 (mingw64)     : dynamic link against MSYS2's libevent
#                                  + ncurses DLLs. DLLs are bundled
#                                  alongside tmux.exe by package.ps1.
#                                  Windows application-local DLL search
#                                  finds them automatically.
# ====================================================================
#
# Why a HYBRID linkage model? tmux's `--enable-static` is the cleanest
# path on Linux (one -static flag does everything), but the configure
# script explicitly rejects it on macOS with `AC_MSG_ERROR`. Windows
# MSYS2 doesn't support `-static` either (mingw ld doesn't have it).
# So we use the best tool each host offers:
#   Linux  : autotools -static
#   macOS  : ld -force_load .a archives
#   Windows: dynamic + bundled DLLs
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="${TMUX_SRC:-$ROOT/upstream/tmux}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"

TMUX_VERSION="${TMUX_VERSION:-3.7}"

[ -f "$SRC/configure.ac" ] \
	|| { echo "error: $SRC/configure.ac not found (vendoring incomplete?)" >&2; exit 1; }
command -v autoreconf >/dev/null 2>&1 \
	|| { echo "error: autoreconf not found in PATH (install autoconf + automake + libtool)" >&2; exit 1; }
command -v gcc >/dev/null 2>&1 && command -v cc >/dev/null 2>&1 \
	|| { echo "error: gcc/cc required in PATH" >&2; exit 1; }
command -v make >/dev/null 2>&1 \
	|| { echo "error: make required in PATH" >&2; exit 1; }

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.nproc 2>/dev/null || echo 4)"

# ----------------------------------------------------------------------
# Default configure args.
#   --disable-dependency-tracking   one-shot CI build, no dep graph
#   --disable-silent-rules          `make` logs each step (CI shows it)
#   --enable-static                 fully static on Linux (rejected on
#                                   macOS — handled by the host branch
#                                   below)
# ----------------------------------------------------------------------
CONFIGURE_BASE="--disable-dependency-tracking --disable-silent-rules"

# Cross-compile knobs.
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
TARGET_ARCH="${TMUX_TARGET_ARCH:-$HOST_ARCH}"
TRIPLET="${TMUX_TRIPLET:-}"
if [ -n "${TMUX_TARGET_OS:-}" ]; then
	TRIPLET="${TRIPLET:-${TMUX_TARGET_ARCH}-${TMUX_TARGET_OS}}"
fi

# Normalize arch aliases (arm64 == aarch64; amd64 == x86_64).
normalize_arch() {
	case "$1" in
		arm64) printf '%s' aarch64 ;;
		x86_64|amd64) printf '%s' x86_64 ;;
		i386|i486|i586|i686) printf '%s' i386 ;;
		*) printf '%s' "$1" ;;
	esac
}
HOST_ARCH="$(normalize_arch "$HOST_ARCH")"
TARGET_ARCH="$(normalize_arch "$TARGET_ARCH")"

# ----------------------------------------------------------------------
# Per-OS CFLAGS / LDFLAGS setup.
# ----------------------------------------------------------------------
macos_force_load_libs() {
	# Returns a space-separated list of -Wl,-force_load,<path> flags
	# for Homebrew's libevent + ncurses (incl. libtinfo). On macOS we
	# statically embed both via ld's force_load.
	LIBEVENT_A="$(brew --prefix libevent 2>/dev/null)/lib/libevent.a"
	NCURSES_A="$(brew --prefix ncurses 2>/dev/null)/lib/libncurses.a"
	TINFO_A="$(brew --prefix ncurses 2>/dev/null)/lib/libtinfo.a"

	flags=""
	for f in "$LIBEVENT_A" "$NCURSES_A" "$TINFO_A"; do
		[ -f "$f" ] || { echo "warn: missing $f (run: brew install libevent ncurses)" >&2; continue; }
		flags="$flags -Wl,-force_load,$f"
	done
	printf '%s' "$flags"
}

case "${TMUX_OS_HINT:-}:$(uname -s 2>/dev/null || echo unknown)" in
darwin:*)
	# macOS build (host OR cross). --enable-static rejected by tmux
	# configure, so we use force_load on the .a archives. Apple SDK
	# is shared between arches; clang auto-discovers via xcrun.
	if [ -n "${TMUX_OS_HINT:-}" ]; then
		# Cross-build (TMUX_TARGET_ARCH != host arch).
		export CC=clang
		: "${CFLAGS:=-arch $TARGET_ARCH -O2 -D_FORTIFY_SOURCE=2}"
		: "${LDFLAGS:=-arch $TARGET_ARCH $(macos_force_load_libs)}"
		export CFLAGS LDFLAGS
	else
		# Native macOS build.
		export CC=clang
		: "${CFLAGS:=-O2 -D_FORTIFY_SOURCE=2}"
		: "${LDFLAGS:=$(macos_force_load_libs)}"
		export CFLAGS LDFLAGS
	fi
	CONFIGURE_ARGS="$CONFIGURE_BASE --disable-utf8proc --disable-systemd"
	;;
*:MINGW*|*:MSYS*|msys:*)
	# Windows MSYS2 (mingw64). Dynamic link; package.ps1 will bundle
	# the libevent + ncurses DLLs alongside tmux.exe.
	export CC="${CC:-gcc}"
	: "${CFLAGS:=-O2 -D_FORTIFY_SOURCE=2}"
	: "${LDFLAGS:=-lws2_32 -liconv}"   # winsock + iconv (tmux uses both)
	export CFLAGS LDFLAGS
	CONFIGURE_ARGS="$CONFIGURE_BASE --disable-utf8proc --disable-systemd --enable-shared --disable-static"
	;;
*:*Linux*|linux:*)
	# Linux host (glibc or musl — Alpine docker for the musl case).
	# --enable-static adds -static to LDFLAGS, producing a fully
	# static binary that runs everywhere.
	CONFIGURE_ARGS="$CONFIGURE_BASE --enable-static --disable-utf8proc --disable-systemd"
	;;
*)
	echo "error: unknown host (set TMUX_OS_HINT=darwin|msys)" >&2
	exit 1
	;;
esac

# Cross-compile: set --host so autotools picks the right compiler checks.
if [ "$TARGET_ARCH" != "$HOST_ARCH" ] || [ -n "${TMUX_TARGET_OS:-}" ]; then
	[ -z "$TRIPLET" ] && TRIPLET="${TARGET_ARCH}-${TMUX_TARGET_OS:-unknown}"
	CONFIGURE_ARGS="$CONFIGURE_ARGS --host=$TRIPLET"
	echo "==> cross-compile: host=$HOST_ARCH → target=$TARGET_ARCH ($TRIPLET)"
fi

# ----------------------------------------------------------------------
# Clean stale state from prior builds (defensive idempotency).
# ----------------------------------------------------------------------
( cd "$SRC" && find . -maxdepth 2 \
		\( -name Makefile -o -name 'config.h' -o -name 'config.status' \
		-o -name 'config.log' -o -name 'stamp-h1' -o -name 'stamp-h2' \
		-o -name 'libtool' -o -name '*.o' -o -name 'cmd-parse.c' \
		-o -name 'tmux' -o -name 'tmux.exe' \) \
	-delete 2>/dev/null || true )

# ----------------------------------------------------------------------
# autoreconf if needed (configure missing or newer than configure.ac).
# tmux 3.7 ships a configure script in the release tarball so this
# is usually a no-op. Idempotent — we re-run if upstream bumps ac.
# ----------------------------------------------------------------------
if [ ! -x "$SRC/configure" ] || [ "$SRC/configure.ac" -nt "$SRC/configure" ]; then
	echo "==> autoreconf -fi in $SRC"
	( cd "$SRC" && autoreconf -fi )
fi

mkdir -p "$BUILD_DIR"

echo "==> configure: $SRC/configure $CONFIGURE_ARGS"
echo "    CC=${CC:-cc}  CFLAGS=${CFLAGS:-default}  LDFLAGS=${LDFLAGS:-default}"
( cd "$BUILD_DIR" && "$SRC/configure" --srcdir="$SRC" $CONFIGURE_ARGS )

# macOS post-process: the libtool wrapper may inject its own -L
# /usr/lib reference for libevent/ncurses that the brew install doesn't
# satisfy (since brew installs to /opt/homebrew/lib). Confirm the
# Makefile actually uses our force_load flags; if not, abort with a
# clear error.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ] || [ "${TMUX_OS_HINT:-}" = "darwin" ]; then
	echo "==> macOS verify: force_load libevent/ncurses present in link flags"
	grep -q -- "-Wl,-force_load" "$BUILD_DIR/Makefile" \
		|| { echo "FAIL: -Wl,-force_load not in Makefile; libtool may have stripped it" >&2; exit 1; }
fi

# ----------------------------------------------------------------------
# Build.
# ----------------------------------------------------------------------
echo "==> make -C $BUILD_DIR -j$JOBS"
make -C "$BUILD_DIR" -j"$JOBS"

ext_for() { [ -f "$1.exe" ] && printf '%s.exe' "$1" || printf '%s' "$1"; }
BIN="$(ext_for "$BUILD_DIR/tmux")"
[ -x "$BIN" ] || { echo "error: $BIN not built" >&2; exit 1; }

# Strip debug info on Linux/macOS (tmux build keeps debug_info by
# default; a musl-static binary bloats from ~1.0 MiB to ~3 MiB).
if [ "$(uname -s 2>/dev/null)" = "Darwin" ] || [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
	strip "$BIN" 2>/dev/null || true
fi

echo "==> built:"
ls -la "$BIN"
file "$BIN" | head -c 200
echo
echo "    version: $("$BIN" -V 2>&1 || "$BIN" -v 2>&1 | head -1)"
