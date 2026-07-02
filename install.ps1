# Custom Icon - installer
# Adds a "Custom Icon" entry to the right-click context menu for folders.
# Installs per-user (HKCU) - no administrator rights required.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

$launcher = Join-Path $root 'launcher.vbs'
$script   = Join-Path $root 'CustomIcon.ps1'
if (-not (Test-Path $launcher) -or -not (Test-Path $script)) {
    throw "launcher.vbs / CustomIcon.ps1 not found next to install.ps1 - run this from the CustomIcon folder."
}

$key = 'HKCU:\Software\Classes\Directory\shell\CustomIcon'
New-Item -Path $key -Force | Out-Null
Set-ItemProperty -Path $key -Name 'MUIVerb' -Value 'Custom Icon'
Set-ItemProperty -Path $key -Name 'Icon'    -Value 'shell32.dll,69'

New-Item -Path "$key\command" -Force | Out-Null
Set-Item -Path "$key\command" -Value "wscript.exe `"$launcher`" `"%1`""

Write-Host 'Installed!' -ForegroundColor Green
Write-Host 'Right-click any folder and choose "Custom Icon".'
Write-Host 'Note: on Windows 11 the entry appears under "Show more options" (or Shift+F10).'
