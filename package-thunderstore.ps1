# package-thunderstore.ps1 — build the Thunderstore package zip (Windows).
#
# Produces dist\Antelytics-thunderstore.zip: mod files FLAT at the zip root
# next to manifest.json, README.md and icon.png (Thunderstore layout — see
# package-thunderstore.sh for the rationale). version_number is derived from
# Antelytics.json with the `~alpha` suffix stripped.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$version   = (Get-Content Antelytics.json -Raw | ConvertFrom-Json).version
$tsVersion = ($version -split '~')[0]
Write-Host "Packaging Antelytics v$version for Thunderstore as $tsVersion"

$stage = "dist\thunderstore"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
if (Test-Path dist\Antelytics-thunderstore.zip) { Remove-Item -Force dist\Antelytics-thunderstore.zip }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

$manifest = Get-Content thunderstore\manifest.json -Raw | ConvertFrom-Json
$manifest.version_number = $tsVersion
$manifest | ConvertTo-Json -Depth 3 | Set-Content "$stage\manifest.json" -Encoding UTF8
Copy-Item thunderstore\icon.png, README.md, CHANGELOG.md $stage

Copy-Item main.lua, Antelytics.json, config.lua $stage
Copy-Item lib "$stage\lib" -Recurse
if (Test-Path LICENSE) { Copy-Item LICENSE $stage }

# Zip the CONTENTS of the stage (flat root), not the stage folder itself.
Compress-Archive -Path "$stage\*" -DestinationPath "dist\Antelytics-thunderstore.zip" -Force

Write-Host "Wrote dist\Antelytics-thunderstore.zip ($tsVersion)"
