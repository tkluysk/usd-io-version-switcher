# Installs a Start Menu shortcut "USD IO Switcher.lnk" that runs switch-version.ps1
# elevated. From there it can be pinned to the taskbar (right-click in Start ->
# Pin to taskbar). Also removes a stale copy from the Desktop if present.
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PsScript  = Join-Path $ScriptDir 'switch-version.ps1'
if (-not (Test-Path $PsScript)) { throw "switch-version.ps1 not found next to this script: $PsScript" }

$ProgramsDir = [Environment]::GetFolderPath('Programs')
$LinkPath    = Join-Path $ProgramsDir 'USD IO Switcher.lnk'

$StaleDesktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'USD IO Switcher.lnk'
if (Test-Path $StaleDesktop) { Remove-Item $StaleDesktop -Force; Write-Host "Removed stale Desktop shortcut: $StaleDesktop" }

$shell = New-Object -ComObject WScript.Shell
$lnk   = $shell.CreateShortcut($LinkPath)
$lnk.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments        = "-ExecutionPolicy Bypass -NoProfile -File `"$PsScript`""
$lnk.WorkingDirectory = $ScriptDir
$lnk.IconLocation     = "$env:SystemRoot\System32\imageres.dll,109"  # generic blue/cog icon
$lnk.Description      = 'Switch the installed USD IO plugin version in SketchUp'
$lnk.Save()

# Flip the "Run as administrator" bit (offset 21, bit 0x20) inside the .lnk binary.
$bytes = [System.IO.File]::ReadAllBytes($LinkPath)
$bytes[21] = $bytes[21] -bor 0x20
[System.IO.File]::WriteAllBytes($LinkPath, $bytes)

Write-Host "Installed: $LinkPath"
Write-Host "Pin to taskbar: open Start, search 'USD IO Switcher', right-click the result -> Pin to taskbar."
