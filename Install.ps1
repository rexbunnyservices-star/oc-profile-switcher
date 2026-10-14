$ErrorActionPreference = 'Stop'
$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir = Join-Path $env:LOCALAPPDATA 'OpenCodeAccountWidget'
$StartupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$ShortcutPath = Join-Path $StartupDir 'OpenCode Account Widget.lnk'

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
foreach ($name in @('OpenCodeAccountWidget.ps1', 'account-bridge.mjs', 'widget-config.json', 'README.md', 'Uninstall.ps1')) {
    $source = Join-Path $SourceDir $name
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $InstallDir $name) -Force
    }
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($ShortcutPath)
$shortcut.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $InstallDir 'OpenCodeAccountWidget.ps1') + '"'
$shortcut.WorkingDirectory = $InstallDir
$shortcut.Description = 'OpenCode account tracker and switcher'
$shortcut.IconLocation = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
$shortcut.Save()

$existing = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like '*OpenCodeAccountWidget.ps1*' -and $_.ProcessId -ne $PID })
foreach ($process in $existing) {
    Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
}
if ($existing.Count -gt 0) { Start-Sleep -Milliseconds 350 }
Start-Process -FilePath $shortcut.TargetPath -ArgumentList $shortcut.Arguments -WindowStyle Hidden | Out-Null

Write-Host "Installed: $InstallDir"
Write-Host "Startup shortcut: $ShortcutPath"
