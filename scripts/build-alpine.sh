#!/usr/bin/env sh
# Build tmux as a true musl-static binary inside an Alpine container.
# Out-of-tree build into /w/build so host-side state never leaks in.
#
# CI invokes:
#   docker run --rm --platform linux/$ARCH -v "$PWD":/w -w /w \
#     alpine:3.20 sh -c 'apk add --no-cache bash >/dev/null \
#       && bash /w/scripts/build-alpine.sh && bash /w/scripts/smoke.sh'
#
# Alpine's musl + Alpine's gcc → fully static tmux binary that runs on
# Alpine AND every glibc distro (Ubuntu/Debian/Fedora/Arch). The
# resulting binary's only "linkage" is libc.so.6 ⇒ none — `ldd` reports
# "not a dynamic executable".
#
# We delegate to scripts/build.sh (with TMUX_OS_HINT unset so the
# host-Linux branch picks --enable-static), after `apk add`-ing the
# musl-native toolchain + libevent/ncurses dev headers (Alpine's apk
# ships static .a libs for both, so the --enable-static flag in
# tmux's configure can statically link them).
set -eu

echo "==> apk add: build deps (musl-native toolchain + libevent-dev + ncurses-dev)"
apk add --no-cache \
	build-base \
	bash \
	autoconf \
	automake \
	libtool \
	pkgconfig \
	git \
	linux-headers \
	libevent-dev \
	libevent-static \
	ncurses-dev \
	ncurses-static

echo "==> delegate to scripts/build.sh (Linux host → --enable-static)"
exec "$(dirname "$0")/build.sh"
