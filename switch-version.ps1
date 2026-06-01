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

# Optionally pull new SkpXyz releases from the GitLab wiki into Drive so the
# version list below is up to date. Never aborts the switcher on failure.
function Invoke-MaybeSync {
    $syncScript = Join-Path $ScriptDir 'sync-releases.py'
    if (-not (Test-Path $syncScript)) { return }

    $ans = Read-Host "Check GitLab for new versions and sync to Drive? [y/N]"
    if ($ans -notmatch '^[Yy]$') { return }

    $venvPy = Join-Path $ScriptDir '.venv\Scripts\python.exe'
    if (Test-Path $venvPy) {
        $pyPath = $venvPy
    } else {
        $py = Get-Command python -ErrorAction SilentlyContinue
        if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
        if (-not $py) {
            Write-Host "  python not found - skipping version check." -ForegroundColor Yellow
            return
        }
        $pyPath = $py.Source
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

Write-Host ""
Read-Host "Press Enter to exit"
