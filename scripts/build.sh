#!/usr/bin/env sh
# Build tmux on host (Linux glibc/musl, macOS) or cross-compile to MinGW
# from a POSIX shell. Out-of-tree build into BUILD_DIR (default ./build).
#
# Used by:
#   - .github/workflows/build-and-test.yml + release.yml on:
#       ubuntu-latest + Alpine docker     (x86_64-linux-musl)
#       ubuntu-24.04-arm + Alpine docker  (aarch64-linux-musl)
#       macos-14                          (aarch64-macos; cross to x86_64)
#       windows-latest + MSYS2/mingw64    (x86_64-windows — DEFERRED to v0.2;
#                                          tmux 3.7 configure fails on MinGW
#                                          due to CMSG_DATA check; upstream
#                                          does NOT support Windows)
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
#                                  libncurses.a into the tmux binary.
#                                  Only /usr/lib/libSystem.B.dylib remains
#                                  dynamically linked (Apple's user-space
#                                  is built this way).
#
#   Windows MSYS2 (mingw64)     : DEFERRED — tmux 3.7 configure checks
#                                  for CMSG_DATA in <sys/socket.h>, which
#                                  doesn't exist on MinGW. Upstream tmux
#                                  does not support Windows; the MSYS2
#                                  tmux port uses patches not yet in 3.7.
#                                  See NOTICE.md §Windows support.
# ====================================================================
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
# ----------------------------------------------------------------------
CONFIGURE_BASE="--disable-dependency-tracking --disable-silent-rules"

# Cross-compile knobs.
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
HOST_OS="$(uname -s 2>/dev/null || echo unknown)"
TARGET_ARCH="${TMUX_TARGET_ARCH:-$HOST_ARCH}"
TRIPLET="${TMUX_TRIPLET:-}"

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
# Detect host by TMUX_OS_HINT (if set) OR uname -s.
# ----------------------------------------------------------------------
macos_force_load_libs() {
	# Returns a space-separated list of -Wl,-force_load,<path> flags
	# for Homebrew's libevent + ncurses. On macOS we statically embed
	# both via ld's force_load.
	#
	# Homebrew's ncurses (since the `ncurses` formula rewrite in 2024)
	# merges libtinfo into libncurses — `libtinfo.a` no longer exists
	# as a separate file. We probe for both and use what's available.
	LIBEVENT_A="$(brew --prefix libevent 2>/dev/null)/lib/libevent.a"
	NCURSES_A="$(brew --prefix ncurses 2>/dev/null)/lib/libncurses.a"
	TINFO_A="$(brew --prefix ncurses 2>/dev/null)/lib/libtinfo.a"

	flags=""
	for f in "$LIBEVENT_A" "$NCURSES_A"; do
		if [ -f "$f" ]; then
			flags="$flags -Wl,-force_load,$f"
		else
			echo "warn: missing $f (run: brew install libevent ncurses)" >&2
		fi
	done
	# libtinfo.a is optional — only present in older Homebrew ncurses.
	if [ -f "$TINFO_A" ]; then
		flags="$flags -Wl,-force_load,$TINFO_A"
	fi
	printf '%s' "$flags"
}

# Determine the effective OS: TMUX_OS_HINT takes priority; otherwise
# fall back to uname -s. Normalize to darwin | linux | msys.
effective_os() {
	if [ -n "${TMUX_OS_HINT:-}" ]; then
		printf '%s' "$TMUX_OS_HINT"
		return
	fi
	case "$HOST_OS" in
		Darwin)  printf '%s' darwin ;;
		Linux)   printf '%s' linux  ;;
		MINGW*|MSYS*|CYGWIN*) printf '%s' msys ;;
		*)       printf '%s' unknown ;;
	esac
}
OS="$(effective_os)"

case "$OS" in
darwin)
	# macOS build (host OR cross). --enable-static rejected by tmux
	# configure, so we use force_load on the .a archives. Apple SDK
	# is shared between arches; clang auto-discovers via xcrun.
	if [ "$TARGET_ARCH" != "$HOST_ARCH" ]; then
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
	# Triplet for cross: x86_64-apple-darwin / aarch64-apple-darwin.
	if [ -z "$TRIPLET" ] && [ "$TARGET_ARCH" != "$HOST_ARCH" ]; then
		TRIPLET="${TARGET_ARCH}-apple-darwin"
	elif [ -z "$TRIPLET" ]; then
		TRIPLET="${HOST_ARCH}-apple-darwin"
	fi
	;;
msys)
	# Windows MSYS2 (mingw64). DEFERRED — tmux 3.7 configure fails
	# because CMSG_DATA is not in MinGW's <sys/socket.h>. We still
	# honor the request (so manual builds work), but emit a clear
	# message and bail out with a documented exit code so the CI
	# YAML's `continue-on-error: true` gate catches it gracefully.
	export CC="${CC:-gcc}"
	: "${CFLAGS:=-O2 -D_FORTIFY_SOURCE=2}"
	: "${LDFLAGS:=-lws2_32}"
	export CFLAGS LDFLAGS
	CONFIGURE_ARGS="$CONFIGURE_BASE --disable-utf8proc --disable-systemd --enable-shared --disable-static"
	if [ -z "$TRIPLET" ]; then
		TRIPLET="${TARGET_ARCH}-w64-mingw32"
	fi
	# Probe for the known CMSG_DATA failure early so the user gets a
	# clear message rather than a deep autotools backtrace.
	cat <<'EOF' >&2
==> NOTE: tmux 3.7 Windows support is DEFERRED in this repo.
    tmux 3.7's configure.ac checks for CMSG_DATA in <sys/socket.h>,
    which MinGW's mingw64 headers don't provide without a feature
    test macro. Upstream tmux does not support Windows; the MSYS2
    tmux port uses local patches not yet in 3.7.
    See NOTICE.md §Windows support and mneme#N for the patch plan.
EOF
	;;
linux)
	# Linux host (glibc or musl — Alpine docker for the musl case).
	# --enable-static adds -static to LDFLAGS, producing a fully
	# static binary that runs everywhere.
	CONFIGURE_ARGS="$CONFIGURE_BASE --enable-static --disable-utf8proc --disable-systemd"
	if [ -z "$TRIPLET" ]; then
		TRIPLET="${TARGET_ARCH}-unknown-linux-musl"
	fi
	# Verify yacc/byacc/bison — tmux's configure calls AC_PROG_YACC
	# even though we vendor a pre-generated cmd-parse.c (configure
	# still aborts if no YACC-like tool is present, because the
	# Makefile.am rule might try to regenerate cmd-parse.c).
	command -v yacc >/dev/null 2>&1 \
		|| command -v byacc >/dev/null 2>&1 \
		|| command -v bison >/dev/null 2>&1 \
		|| { echo "error: yacc/byacc/bison required on Linux (apk add byacc)" >&2; exit 1; }
	;;
*)
	echo "error: unknown OS (set TMUX_OS_HINT=darwin|msys|linux)" >&2
	exit 1
	;;
esac

# Cross-compile: set --host so autotools picks the right compiler checks.
if [ "$TARGET_ARCH" != "$HOST_ARCH" ] || [ -n "${TMUX_TARGET_OS:-}" ]; then
	CONFIGURE_ARGS="$CONFIGURE_ARGS --host=$TRIPLET"
	echo "==> cross-compile: host=$HOST_ARCH/$HOST_OS → target=$TARGET_ARCH ($TRIPLET)"
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

# ----------------------------------------------------------------------
# Suppress make's autotools regeneration rules.
# Vendored configure.ac + Makefile.am often have newer timestamps
# than the generated aclocal.m4 + Makefile.in (the tarball `make
# dist` regenerates them in a different order than they're consumed).
# `make` then tries to run aclocal-1.15 / automake-1.15, which aren't
# installed in CI images — error 127.
#
# Touch the generated files so make's regeneration rules see them as
# fresh and skip the rebuild. Same pattern as ljh-sh/gawk.
# ----------------------------------------------------------------------
echo "==> touch: stamp aclocal.m4 + Makefile.in to suppress autotools regen"
( cd "$SRC" \
	&& touch -r configure.ac aclocal.m4 2>/dev/null || touch aclocal.m4 \
	&& touch -r Makefile.am Makefile.in configure config.h.in 2>/dev/null \
	|| true )

mkdir -p "$BUILD_DIR"

echo "==> configure: $SRC/configure $CONFIGURE_ARGS"
echo "    CC=${CC:-cc}  CFLAGS=${CFLAGS:-default}  LDFLAGS=${LDFLAGS:-default}"
( cd "$BUILD_DIR" && "$SRC/configure" --srcdir="$SRC" $CONFIGURE_ARGS )

# ----------------------------------------------------------------------
# macOS post-process: strip Homebrew's -L paths and -l flags from the
# generated Makefile, so libtool can't pull in the .dylib references
# from /opt/homebrew/{libevent,ncurses}/lib/. Our -Wl,-force_load of
# the .a archives above already provides every symbol statically.
#
# Without this, libtool happily links libevent_core-2.1.7.dylib etc.
# in addition to our force-loaded libevent.a — producing a binary
# that depends on Homebrew at runtime. Same pattern as ljh-sh/iperf
# (which strips -lssl -lcrypto from its Makefiles for the same
# reason).
# ----------------------------------------------------------------------
if [ "$OS" = "darwin" ]; then
	echo "==> macOS verify: force_load libevent/ncurses present in link flags"
	grep -q -- "-Wl,-force_load" "$BUILD_DIR/Makefile" \
		|| { echo "FAIL: -Wl,-force_load not in Makefile; libtool may have stripped it" >&2; exit 1; }
	echo "==> macOS post-process: strip -L<homebrew> and -l<libevent/ncurses>"
	( cd "$BUILD_DIR" && \
		find . -name Makefile -print0 | xargs -0 sed -i '' \
			-e 's|-L/opt/homebrew/[^ ]*||g' \
			-e 's|-L/usr/local/[^ ]*||g' \
			-e 's| -levent_core-2-1-0||g' \
			-e 's| -levent_extra-2-1-0||g' \
			-e 's| -levent-2-1-0||g' \
			-e 's| -levent_core||g' \
			-e 's| -levent_extra||g' \
			-e 's| -levent||g' \
			-e 's| -lncursesw||g' \
			-e 's| -lncurses||g' \
			-e 's| -ltinfo||g' \
	)
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
if [ "$OS" = "darwin" ] || [ "$OS" = "linux" ]; then
	strip "$BIN" 2>/dev/null || true
fi

echo "==> built:"
ls -la "$BIN"
file "$BIN" | head -c 200
echo
echo "    version: $("$BIN" -V 2>&1 || "$BIN" -v 2>&1 | head -1)"
