@echo off
rem tmux.cmd - Windows wrapper for tmux.exe (v0.2.2+)
rem
rem Locates Git Bash via Windows registry and adds its usr/bin to the
rem current process's Win32 PATH so tmux.exe can find msys-2.0.dll via
rem the standard DLL search order. tmux.exe inherits Git Bash's mount
rem table (/etc/fstab), enabling POSIX-style paths (-S /c/Users/foo/...).
rem
rem Requires: Git for Windows (https://git-scm.com/download/win)
rem
rem Used by: scripts/package.ps1 (zipped at zip root, adjacent to bin/)
rem so that 'tmux' resolves to this wrapper (PATHEXT precedence:
rem .EXE > .CMD). Users add the zip root to PATH; this wrapper then
rem execs bin\tmux.exe.

setlocal

rem Locate Git Bash via registry (HKLM 64-bit, then WOW6432Node 32-bit)
set "GIT_BIN="
for /f "tokens=2*" %%i in ('reg query "HKLM\SOFTWARE\GitForWindows" /v InstallPath 2^>nul') do set "GIT_BIN=%%j\usr\bin"
if "%GIT_BIN%"=="" for /f "tokens=2*" %%i in ('reg query "HKLM\SOFTWARE\WOW6432Node\GitForWindows" /v InstallPath 2^>nul') do set "GIT_BIN=%%j\usr\bin"
if not exist "%GIT_BIN%\msys-2.0.dll" (
    echo ERROR: Git Bash not found. Install Git for Windows: https://git-scm.com/download/win 1>&2
    exit /b 1
)

rem Inject Git Bash into current process Win32 PATH so tmux.exe finds
rem Git Bash's msys-2.0.dll via DLL search.
set "PATH=%GIT_BIN%;%PATH%"

rem Exec tmux.exe (adjacent to this wrapper, at <wrapper_dir>\bin\)
"%~dp0bin\tmux.exe" %*

endlocal