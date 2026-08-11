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

# 2. Bundle runtime DLLs alongside tmux.exe. Read the full ldd output
#    that build-msys2.sh wrote to dist-dll-deps.txt. Each line is an
#    absolute path to a DLL tmux.exe links. Copy each into bin/.
#
#    Why not name-based search: libevent/ncurses DLLs may live in
#    /usr/lib, /usr/bin, /mingw64/bin depending on repo + version.
#    The build step already resolved them via ldd, so we trust that.
$depsFile = Join-Path $root 'dist-dll-deps.txt'
if (Test-Path $depsFile) {
    Get-Content $depsFile | ForEach-Object {
        $src = $_.Trim()
        if ($src -and (Test-Path $src)) {
            $name = Split-Path $src -Leaf
            Copy-Item $src (Join-Path $binDir $name) -Force
            Write-Output "    bundle: $name (from $src)"
        } else {
            Write-Warning "WARN: ldd entry not found: $src"
        }
    }
} else {
    Write-Warning "WARN: $depsFile not found - skipping DLL bundle. Run scripts/build-msys2.sh first."
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

# 5. tmux.cmd wrapper (Windows only). Placed at zip root, NOT in bin/:
#    PATHEXT precedence (.EXE > .CMD) means `tmux` resolves to tmux.exe
#    directly if both are co-located. Users add the zip root to PATH so
#    `tmux` invokes this wrapper, which sets TMPDIR and execs bin\tmux.exe.
$wrapperSrc = Join-Path $root 'scripts/tmux.cmd'
if (Test-Path $wrapperSrc) {
    Copy-Item $wrapperSrc (Join-Path $outDir 'tmux.cmd')
} else {
    Write-Warning "WARN: $wrapperSrc not found - skipping tmux.cmd wrapper"
}

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
