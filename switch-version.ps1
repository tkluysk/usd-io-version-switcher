#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

$ScriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$LocalBuildsDir = Join-Path $ScriptDir 'builds'
$DriveRelPath   = 'My Drive\Projects & Clients\JCube\Deliverables'
$DriveCacheDir  = Join-Path $ScriptDir '.drive-cache'
# Newly-synced Release zips that Drive for Desktop may not have surfaced on
# the local mount yet — staged by sync-releases.py so the switcher can use
# them immediately. Treated as additional drive-mode entries below.
$IncomingDir    = Join-Path $DriveCacheDir 'incoming'
$SketchUpRoot   = 'C:\Program Files\SketchUp'
# Output folder for generated plugin-only zip packages (gitignored).
$PackagesDir    = Join-Path $ScriptDir 'packages'

$script:BuildsDir       = ''
$script:DriveBuildsDir  = ''
$script:SourceMode      = ''   # 'local' or 'drive'
$script:SketchUpTargets = @()
$script:Versions        = @()
$script:VersionRoots    = @()
$script:ExportersDir    = ''
$script:ImportersDir    = ''

# ── helpers ───────────────────────────────────────────────────────────────────

function Die([string]$msg) {
    Write-Host ""
    Write-Host "ERROR: $msg" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

function Find-DriveBuildsDir {
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        $candidate = Join-Path $drive.RootDirectory.FullName $DriveRelPath
        if (Test-Path $candidate -PathType Container) { return $candidate }
    }
    return $null
}

# SketchUp 2024 has Exporters/Importers directly under the version dir;
# 2026+ nests them under a SketchUp\ subfolder. Returns @(exporters, importers) or $null.
function Get-ExporterImporterDirs([string]$sketchupDir) {
    $nestedExp = Join-Path $sketchupDir 'SketchUp\Exporters'
    $nestedImp = Join-Path $sketchupDir 'SketchUp\Importers'
    if ((Test-Path $nestedExp -PathType Container) -and (Test-Path $nestedImp -PathType Container)) {
        return @($nestedExp, $nestedImp)
    }
    $flatExp = Join-Path $sketchupDir 'Exporters'
    $flatImp = Join-Path $sketchupDir 'Importers'
    if ((Test-Path $flatExp -PathType Container) -and (Test-Path $flatImp -PathType Container)) {
        return @($flatExp, $flatImp)
    }
    return $null
}

# Locate the Python interpreter to drive sync-releases.py: prefer the repo-local
# venv, fall back to whatever python is on PATH. Returns $null if none found.
function Resolve-Python {
    $venvPy = Join-Path $ScriptDir '.venv\Scripts\python.exe'
    if (Test-Path $venvPy) { return $venvPy }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if ($py) { return $py.Source }
    return $null
}

# Optionally pull new SkpXyz releases from the GitLab wiki into Drive so the
# version list below is up to date. Never aborts the switcher on failure.
function Invoke-MaybeSync {
    $syncScript = Join-Path $ScriptDir 'sync-releases.py'
    if (-not (Test-Path $syncScript)) { return }

    $ans = Read-Host "Check GitLab for new versions and sync to Drive? [y/N]"
    if ($ans -notmatch '^[Yy]$') { return }

    $pyPath = Resolve-Python
    if (-not $pyPath) {
        Write-Host "  python not found - skipping version check." -ForegroundColor Yellow
        return
    }

    Write-Host "Checking GitLab for new releases..."
    try {
        & $pyPath $syncScript
        if ($LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE" }
    } catch {
        Write-Host "  (version check failed - continuing with versions already in Drive)" -ForegroundColor Yellow
    }
}

function Select-Source {
    $localOk = Test-Path $LocalBuildsDir -PathType Container
    $script:DriveBuildsDir = Find-DriveBuildsDir
    $driveOk = [bool]$script:DriveBuildsDir

    if ($localOk -and -not $driveOk) {
        $script:SourceMode = 'local'; $script:BuildsDir = $LocalBuildsDir; return
    }
    if ($driveOk -and -not $localOk) {
        $script:SourceMode = 'drive'; $script:BuildsDir = $script:DriveBuildsDir; return
    }
    if (-not $localOk -and -not $driveOk) {
        Die "Neither local builds dir ($LocalBuildsDir) nor a Google Drive mount with '$DriveRelPath' was found."
    }

    Write-Host "Select source:"
    Write-Host "  1) Local builds folder ($LocalBuildsDir)"
    Write-Host "  2) Google Drive ($script:DriveBuildsDir)"
    Write-Host ""
    $choice = Read-Host "Select source [1-2]"
    switch ($choice) {
        '1' { $script:SourceMode = 'local'; $script:BuildsDir = $LocalBuildsDir }
        '2' { $script:SourceMode = 'drive'; $script:BuildsDir = $script:DriveBuildsDir }
        default { Die "Invalid selection: $choice" }
    }
}

function Select-SketchUp {
    $available = @()
    $dirs = Get-ChildItem $SketchUpRoot -Directory -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
        if (Get-ExporterImporterDirs $d.FullName) {
            $available += $d.FullName
        }
    }

    if ($available.Count -eq 0) { Die "No SketchUp installation found in $SketchUpRoot." }

    if ($available.Count -eq 1) {
        $script:SketchUpTargets = $available; return
    }

    Write-Host "Select SketchUp installation:"
    for ($i = 0; $i -lt $available.Count; $i++) {
        Write-Host "  $($i+1)) $($available[$i])"
    }
    Write-Host "  a) All of the above"
    Write-Host ""
    $choice = Read-Host "Select app [1-$($available.Count)/a]"
    if ($choice -eq 'a') {
        $script:SketchUpTargets = $available
    } elseif ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $available.Count) {
        $script:SketchUpTargets = @($available[[int]$choice - 1])
    } else {
        Die "Invalid selection: $choice"
    }
}

# Finds or extracts a win64-Release root dir for a given version folder.
# Returns the path on success, $null on failure.
function Resolve-WindowsRoot([string]$dir) {
    $winDir = Get-ChildItem $dir -Directory -Filter '*win64-Release*' -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if ($winDir) { return $winDir.FullName }

    if ($script:SourceMode -eq 'drive') {
        $zip = Get-ChildItem $dir -File -Filter '*win64-Release*.zip' -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if (-not $zip) { return $null }

        # Use the dir path relative to its source root as a stable cache key.
        # Staged dirs live under $IncomingDir; Drive-mount dirs under $script:BuildsDir.
        if ($dir.StartsWith($IncomingDir, [StringComparison]::OrdinalIgnoreCase)) {
            $label = $dir.Substring($IncomingDir.Length).TrimStart('\')
        } else {
            $label = $dir.Substring($script:BuildsDir.Length).TrimStart('\')
        }
        $cache = Join-Path $DriveCacheDir ($label -replace '\\', '__')
        $winDir = Get-ChildItem $cache -Directory -Filter '*win64-Release*' -ErrorAction SilentlyContinue |
                  Select-Object -First 1
        if (-not $winDir) {
            New-Item -ItemType Directory -Force $cache | Out-Null
            Write-Host "  extracting $($zip.Name) -> .drive-cache\$label\" -ForegroundColor DarkGray
            Expand-Archive -Path $zip.FullName -DestinationPath $cache -Force
            $winDir = Get-ChildItem $cache -Directory -Filter '*win64-Release*' -ErrorAction SilentlyContinue |
                      Select-Object -First 1
        }
        if ($winDir) { return $winDir.FullName }
    }
    return $null
}

function Test-HasWindowsBuild([string]$dir) {
    $hasDir = [bool](Get-ChildItem $dir -Directory -Filter '*win64-Release*' -ErrorAction SilentlyContinue | Select-Object -First 1)
    $hasZip = [bool](Get-ChildItem $dir -File    -Filter '*win64-Release*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1)
    return $hasDir -or $hasZip
}

function Get-Versions {
    $idx  = 1
    $seen = @{}

    # Pre-pass: list staged versions (newly-synced zips that Drive for Desktop
    # may not have surfaced on the local mount yet). Drive mode only.
    if ($script:SourceMode -eq 'drive' -and (Test-Path $IncomingDir)) {
        $stagedDirs = Get-ChildItem $IncomingDir -Directory |
                      Sort-Object { [version]($_.Name -replace '^.*?(\d+\.\d+(\.\d+)*).*$','$1') } -Descending -ErrorAction SilentlyContinue
        foreach ($dir in $stagedDirs) {
            $label = $dir.Name
            if (Test-HasWindowsBuild $dir.FullName) {
                $script:Versions     += $label
                $script:VersionRoots += $dir.FullName
                Write-Host "  $idx) $label"
                $seen[$label] = $true
                $idx++
            }
        }
    }

    $dirs = Get-ChildItem $script:BuildsDir -Directory |
            Sort-Object { [version]($_.Name -replace '^.*?(\d+\.\d+(\.\d+)*).*$','$1') } -Descending -ErrorAction SilentlyContinue

    foreach ($dir in $dirs) {
        $label = $dir.Name
        # Already added from the staging pre-pass — don't list again.
        if ($seen.ContainsKey($label)) { continue }
        # Skip pre-0.4.0
        if ($label -match '\s0\.[0-3]\.' -or $label -match '\s0\.[0-3]$') { continue }

        if ($script:SourceMode -eq 'drive') {
            $added = $false
            if (Test-HasWindowsBuild $dir.FullName) {
                $script:Versions     += $label
                $script:VersionRoots += $dir.FullName
                Write-Host "  $idx) $label"
                $idx++; $added = $true
            }
            if (-not $added) {
                $subs = Get-ChildItem $dir.FullName -Directory | Sort-Object Name
                foreach ($sub in $subs) {
                    $sublabel = "$label / $($sub.Name)"
                    if (Test-HasWindowsBuild $sub.FullName) {
                        $script:Versions     += $sublabel
                        $script:VersionRoots += $sub.FullName
                        Write-Host "  $idx) $sublabel"
                        $idx++
                    }
                }
            }
        } else {
            $winDir = Get-ChildItem $dir.FullName -Directory -Filter '*win64-Release*' -ErrorAction SilentlyContinue |
                      Select-Object -First 1
            if (-not $winDir) { continue }
            $script:Versions     += $label
            $script:VersionRoots += $winDir.FullName
            Write-Host "  $idx) $label"
            $idx++
        }
    }
}

function Get-CurrentVersion {
    $marker = Join-Path $script:ExportersDir '.usd_version'
    if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { '(none)' }
}

# ── removal ───────────────────────────────────────────────────────────────────

function Shorten([string]$path) {
    $path = $path -replace [regex]::Escape($script:BuildsDir + '\'), ''
    $path = $path -replace [regex]::Escape($DriveCacheDir   + '\'), '.drive-cache\'
    $path = $path -replace [regex]::Escape($env:USERPROFILE + '\'), '~\'
    if ($path -match '(SkpXyz-[^\\]+\\.+)') { $path = "...\$($Matches[1])" }
    if ($path -match '.+\\(SketchUp [^\\]+\\SketchUp\\.+)') { $path = "...\$($Matches[1])" }
    return $path
}

function Safe-Remove([string]$path) {
    if (Test-Path $path) {
        Write-Host "  rm $(Shorten $path)"
        Remove-Item $path -Recurse -Force
    }
}

function Remove-InstalledFiles {
    Write-Host "Removing previously installed USD plugin files..."

    foreach ($targetDir in @($script:ExportersDir, $script:ImportersDir)) {
        Safe-Remove (Join-Path $targetDir 'UsdExporter.dll')
        Safe-Remove (Join-Path $targetDir 'UsdImporter.dll')
        Safe-Remove (Join-Path $targetDir 'SkpXyz.dll')
        Safe-Remove (Join-Path $targetDir 'su_usd_ms.dll')
        Safe-Remove (Join-Path $targetDir 'tbb12.dll')
        Safe-Remove (Join-Path $targetDir 'tbbmalloc.dll')
        Safe-Remove (Join-Path $targetDir 'usd')
    }

    Safe-Remove (Join-Path $script:ExportersDir '.usd_version')
    Write-Host "Done removing."
}

# ── installation ──────────────────────────────────────────────────────────────

function Log-Copy([string]$src, [string]$dst) {
    Write-Host "  cp $(Shorten $src) -> $(Shorten $dst)"
    Copy-Item $src $dst -Recurse -Force
}

function Install-04x([string]$root) {
    Write-Host "Installing v0.4.x+ (Exporter & Importer)..."

    $lib = Join-Path $root 'lib'

    Log-Copy (Join-Path $lib 'Exporters\UsdExporter.dll') $script:ExportersDir
    Log-Copy (Join-Path $lib 'Importers\UsdImporter.dll') $script:ImportersDir

    foreach ($targetDir in @($script:ExportersDir, $script:ImportersDir)) {
        Log-Copy (Join-Path $lib 'SkpXyz.dll')    $targetDir
        Log-Copy (Join-Path $lib 'su_usd_ms.dll') $targetDir
        Log-Copy (Join-Path $lib 'tbb12.dll')     $targetDir
        Log-Copy (Join-Path $lib 'tbbmalloc.dll') $targetDir

        $usdDir = Join-Path $lib 'usd'
        if (Test-Path $usdDir) { Log-Copy $usdDir $targetDir }
    }
}

function Install-Version([string]$label, [string]$root) {
    Remove-InstalledFiles
    Install-04x $root
    Set-Content (Join-Path $script:ExportersDir '.usd_version') $label -NoNewline
    Write-Host ""
    Write-Host "Installed: $label -> $(Split-Path -Leaf $sketchupDir)"
}

# ── plugin-only packaging ───────────────────────────────────────────────────────
# Builds zip packages that contain ONLY the files needed to install the
# Importer/Exporter plugin into SketchUp. The standalone Converter (bin/) and
# all dev artefacts (include/, src/, doc/, cmake/, SketchUpAPI, import libs) are
# deliberately excluded, so these packages cannot run conversions outside
# SketchUp.

# Decide whether a build-package entry (path relative to the build root, with
# forward slashes) belongs in a plugin-only package. This is the single source
# of truth for "what is a plugin file" — it mirrors what the switcher installs.
function Test-KeepPluginEntry([string]$rel) {
    foreach ($prefix in @('lib/Exporters/', 'lib/Importers/', 'lib/usd/', 'lib/su_usd/', 'lib/skp_usd/')) {
        if ($rel -eq $prefix -or $rel.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    if ($rel -ieq 'CHANGELOG.md') { return $true }
    # Runtime libraries living directly under lib/ (no further subfolder).
    if ($rel -match '^lib/[^/]+$') {
        $name = $rel.Substring(4)
        $keep = @(
            'SkpXyz.dll', 'su_usd_ms.dll', 'skp_usd_ms.dll', 'tbb12.dll', 'tbbmalloc.dll',
            'libSkpXyz.dylib', 'libsu_usd_ms.dylib', 'libskp_usd_ms.dylib'
        )
        if ($keep -contains $name) { return $true }
        if ($name -match '^libtbb.*\.dylib$') { return $true }
    }
    return $false
}

function Get-PluginInstallText([string]$platform, [string]$version) {
    if ($platform -eq 'Windows') {
        return @"
# SkpXyz USD Plugin for SketchUp - $version (Windows)

This package contains ONLY the SketchUp USD (TUSD) import/export plugin and
its runtime libraries. The standalone command-line Converter is deliberately
NOT included; this package cannot run conversions outside SketchUp.

## Install

Copy the plugin DLLs:

    lib\Exporters\UsdExporter.dll
    lib\Importers\UsdImporter.dll

and the runtime files:

    lib\SkpXyz.dll
    lib\su_usd_ms.dll
    lib\tbb12.dll
    lib\tbbmalloc.dll
    lib\usd\          (the whole folder)

into BOTH the Exporters and Importers folders of your SketchUp install, e.g.:

    C:\Program Files\SketchUp\SketchUp 2026\SketchUp\Exporters
    C:\Program Files\SketchUp\SketchUp 2026\SketchUp\Importers

(Older layouts put these directly under the version dir:
 ...\SketchUp 2024\Exporters and ...\SketchUp 2024\Importers.)

Then launch SketchUp and use File -> Import / Export; choose the TUSD format.
"@
    }
    return @"
# SkpXyz USD Plugin for SketchUp - $version (macOS)

This package contains ONLY the SketchUp USD (TUSD) import/export plugin and
its runtime libraries. The standalone command-line Converter is deliberately
NOT included; this package cannot run conversions outside SketchUp.

## Install

Copy the plugin bundles:

    lib/Exporters/UsdExporter.plugin
    lib/Importers/UsdImporter.plugin

into:

    <SketchUp.app>/Contents/PlugIns

and the runtime libraries:

    lib/libSkpXyz.dylib
    lib/libsu_usd_ms.dylib
    lib/libtbb*.dylib

into:

    <SketchUp.app>/Contents/Frameworks

The Frameworks/usd entry in the SketchUp bundle is a symlink to Resources/usd.
Back up the existing Resources/usd folder (e.g. to Resources/usd-simlab), then
copy this package's

    lib/usd

into <SketchUp.app>/Contents/Resources.

You may need to disable macOS security or codesign the copied binaries. Then
launch SketchUp and use File -> Import / Export; choose the TUSD format.
"@
}

# Filter a source release zip into a plugin-only zip, copying only the kept
# entries. File CONTENT is copied byte-for-byte, so any embedded macOS code
# signatures stay valid. Note: Windows PowerShell's zip writer stamps entries
# with an MS-DOS host, so Unix exec bits are not reproduced when a macOS package
# is built on Windows; that is harmless here (SketchUp dlopen's the plugin
# binaries, which needs only read access, and the kept set has no symlinks), and
# INSTALL.md covers codesigning. A macOS package built by switch-version.sh
# keeps full permissions. Returns the kept count.
function New-PluginZipFromZip([string]$srcZip, [string]$outZip, [string]$topName, [string]$platform, [string]$version) {
    Add-Type -AssemblyName System.IO.Compression | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

    if (Test-Path $outZip) { Remove-Item $outZip -Force }

    $kept = 0
    $src = [System.IO.Compression.ZipFile]::OpenRead($srcZip)
    try {
        $out = [System.IO.Compression.ZipFile]::Open($outZip, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $src.Entries) {
                $slash = $entry.FullName.IndexOf('/')
                if ($slash -lt 0) { continue }                       # skip stray top-level files
                $rel = $entry.FullName.Substring($slash + 1)
                if ([string]::IsNullOrEmpty($rel)) { continue }
                if (-not (Test-KeepPluginEntry $rel)) { continue }

                $newName = "$topName/$rel"
                if ($entry.FullName.EndsWith('/')) {
                    $dst = $out.CreateEntry($newName)
                    $dst.ExternalAttributes = $entry.ExternalAttributes
                    continue
                }
                $dst = $out.CreateEntry($newName, [System.IO.Compression.CompressionLevel]::Optimal)
                $dst.ExternalAttributes = $entry.ExternalAttributes
                $dst.LastWriteTime      = $entry.LastWriteTime
                $si = $entry.Open(); $do = $dst.Open()
                try { $si.CopyTo($do) } finally { $do.Dispose(); $si.Dispose() }
                $kept++
            }

            $install = $out.CreateEntry("$topName/INSTALL.md", [System.IO.Compression.CompressionLevel]::Optimal)
            $sw = New-Object System.IO.StreamWriter($install.Open())
            try { $sw.Write((Get-PluginInstallText $platform $version)) } finally { $sw.Dispose() }
        } finally { $out.Dispose() }
    } finally { $src.Dispose() }
    return $kept
}

# Fallback when only an extracted build dir is available (local mode, no zip):
# copy the allow-listed files into a staging tree and compress it. Note that
# Compress-Archive does not preserve Unix exec bits, so a macOS package built
# this way on Windows may need its binaries re-signed/chmod'd after extraction.
function New-PluginZipFromDir([string]$root, [string]$outZip, [string]$topName, [string]$platform, [string]$version) {
    $lib = Join-Path $root 'lib'
    if (-not (Test-Path $lib)) { return 0 }

    $stage    = Join-Path ([System.IO.Path]::GetTempPath()) ("usdplugin_" + [System.IO.Path]::GetRandomFileName())
    $stageTop = Join-Path $stage $topName
    $stageLib = Join-Path $stageTop 'lib'
    New-Item -ItemType Directory -Force $stageLib | Out-Null

    $kept = 0
    foreach ($sub in @('Exporters', 'Importers', 'usd', 'su_usd', 'skp_usd')) {
        $s = Join-Path $lib $sub
        if (Test-Path $s) { Copy-Item $s (Join-Path $stageLib $sub) -Recurse -Force; $kept++ }
    }
    foreach ($f in (Get-ChildItem $lib -File -ErrorAction SilentlyContinue)) {
        if (Test-KeepPluginEntry "lib/$($f.Name)") { Copy-Item $f.FullName (Join-Path $stageLib $f.Name) -Force; $kept++ }
    }
    $changelog = Join-Path $root 'CHANGELOG.md'
    if (Test-Path $changelog) { Copy-Item $changelog (Join-Path $stageTop 'CHANGELOG.md') -Force }
    Set-Content (Join-Path $stageTop 'INSTALL.md') (Get-PluginInstallText $platform $version) -NoNewline

    if ($kept -gt 0) {
        if (Test-Path $outZip) { Remove-Item $outZip -Force }
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $outZip -Force
        if ($platform -eq 'macOS') {
            Write-Host "    note: built from extracted files - macOS binaries may need re-signing after extraction." -ForegroundColor Yellow
        }
    }
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    return $kept
}

# Generate plugin-only packages (both platforms) for the selected version.
function Invoke-GeneratePackages([string]$label, [string]$versionRoot) {
    # Find the folder that holds both platforms' sources. In drive mode the
    # version root already is that folder; in local mode it is a single
    # platform's extracted dir, so step up one level.
    if ($script:SourceMode -eq 'drive') {
        $verFolder = $versionRoot
    } else {
        $verFolder = Split-Path -Parent $versionRoot
    }

    New-Item -ItemType Directory -Force $PackagesDir | Out-Null

    $platforms = @(
        @{ Name = 'Windows'; ZipPat = '*win64-Release*.zip';  DirPat = '*win64-Release*' },
        @{ Name = 'macOS';   ZipPat = '*Darwin-Release*.zip'; DirPat = '*Darwin-Release*' }
    )

    $made = @()
    foreach ($p in $platforms) {
        $srcZip = Get-ChildItem $verFolder -File -Filter $p.ZipPat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($srcZip) {
            $top    = [System.IO.Path]::GetFileNameWithoutExtension($srcZip.Name) + '-plugin-only'
            $outZip = Join-Path $PackagesDir ($top + '.zip')
            Write-Host "  building $($p.Name) plugin-only package from $($srcZip.Name)..."
            $kept = New-PluginZipFromZip $srcZip.FullName $outZip $top $p.Name $label
        } else {
            $dir = Get-ChildItem $verFolder -Directory -Filter $p.DirPat -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $dir) {
                Write-Host "  ($($p.Name): no $($p.DirPat) source found - skipped)" -ForegroundColor Yellow
                continue
            }
            $top    = $dir.Name + '-plugin-only'
            $outZip = Join-Path $PackagesDir ($top + '.zip')
            Write-Host "  building $($p.Name) plugin-only package from $($dir.Name)\..."
            $kept = New-PluginZipFromDir $dir.FullName $outZip $top $p.Name $label
        }

        if ($kept -gt 0) {
            $made += $outZip
            Write-Host "    -> packages\$(Split-Path -Leaf $outZip)  ($kept plugin items)" -ForegroundColor Green
        } else {
            Write-Host "    ($($p.Name): no plugin files found - skipped)" -ForegroundColor Yellow
            if (Test-Path $outZip) { Remove-Item $outZip -Force -ErrorAction SilentlyContinue }
        }
    }

    if ($made.Count -eq 0) {
        Write-Host "No plugin-only packages were generated." -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "Generated $($made.Count) plugin-only package(s) in $PackagesDir"
    }
    return $made
}

# Push generated plugin-only zips to their per-version Deliverables subfolder on
# Drive (via sync-releases.py's Drive API path). Never aborts on failure.
function Invoke-MaybeUpload([string[]]$zips) {
    if (-not $zips -or $zips.Count -eq 0) { return }
    $syncScript = Join-Path $ScriptDir 'sync-releases.py'
    if (-not (Test-Path $syncScript)) { return }

    Write-Host ""
    $ans = Read-Host "Upload the plugin-only package(s) to the Drive Deliverables subfolder? [y/N]"
    if ($ans -notmatch '^[Yy]$') { return }

    $pyPath = Resolve-Python
    if (-not $pyPath) {
        Write-Host "  python not found - skipping upload." -ForegroundColor Yellow
        return
    }

    Write-Host "Uploading to Drive..."
    try {
        & $pyPath $syncScript --upload-plugin @zips
        if ($LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE" }
    } catch {
        Write-Host "  (upload failed - packages are still available in $PackagesDir)" -ForegroundColor Yellow
    }
}

function Invoke-MaybePackage([string]$label, [string]$versionRoot) {
    Write-Host ""
    $ans = Read-Host "Also generate plugin-only zip package(s) for $label (Windows + macOS)? [y/N]"
    if ($ans -notmatch '^[Yy]$') { return }
    Write-Host ""
    Write-Host "Generating plugin-only packages (Converter excluded)..."
    $made = Invoke-GeneratePackages $label $versionRoot
    Invoke-MaybeUpload $made
}

# ── main ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "USD IO Version Switcher"
Write-Host "========================"
Write-Host ""

Invoke-MaybeSync
Write-Host ""

Select-Source
if (-not (Test-Path $script:BuildsDir)) { Die "Builds directory not found at: $script:BuildsDir" }

Write-Host ""
Select-SketchUp

Write-Host ""
Write-Host "Available versions (source: $($script:SourceMode)):"
Get-Versions
Write-Host ""

if ($script:Versions.Count -eq 0) { Die "No build versions found in $script:BuildsDir" }

$choice = Read-Host "Select version [1-$($script:Versions.Count)]"
if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $script:Versions.Count) {
    Die "Invalid selection: $choice"
}
$idx = [int]$choice - 1

foreach ($sketchupDir in $script:SketchUpTargets) {
    $dirs = Get-ExporterImporterDirs $sketchupDir
    if (-not $dirs) { Die "Exporters/Importers folders not found under $sketchupDir" }
    $script:ExportersDir = $dirs[0]
    $script:ImportersDir = $dirs[1]

    Write-Host ""
    Write-Host ">>> $(Split-Path -Leaf $sketchupDir)"
    Write-Host "    Currently installed: $(Get-CurrentVersion)"

    $root = $script:VersionRoots[$idx]
    if ($script:SourceMode -eq 'drive') {
        $root = Resolve-WindowsRoot $root
        if (-not $root) { Die "Could not extract Windows build for $($script:Versions[$idx])" }
    }
    Install-Version $script:Versions[$idx] $root
}

Invoke-MaybePackage $script:Versions[$idx] $script:VersionRoots[$idx]

Write-Host ""
Read-Host "Press Enter to exit"
