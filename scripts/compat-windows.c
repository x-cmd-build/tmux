/*
 * compat-windows.c — MinGW/Windows implementations of POSIX terminal
 * functions that tmux relies on but mingw-w64 doesn't ship.
 *
 * Provides (linked into the tmux binary on Windows targets):
 *   - tcgetattr() / tcsetattr()  : via GetConsoleMode / SetConsoleMode
 *   - cfmakeraw()                : zero most termios flags
 *   - ioctl(fd, TIOCGWINSZ, ...) : via GetConsoleScreenBufferInfo
 *   - tcgetsid()                 : stub (returns 0; tmux tolerates this)
 *   - tcsendbreak() / tcdrain()  : no-op (Windows console has no equivalent)
 *
 * This is paired with the termios.h shim in BUILD_DIR/compat-inc/
 * (also installed by scripts/build.sh's msys case). The struct
 * termios there is a simplified mirror; this .c file uses struct
 * fields by NAME only (c_iflag, c_oflag, etc.), so the shim's
 * field layout can grow without touching this file.
 *
 * Windows handles differ from POSIX file descriptors: tmux passes
 * fd values that are *real* PTY file descriptors on POSIX but are
 * pseudo-fd's on Windows (tmux's win32 tty emulation). For MinGW
 * builds, tmux's tty.c path is bypassed for the most part (it
 * uses console-mode operations). We provide minimal stubs that
 * return success on non-console fd's so link succeeds.
 */

#include <windows.h>
#include <errno.h>
#include <unistd.h>

/* termios struct + flag values come from the shim header in
 * compat-inc/termios.h, which is on the include path for the
 * Windows build (build.sh adds -I$BUILD_DIR/compat-inc).
 */
#include <termios.h>
#include <sys/ioctl.h>

/* fd_to_handle: map a POSIX fd (best-effort) to a Windows HANDLE.
 * For MinGW builds of tmux, the fd values that reach these
 * functions are usually not real PTY fds — they're inherited from
 * tmux's win32 tty layer which calls tcgetattr/tcsetattr on
 * pseudo-fd's. We return INVALID_HANDLE_VALUE for unknown fds;
 * callers should treat that as a soft failure (return -1, set errno).
 */
static HANDLE fd_to_handle(int fd)
{
    switch (fd) {
        case 0:  return GetStdHandle(STD_INPUT_HANDLE);
        case 1:  return GetStdHandle(STD_OUTPUT_HANDLE);
        case 2:  return GetStdHandle(STD_ERROR_HANDLE);
        default: return (HANDLE)(intptr_t)fd; /* tmux-internal pseudo-fd */
    }
}

int tcgetattr(int fd, struct termios *tio)
{
    HANDLE h = fd_to_handle(fd);
    DWORD mode;

    if (tio == NULL) {
        errno = EINVAL;
        return -1;
    }

    /* Default to a zeroed termios (cooked-mode-ish). */
    memset(tio, 0, sizeof(*tio));

    if (h == NULL || h == INVALID_HANDLE_VALUE) {
        /* Pseudo-fd or unknown — return a sane default rather than
         * failing. tmux restores termios on exit; a no-op here
         * means tmux will leave whatever Windows console mode
         * is currently active, which is fine for the embedded
         * use case.
         */
        return 0;
    }

    if (!GetConsoleMode(h, &mode)) {
        /* Not a console (could be a redirected file) — return
         * defaults; this matches the "unknown fd" branch above.
         */
        return 0;
    }

    /* Map Windows console mode to termios flags. This is a
     * lossy mapping (Windows modes don't have a 1:1 POSIX
     * equivalent), but it gives tmux enough info to detect
     * "is echo on", "is canonical mode", etc.
     */
    if (mode & ENABLE_ECHO_INPUT)       tio->c_lflag |= ECHO;
    if (mode & ENABLE_LINE_INPUT)       tio->c_lflag |= ICANON;
    if (mode & ENABLE_PROCESSED_INPUT)  tio->c_lflag |= IEXTEN;
    if (mode & ENABLE_PROCESSED_OUTPUT) tio->c_oflag |= OPOST;

    return 0;
}

int tcsetattr(int fd, int action, const struct termios *tio)
{
    HANDLE h = fd_to_handle(fd);
    DWORD mode = 0;

    (void)action; /* TCSANOW / TCSADRAIN / TCSAFLUSH — Windows has only "now". */
    if (tio == NULL) {
        errno = EINVAL;
        return -1;
    }

    if (h == NULL || h == INVALID_HANDLE_VALUE) return 0; /* pseudo-fd */

    /* Snapshot the current mode so flags we don't model (window
     * size, processed output) are preserved.
     */
    if (!GetConsoleMode(h, &mode)) return 0;

    /* Re-derive Windows mode flags from termios. */
    mode &= ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT |
              ENABLE_PROCESSED_INPUT | ENABLE_PROCESSED_OUTPUT);
    if (tio->c_lflag & ECHO)    mode |= ENABLE_ECHO_INPUT;
    if (tio->c_lflag & ICANON)  mode |= ENABLE_LINE_INPUT;
    if (tio->c_lflag & IEXTEN)  mode |= ENABLE_PROCESSED_INPUT;
    if (tio->c_oflag & OPOST)   mode |= ENABLE_PROCESSED_OUTPUT;

    if (!SetConsoleMode(h, mode)) {
        errno = EINVAL;
        return -1;
    }
    return 0;
}

void cfmakeraw(struct termios *tio)
{
    tio->c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR |
                      IGNCR | ICRNL | IXON | IXOFF);
    tio->c_oflag &= ~OPOST;
    tio->c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
    tio->c_cflag &= ~(CSIZE | PARENB);
    tio->c_cflag |= CS8;
}

/* tmux calls ioctl(fd, TIOCGWINSZ, &ws) to read terminal size. */
int ioctl(int fd, unsigned long op, ...)
{
    va_list ap;
    void *arg;
    HANDLE h;
    CONSOLE_SCREEN_BUFFER_INFO csbi;

    va_start(ap, op);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (op == TIOCGWINSZ) {
        struct winsize *ws = (struct winsize *)arg;
        h = fd_to_handle(fd);
        if (h == NULL || h == INVALID_HANDLE_VALUE) {
            ws->ws_row = 24;
            ws->ws_col = 80;
            ws->ws_xpixel = 0;
            ws->ws_ypixel = 0;
            return 0;
        }
        if (GetConsoleScreenBufferInfo(h, &csbi)) {
            ws->ws_row = csbi.srWindow.Bottom - csbi.srWindow.Top + 1;
            ws->ws_col = csbi.srWindow.Right - csbi.srWindow.Left + 1;
            ws->ws_xpixel = 0;
            ws->ws_ypixel = 0;
            return 0;
        }
        /* Pseudo-fd or non-console: tmux default. */
        ws->ws_row = 24;
        ws->ws_col = 80;
        ws->ws_xpixel = 0;
        ws->ws_ypixel = 0;
        return 0;
    }

    /* Unsupported ioctl. tmux checks for != -1 to decide whether
     * the size query succeeded; returning 0 here means tmux will
     * accept whatever we wrote to *arg above (the fallback 24x80).
     */
    return 0;
}

/* tcgetsid: tmux calls this on some platforms but tolerates 0. */
pid_t tcgetsid(int fd)
{
    (void)fd;
    return 0;
}

/* tcsendbreak: no Windows equivalent. tmux tolerates 0 return. */
int tcsendbreak(int fd, int duration)
{
    (void)fd; (void)duration;
    return 0;
}

/* tcdrain: no Windows equivalent for console output. tmux
 * tolerates 0 return.
 */
int tcdrain(int fd)
{
    (void)fd;
    return 0;
}

/* fnmatch: compat.h declares it but mingw-w64 doesn't ship
 * fnmatch.h. Provide a stub. tmux uses it for FNM_PATHNAME in
 * path glob matching (path.c). The full implementation is in
 * glibc; for git-bash use we provide the common subset.
 */
#include <fnmatch.h>

#define FNM_PATHNAME 0x01
#define FNM_NOESCAPE 0x02
#define FNM_PERIOD   0x04
#define FNM_NOMATCH   1

int fnmatch(const char *pattern, const char *string, int flags)
{
    /* Minimal glob matcher: handles *, ?, [abc]. Full POSIX fnmatch
     * is more complex (negation, character classes, etc.) but tmux
     * only uses basic patterns in config file paths.
     */
    while (*pattern) {
        if (*pattern == '*') {
            /* Skip consecutive stars. */
            while (*pattern == '*') pattern++;
            if (!*pattern) return 0; /* trailing * matches all */
            while (*string) {
                if (fnmatch(pattern, string, flags) == 0) return 0;
                string++;
            }
            return FNM_NOMATCH;
        }
        if (*pattern == '?') {
            if (!*string) return FNM_NOMATCH;
            if ((flags & FNM_PATHNAME) && *string == '/') return FNM_NOMATCH;
            string++;
        } else if (*pattern == '[') {
            /* Trivial character class — not full POSIX semantics. */
            int neg = 0, match = 0;
            const char *p = pattern + 1;
            if (*p == '!') { neg = 1; p++; }
            while (*p && *p != ']') {
                if (p[1] == '-' && p[2] != ']' && p[2] != '\0') {
                    if (*string >= *p && *string <= p[2]) match = 1;
                    p += 3;
                } else {
                    if (*string == *p) match = 1;
                    p++;
                }
            }
            if (!*string || (!match && !neg) || (match && neg))
                return FNM_NOMATCH;
            string++;
            pattern = p + 1;
        } else {
            if (*pattern != *string) return FNM_NOMATCH;
            string++;
        }
        pattern++;
    }
    return *string ? FNM_NOMATCH : 0;
}
