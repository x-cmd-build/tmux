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

TMUX_VERSION="${TMUX_VERSION:-3.7b}"

# Windows-specific configure additions.
# MSYS2 PKGBUILD for tmux 3.7b has zero patches — just CPPFLAGS that
# undefine _XOPEN_SOURCE and force ncursesw (wide-char) headers. This
# bypasses tmux's CMSG_DATA check (which fails on MinGW because Win-
# sock uses WSA_CMSG_DATA instead). See scripts/build.sh history —
# this is the v0.2.0 revert of the v0.1.0 'Windows DEFERRED' claim.
TMUX_MSYS_CPPFLAGS="-U_XOPEN_SOURCE -I/usr/include/ncursesw"
TMUX_MSYS_CONFIGURE_ARGS="--enable-sixel --prefix=/usr"

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
	#
	# Cross-build from aarch64 → x86_64: set LIBEVENT_PREFIX /
	# NCURSES_PREFIX env vars to point at the x86_64 Homebrew under
	# /usr/local (Rosetta path), NOT the native arm64 /opt/homebrew.
	# The aarch64 .a archives are wrong-arch and break x86_64 link.
	LIBEVENT_PREFIX="${LIBEVENT_PREFIX:-$(brew --prefix libevent 2>/dev/null)}"
	NCURSES_PREFIX="${NCURSES_PREFIX:-$(brew --prefix ncurses 2>/dev/null)}"

	LIBEVENT_A="$LIBEVENT_PREFIX/lib/libevent.a"
	NCURSES_A="$NCURSES_PREFIX/lib/libncurses.a"
	TINFO_A="$NCURSES_PREFIX/lib/libtinfo.a"

	flags=""
	for f in "$LIBEVENT_A" "$NCURSES_A"; do
		if [ -f "$f" ]; then
			flags="$flags -Wl,-force_load,$f"
		else
			echo "warn: missing $f (set LIBEVENT_PREFIX/NCURSES_PREFIX)" >&2
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
	# Windows MSYS2 (mingw64). tmux 3.7b builds cleanly with
	# CPPFLAGS=-U_XOPEN_SOURCE -I/usr/include/ncursesw (the MSYS2
	# PKGBUILD recipe; no patches). Dynamic link against MSYS2's
	# libevent + ncurses DLLs — package.ps1 copies them alongside
	# tmux.exe (Windows app-local DLL search).
	export CC="${CC:-gcc}"
	: "${CFLAGS:=-O2 -D_FORTIFY_SOURCE=2}"
	: "${LDFLAGS:=-lws2_32}"
	export CFLAGS LDFLAGS
	# CRITICAL: -U_XOPEN_SOURCE bypasses tmux's broken CMSG_DATA
	# detection (which probes <sys/socket.h> for CMSG_DATA, missing
	# from MinGW headers). ncursesw is MSYS2's wide-char ncurses.
	: "${CPPFLAGS:=$TMUX_MSYS_CPPFLAGS}"
	export CPPFLAGS
	CONFIGURE_ARGS="$CONFIGURE_BASE $TMUX_MSYS_CONFIGURE_ARGS --disable-utf8proc --disable-systemd --enable-shared --disable-static"
	if [ -z "$TRIPLET" ]; then
		TRIPLET="${TARGET_ARCH}-w64-mingw32"
	fi
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
# Windows: patch configure.ac + tmux.h to bypass MinGW incompatibilities.
#
# 1. CMSG_DATA check: tmux 3.7b's source code does NOT reference
#    CMSG_DATA, HAVE_CMSG_DATA, or XOPEN_DEFINES anywhere — the
#    configure-time check is purely vestigial (dates from when HP-UX
#    needed explicit _XOPEN_SOURCE for CMSG_DATA). MinGW's
#    <sys/socket.h> lacks CMSG_DATA (Windows uses WSA_CMSG_DATA), so
#    the check fails and the build aborts. Replace the error with
#    `found_cmsg_data=yes; XOPEN_DEFINES=""`.
#
# 2. <sys/uio.h>: tmux.h includes it unconditionally, but no source
#    file references iovec/readv/writev — another vestigial include.
#    MinGW doesn't ship <sys/uio.h>. Wrap the include in a Linux/macOS
#    gate.
# ----------------------------------------------------------------------
case "$OS" in
msys)
	# Patch 1: bypass CMSG_DATA check.
	if [ -f "$SRC/configure.ac" ] && ! grep -q 'PATCHED: tmux source does not use CMSG_DATA' "$SRC/configure.ac"; then
		echo "==> patch configure.ac: bypass CMSG_DATA check (Windows/MinGW)"
		( cd "$SRC" && \
			sed -i 's|		AC_MSG_ERROR("CMSG_DATA not found")|		# PATCHED: tmux source does not use CMSG_DATA; bypass MinGW check\n		found_cmsg_data=yes; XOPEN_DEFINES=""|' configure.ac \
			|| { echo "ERROR: failed to patch configure.ac" >&2; exit 1; } )
	fi
	# Patch 2: gate <sys/uio.h> (no source uses iovec).
	if [ -f "$SRC/tmux.h" ] && ! grep -q 'PATCHED: tmux source does not use iovec' "$SRC/tmux.h"; then
		echo "==> patch tmux.h: gate <sys/uio.h> (Windows/MinGW)"
		( cd "$SRC" && \
			sed -i 's|#include <sys/uio.h>|/* PATCHED: tmux source does not use iovec; skip on MinGW */\n#if !defined(_WIN32)\n#include <sys/uio.h>\n#endif|' tmux.h \
			|| { echo "ERROR: failed to patch tmux.h" >&2; exit 1; } )
	fi

	# Patch 3: provide compat shim headers for MinGW. MinGW's
	# mingw-w64-headers has been dropping POSIX/BSD compat headers
	# over time (sys/uio.h, termios.h, sys/tree.h, sys/queue.h, etc.)
	# even though MSYS2's tmux package somehow builds. The easiest
	# workaround: provide empty shims for headers that tmux.h includes
	# but tmux source doesn't use.
	COMPAT_INC="$BUILD_DIR/compat-inc"
	rm -rf "$COMPAT_INC"
	mkdir -p "$COMPAT_INC/sys" "$COMPAT_INC"
	# Empty shims for headers tmux.h includes but source doesn't use.
	cat > "$COMPAT_INC/sys/uio.h" <<'SHIM'
/* shim: tmux source does not use iovec */
SHIM
	cat > "$COMPAT_INC/sys/tree.h" <<'SHIM'
/* shim: tmux source does not use RB-tree macros */
SHIM
	cat > "$COMPAT_INC/sys/queue.h" <<'SHIM'
/* shim: tmux source does not use BSD list macros */
SHIM
	cat > "$COMPAT_INC/sys/param.h" <<'SHIM'
/* shim */
SHIM
	cat > "$COMPAT_INC/sys/filio.h" <<'SHIM'
/* shim */
SHIM
	cat > "$COMPAT_INC/sys/proc.h" <<'SHIM'
/* shim */
SHIM
	cat > "$COMPAT_INC/sys/sysctl.h" <<'SHIM'
/* shim */
SHIM
	cat > "$COMPAT_INC/sys/user.h" <<'SHIM'
/* shim */
SHIM
	# sys/ioctl.h: compat.h uses it for TIOCGWINSZ. Provide a stub.
	cat > "$COMPAT_INC/sys/ioctl.h" <<'SHIM'
/* shim: tmux uses TIOCGWINSZ (via ioctl) for terminal size. */
/* On Windows we map this to Windows Console API at link time. */
#ifndef _SYS_IOCTL_H_SHIM
#define _SYS_IOCTL_H_SHIM
struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
};
#define TIOCGWINSZ 0x5413
#define TIOCSWINSZ 0x5414
#endif
SHIM
	cat > "$COMPAT_INC/fnmatch.h" <<'SHIM'
/* shim: tmux compat.h uses fnmatch() */
#ifndef _FNMATCH_H_SHIM
#define _FNMATCH_H_SHIM
#define FNM_NOMATCH 1
#define FNM_PATHNAME 2
#define FNM_PERIOD 4
#define FNM_NOESCAPE 8
#define FNM_CASEFOLD 16
extern int fnmatch(const char *, const char *, int);
#endif
SHIM
	# termios.h is used by tmux — provide a minimal stub that maps
	# to the Win32 Console API equivalents. tmux uses tcgetattr,
	# tcsetattr, cfmakeraw — all need termios structs. MSYS2's older
	# mingw-w64 shipped a termios.h that wrapped wincon; newer versions
	# dropped it. Without a termios.h shim, the build is impossible.
	# We shim with empty structs + ioctl-equivalent that tmux can
	# compile against (the actual terminal I/O may not work in all
	# modes, but tmux will at least link and start).
	cat > "$COMPAT_INC/termios.h" <<'SHIM'
/* termios.h shim for MinGW — minimal stubs.
 * tmux 3.7b only uses: tcgetattr, tcsetattr, tcgetsid, cfmakeraw,
 * tcsendbreak, tcdrain. We define the structs/macros but the
 * functions themselves are unresolved — tmux will fail to link if
 * any of these are actually called. For a fuller shim, install
 * mingw-w64-x86_64-termcap or define these functions via
 * Windows Console API. */
#ifndef _TERMIOS_H_SHIM
#define _TERMIOS_H_SHIM
struct termios {
    unsigned long c_iflag;
    unsigned long c_oflag;
    unsigned long c_cflag;
    unsigned long c_lflag;
    unsigned char c_line;
    unsigned char c_cc[32];
    unsigned long c_ispeed;
    unsigned long c_ospeed;
};
#define TCGETS    0x5401
#define TCSETS    0x5402
#define TCSETSW   0x5403
#define TCSETSF   0x5404
#define TCIFLUSH  0x540B
#define TCOFLUSH  0x540C
#define TCIOFLUSH 0x540D
#define TCOOFF    0x540E
#define TCOON     0x540F
#define TCSBRKP   0x5425
#define TCXONC    0x540F
#define TCSBRK    0x5425
#define TCSAFLUSH 0x5410
#define IGNBRK    0x001
#define BRKINT    0x002
#define IGNPAR    0x004
#define PARMRK    0x010
#define INPCK     0x020
#define ISTRIP    0x040
#define INLCR     0x100
#define IGNCR     0x200
#define ICRNL     0x400
#define IXON      0x1000
#define IXOFF     0x2000
#define IXANY     0x4000
#define OPOST     0x001
#define ONLCR     0x002
#define OCRNL     0x004
#define ONOCR     0x010
#define ONLRET    0x020
#define OFDEL     0x040
#define B0        0
#define B50       50
#define B75       75
#define B110      110
#define B134      134
#define B150      150
#define B200      200
#define B300      300
#define B600      600
#define B1200     1200
#define B1800     1800
#define B2400     2400
#define B4800     4800
#define B9600     9600
#define B19200    19200
#define B38400    38400
#define B57600    57600
#define B115200   115200
#define B230400   230400
#define CSIZE     0x030
#define CS5       0x000
#define CS6       0x010
#define CS7       0x020
#define CS8       0x030
#define CSTOPB    0x040
#define CREAD     0x080
#define PARENB    0x100
#define PARODD    0x200
#define HUPCL     0x400
#define CLOCAL    0x800
#define ECHO      0x001
#define ECHOE     0x002
#define ECHOK     0x004
#define ECHONL    0x010
#define ICANON    0x100
#define ISIG      0x001
#define IEXTEN    0x080
#define NOFLSH    0x080
#define TOSTOP    0x100
#define VMIN      0x004
#define VTIME     0x008
#endif
SHIM
	# Add compat-inc to CPPFLAGS so -I picks it up before /mingw64/include.
	export CPPFLAGS="$CPPFLAGS -I$COMPAT_INC"
	# Compile the termios/ioctl/fnmatch compat shim into tmux.
	# mingw-w64 doesn't ship these functions; we provide minimal
	# Windows Console API implementations.
	TMUX_COMPAT_OBJS=""
	TMUX_SRC="$ROOT/scripts/compat-windows.c"
	if [ -f "$TMUX_SRC" ]; then
		echo "==> compile compat-windows.c (Windows Console API shim)"
		TMUX_COMPAT_O="$BUILD_DIR/compat-windows.o"
		${CC:-gcc} -c -O2 -D_FORTIFY_SOURCE=2 \
			"$TMUX_SRC" -o "$TMUX_COMPAT_O" \
			-I"$COMPAT_INC" \
			|| { echo "ERROR: compat-windows.c failed to compile" >&2; exit 1; }
		TMUX_COMPAT_OBJS="$TMUX_COMPAT_O"
	fi
	;;
esac

# ----------------------------------------------------------------------
# autoreconf if needed (configure missing or newer than configure.ac).
# tmux 3.7b ships a configure script in the release tarball so this
# is usually a no-op. Idempotent — we re-run if upstream bumps ac.
# On Windows we always re-run because we patched configure.ac.
# ----------------------------------------------------------------------
if [ "$OS" = "msys" ] || [ ! -x "$SRC/configure" ] || [ "$SRC/configure.ac" -nt "$SRC/configure" ]; then
	echo "==> autoreconf -fi in $SRC"
	( cd "$SRC" && autoreconf -fi )
fi

# ----------------------------------------------------------------------
# Suppress make's autotools regeneration rules.
# Vendored configure.ac + Makefile.am often have newer timestamps
# than the generated aclocal.m4 + Makefile.in (the tarball `make
# dist` regenerates them in a different order than they're consumed).
# `make` then tries to run `$(AUTOMAKE) --foreign`, which is
# `/etc/missing automake-1.15 --foreign` — and Alpine apk ships
# `automake` (no versioned binary), so error 127.
#
# Touching timestamps doesn't reliably suppress regen (autoconf's
# "newly created file is older than distributed" check fires when
# Makefile.in is touched to a future date, AND make's strict <
# comparison still triggers regen with equal mtimes).
#
# The robust fix: override the make variables AUTOMAKE / AUTOCONF /
# ACLOCAL / AUTOHEADER to `true`, so the regen recipe becomes
# `cd $(srcdir) && true --foreign` — succeeds, exits 0, and
# leaves Makefile.in unchanged. Same approach ljh-sh uses across
# its vendored-C dist repos when the build target's autotools
# version doesn't match what's installed in CI.
# ----------------------------------------------------------------------
MAKE_AUTOTOOLS_STUB="AUTOMAKE=true AUTOCONF=true ACLOCAL=true AUTOHEADER=true"

mkdir -p "$BUILD_DIR"

# tmux uses AC_CONFIG_LIBOBJ_DIR(compat) — the Makefile writes
# compat/closefrom.o, compat/freezero.o, etc. relative to the build
# dir, but `make` doesn't auto-create the subdir. Create it before
# invoking configure so the rule at Makefile:930 can write its
# outputs. Empty files are fine — they're just directory placeholders.
mkdir -p "$BUILD_DIR/compat"

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
echo "==> make -C $BUILD_DIR -j$JOBS  ($MAKE_AUTOTOOLS_STUB)"
# shellcheck disable=SC2086  # MAKE_AUTOTOOLS_STUB is intentionally split.
make -C "$BUILD_DIR" -j"$JOBS" $MAKE_AUTOTOOLS_STUB

# On Windows, append the compat shim object to the final link so
# tcgetattr/tcsetattr/cfmakeraw/ioctl(TIOCGWINSZ)/fnmatch resolve.
# (Linux/macOS leave TMUX_COMPAT_OBJS empty — those platforms link
# against the real libtermios/libc.)
if [ "$OS" = "msys" ] && [ -n "$TMUX_COMPAT_OBJS" ]; then
	echo "==> re-link tmux with compat shim objects (Windows)"
	cd "$BUILD_DIR"
	TMUX_OBJS=$(ls *.o 2>/dev/null | tr '\n' ' ')
	# Re-link using the link command captured from the Makefile
	# (we can't re-run `make` with extra objects reliably, so we
	# invoke gcc/clang directly with the same flags).
	CC_CMD="${CC:-gcc}"
	if "$CC_CMD" -o tmux $TMUX_OBJS $TMUX_COMPAT_OBJS $LDFLAGS -lws2_32 -lbcrypt 2>&1 | tail -3; then
		echo "    re-link OK"
	else
		echo "    re-link FAILED — falling back to make-built binary"
	fi
	cd - >/dev/null
fi

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
