# package.ps1 — build the distributable mod zip (Windows).
#
# Produces dist\Antelytics.zip containing a single top-level `Antelytics\`
# folder with only the runtime files, so a user just extracts it into their
# Balatro Mods directory.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$manifest = Get-Content Antelytics.json -Raw | ConvertFrom-Json
$version  = $manifest.version
Write-Host "Packaging Antelytics v$version"

$stage = "dist\Antelytics"
if (Test-Path dist) { Remove-Item -Recurse -Force dist }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

# Runtime files only.
Copy-Item main.lua, Antelytics.json, config.lua, README.md $stage
Copy-Item lib "$stage\lib" -Recurse
if (Test-Path LICENSE) { Copy-Item LICENSE $stage }

# Zip the staged folder — the archive contains a top-level Antelytics\.
Compress-Archive -Path $stage -DestinationPath "dist\Antelytics.zip" -Force

Write-Host "Wrote dist\Antelytics.zip (v$version)"
