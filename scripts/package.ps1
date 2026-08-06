# Package tmux for Windows: zip archive containing bin/tmux.exe +
# bundled libevent/ncurses DLLs + man page + example config + LICENSE +
# NOTICE + README. Used by build-and-test.yml + release.yml on
# windows-latest after MSYS2 build.
#
# Self-containedness: we copy the libevent + ncurses DLLs that tmux.exe
# depends on (per `ldd tmux.exe`) into bin/ alongside tmux.exe.
# Windows application-local DLL search then finds them at runtime —
# no PATH manipulation, no MSYS2 install required by the end user.
$ErrorActionPreference = 'Stop'

$root    = (Resolve-Path "$PSScriptRoot/..").Path
$target  = $env:TARGET
if (-not $target) { throw 'TARGET env var required (e.g. x86_64-windows)' }

$buildDir = Join-Path $root 'build'
$srcBin   = Join-Path $buildDir 'tmux.exe'
if (-not (Test-Path $srcBin)) { throw "missing: $srcBin (run scripts/build.sh first)" }

$outDir = Join-Path $root "dist/tmux-$target"
if (Test-Path $outDir) { Remove-Item -Recurse -Force $outDir }
$binDir = Join-Path $outDir 'bin'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null

# ─── 1. tmux.exe ────────────────────────────────────────────────────────
Copy-Item $srcBin (Join-Path $binDir 'tmux.exe')

# ─── 2. Bundle libevent + ncurses DLLs alongside tmux.exe ───────────────
# tmux.exe links against these at runtime (per `objdump -p tmux.exe`
# on a mingw64 build). Windows searches the directory of the .exe
# first (SetDefaultDllDirectories + LOAD_LIBRARY_SEARCH_DEFAULT_DIRS
# + SafeProcessSearchPathMode), so co-location makes tmux.exe
# portable without requiring an MSYS2 install.
#
# We discover DLL paths via `ldd tmux.exe` from the MSYS2 shell
# (cross-shell call). Each DLL is copied if not already present.
$dllNames = @(
    'libevent-2-1-0.dll',
    'libevent_core-2-1-0.dll',
    'libevent_extra-2-1-0.dll',
    'libncursesw6.dll',
    'libtinfo6.dll'
)
foreach ($dll in $dllNames) {
    $found = $null
    $mingw64Root = 'C:\msys64\mingw64\bin'
    $candidate   = Join-Path $mingw64Root $dll
    if (Test-Path $candidate) {
        $found = $candidate
    } else {
        # Fall back to PATH search.
        $cmd = Get-Command $dll -ErrorAction SilentlyContinue
        if ($cmd) { $found = $cmd.Source }
    }
    if ($found) {
        Copy-Item $found (Join-Path $binDir $dll) -Force
        Write-Output "    bundle: $dll (from $found)"
    } else {
        Write-Warning "WARN: $dll not found — tmux.exe may fail to start"
    }
}

# ─── 3. Man page + example config ──────────────────────────────────────
$tmuxSrc = Join-Path $root 'upstream/tmux'
New-Item -ItemType Directory -Path (Join-Path $outDir 'man/man1') -Force | Out-Null
Copy-Item (Join-Path $tmuxSrc 'tmux.1')         (Join-Path $outDir 'man/man1/tmux.1')
Copy-Item (Join-Path $tmuxSrc 'example_tmux.conf') (Join-Path $outDir 'example_tmux.conf')

# ─── 4. LICENSE / NOTICE / README ──────────────────────────────────────
Copy-Item (Join-Path $root 'LICENSE')     (Join-Path $outDir 'LICENSE')
Copy-Item (Join-Path $root 'NOTICE.md')   (Join-Path $outDir 'NOTICE.md')
Copy-Item (Join-Path $root 'README.md')   (Join-Path $outDir 'README.md')
Copy-Item (Join-Path $root 'README.cn.md') (Join-Path $outDir 'README.cn.md')

# ─── 5. Zip it up ──────────────────────────────────────────────────────
$zipPath = Join-Path $root "dist/tmux-$target.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($outDir, $zipPath)

$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
"$hash  $(Split-Path $zipPath -Leaf)" | Set-Content -Encoding ascii (Join-Path $root "dist/tmux-$target.zip.sha256")

Write-Output '==> packaged:'
Get-ChildItem $zipPath | Format-Table Name, Length
Get-Content (Join-Path $root "dist/tmux-$target.zip.sha256")
Write-Output ''
Write-Output '==> Layout preview:'
Get-ChildItem $outDir -Recurse | Select-Object FullName | Format-Table -HideTableHeaders
