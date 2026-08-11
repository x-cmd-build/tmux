@echo off
rem tmux-v022-candidate.cmd - v0.2.2 candidate wrapper
rem
rem Hypothesis: bundled msys-2.0.dll is an isolated sandbox that
rem does NOT inherit Git Bash's mount table. Drop the bundle, locate
rem Git Bash via registry, inject its usr/bin into Win32 PATH before
rem exec'ing tmux.exe. tmux.exe then loads Git Bash's DLL (via PATH)
rem which has proper /c, /tmp, etc. mounts.
rem
rem This is the v0.2.2 candidate — must be tested with bundled DLL
rem REMOVED. See scripts/windows-empirical-test.sh for the matrix.

setlocal

rem 1. Locate Git Bash (HKLM first, then WOW6432Node for 32-bit-on-64-bit)
set "GIT_BIN="
for /f "tokens=2*" %%i in ('reg query "HKLM\SOFTWARE\GitForWindows" /v InstallPath 2^>nul') do set "GIT_BIN=%%j\usr\bin"
if "%GIT_BIN%"=="" for /f "tokens=2*" %%i in ('reg query "HKLM\SOFTWARE\WOW6432Node\GitForWindows" /v InstallPath 2^>nul') do set "GIT_BIN=%%j\usr\bin"
if not exist "%GIT_BIN%\msys-2.0.dll" (
    echo ERROR: Git Bash not found. Install Git for Windows: https://git-scm.com/download/win 1>&2
    exit /b 1
)

rem 2. Inject Git Bash into current process PATH
rem    (Win32 DLL search will find Git Bash's msys-2.0.dll here)
set "PATH=%GIT_BIN%;%PATH%"

rem 3. Exec tmux.exe (inherits PATH)
"%~dp0bin\tmux.exe" %*

endlocal