$ErrorActionPreference = 'SilentlyContinue'
$InstallDir = Join-Path $env:LOCALAPPDATA 'OpenCodeAccountWidget'
$StartupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$ShortcutPath = Join-Path $StartupDir 'OpenCode Account Widget.lnk'
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like '*OpenCodeAccountWidget.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Remove-Item -LiteralPath $ShortcutPath -Force
Remove-Item -LiteralPath $InstallDir -Recurse -Force
Write-Host 'OpenCode Account Widget removed.'
