# Package tmux for Windows: zip archive containing bin/tmux.exe +
# bundled runtime DLLs (msys-2.0.dll + libevent + ncurses) + man page +
# example config + LICENSE + NOTICE + README.
#
# Self-containedness: v0.2.0 builds in the MSYS shell with msys gcc,
# so tmux.exe links msys-2.0.dll (the MSYS2 runtime, just like
# MSYS2's official tmux package). End users get a self-extracting
# bundle: extract zip, cd bin, ./tmux.exe - no MSYS2 install needed.
#
# Windows application-local DLL search: tmux.exe is in bin/, and
# Windows searches that directory first for DLL dependencies, so
# co-locating the runtime DLLs alongside the .exe makes the bundle
# portable.
$ErrorActionPreference = 'Stop'

$root    = (Resolve-Path "$PSScriptRoot/..").Path
$target  = $env:TARGET
if (-not $target) { throw 'TARGET env var required (e.g. x86_64-windows)' }

# tmux.exe is built in-tree by build-msys2.sh.
$srcBin = Join-Path $root 'upstream/tmux/tmux.exe'
if (-not (Test-Path $srcBin)) {
    # Fall back to old build/tmux.exe (used by build.sh MSYS2 branch
    # if it ever runs).
    $altBin = Join-Path $root 'build/tmux.exe'
    if (Test-Path $altBin) {
        $srcBin = $altBin
    } else {
        throw "missing: $srcBin (run scripts/build-msys2.sh first)"
    }
}

$outDir = Join-Path $root "dist/tmux-$target"
if (Test-Path $outDir) { Remove-Item -Recurse -Force $outDir }
$binDir = Join-Path $outDir 'bin'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null

# 1. tmux.exe
Copy-Item $srcBin (Join-Path $binDir 'tmux.exe')

# 2. Bundle runtime DLLs alongside tmux.exe. Search order:
#    C:\msys64\usr\bin   (MSYS runtime + MSYS libevent/ncurses)
#    C:\msys64\mingw64\bin (mingw64 libevent/ncurses fallback)
#    PATH (last resort)
$msysRoots = @('C:\msys64\usr\bin', 'C:\msys64\mingw64\bin')
$dllNames = @(
    'msys-2.0.dll',
    'libevent-2-1-0.dll',
    'libevent_core-2-1-0.dll',
    'libevent_extra-2-1-0.dll',
    'libncursesw6.dll',
    'libtinfo6.dll'
)
foreach ($dll in $dllNames) {
    $found = $null
    foreach ($rootDir in $msysRoots) {
        $candidate = Join-Path $rootDir $dll
        if (Test-Path $candidate) {
            $found = $candidate
            break
        }
    }
    if ($null -eq $found) {
        $cmd = Get-Command -Name $dll -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { $found = $cmd.Source }
    }
    if ($found) {
        Copy-Item $found (Join-Path $binDir $dll) -Force
        Write-Output "    bundle: $dll (from $found)"
    } else {
        Write-Warning "WARN: $dll not found, tmux.exe may fail to start"
    }
}

# 3. Man page + example config
$tmuxSrc = Join-Path $root 'upstream/tmux'
New-Item -ItemType Directory -Path (Join-Path $outDir 'man/man1') -Force | Out-Null
Copy-Item (Join-Path $tmuxSrc 'tmux.1')         (Join-Path $outDir 'man/man1/tmux.1')
Copy-Item (Join-Path $tmuxSrc 'example_tmux.conf') (Join-Path $outDir 'example_tmux.conf')

# 4. LICENSE / NOTICE / README
Copy-Item (Join-Path $root 'LICENSE')     (Join-Path $outDir 'LICENSE')
Copy-Item (Join-Path $root 'NOTICE.md')   (Join-Path $outDir 'NOTICE.md')
Copy-Item (Join-Path $root 'README.md')   (Join-Path $outDir 'README.md')
Copy-Item (Join-Path $root 'README.cn.md') (Join-Path $outDir 'README.cn.md')

# 5. Zip it up
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
