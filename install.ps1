# install.ps1 — Windows PowerShell equivalent of install.sh.
#
# Copies the BalatroAntelytics mod source into the Balatro Mods directory
# under %APPDATA%\Balatro\Mods\BalatroAntelytics.
#
# Usage:
#   pwsh install.ps1
#   (or)  powershell -ExecutionPolicy Bypass -File install.ps1
#
# COPY-ONLY: never uses symlinks (per the no-symlinks rule in the
# project README — Balatro holds files open at runtime, symlinks
# would let a vite-dev hot-reload or npm-run-build corrupt a mid-game
# capture).

$ErrorActionPreference = 'Stop'

$RepoDir = $PSScriptRoot
$ModsDir = Join-Path $env:APPDATA "Balatro\Mods\Antelytics"

Write-Host ("Source : {0}" -f $RepoDir)
Write-Host ("Target : {0}" -f $ModsDir)
Write-Host ""

# Excludes — keep in sync with install.sh's rsync flags.
$Excludes = @(
    '.git',
    'spec',
    'log',
    'session.log',
    '.DS_Store',
    'install.sh',
    'install.ps1',
    '*.bak',
    '.kiro'
)

# Wipe source files only. NEVER touch log/ or session.log — those hold
# captured run data (the whole point of the mod) and the runtime log — nor an
# EXISTING config.lua, which holds the user's settings (player_id, enabled).
# All must survive a reinstall.
$PreserveNames = @('log', 'session.log', 'config.lua')

if (Test-Path $ModsDir) {
    Get-ChildItem -Path $ModsDir -Force | ForEach-Object {
        if ($PreserveNames -notcontains $_.Name) {
            Remove-Item -Recurse -Force $_.FullName
        }
    }
} else {
    New-Item -ItemType Directory -Path $ModsDir -Force | Out-Null
}

# Copy each top-level item, skipping excluded names. Recursive for
# directories. No symlink dereferencing — PowerShell's Copy-Item does
# real copies by default.
Get-ChildItem -Path $RepoDir -Force | ForEach-Object {
    $name = $_.Name
    $excluded = $false
    foreach ($pat in $Excludes) {
        if ($name -like $pat) { $excluded = $true; break }
    }
    if ($excluded) { return }

    # Don't clobber an existing config.lua — keep the user's settings. A fresh
    # install (no config yet) still gets the default copied.
    $dest = Join-Path $ModsDir $name
    if ($name -eq 'config.lua' -and (Test-Path $dest)) { return }

    if ($_.PSIsContainer) {
        Copy-Item -Path $_.FullName -Destination $dest -Recurse -Force
    } else {
        Copy-Item -Path $_.FullName -Destination $dest -Force
    }
}

Write-Host ("Done. Mod installed to: {0}" -f $ModsDir)
Write-Host ""
Write-Host "Restart Balatro to pick up the changes."
Write-Host "Run logs will land at: $ModsDir\log\*.json.gz"
