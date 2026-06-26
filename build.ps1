# Build pixel-normal-generator.aseprite-extension (Windows / PowerShell).
# An .aseprite-extension is just a .zip with package.json + the .lua files at
# the archive ROOT. Run from the repo root:  ./build.ps1

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$name = "pixel-normal-generator"

$files = @("package.json", "main.lua", "normalmap.lua", "ui.lua", "LICENSE", "README.md") |
  ForEach-Object { Join-Path $root $_ }

foreach ($f in $files) {
  if (-not (Test-Path $f)) { throw "Missing file: $f" }
}

$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$zip = Join-Path $dist "$name.zip"
$ext = Join-Path $dist "$name.aseprite-extension"
if (Test-Path $zip) { Remove-Item $zip -Force }
if (Test-Path $ext) { Remove-Item $ext -Force }

Compress-Archive -Path $files -DestinationPath $zip -Force
Move-Item $zip $ext -Force

Write-Host "Built $ext"
Write-Host "Install: Aseprite -> Edit -> Preferences -> Extensions -> Add Extension"
