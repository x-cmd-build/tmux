@echo off
rem tmux.cmd - Windows wrapper for tmux.exe (v0.2.1+)
rem
rem Why: bare cmd.exe / PowerShell runs of the bundled tmux.exe fail
rem with "no suitable socket path" - the bundled msys-2.0.dll has
rem no /etc/fstab, so realpath("/tmp") returns NULL. tmux's
rem make_label() (upstream/tmux/tmux.c:187) calls expand_paths() on
rem $TMUX_TMPDIR and /tmp; both fail realpath() on bare Windows ->
rem n=0 -> error.
rem
rem Fix: set TMPDIR to a real existing directory before exec.
rem
rem Placement note: this wrapper must NOT be co-located with
rem tmux.exe. PATHEXT precedence (.EXE > .CMD) means typing `tmux`
rem would resolve to tmux.exe directly if both are present. Place
rem this at the zip ROOT; tmux.exe stays in bin/. Users add the
rem zip root to PATH so `tmux` resolves to this wrapper, which
rem then execs bin\tmux.exe.
rem
rem Used by: scripts/package.ps1 (zipped at zip root, alongside
rem LICENSE / NOTICE / README - NOT inside bin/).

setlocal
if not defined TMPDIR set "TMPDIR=%USERPROFILE%\AppData\Local\Temp"
if not exist "%TMPDIR%" mkdir "%TMPDIR%"
"%~dp0bin\tmux.exe" %*
endlocal