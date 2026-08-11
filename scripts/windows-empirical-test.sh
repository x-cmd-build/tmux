#!/usr/bin/env bash
# scripts/windows-empirical-test.sh
#
# Empirical Windows tmux behavior validation. Runs on a Windows runner
# with bash (Git Bash) available; captures ground-truth behavior of
# v0.2.1's tmux.exe under various configurations so design decisions
# are based on measured data, not theory.
#
# Called by: .github/workflows/windows-empirical-test.yml (dispatch only)
#
# Each scenario records: scenario name, status (PASS/FAIL/SKIP), exit
# code. Aggregated results go to $GITHUB_STEP_SUMMARY for easy review.

set -u

TMUX_ROOT="${TMUX_ROOT:-$(pwd)/tmux}"
GIT_BIN="${GIT_BIN:-}"
# Map Git Bash's POSIX bin path (if set) to a Windows path tmux.exe
# can resolve. Example: /c/Program Files/Git/usr/bin -> C:\Program Files\Git\usr\bin
if [ -n "$GIT_BIN" ] && command -v cygpath >/dev/null 2>&1; then
    GIT_BIN_WIN="$(cygpath -w "$GIT_BIN")"
else
    GIT_BIN_WIN="$GIT_BIN"
fi

declare -a RESULTS

record() {
    local scenario="$1"
    local status="$2"
    local detail="$3"
    RESULTS+=("$scenario | $status | $detail")
    echo "RESULT: $scenario | $status | $detail"
}

run_scenario() {
    local scenario="$1"
    local cmd="$2"
    local cleanup="${3:-}"

    echo "=== $scenario ==="
    echo "CMD: $cmd"

    # Capture stdout+stderr, exit code
    local output
    local exit_code
    output=$(eval "$cmd" 2>&1)
    exit_code=$?

    echo "EXIT: $exit_code"
    if [ -n "$output" ]; then
        echo "OUTPUT:"
        echo "$output"
    fi
    echo ""

    if [ "$exit_code" -eq 0 ]; then
        record "$scenario" "PASS" "exit=0"
    else
        record "$scenario" "FAIL" "exit=$exit_code"
    fi

    # Optional cleanup command
    if [ -n "$cleanup" ]; then
        eval "$cleanup" 2>/dev/null || true
    fi
}

# Pre-clean state
taskkill //F //IM tmux.exe 2>/dev/null || true
sleep 1
rm -rf "$HOME/.tmux-s"* "$TEMP/.tmux-s"* 2>/dev/null || true
rm -rf "$USERPROFILE/.tmux-s"* 2>/dev/null || true

# Ensure tmux.exe + wrapper are on PATH
export PATH="$TMUX_ROOT/bin:$PATH"
# Clear any stale TMUX env var
unset TMUX

# === S1: Sanity — does tmux.exe even start with bundled DLL? ===
run_scenario "S1-sanity" \
    "'$TMUX_ROOT/bin/tmux.exe' -V"

# === S2: Basic new-session with TMPDIR set (mimics what tmux.cmd does) ===
TMPDIR="$USERPROFILE/AppData/Local/Temp" \
run_scenario "S2-new-session-TMPDIR-set" \
    "echo 'ENV: TMPDIR='\"\${TMPDIR:-unset}\"' HOME='\"\${HOME:-unset}\"' USERPROFILE='\"\${USERPROFILE:-unset}\"'; '$TMUX_ROOT/bin/tmux.exe' -L s2 new-session -d && '$TMUX_ROOT/bin/tmux.exe' -L s2 list-sessions && '$TMUX_ROOT/bin/tmux.exe' -L s2 kill-server"

# === S3: tmux.cmd wrapper (current v0.2.1 design) ===
run_scenario "S3-tmux-cmd-wrapper" \
    "'$TMUX_ROOT/tmux.cmd' -L s3 new-session -d && '$TMUX_ROOT/bin/tmux.exe' -L s3 list-sessions && '$TMUX_ROOT/bin/tmux.exe' -L s3 kill-server"

# === S3b: tmux.cmd wrapper with HOME set (hypothesis: wrapper needs to set HOME for /c mount) ===
HOME="$USERPROFILE" run_scenario "S3b-tmux-cmd-wrapper-HOME-set" \
    "'$TMUX_ROOT/tmux.cmd' -L s3b new-session -d && '$TMUX_ROOT/bin/tmux.exe' -L s3b list-sessions && '$TMUX_ROOT/bin/tmux.exe' -L s3b kill-server"

# === S4: -S with Windows-style absolute path (mixed separators) ===
SOCK_S4="$USERPROFILE/.tmux-s4-test/default"
rm -rf "$USERPROFILE/.tmux-s4-test" 2>/dev/null
mkdir -p "$USERPROFILE/.tmux-s4-test" 2>/dev/null
run_scenario "S4-S-Windows-path" \
    "'$TMUX_ROOT/bin/tmux.exe' -S '$SOCK_S4' new-session -d && '$TMUX_ROOT/bin/tmux.exe' -S '$SOCK_S4' list-sessions && '$TMUX_ROOT/bin/tmux.exe' -S '$SOCK_S4' kill-server" \
    "rm -rf '$USERPROFILE/.tmux-s4-test'"

# === S4b: -S with pure Windows path (all backslashes, no POSIX mixed) ===
SOCK_S4b_WIN="C:\\Users\\runneradmin\\.tmux-s4b-test\\default"
SOCK_S4b_POSIX="/c/Users/runneradmin/.tmux-s4b-test/default"
rm -rf "$USERPROFILE/.tmux-s4b-test" 2>/dev/null
mkdir -p "$USERPROFILE/.tmux-s4b-test" 2>/dev/null
run_scenario "S4b-S-Windows-backslashes" \
    "'$TMUX_ROOT/bin/tmux.exe' -S 'C:\\Users\\runneradmin\\.tmux-s4b-test\\default' new-session -d && '$TMUX_ROOT/bin/tmux.exe' -S 'C:\\Users\\runneradmin\\.tmux-s4b-test\\default' list-sessions && '$TMUX_ROOT/bin/tmux.exe' -S 'C:\\Users\\runneradmin\\.tmux-s4b-test\\default' kill-server" \
    "rm -rf '$USERPROFILE/.tmux-s4b-test'"

# === S4c: -S with POSIX /c path (the format S5 used and passed) ===
run_scenario "S4c-S-POSIX-c-path" \
    "'$TMUX_ROOT/bin/tmux.exe' -S '$SOCK_S4b_POSIX' new-session -d && '$TMUX_ROOT/bin/tmux.exe' -S '$SOCK_S4b_POSIX' list-sessions && '$TMUX_ROOT/bin/tmux.exe' -S '$SOCK_S4b_POSIX' kill-server" \
    "rm -rf '$USERPROFILE/.tmux-s4b-test'"

# === S9: Option B + wrapper (hypothesis: wrapper that injects Git Bash PATH + tmux.cmd contents) ===
if [ -n "$GIT_BIN_WIN" ] && [ -f "$GIT_BIN_WIN/msys-2.0.dll" ]; then
    PATH_WITH_GIT="$GIT_BIN_WIN:$TMUX_ROOT/bin:$PATH"
    rm -rf "$TMUX_ROOT/bin/msys-2.0.dll" 2>/dev/null
    # Enhanced wrapper that uses Git Bash DLL via PATH injection
    run_scenario "S9-no-bundle-wrapper-enhanced" \
        "PATH='$PATH_WITH_GIT' '$TMUX_ROOT/bin/tmux.exe' -L s9 new-session -d && PATH='$PATH_WITH_GIT' '$TMUX_ROOT/bin/tmux.exe' -L s9 list-sessions && PATH='$PATH_WITH_GIT' '$TMUX_ROOT/bin/tmux.exe' -L s9 kill-server"
    # Restore bundle
    if [ -f "$TMUX_ROOT/bin/msys-2.0.dll.bak" ]; then
        mv "$TMUX_ROOT/bin/msys-2.0.dll.bak" "$TMUX_ROOT/bin/msys-2.0.dll"
    fi
else
    record "S9-no-bundle-wrapper-enhanced" "SKIP" "GIT_BIN not detected"
fi

# === S5: -S with HOME-derived POSIX path (expected to FAIL with bundled DLL) ===
SOCK_S5="$HOME/.tmux-s5-test/default"
rm -rf "$HOME/.tmux-s5-test" 2>/dev/null
mkdir -p "$HOME/.tmux-s5-test" 2>/dev/null
run_scenario "S5-S-HOME-POSIX-path" \
    "'$TMUX_ROOT/bin/tmux.exe' -S '$SOCK_S5' new-session -d" \
    "rm -rf '$HOME/.tmux-s5-test'"

# === S6: Delete bundled DLL, Git Bash on Win32 PATH, tmux.exe -V ===
if [ -n "$GIT_BIN_WIN" ] && [ -f "$GIT_BIN_WIN/msys-2.0.dll" ]; then
    # Backup + delete bundle
    if [ -f "$TMUX_ROOT/bin/msys-2.0.dll" ]; then
        mv "$TMUX_ROOT/bin/msys-2.0.dll" "$TMUX_ROOT/bin/msys-2.0.dll.bak"
    fi

    # PATH with Git Bash FIRST (so its DLL is found before any system one)
    PATH_WITH_GIT="$GIT_BIN_WIN:$TMUX_ROOT/bin:$PATH"

    run_scenario "S6-no-bundle-gitbash-V" \
        "PATH='$PATH_WITH_GIT' '$TMUX_ROOT/bin/tmux.exe' -V"

    # === S7: Same config, -S with HOME path (should now work with Git Bash's fstab) ===
    SOCK_S7="$HOME/.tmux-s7-test/default"
    rm -rf "$HOME/.tmux-s7-test" 2>/dev/null
    mkdir -p "$HOME/.tmux-s7-test" 2>/dev/null
    run_scenario "S7-no-bundle-gitbash-S-HOME" \
        "PATH='$PATH_WITH_GIT' '$TMUX_ROOT/bin/tmux.exe' -S '$SOCK_S7' new-session -d && PATH='$PATH_WITH_GIT' '$TMUX_ROOT/bin/tmux.exe' -S '$SOCK_S7' list-sessions && PATH='$PATH_WITH_GIT' '$TMUX_ROOT/bin/tmux.exe' -S '$SOCK_S7' kill-server" \
        "rm -rf '$HOME/.tmux-s7-test'"

    # === S8: Same config, basic new-session (should work) ===
    run_scenario "S8-no-bundle-gitbash-new-session" \
        "PATH='$PATH_WITH_GIT' '$TMUX_ROOT/bin/tmux.exe' -L s8 new-session -d && PATH='$PATH_WITH_GIT' '$TMUX_ROOT/bin/tmux.exe' -L s8 list-sessions && PATH='$PATH_WITH_GIT' '$TMUX_ROOT/bin/tmux.exe' -L s8 kill-server"

    # Restore bundle
    if [ -f "$TMUX_ROOT/bin/msys-2.0.dll.bak" ]; then
        mv "$TMUX_ROOT/bin/msys-2.0.dll.bak" "$TMUX_ROOT/bin/msys-2.0.dll"
    fi
else
    record "S6-no-bundle-gitbash-V" "SKIP" "GIT_BIN not detected ($GIT_BIN_WIN)"
    record "S7-no-bundle-gitbash-S-HOME" "SKIP" "depends on S6"
    record "S8-no-bundle-gitbash-new-session" "SKIP" "depends on S6"
fi

# === Summary ===
echo ""
echo "=== SUMMARY ==="
PASS=0;FAIL_C=0;SKIP=0
for r in "${RESULTS[@]}"; do
    echo "$r"
    case "$r" in
        *" | PASS |"*) PASS=$((PASS+1)) ;;
        *" | FAIL |"*) FAIL_C=$((FAIL_C+1)) ;;
        *" | SKIP |"*) SKIP=$((SKIP+1)) ;;
    esac
done
echo ""
echo "Total: PASS=$PASS FAIL=$FAIL_C SKIP=$SKIP"

# Write structured summary
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "## Windows empirical test results"
        echo ""
        echo "| Scenario | Status | Detail |"
        echo "|----------|--------|--------|"
        for r in "${RESULTS[@]}"; do
            s=$(echo "$r" | awk -F' \\| ' '{print $1}')
            st=$(echo "$r" | awk -F' \\| ' '{print $2}')
            d=$(echo "$r" | awk -F' \\| ' '{print $3}')
            echo "| \`$s\` | $st | $d |"
        done
        echo ""
        echo "**Total**: PASS=$PASS FAIL=$FAIL_C SKIP=$SKIP"
    } >> "$GITHUB_STEP_SUMMARY"
fi