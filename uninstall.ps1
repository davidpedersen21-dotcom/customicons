# Custom Icon - uninstaller
# Removes the context-menu entry. Does not touch icons already applied to folders,
# and leaves your config (%APPDATA%\CustomIcon) in place unless -PurgeConfig is passed.
param([switch]$PurgeConfig)

$key = 'HKCU:\Software\Classes\Directory\shell\CustomIcon'
if (Test-Path $key) {
    Remove-Item -Path $key -Recurse -Force
    Write-Host 'Context menu entry removed.' -ForegroundColor Green
} else {
    Write-Host 'Context menu entry was not installed.'
}

if ($PurgeConfig) {
    $cfg = Join-Path $env:APPDATA 'CustomIcon'
    if (Test-Path $cfg) { Remove-Item $cfg -Recurse -Force; Write-Host 'Config removed.' }
}
