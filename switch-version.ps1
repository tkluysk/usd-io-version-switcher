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

$script:DriveBuildsDir  = ''   # Drive for Desktop mount path, if found (cache-key use)
# Build-source roots in priority order (most-local first); kinds are parallel:
# 'dir' = folders hold an already-extracted *win64-Release* root; 'zip' = folders
# hold a *win64-Release*.zip to extract on demand into .drive-cache\.
$script:SourceDirs      = @()
$script:SourceKinds     = @()
$script:SketchUpTargets = @()
$script:Versions        = @()
$script:VersionRoots    = @()
$script:VersionKinds    = @()  # 'dir' | 'zip' | 'api', parallel to Versions
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

# ── Drive API fallback ─────────────────────────────────────────────────────────
# Last resort, used only when there is no Drive mount and a build isn't already
# staged locally: sync-releases.py lists and downloads builds straight from the
# Deliverables folder over the Drive API.

function Test-DriveApiAvailable {
    if (-not (Test-Path (Join-Path $ScriptDir 'sync-releases.py'))) { return $false }
    return [bool](Resolve-Python)
}

# Ordered list of [pscustomobject]@{ Label; Win; Darwin } for every version in
# the Deliverables folder, or @() on any failure (offline, no creds, ...).
function Get-DriveApiVersions {
    $py = Resolve-Python
    if (-not $py) { return @() }
    $syncScript = Join-Path $ScriptDir 'sync-releases.py'
    try {
        $lines = & $py $syncScript --list-deliverables 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
    } catch { return @() }

    $out = @()
    foreach ($line in $lines) {
        if (-not $line) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -lt 3) { continue }
        $out += [pscustomobject]@{
            Label  = $parts[0]
            Win    = if ($parts[1] -eq '-') { $null } else { $parts[1] }
            Darwin = if ($parts[2] -eq '-') { $null } else { $parts[2] }
        }
    }
    return $out
}

# Download a version's platform ('win64'|'Darwin') Release zip into
# .drive-cache\incoming\<label>\ via the Drive API. Returns that folder on
# success (ready for Resolve-WindowsRoot / packaging), $null on failure.
function Invoke-DriveApiDownload([string]$label, [string]$platform) {
    $py = Resolve-Python
    if (-not $py) { return $null }
    $syncScript = Join-Path $ScriptDir 'sync-releases.py'
    $dest = Join-Path $IncomingDir $label
    Write-Host "  downloading $label ($platform) from Drive..." -ForegroundColor DarkGray
    try {
        # Pipe the child's output to the host so it stays off this function's
        # pipeline — otherwise its stdout would pollute the returned path.
        & $py $syncScript --download $label $platform $dest 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  (Drive download failed for $label / $platform)" -ForegroundColor Yellow
            return $null
        }
    } catch {
        Write-Host "  (Drive download failed for $label / $platform)" -ForegroundColor Yellow
        return $null
    }
    return $dest
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

# Gather every place a build might live, in priority order (newest/most-local
# first): freshly-synced staging, the checked-in builds\ folder, then the live
# Drive mount as a fallback. Get-Versions dedups by label across all of them, so
# there's no source to pick — the union is the source. Get-Versions also
# consults the Drive API as a last resort for versions not visible locally.
function Find-BuildSources {
    if (Test-Path $IncomingDir -PathType Container) {
        $script:SourceDirs += $IncomingDir;      $script:SourceKinds += 'zip'
    }
    if (Test-Path $LocalBuildsDir -PathType Container) {
        $script:SourceDirs += $LocalBuildsDir;   $script:SourceKinds += 'dir'
    }
    $script:DriveBuildsDir = Find-DriveBuildsDir
    if ($script:DriveBuildsDir) {
        $script:SourceDirs += $script:DriveBuildsDir; $script:SourceKinds += 'zip'
    }

    # The Drive API can surface versions even with no local source at all, so
    # don't die yet if it's available — Get-Versions will try it.
    if ($script:SourceDirs.Count -eq 0 -and -not (Test-DriveApiAvailable)) {
        Die "No build sources found (looked in $LocalBuildsDir, $IncomingDir, and Google Drive)."
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

# Returns a win64-Release root dir for the given version folder. If the folder
# already holds an extracted *win64-Release* root, that's returned as-is;
# otherwise a *win64-Release*.zip is extracted on demand into .drive-cache\.
function Resolve-WindowsRoot([string]$dir) {
    $winDir = Get-ChildItem $dir -Directory -Filter '*win64-Release*' -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if ($winDir) { return $winDir.FullName }

    $zip = Get-ChildItem $dir -File -Filter '*win64-Release*.zip' -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $zip) { return $null }

    # Use the dir path relative to its source root as a stable cache key.
    # Staged dirs live under $IncomingDir; Drive-mount dirs under $script:DriveBuildsDir.
    if ($dir.StartsWith($IncomingDir, [StringComparison]::OrdinalIgnoreCase)) {
        $label = $dir.Substring($IncomingDir.Length).TrimStart('\')
    } elseif ($script:DriveBuildsDir -and $dir.StartsWith($script:DriveBuildsDir, [StringComparison]::OrdinalIgnoreCase)) {
        $label = $dir.Substring($script:DriveBuildsDir.Length).TrimStart('\')
    } else {
        $label = Split-Path -Leaf $dir
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
    return $null
}

# True if a folder directly contains an extracted *win64-Release* root or a
# *win64-Release*.zip — i.e. it's an installable version folder.
function Test-HasWindowsBuild([string]$dir) {
    $hasDir = [bool](Get-ChildItem $dir -Directory -Filter '*win64-Release*' -ErrorAction SilentlyContinue | Select-Object -First 1)
    $hasZip = [bool](Get-ChildItem $dir -File    -Filter '*win64-Release*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1)
    return $hasDir -or $hasZip
}

function Test-PreRelease([string]$label) {
    return ($label -match '\s0\.[0-3]\.' -or $label -match '\s0\.[0-3]$')
}

# Record one installable entry into $pending (an ArrayList) unless a
# higher-priority source already claimed its label. For 'dir' sources the root
# is the extracted win64 dir; for 'zip' sources it's the version folder itself
# (extracted on demand later). $pending and $seen are objects, so mutations here
# persist in the caller.
function Add-PendingVersion($pending, $seen, [string]$label, [string]$dir, [string]$srcKind) {
    if ($seen.ContainsKey($label)) { return }
    if ($srcKind -eq 'dir') {
        $root = Get-ChildItem $dir -Directory -Filter '*win64-Release*' -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if (-not $root) { return }
        $root = $root.FullName
    } else {
        $root = $dir
    }
    [void]$pending.Add([pscustomobject]@{ Label = $label; Kind = $srcKind; Root = $root })
    $seen[$label] = $true
}

# Build a single deduplicated version list across every source in SourceDirs,
# then sort it strictly newest-first regardless of source. On a duplicate label
# the first (highest-priority) source wins — so a freshly-synced build in
# incoming\ shadows an older copy on the slow Drive mount — but the final list
# is ordered purely by version. The Drive API is consulted last and only ADDS
# versions not already found locally.
function Get-Versions {
    $seen    = @{}
    $pending = [System.Collections.ArrayList]::new()

    for ($i = 0; $i -lt $script:SourceDirs.Count; $i++) {
        $src     = $script:SourceDirs[$i]
        $srcKind = $script:SourceKinds[$i]
        if (-not (Test-Path $src -PathType Container)) { continue }

        foreach ($dir in (Get-ChildItem $src -Directory -ErrorAction SilentlyContinue)) {
            $label = $dir.Name
            if (Test-PreRelease $label) { continue }
            if (Test-HasWindowsBuild $dir.FullName) {
                Add-PendingVersion $pending $seen $label $dir.FullName $srcKind
            } else {
                # Descend one level for variant subfolders (e.g. "Using SketchUp libs").
                foreach ($sub in (Get-ChildItem $dir.FullName -Directory -ErrorAction SilentlyContinue)) {
                    if (Test-HasWindowsBuild $sub.FullName) {
                        Add-PendingVersion $pending $seen "$label / $($sub.Name)" $sub.FullName $srcKind
                    }
                }
            }
        }
    }

    # Drive API fallback (last resort): surface versions that exist on Drive but
    # aren't visible locally. This runs even with a mount present, because Drive
    # for Desktop routinely leaves the folder materialised-but-empty (the path
    # exists but enumeration sees nothing inside), which would otherwise hide
    # brand-new builds. The $seen dedup ensures the API only ADDS missing
    # versions; each is an "API::<label>" sentinel, downloaded on demand only if
    # selected.
    if (Test-DriveApiAvailable) {
        Write-Host "  checking Drive for more versions..." -ForegroundColor DarkGray
        foreach ($v in (Get-DriveApiVersions)) {
            if ($seen.ContainsKey($v.Label)) { continue }
            if (-not $v.Win) { continue }          # need a Windows build to install here
            if (Test-PreRelease $v.Label) { continue }
            [void]$pending.Add([pscustomobject]@{ Label = $v.Label; Kind = 'api'; Root = "API::$($v.Label)" })
            $seen[$v.Label] = $true
        }
    }

    # Sort the merged buffer newest-first by version, then publish + display.
    $sorted = $pending |
              Sort-Object { [version]($_.Label -replace '^.*?(\d+\.\d+(\.\d+)*).*$','$1') } -Descending -ErrorAction SilentlyContinue
    $idx = 1
    foreach ($v in $sorted) {
        $script:Versions     += $v.Label
        $script:VersionRoots += $v.Root
        $script:VersionKinds += $v.Kind
        if ($v.Kind -eq 'api') { Write-Host "  $idx) $($v.Label)  (Drive)" }
        else                   { Write-Host "  $idx) $($v.Label)" }
        $idx++
    }
}

function Get-CurrentVersion {
    $marker = Join-Path $script:ExportersDir '.usd_version'
    if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { '(none)' }
}

# ── removal ───────────────────────────────────────────────────────────────────

function Shorten([string]$path) {
    foreach ($src in $script:SourceDirs) {
        $path = $path -replace [regex]::Escape($src + '\'), ''
    }
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
        # USD data folder rename history: skp_usd (very old) -> usd -> su_usd
        # (0.7.8+). Clean up whichever name a previous install left behind.
        Safe-Remove (Join-Path $targetDir 'usd')
        Safe-Remove (Join-Path $targetDir 'su_usd')
        Safe-Remove (Join-Path $targetDir 'skp_usd')
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

        # USD data folder was renamed 'usd' -> 'su_usd' at 0.7.8 (and was
        # 'skp_usd' in the very early releases). Copy the first one that
        # exists in this release's lib/.
        foreach ($name in @('su_usd', 'usd', 'skp_usd')) {
            $usdDir = Join-Path $lib $name
            if (Test-Path $usdDir -PathType Container) {
                Log-Copy $usdDir $targetDir
                break
            }
        }
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
function Invoke-GeneratePackages([string]$label, [string]$versionRoot, [string]$kind) {
    # Find the folder that holds both platforms' sources. 'zip' entries point at
    # the version folder (holds the platform zips); 'dir' entries point at the
    # extracted win64 root, so step up one level.
    if ($kind -eq 'zip') {
        $verFolder = $versionRoot
    } else {
        $verFolder = Split-Path -Parent $versionRoot
    }

    New-Item -ItemType Directory -Force $PackagesDir | Out-Null

    $platforms = @(
        @{ Name = 'Windows'; ZipPat = '*win64-Release*.zip';  DirPat = '*win64-Release*';  ApiPlat = 'win64'  },
        @{ Name = 'macOS';   ZipPat = '*Darwin-Release*.zip'; DirPat = '*Darwin-Release*'; ApiPlat = 'Darwin' }
    )

    $made = @()
    foreach ($p in $platforms) {
        $srcZip = Get-ChildItem $verFolder -File -Filter $p.ZipPat -ErrorAction SilentlyContinue | Select-Object -First 1
        # Drive API fallback: a platform zip missing locally (e.g. an API-only
        # version fetched for the other platform's install) is downloaded now.
        if (-not $srcZip -and (Test-DriveApiAvailable)) {
            $dl = Invoke-DriveApiDownload (Split-Path -Leaf $verFolder) $p.ApiPlat
            if ($dl) { $srcZip = Get-ChildItem $dl -File -Filter $p.ZipPat -ErrorAction SilentlyContinue | Select-Object -First 1 }
        }
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

function Invoke-MaybePackage([string]$label, [string]$versionRoot, [string]$kind) {
    Write-Host ""
    $ans = Read-Host "Also generate plugin-only zip package(s) for $label (Windows + macOS)? [y/N]"
    if ($ans -notmatch '^[Yy]$') { return }
    Write-Host ""
    Write-Host "Generating plugin-only packages (Converter excluded)..."
    $made = Invoke-GeneratePackages $label $versionRoot $kind
    Invoke-MaybeUpload $made
}

# ── main ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "USD IO Version Switcher"
Write-Host "========================"
Write-Host ""

Invoke-MaybeSync
Write-Host ""

Find-BuildSources

Write-Host ""
Select-SketchUp

Write-Host ""
Write-Host "Available versions:"
Get-Versions
Write-Host ""

if ($script:Versions.Count -eq 0) { Die "No build versions found." }

$choice = Read-Host "Select version [1-$($script:Versions.Count)]"
if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $script:Versions.Count) {
    Die "Invalid selection: $choice"
}
$idx = [int]$choice - 1

# An 'api' selection has no local copy: download it into incoming\ first, which
# turns it into an ordinary 'zip' entry pointing at the staged folder. Done once,
# up front, so both the install loop and packaging reuse the same download.
if ($script:VersionKinds[$idx] -eq 'api') {
    $apiLabel = $script:VersionRoots[$idx].Substring(5)
    Write-Host ""
    Write-Host "Fetching $apiLabel from Drive (no local copy found)..."
    $dl = Invoke-DriveApiDownload $apiLabel 'win64'
    if (-not $dl) { Die "Could not download $apiLabel from Drive." }
    $script:VersionRoots[$idx] = $dl
    $script:VersionKinds[$idx] = 'zip'
}

# Resolve the win64 root once ('zip' entries extract on demand into .drive-cache\;
# 'dir' entries already point at the extracted root).
$winRoot = $script:VersionRoots[$idx]
if ($script:VersionKinds[$idx] -eq 'zip') {
    $winRoot = Resolve-WindowsRoot $winRoot
    if (-not $winRoot) { Die "Could not extract Windows build for $($script:Versions[$idx])" }
}

foreach ($sketchupDir in $script:SketchUpTargets) {
    $dirs = Get-ExporterImporterDirs $sketchupDir
    if (-not $dirs) { Die "Exporters/Importers folders not found under $sketchupDir" }
    $script:ExportersDir = $dirs[0]
    $script:ImportersDir = $dirs[1]

    Write-Host ""
    Write-Host ">>> $(Split-Path -Leaf $sketchupDir)"
    Write-Host "    Currently installed: $(Get-CurrentVersion)"

    Install-Version $script:Versions[$idx] $winRoot
}

Invoke-MaybePackage $script:Versions[$idx] $script:VersionRoots[$idx] $script:VersionKinds[$idx]

Write-Host ""
Read-Host "Press Enter to exit"
