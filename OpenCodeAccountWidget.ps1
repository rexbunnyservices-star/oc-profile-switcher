$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('OpenCodeWidgetNative.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace OpenCodeWidgetNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct AccentPolicy
    {
        public int AccentState;
        public int AccentFlags;
        public int GradientColor;
        public int AnimationId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WindowCompositionAttributeData
    {
        public int Attribute;
        public IntPtr Data;
        public int SizeOfData;
    }

    public static class NativeMethods
    {
        [DllImport("user32.dll")]
        public static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttributeData data);

        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    }
}
'@
}

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:OpenCodeDir = Join-Path $HOME '.config\opencode'
$script:MultiDir = Join-Path $script:OpenCodeDir 'multi-account'
$script:AccountsFile = Join-Path $script:MultiDir 'accounts.json'
$script:StateFile = Join-Path $script:MultiDir 'state.json'
$script:QuotaFile = Join-Path $script:MultiDir 'provider-quota.json'
$script:DcpDir = Join-Path $HOME '.local\share\opencode\storage\plugin\dcp'
$script:Bridge = Join-Path $script:Root 'account-bridge.mjs'
$script:ConfigFile = Join-Path $script:Root 'widget-config.json'
$script:SettingsDir = Join-Path $env:LOCALAPPDATA 'OpenCodeAccountWidget'
$script:SettingsFile = Join-Path $script:SettingsDir 'settings.json'
$script:Window = $null
$script:App = $null
$script:Timer = $null
$script:Tray = $null
$script:TrayMenu = $null
$script:Mutex = $null
$script:HasMutex = $false
$script:ForceExit = $false
$script:Expanded = $false
$script:Minimized = $false
$script:Switching = $false
$script:Dragging = $false
$script:DragOrigin = $null
$script:WindowOrigin = $null
$script:SessionId = $null
$script:LastAccountSignature = ''
$script:LastStatusText = ''
$script:NodeExe = $null
$script:BridgeProcess = $null
$script:BridgeWriter = $null
$script:BridgeReader = $null
$script:BridgeRequestId = 0
$script:BridgeTimeoutMs = 3000
$script:OpenCodeWasRunning = $false
$script:OpenCodeStateInitialized = $false

function New-Brush([string]$Hex) {
    try {
        return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex)
    } catch {
        return [System.Windows.Media.Brushes]::Transparent
    }
}

# Opaque charcoal shell; depth comes from a white-alpha ladder, not more greys.
$script:BrushBg = New-Brush '#FF0C0C10'
$script:BrushBgHover = New-Brush '#FF141419'
$script:BrushPanel = New-Brush '#0FFFFFFF'
$script:BrushPanelHover = New-Brush '#16FFFFFF'
$script:BrushPanel2 = New-Brush '#12FFFFFF'
$script:BrushBorder = New-Brush '#24FFFFFF'
$script:BrushBorderStrong = New-Brush '#33FFFFFF'
$script:BrushText = New-Brush '#F4F4F6'
$script:BrushMuted = New-Brush '#9A9AA2'
$script:BrushFaint = New-Brush '#5E5E66'
$script:BrushAccent = New-Brush '#E6E6EA'
$script:BrushAccentInk = New-Brush '#0A0A0C'
$script:BrushAccentSoft = New-Brush '#3AFFFFFF'
$script:BrushGreen = New-Brush '#93D9B4'
$script:BrushAmber = New-Brush '#D9C08C'
$script:BrushRed = New-Brush '#D99BA8'
$script:BrushBlue = New-Brush '#A6BBD0'

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-Prop($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    try {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    } catch { }
    return $Default
}

function Get-Config {
    $config = Read-JsonFile $script:ConfigFile
    $budget = [int](Get-Prop $config 'localBudgetTokens' 1000000)
    if ($budget -le 0) { $budget = 1000000 }
    return [pscustomobject]@{
        LocalBudgetTokens = $budget
        PollMs = [Math]::Max(1000, [int](Get-Prop $config 'pollMs' 2000))
        AutoStartWithOpenCode = [bool](Get-Prop $config 'autoStartWithOpenCode' $true)
        HideWhenOpenCodeClosed = [bool](Get-Prop $config 'hideWhenOpenCodeClosed' $true)
    }
}

function Enable-NativeBackdrop {
    if ($null -eq $script:Window) { return }
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($script:Window)
        $hwnd = $helper.Handle
        if ($hwnd -eq [IntPtr]::Zero) { return }

        # Ask DWM for dark immersive chrome on Windows 10/11.
        $dark = 1
        [void][OpenCodeWidgetNative.NativeMethods]::DwmSetWindowAttribute($hwnd, 20, [ref]$dark, 4)
        $corner = 2
        [void][OpenCodeWidgetNative.NativeMethods]::DwmSetWindowAttribute($hwnd, 33, [ref]$corner, 4)

        # SetWindowCompositionAttribute provides the acrylic-like blur fallback
        # for the small borderless overlay on Windows 10 1803 and later.
        $policy = New-Object OpenCodeWidgetNative.AccentPolicy
        $policy.AccentState = 4
        $policy.AccentFlags = 2
        $policy.GradientColor = 0x6600142B
        $policy.AnimationId = 0
        $size = [Runtime.InteropServices.Marshal]::SizeOf([type][OpenCodeWidgetNative.AccentPolicy])
        $pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
        try {
            [Runtime.InteropServices.Marshal]::StructureToPtr($policy, $pointer, $false)
            $data = New-Object OpenCodeWidgetNative.WindowCompositionAttributeData
            $data.Attribute = 19
            $data.Data = $pointer
            $data.SizeOfData = $size
            [void][OpenCodeWidgetNative.NativeMethods]::SetWindowCompositionAttribute($hwnd, [ref]$data)
        } finally {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)
        }
    } catch {
        # The translucent WPF surface remains a readable fallback if the
        # Windows composition API is unavailable or disabled by policy.
    }
}

function Set-ShellHover([bool]$Hovered) {
    if ($null -eq $script:Window) { return }
    $shell = $script:Window.FindName('Shell')
    if ($null -eq $shell) { return }
    $shell.Background = if ($Hovered) { $script:BrushBgHover } else { $script:BrushBg }
    $shell.BorderBrush = if ($Hovered) { $script:BrushBorderStrong } else { $script:BrushBorder }
}

function Test-OpenCodeRunning {
    try {
        $processes = @(Get-Process -Name @('OpenCode', 'opencode') -ErrorAction SilentlyContinue)
        return ($processes.Count -gt 0)
    } catch {
        return $false
    }
}

function Show-Widget {
    if ($null -eq $script:Window) { return }
    if (-not $script:Window.IsVisible) { $script:Window.Show() }
    if ($script:Window.IsVisible) { $script:Window.Activate() }
}

function Hide-Widget {
    if ($null -ne $script:Window -and $script:Window.IsVisible) { $script:Window.Hide() }
}

function Sync-OpenCodeVisibility {
    $config = Get-Config
    if (-not $config.AutoStartWithOpenCode) { return }

    $running = Test-OpenCodeRunning
    if (-not $script:OpenCodeStateInitialized) {
        $script:OpenCodeStateInitialized = $true
        $script:OpenCodeWasRunning = $running
        if ($running) { Show-Widget } else { Hide-Widget }
        return
    }

    if ($running -and -not $script:OpenCodeWasRunning) {
        Show-Widget
    } elseif (-not $running -and $script:OpenCodeWasRunning -and $config.HideWhenOpenCodeClosed) {
        Hide-Widget
    }
    $script:OpenCodeWasRunning = $running
}

function Get-SessionId {
    $statusPath = Join-Path $script:MultiDir 'last-session-status.json'
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        try {
            $age = ((Get-Date) - (Get-Item -LiteralPath $statusPath).LastWriteTime).TotalMinutes
            if ($age -lt 15) {
                $status = Read-JsonFile $statusPath
                $event = Get-Prop $status 'event' $null
                $properties = Get-Prop $event 'properties' $null
                $candidate = Get-Prop $properties 'sessionID' $null
                if ($candidate -is [string] -and $candidate.Trim()) { return $candidate.Trim() }
            }
        } catch { }
    }

    if (Test-Path -LiteralPath $script:DcpDir -PathType Container) {
        try {
            $latest = Get-ChildItem -LiteralPath $script:DcpDir -Filter '*.json' -File |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($null -ne $latest) { return $latest.BaseName }
        } catch { }
    }
    return $null
}

function Get-StatusColor([string]$Status) {
    switch ($Status) {
        'active' { return $script:BrushGreen }
        'rate_limited' { return $script:BrushAmber }
        'disabled' { return $script:BrushRed }
        'invalid' { return $script:BrushRed }
        default { return $script:BrushFaint }
    }
}

function Format-Tokens([double]$Value) {
    if ($Value -ge 1000000) { return ('{0:0.#}M' -f ($Value / 1000000)) }
    if ($Value -ge 1000) { return ('{0:0.#}k' -f ($Value / 1000)) }
    return ('{0:0}' -f [Math]::Max(0, $Value))
}

function Format-Cooldown([double]$Milliseconds) {
    if ($Milliseconds -le 0) { return 'ready' }
    $seconds = [Math]::Ceiling($Milliseconds / 1000)
    $hours = [Math]::Floor($seconds / 3600)
    $minutes = [Math]::Floor(($seconds % 3600) / 60)
    $remaining = $seconds % 60
    if ($hours -gt 0) { return ('{0}h {1}m' -f $hours, $minutes) }
    if ($minutes -gt 0) { return ('{0}m {1}s' -f $minutes, $remaining) }
    return ('{0}s' -f $remaining)
}

function Get-AccountSnapshot {
    # Let the bridge resolve the active session from the fresh status/DCP
    # sources. The WPF-side session value is only a fallback for the selector
    # before the first snapshot arrives.
    # The bridge owns account validation, provider-scoped entries, state, and
    # auth synchronization. It is reloaded for every request, so this display
    # path cannot drift from the OpenCode/TUI account manager.
    $response = Invoke-Bridge @('snapshot')
    if (-not (Get-Prop $response 'ok' $false)) {
        $message = [string](Get-Prop $response 'error' 'Account bridge request failed')
        throw $message
    }
    $snapshot = Get-Prop $response 'snapshot' $null
    if ($null -eq $snapshot) { throw 'Account bridge returned no snapshot' }

    $context = Get-Prop $snapshot 'context' $null
    $contextTokens = Get-Prop $context 'tokens' $null
    if ($null -ne $contextTokens) {
        try { $contextTokens = [double]$contextTokens } catch { $contextTokens = $null }
    }
    $sessionId = [string](Get-Prop $snapshot 'sessionId' '')
    return [pscustomobject]@{
        Accounts = @(Get-Prop $snapshot 'accounts' @())
        Tracking = Get-Prop $snapshot 'tracking' $null
        CurrentAccountId = [string](Get-Prop $snapshot 'currentAccountId' '')
        SessionAccountId = [string](Get-Prop $snapshot 'sessionAccountId' '')
        SessionId = $sessionId
        LastUpdated = [string](Get-Prop $snapshot 'observedAt' (Get-Prop $snapshot 'lastUpdated' ''))
        StateLastUpdated = [string](Get-Prop $snapshot 'lastUpdated' '')
        ContextTokens = $contextTokens
        Context = $context
        Quota = Get-Prop $snapshot 'quota' $null
        KeyHealth = Get-Prop $snapshot 'keyHealth' $null
        Config = Get-Config
    }
}

function Set-Text([string]$Name, [string]$Value) {
    if ($null -eq $script:Window) { return }
    $control = $script:Window.FindName($Name)
    if ($null -ne $control -and $control.PSObject.Properties['Text']) { $control.Text = $Value }
}

function Set-AccountRows($Snapshot) {
    $list = $script:Window.FindName('AccountList')
    if ($null -eq $list) { return }
    $signature = (@($Snapshot.Accounts | ForEach-Object {
        '{0}|{1}|{2:0}|{3}|{4}' -f $_.Id, $_.Status, $_.CooldownRemainingMs, $_.IsGlobalCurrent, $_.IsSessionCurrent
    }) -join '||')
    if ($signature -eq $script:LastAccountSignature) { return }
    $script:LastAccountSignature = $signature
    $list.Children.Clear()

    foreach ($account in @($Snapshot.Accounts)) {
        $row = New-Object System.Windows.Controls.Border
        $row.Background = $script:BrushPanel
        $row.BorderBrush = [System.Windows.Media.Brushes]::Transparent
        $row.BorderThickness = New-Object System.Windows.Thickness(0)
        $row.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $row.Padding = New-Object System.Windows.Thickness(10, 9, 10, 9)
        $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
        $row.Add_MouseEnter({ param($sender, $eventArgs) $sender.Background = $script:BrushPanelHover }.GetNewClosure())
        $row.Add_MouseLeave({ param($sender, $eventArgs) $sender.Background = $script:BrushPanel }.GetNewClosure())

        $grid = New-Object System.Windows.Controls.Grid
        $dotColumn = New-Object System.Windows.Controls.ColumnDefinition
        $dotColumn.Width = [System.Windows.GridLength]::Auto
        $textColumn = New-Object System.Windows.Controls.ColumnDefinition
        $textColumn.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $buttonColumn = New-Object System.Windows.Controls.ColumnDefinition
        $buttonColumn.Width = [System.Windows.GridLength]::Auto
        $grid.ColumnDefinitions.Add($dotColumn) | Out-Null
        $grid.ColumnDefinitions.Add($textColumn) | Out-Null
        $grid.ColumnDefinitions.Add($buttonColumn) | Out-Null

        $dot = New-Object System.Windows.Controls.Border
        $dot.Width = 8; $dot.Height = 8; $dot.CornerRadius = New-Object System.Windows.CornerRadius(4)
        $dot.Background = Get-StatusColor $account.Status
        $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $dot.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
        [System.Windows.Controls.Grid]::SetColumn($dot, 0)
        $grid.Children.Add($dot) | Out-Null

        $textPanel = New-Object System.Windows.Controls.StackPanel
        $textPanel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = [string]$account.Name
        $name.Foreground = $script:BrushText
        $name.FontSize = 12
        $name.FontWeight = [System.Windows.FontWeights]::SemiBold
        $name.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $textPanel.Children.Add($name) | Out-Null
        $meta = New-Object System.Windows.Controls.TextBlock
        $marks = @()
        if ($account.IsGlobalCurrent) { $marks += 'GLOBAL' }
        if ($account.IsSessionCurrent) { $marks += 'SESSION' }
        if ($marks.Count -eq 0) { $marks += ('P' + $account.Priority) }
        $metaText = ('{0} - {1} - {2}' -f $account.Provider, ($marks -join '+'), $account.Status)
        if ($account.Status -eq 'rate_limited') { $metaText += ' - ' + (Format-Cooldown $account.CooldownRemainingMs) }
        $meta.Text = $metaText
        $meta.Foreground = $script:BrushFaint
        $meta.FontSize = 9.5
        $meta.Margin = New-Object System.Windows.Thickness(0, 2, 8, 0)
        $meta.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $textPanel.Children.Add($meta) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($textPanel, 1)
        $grid.Children.Add($textPanel) | Out-Null

        $button = New-Object System.Windows.Controls.Button
        $button.Tag = [string]$account.Id
        $button.Content = if ($account.IsGlobalCurrent) { 'CURRENT' } elseif (-not $account.Selectable) { 'WAIT' } else { 'USE' }
        $button.Width = 64
        $button.Height = 26
        $button.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $button.FontSize = 10
        $button.FontWeight = [System.Windows.FontWeights]::SemiBold
        $button.Foreground = if ($account.IsGlobalCurrent) { $script:BrushText } else { $script:BrushAccentInk }
        $button.Background = if ($account.IsGlobalCurrent) { $script:BrushPanel2 } else { $script:BrushAccent }
        $button.BorderBrush = if ($account.IsGlobalCurrent) { $script:BrushBorder } else { $script:BrushAccent }
        $button.BorderThickness = New-Object System.Windows.Thickness(1)
        $button.Cursor = [System.Windows.Input.Cursors]::Hand
        $button.IsEnabled = [bool]$account.Selectable
        $button.Opacity = if ($account.Selectable) { 1.0 } else { 0.55 }
        $button.ToolTip = 'Switch the global OpenCode account'
        $buttonStyle = $script:Window.TryFindResource('UseButton')
        if ($null -ne $buttonStyle) { $button.Style = $buttonStyle }
        Enable-ControlTransitions $button
        $accountId = [string]$account.Id
        $button.Add_Click({ param($sender, $eventArgs) Invoke-AccountSwitch $accountId }.GetNewClosure())
        [System.Windows.Controls.Grid]::SetColumn($button, 2)
        $grid.Children.Add($button) | Out-Null
        $row.Child = $grid
        $list.Children.Add($row) | Out-Null
    }
}

function Update-TrackingText($Snapshot) {
    $tracking = $Snapshot.Tracking
    $rateEvents = [int](Get-Prop $tracking 'totalRateLimitEvents' 0)
    $rotations = [int](Get-Prop $tracking 'totalRotations' 0)
    $manual = [int](Get-Prop $tracking 'totalManualSwitches' 0)
    $last = [string](Get-Prop $tracking 'lastRotationAt' '')
    $lastText = 'never'
    if ($last) {
        try { $lastText = ([datetime]::Parse($last).ToLocalTime()).ToString('g') } catch { $lastText = $last }
    }
    $text = ('Rate-limit events  {0}     Automatic rotations  {1}     Manual switches  {2}' -f $rateEvents, $rotations, $manual) + [Environment]::NewLine + ('Last rotation  {0}' -f $lastText)
    Set-Text 'TrackingText' $text
}

function Update-Widget {
    try {
        $script:SessionId = Get-SessionId
        $snapshot = Get-AccountSnapshot
        if (-not [string]::IsNullOrWhiteSpace([string]$snapshot.SessionId)) {
            $script:SessionId = [string]$snapshot.SessionId
        }
        $accounts = @($snapshot.Accounts)
        $active = @($accounts | Where-Object { $_.Status -eq 'active' })
        $cooling = @($accounts | Where-Object { $_.Status -eq 'rate_limited' })
        $current = $accounts | Where-Object { $_.IsSessionCurrent } | Select-Object -First 1
        if ($null -eq $current) { $current = $accounts | Where-Object { $_.IsGlobalCurrent } | Select-Object -First 1 }
        if ($null -eq $current -and $accounts.Count -gt 0) { $current = $accounts[0] }
        $tracking = $snapshot.Tracking
        $rotations = [int](Get-Prop $tracking 'totalRotations' 0)
        $manual = [int](Get-Prop $tracking 'totalManualSwitches' 0)
        $quotaForDisplay = $snapshot.Quota
        $quotaMini = 'tokens n/a'
        if ([bool](Get-Prop $quotaForDisplay 'available' $false)) {
            $quotaMini = ('tokens {0}/{1}' -f (Format-Tokens ([double](Get-Prop $quotaForDisplay 'used' 0))), (Format-Tokens ([double](Get-Prop $quotaForDisplay 'limit' 0))))
        }

        Set-Text 'HealthyValue' ([string]$active.Count + '/' + [string]$accounts.Count)
        Set-Text 'HealthyValue2' ([string]$active.Count + '/' + [string]$accounts.Count)
        Set-Text 'CoolingValue' ([string]$cooling.Count)
        Set-Text 'RotationValue' ([string]$rotations)
        Set-Text 'ManualValue' ([string]$manual)
        Set-Text 'AccountCountText' ($accounts.Count.ToString() + ' configured')

        if ($null -ne $current) {
            Set-Text 'CurrentText' ([string]$current.Name)
            $statusLabel = switch ($current.Status) { 'active' { 'Active' } 'rate_limited' { 'Rate limited' } 'disabled' { 'Disabled' } 'invalid' { 'Key invalid' } default { [string]$current.Status } }
            Set-Text 'CurrentSubText' $statusLabel
            $dot = $script:Window.FindName('CurrentDot')
            if ($null -ne $dot) { $dot.Background = Get-StatusColor $current.Status }
        } else {
            Set-Text 'CurrentText' 'No account loaded'
            Set-Text 'CurrentSubText' 'OpenCode multi-account state unavailable'
            $dot = $script:Window.FindName('CurrentDot')
            if ($null -ne $dot) { $dot.Background = $script:BrushRed }
        }

        $miniAccount = if ($null -ne $current) { [string]$current.Name } else { 'No account' }
        $miniStatus = if ($null -ne $current) { ([string]$current.Provider + ' - ' + $quotaMini) } else { 'state unavailable' }
        Set-Text 'MiniAccountText' $miniAccount
        Set-Text 'MiniStatusText' $miniStatus
        Set-Text 'MiniHealth' ('{0}/{1}' -f $active.Count, $accounts.Count)

        $config = $snapshot.Config
        $context = $snapshot.ContextTokens
        $contextInfo = $snapshot.Context
        $contextFresh = [bool](Get-Prop $contextInfo 'fresh' $false)
        $contextSource = [string](Get-Prop $contextInfo 'source' '')
        $usageBar = $script:Window.FindName('UsageBar')
        if ($null -ne $usageBar) {
            $usageBar2 = $script:Window.FindName('UsageBar2')
            if ($null -eq $context) {
                $usageBar.Value = 0
                $usageBar.Foreground = $script:BrushFaint
                if ($null -ne $usageBar2) { $usageBar2.Value = 0; $usageBar2.Foreground = $script:BrushFaint }
                Set-Text 'UsageText' 'Context tokens  n/a  -  no active data'
                Set-Text 'UsageText2' 'Context tokens  n/a  -  no active data'
            } else {
                $contextLimit = [double](Get-Prop $contextInfo 'limit' 0)
                if ($contextLimit -le 0) { $contextLimit = [double]$config.LocalBudgetTokens }
                $rawRatio = ([double]$context / $contextLimit) * 100
                $ratio = [Math]::Max(0, [Math]::Min(100, $rawRatio))
                $usageColor = if ($rawRatio -ge 90) { $script:BrushRed } elseif ($rawRatio -ge 70) { $script:BrushAmber } else { $script:BrushGreen }
                $usageBar.Value = $ratio
                $usageBar.Foreground = $usageColor
                if ($null -ne $usageBar2) { $usageBar2.Value = $ratio; $usageBar2.Foreground = $usageColor }
                $freshLabel = if ($contextFresh) { 'live' } else { 'stale' }
                $usageText = ('{0} / {1}  ·  {2:0}%  ·  {3}' -f (Format-Tokens $context), (Format-Tokens $contextLimit), $rawRatio, $freshLabel)
                Set-Text 'UsageText' $usageText
                Set-Text 'UsageText2' $usageText
            }
        }

        $miniUsage = $script:Window.FindName('MiniUsageBar')
        if ($null -ne $miniUsage) {
            if ($null -eq $context) {
                $miniUsage.Value = 0
                $miniUsage.Foreground = $script:BrushFaint
            } else {
                $miniUsage.Value = $ratio
                $miniUsage.Foreground = $usageColor
            }
        }

        $quota = $snapshot.Quota
        $quotaAvailable = [bool](Get-Prop $quota 'available' $false)
        if ($quotaAvailable) {
            $used = [double](Get-Prop $quota 'used' 0)
            $limit = [double](Get-Prop $quota 'limit' 0)
            if ($limit -gt 0) {
                $qRatio = [Math]::Max(0, [Math]::Min(100, ($used / $limit) * 100))
                $quotaFresh = [bool](Get-Prop $quota 'fresh' $false)
                $quotaLabel = if ($quotaFresh) { 'live' } else { 'stale' }
                Set-Text 'QuotaText' ('Session tokens  {0} / {1}  -  {2:0}%  -  {3}' -f (Format-Tokens $used), (Format-Tokens $limit), $qRatio, $quotaLabel)
            } else {
                Set-Text 'QuotaText' 'Session tokens  n/a'
            }
        } else {
            Set-Text 'QuotaText' 'Session tokens  n/a  -  no active session'
        }

        $keyHealth = $snapshot.KeyHealth
        if ([bool](Get-Prop $keyHealth 'available' $false)) {
            $khPass = [int](Get-Prop $keyHealth 'pass' 0)
            $khTotal = [int](Get-Prop $keyHealth 'total' 0)
            $khMark = if ([bool](Get-Prop $keyHealth 'ok' $false)) { 'OK' } else { 'FAIL' }
            $khAgeMs = [double](Get-Prop $keyHealth 'ageMs' 0)
            $khAge = ''
            if ($khAgeMs -gt (24 * 60 * 60 * 1000)) {
                $khAge = '  -  ' + [string][Math]::Floor($khAgeMs / 86400000) + 'd old'
            }
            Set-Text 'KeyHealthText' ('Zen keys  {0}/{1}  -  {2}{3}' -f $khPass, $khTotal, $khMark, $khAge)
        } else {
            Set-Text 'KeyHealthText' 'Zen keys  n/a  -  run zen_key_probe.mjs'
        }

        $scopeBox = $script:Window.FindName('ScopeBox')
        if ($null -ne $scopeBox) {
            $scopeSession = $scopeBox.Items | Where-Object { $_.Content -eq 'This session' } | Select-Object -First 1
            if ($null -ne $scopeSession) { $scopeSession.IsEnabled = -not [string]::IsNullOrWhiteSpace([string]$script:SessionId) }
            if ($scopeBox.SelectedIndex -lt 0) { $scopeBox.SelectedIndex = 0 }
        }
        $sessionText = if ([string]::IsNullOrWhiteSpace([string]$script:SessionId)) { 'No active session detected' } else { 'Session ' + ([string]$script:SessionId).Substring(0, [Math]::Min(18, ([string]$script:SessionId).Length)) + '...' }
        Set-Text 'ScopeText' $sessionText
        Set-AccountRows $snapshot
        Update-TrackingText $snapshot

        $updated = $snapshot.LastUpdated
        if ($updated) {
            try { $updated = ([datetime]::Parse($updated).ToLocalTime()).ToString('HH:mm:ss') } catch { }
        } else { $updated = 'unknown' }
        Set-Text 'FooterText' ('{0} accounts  ·  updated {1}' -f $accounts.Count, $updated)
        Set-Text 'FooterText2' ('Updated {0}  ·  Drag the title to move  ·  click USE to switch globally' -f $updated)
    } catch {
        $message = $_.Exception.Message
        try {
            $debug = @(
                ('[' + (Get-Date).ToString('o') + '] ' + $message),
                $_.ScriptStackTrace,
                ($_.InvocationInfo | Out-String)
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $script:Root 'widget-error.log') -Value $debug -Encoding UTF8
        } catch { }
        if ($message.Length -gt 160) { $message = $message.Substring(0, 160) }
        $script:LastStatusText = $message
        Set-Text 'FooterText' ('Widget refresh error: ' + $message)
        Set-Text 'FooterText2' ('Widget refresh error: ' + $message)
    }
}

function Quote-Arg([string]$Value) {
    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Stop-BridgeProcess {
    $process = $script:BridgeProcess
    $script:BridgeProcess = $null
    $script:BridgeWriter = $null
    $script:BridgeReader = $null
    if ($null -eq $process) { return }
    try {
        if (-not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(750)
        }
    } catch { }
    try { $process.Dispose() } catch { }
}

function Start-BridgeProcess {
    if ($null -ne $script:BridgeProcess) {
        try {
            if (-not $script:BridgeProcess.HasExited) { return $true }
        } catch { }
        Stop-BridgeProcess
    }

    if ([string]::IsNullOrWhiteSpace($script:NodeExe)) {
        $command = Get-Command node.exe -ErrorAction SilentlyContinue
        if ($null -ne $command) { $script:NodeExe = $command.Source } else { $script:NodeExe = 'node' }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:NodeExe
    $psi.Arguments = ((Quote-Arg $script:Bridge) + ' --daemon')
    $psi.WorkingDirectory = $script:Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $false
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $script:BridgeProcess = $process
    $script:BridgeWriter = $process.StandardInput
    $script:BridgeWriter.AutoFlush = $true
    $script:BridgeReader = $process.StandardOutput
    return $true
}

function Invoke-Bridge([string[]]$Arguments) {
    $command = if ($null -ne $Arguments -and $Arguments.Count -gt 0) { [string]$Arguments[0] } else { 'snapshot' }
    $accountId = if ($null -ne $Arguments -and $Arguments.Count -gt 1) { [string]$Arguments[1] } else { '' }
    $scope = if ($null -ne $Arguments -and $Arguments.Count -gt 2) { [string]$Arguments[2] } else { 'global' }
    $sessionId = if ($null -ne $Arguments -and $Arguments.Count -gt 3) { [string]$Arguments[3] } else { '' }

    try {
        Start-BridgeProcess | Out-Null
        $script:BridgeRequestId = [int]$script:BridgeRequestId + 1
        $requestId = $script:BridgeRequestId
        $request = [ordered]@{
            id = $requestId
            command = $command
            accountId = $accountId
            scope = $scope
            sessionId = $sessionId
        }
        $script:BridgeWriter.WriteLine(($request | ConvertTo-Json -Compress))
        $readTask = $script:BridgeReader.ReadLineAsync()
        if (-not $readTask.Wait($script:BridgeTimeoutMs)) {
            throw 'Account bridge timed out'
        }
        $line = [string]$readTask.Result
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw 'Account bridge returned no result'
        }
        $response = $line | ConvertFrom-Json
        $responseId = Get-Prop $response 'id' $null
        if ($null -ne $responseId -and [int]$responseId -ne $requestId) {
            throw 'Account bridge response mismatch'
        }
        return $response
    } catch {
        Stop-BridgeProcess
        throw
    }
}

function Invoke-AccountSwitch([string]$AccountId) {
    if ($script:Switching) { return }
    $scopeBox = $script:Window.FindName('ScopeBox')
    $scope = if ($null -ne $scopeBox -and $scopeBox.SelectedIndex -eq 1) { 'session' } else { 'global' }
    if ($scope -eq 'session' -and [string]::IsNullOrWhiteSpace([string]$script:SessionId)) {
        Set-Text 'FooterText' 'No active session detected; choose Global default or wait for a session.'
        return
    }
    $script:Switching = $true
    try {
        $sid = if ($scope -eq 'session') { [string]$script:SessionId } else { '' }
        $result = Invoke-Bridge @('switch', $AccountId, $scope, $sid)
        if ($result.ok) {
            $name = [string]$result.account.name
            $script:LastStatusText = ('Switched to ' + $name + ' (' + $scope + ')')
            Set-Text 'FooterText' ('Switched to ' + $name + ' - ' + $scope + ' scope')
        } else {
            $reason = if ($result.reason) { [string]$result.reason } elseif ($result.error) { [string]$result.error } else { 'unavailable' }
            $script:LastStatusText = 'Switch blocked: ' + $reason
            Set-Text 'FooterText' ('Switch blocked: ' + $reason)
        }
    } catch {
        $message = $_.Exception.Message
        if ($message.Length -gt 160) { $message = $message.Substring(0, 160) }
        $script:LastStatusText = 'Switch failed: ' + $message
        Set-Text 'FooterText' ('Switch failed: ' + $message)
    } finally {
        $script:Switching = $false
        Update-Widget
    }
}

function Set-ResponsiveLayout {
    if ($null -eq $script:Window) { return }
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $availableWidth = [Math]::Max(180, $workArea.Width - 24)
    $availableHeight = [Math]::Max(64, $workArea.Height - 24)
    $script:Window.MinWidth = 180
    $script:Window.MinHeight = 64
    if ($script:Minimized) {
        $script:Window.Width = [Math]::Min(220, $availableWidth)
        $script:Window.Height = [Math]::Min(64, $availableHeight)
    } elseif ($script:Expanded) {
        $script:Window.Width = [Math]::Min(400, $availableWidth)
        $script:Window.Height = [Math]::Min(600, $availableHeight)
    } else {
        $script:Window.Width = [Math]::Min(360, $availableWidth)
        $script:Window.Height = [Math]::Min(160, $availableHeight)
    }
}

function Fade-Element($Element, [bool]$Visible) {
    if ($null -eq $Element) { return }
    $Element.BeginAnimation([System.Windows.FrameworkElement]::OpacityProperty, $null)
    $Element.Opacity = if ($Visible) { 0.0 } else { 1.0 }
    if (-not $Visible) { return }
    $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $animation.From = 0.0
    $animation.To = 1.0
    $animation.Duration = [TimeSpan]::FromMilliseconds(180)
    $animation.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
    $Element.BeginAnimation([System.Windows.FrameworkElement]::OpacityProperty, $animation)
}

function Set-ViewMode {
    if ($null -eq $script:Window) { return }
    $isMini = [bool]$script:Minimized
    $isExpanded = (-not $isMini -and [bool]$script:Expanded)
    $details = $script:Window.FindName('DetailsPanel')
    $compact = $script:Window.FindName('CompactPanel')
    $mini = $script:Window.FindName('MiniPanel')
    $toggle = $script:Window.FindName('ToggleButton')
    $toggleIcon = $script:Window.FindName('ToggleIcon')
    $minimize = $script:Window.FindName('MinimizeButton')
    $minimizeIcon = $script:Window.FindName('MinimizeIcon')
    $shell = $script:Window.FindName('Shell')
    $header = $script:Window.FindName('HeaderGrid')
    $headerRow = $script:Window.FindName('HeaderRow')
    $headerTitle = $script:Window.FindName('HeaderTitle')
    $headerSubtitle = $script:Window.FindName('HeaderSubtitle')

    if ($null -ne $details) { $details.Visibility = if ($isExpanded) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    if ($null -ne $compact) { $compact.Visibility = if ((-not $isMini) -and (-not $isExpanded)) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    if ($null -ne $mini) { $mini.Visibility = if ($isMini) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    if ($null -ne $toggle) { $toggle.Visibility = if ($isMini) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible } }
    if ($null -ne $headerSubtitle) { $headerSubtitle.Visibility = if ($isMini) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible } }
    if ($null -ne $headerTitle) { $headerTitle.FontSize = if ($isMini) { 9.0 } else { 10.0 } }
    if ($null -ne $shell) { $shell.Padding = if ($isMini) { New-Object System.Windows.Thickness(10, 7, 10, 7) } else { New-Object System.Windows.Thickness(16, 14, 16, 14) } }
    if ($null -ne $header) { $header.Height = if ($isMini) { 22.0 } else { 30.0 } }
    if ($null -ne $headerRow) { $headerRow.Height = if ($isMini) { 22.0 } else { 30.0 } }
    if ($null -ne $minimize) {
        $minimize.ToolTip = if ($isMini) { 'Restore compact widget' } else { 'Minimize to tray' }
    }
    if ($null -ne $minimizeIcon) {
        $minimizeIcon.Data = [System.Windows.Media.Geometry]::Parse($(if ($isMini) { 'M 0,4 L 8,4 M 4,0 L 4,8' } else { 'M 0,4 L 8,4' }))
    }
    if ($null -ne $toggleIcon) {
        $toggleIcon.Data = [System.Windows.Media.Geometry]::Parse($(if ($isExpanded) { 'M 0,4 L 4,0 L 8,4' } else { 'M 0,0 L 4,4 L 8,0' }))
    }
    Set-ResponsiveLayout
    if ($isMini) {
        Fade-Element $mini $true
    } elseif ($isExpanded) {
        Fade-Element $details $true
    } else {
        Fade-Element $compact $true
    }
}

function Set-Expanded([bool]$Value) {
    if ($Value -and $script:Minimized) { $script:Minimized = $false }
    $script:Expanded = $Value
    Set-ViewMode
    Update-Widget
    Save-WindowPosition
}

function Set-Minimized([bool]$Value) {
    $script:Minimized = $Value
    if ($Value) { $script:Expanded = $false }
    Set-ViewMode
    Update-Widget
    Save-WindowPosition
}

function Animate-ControlScale($Control, [double]$Scale) {
    if ($null -eq $Control) { return }
    $transform = $Control.RenderTransform
    if (-not ($transform -is [System.Windows.Media.ScaleTransform])) { return }
    $duration = [TimeSpan]::FromMilliseconds(200)
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $x = New-Object System.Windows.Media.Animation.DoubleAnimation
    $x.From = $transform.ScaleX
    $x.To = $Scale
    $x.Duration = $duration
    $x.EasingFunction = $ease
    $y = New-Object System.Windows.Media.Animation.DoubleAnimation
    $y.From = $transform.ScaleY
    $y.To = $Scale
    $y.Duration = $duration
    $y.EasingFunction = $ease
    $transform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $x)
    $transform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $y)
}

function Enable-ControlTransitions($Control) {
    if ($null -eq $Control) { return }
    $transform = New-Object System.Windows.Media.ScaleTransform 1.0, 1.0
    $Control.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
    $Control.RenderTransform = $transform
    $Control.Add_MouseEnter({ param($sender, $eventArgs) Animate-ControlScale $sender 1.04 }.GetNewClosure())
    $Control.Add_MouseLeave({ param($sender, $eventArgs) Animate-ControlScale $sender 1.0 }.GetNewClosure())
    $Control.Add_GotKeyboardFocus({ param($sender, $eventArgs) Animate-ControlScale $sender 1.03 }.GetNewClosure())
    $Control.Add_LostKeyboardFocus({ param($sender, $eventArgs) Animate-ControlScale $sender 1.0 }.GetNewClosure())
    $Control.Add_MouseLeftButtonDown({ param($sender, $eventArgs) Animate-ControlScale $sender 0.98 }.GetNewClosure())
    $Control.Add_MouseLeftButtonUp({ param($sender, $eventArgs) Animate-ControlScale $sender 1.0 }.GetNewClosure())
}

function Move-Window([System.Windows.Point]$Point) {
    $script:Window.Left = $script:WindowOrigin.X + ($Point.X - $script:DragOrigin.X)
    $script:Window.Top = $script:WindowOrigin.Y + ($Point.Y - $script:DragOrigin.Y)
}

function Save-WindowPosition {
    try {
        if (-not (Test-Path -LiteralPath $script:SettingsDir -PathType Container)) { New-Item -ItemType Directory -Path $script:SettingsDir -Force | Out-Null }
        $settings = [pscustomobject]@{ Left = $script:Window.Left; Top = $script:Window.Top; Expanded = $script:Expanded; Minimized = $script:Minimized }
        $settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    } catch { }
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OpenCode Account Widget"
        Width="380" Height="176"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        WindowStartupLocation="Manual" FontFamily="Segoe UI" FontSize="12"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="IconButton" TargetType="Button">
      <Setter Property="Width" Value="26" />
      <Setter Property="Height" Value="26" />
      <Setter Property="Margin" Value="4,0,0,0" />
      <Setter Property="Foreground" Value="#E6E6EA" />
      <Setter Property="Background" Value="#10FFFFFF" />
      <Setter Property="BorderBrush" Value="#1FFFFFFF" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" Padding="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#1CFFFFFF" />
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#33FFFFFF" />
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.62" />
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#E6E6EA" />
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.35" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="UseButton" TargetType="Button">
      <Setter Property="Foreground" Value="#0A0A0C" />
      <Setter Property="Background" Value="#E6E6EA" />
      <Setter Property="BorderBrush" Value="#E6E6EA" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="8,2">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.86" />
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.64" />
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#E6E6EA" />
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.32" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="TrackerBar" TargetType="ProgressBar">
      <Setter Property="Height" Value="5" />
      <Setter Property="Background" Value="#12FFFFFF" />
      <Setter Property="Foreground" Value="#E6E6EA" />
      <Setter Property="BorderThickness" Value="0" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border Background="{TemplateBinding Background}" CornerRadius="2.5" />
              <Border x:Name="PART_Track" />
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}" CornerRadius="2.5" />
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ScopeComboItem" TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#F4F4F6" />
      <Setter Property="Background" Value="#1CFFFFFF" />
      <Setter Property="Padding" Value="9,6" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Chrome" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#3AFFFFFF" />
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#40FFFFFF" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ScopeCombo" TargetType="ComboBox">
      <Setter Property="Foreground" Value="#F4F4F6" />
      <Setter Property="Background" Value="#1CFFFFFF" />
      <Setter Property="BorderBrush" Value="#40FFFFFF" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="Padding" Value="9,4" />
      <Setter Property="FontSize" Value="10" />
      <Setter Property="MinHeight" Value="30" />
      <Setter Property="ItemContainerStyle" Value="{StaticResource ScopeComboItem}" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                  </Grid.ColumnDefinitions>
                  <ContentPresenter x:Name="Selected" Grid.Column="0" Margin="{TemplateBinding Padding}" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" VerticalAlignment="Center" TextElement.Foreground="{TemplateBinding Foreground}" />
                  <Path Grid.Column="1" Data="M 0,0 L 4,4 L 8,0" Stroke="#9A9AA2" StrokeThickness="1.2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Width="10" Height="10" Stretch="Uniform" Margin="0,0,9,0" />
                </Grid>
              </Border>
              <ToggleButton x:Name="PART_ToggleButton" Focusable="False" ClickMode="Press" Background="Transparent" BorderThickness="0" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent" />
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False" IsOpen="{TemplateBinding IsDropDownOpen}" PopupAnimation="Fade">
                <Border Background="#F21C1C20" BorderBrush="#40FFFFFF" BorderThickness="1" CornerRadius="8" Padding="4" MinWidth="{TemplateBinding ActualWidth}">
                  <ScrollViewer>
                    <ItemsPresenter />
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#66FFFFFF" />
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.45" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Border x:Name="Shell" Background="#FF0C0C10" BorderBrush="#24FFFFFF" BorderThickness="1" CornerRadius="12" Padding="16,14,16,14">
      <Border.Effect>
        <DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.5" Color="#000000" />
      </Border.Effect>
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition x:Name="HeaderRow" Height="30" />
          <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
        <Grid x:Name="HeaderGrid" Grid.Row="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*" />
            <ColumnDefinition Width="Auto" />
          </Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Border x:Name="CurrentDot" Width="8" Height="8" CornerRadius="4" Background="#93D9B4" VerticalAlignment="Center" Margin="0,0,8,0">
              <Border.Effect>
                <DropShadowEffect BlurRadius="10" ShadowDepth="0" Opacity="0.4" Color="#30000000" />
              </Border.Effect>
            </Border>
            <TextBlock x:Name="HeaderTitle" Text="OPENCODE" Foreground="#9A9AA2" FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center" />
            <TextBlock x:Name="HeaderSubtitle" Text="ACCOUNTS" Foreground="#5E5E66" FontSize="10" Margin="6,0,0,0" VerticalAlignment="Center" />
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="ToggleButton" Style="{StaticResource IconButton}" ToolTip="Expand / collapse" AutomationProperties.Name="Expand or collapse widget">
              <Path x:Name="ToggleIcon" Data="M 0,0 L 4,4 L 8,0" Stroke="#B4B4BC" StrokeThickness="1.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Width="10" Height="10" Stretch="Uniform" />
            </Button>
            <Button x:Name="MinimizeButton" Style="{StaticResource IconButton}" ToolTip="Minimize to tray" AutomationProperties.Name="Minimize widget to tray">
              <Path x:Name="MinimizeIcon" Data="M 0,4 L 8,4" Stroke="#B4B4BC" StrokeThickness="1.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Width="10" Height="10" Stretch="Uniform" />
            </Button>
            <Button x:Name="CloseButton" Style="{StaticResource IconButton}" ToolTip="Quit widget" AutomationProperties.Name="Quit widget">
              <Path Data="M 0,0 L 8,8 M 8,0 L 0,8" Stroke="#B4B4BC" StrokeThickness="1.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Width="10" Height="10" Stretch="Uniform" />
            </Button>
          </StackPanel>
        </Grid>
        <Grid x:Name="CompactPanel" Grid.Row="1" Margin="0,10,0,0" Cursor="Hand" ToolTip="Click to expand">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
          </Grid.RowDefinitions>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*" />
            <ColumnDefinition Width="Auto" />
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Row="0" Grid.Column="0">
            <TextBlock x:Name="CurrentText" Text="Loading account..." Foreground="#F4F4F6" FontSize="19" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" />
            <TextBlock x:Name="CurrentSubText" Text="Reading state" Foreground="#9A9AA2" FontSize="10.5" Margin="0,2,0,0" />
          </StackPanel>
          <StackPanel Grid.Row="0" Grid.Column="1" VerticalAlignment="Center" HorizontalAlignment="Right">
            <TextBlock Text="HEALTH" Foreground="#5E5E66" FontSize="8.5" HorizontalAlignment="Right" />
            <TextBlock x:Name="HealthyValue" Text="-" Foreground="#93D9B4" FontSize="15" FontWeight="Bold" HorizontalAlignment="Right" Margin="0,1,0,0" />
          </StackPanel>
          <StackPanel Grid.Row="1" Grid.ColumnSpan="2" Margin="0,14,0,0">
            <TextBlock Text="CONTEXT" Foreground="#5E5E66" FontSize="8.5" FontWeight="SemiBold" />
            <ProgressBar x:Name="UsageBar" Style="{StaticResource TrackerBar}" Minimum="0" Maximum="100" Value="0" Margin="0,6,0,0" />
            <TextBlock x:Name="UsageText" Text="Context tokens  n/a" Foreground="#6E6E76" FontSize="9.5" Margin="0,5,0,0" TextTrimming="CharacterEllipsis" />
          </StackPanel>
          <TextBlock x:Name="FooterText" Grid.Row="2" Grid.ColumnSpan="2" Text="Loading" Foreground="#5E5E66" FontSize="9" Margin="0,10,0,0" TextTrimming="CharacterEllipsis" />
        </Grid>
        <Grid x:Name="MiniPanel" Grid.Row="1" Margin="0,4,0,0" Visibility="Collapsed" Background="Transparent" Cursor="Hand" ToolTip="Click to restore compact widget" AutomationProperties.Name="Tiny account tracker; click to restore compact widget">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
          </Grid.RowDefinitions>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*" />
            <ColumnDefinition Width="Auto" />
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Row="0" Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="MiniAccountText" Text="No account" Foreground="#F4F4F6" FontSize="11" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" />
            <TextBlock x:Name="MiniStatusText" Text="state unavailable" Foreground="#5E5E66" FontSize="9" Margin="7,0,0,0" TextTrimming="CharacterEllipsis" />
          </StackPanel>
          <TextBlock x:Name="MiniHealth" Grid.Row="0" Grid.Column="1" Text="0/0" Foreground="#E6E6EA" FontSize="11" FontWeight="Bold" VerticalAlignment="Center" Margin="8,0,0,0" />
          <ProgressBar x:Name="MiniUsageBar" Grid.Row="1" Grid.ColumnSpan="2" Style="{StaticResource TrackerBar}" Minimum="0" Maximum="100" Value="0" Height="3" Margin="0,5,0,0" />
        </Grid>
        <StackPanel x:Name="DetailsPanel" Grid.Row="1" Margin="0,12,0,0" Visibility="Collapsed">
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="0,0,6,0">
            <StackPanel>
              <WrapPanel x:Name="StatsGrid" Orientation="Horizontal" Margin="0,0,0,8">
                <Border Width="78" Background="#0FFFFFFF" CornerRadius="8" Padding="10,8" Margin="0,0,6,6">
                  <StackPanel><TextBlock x:Name="HealthyValue2" Text="-" Foreground="#93D9B4" FontSize="16" FontWeight="Bold" /><TextBlock Text="HEALTHY" Foreground="#5E5E66" FontSize="8" Margin="0,2,0,0" /></StackPanel>
                </Border>
                <Border Width="78" Background="#0FFFFFFF" CornerRadius="8" Padding="10,8" Margin="0,0,6,6">
                  <StackPanel><TextBlock x:Name="CoolingValue" Text="-" Foreground="#D9C08C" FontSize="16" FontWeight="Bold" /><TextBlock Text="COOLING" Foreground="#5E5E66" FontSize="8" Margin="0,2,0,0" /></StackPanel>
                </Border>
                <Border Width="78" Background="#0FFFFFFF" CornerRadius="8" Padding="10,8" Margin="0,0,6,6">
                  <StackPanel><TextBlock x:Name="RotationValue" Text="-" Foreground="#E6E6EA" FontSize="16" FontWeight="Bold" /><TextBlock Text="ROTATIONS" Foreground="#5E5E66" FontSize="8" Margin="0,2,0,0" /></StackPanel>
                </Border>
                <Border Width="78" Background="#0FFFFFFF" CornerRadius="8" Padding="10,8" Margin="0,0,0,6">
                  <StackPanel><TextBlock x:Name="ManualValue" Text="-" Foreground="#A6BBD0" FontSize="16" FontWeight="Bold" /><TextBlock Text="MANUAL" Foreground="#5E5E66" FontSize="8" Margin="0,2,0,0" /></StackPanel>
                </Border>
              </WrapPanel>
              <Border Background="#0FFFFFFF" CornerRadius="10" Padding="12,10" Margin="0,0,0,14">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                    <TextBlock Text="TOKEN TRACKER" Foreground="#5E5E66" FontSize="8.5" FontWeight="SemiBold" VerticalAlignment="Center" />
                    <Border Grid.Column="1" Height="1" Background="#12FFFFFF" VerticalAlignment="Center" Margin="8,0,8,0" />
                    <TextBlock x:Name="AccountCountText" Grid.Column="2" Text="0 configured" Foreground="#5E5E66" FontSize="8.5" VerticalAlignment="Center" />
                  </Grid>
                  <ProgressBar x:Name="UsageBar2" Style="{StaticResource TrackerBar}" Minimum="0" Maximum="100" Value="0" Margin="0,9,0,0" />
                  <TextBlock x:Name="UsageText2" Text="Context tokens  n/a" Foreground="#9A9AA2" FontSize="10" Margin="0,6,0,0" />
                  <TextBlock x:Name="QuotaText" Text="Session tokens  n/a" Foreground="#5E5E66" FontSize="9.5" Margin="0,3,0,0" />
                  <TextBlock x:Name="KeyHealthText" Text="Zen keys  n/a" Foreground="#5E5E66" FontSize="9.5" Margin="0,3,0,0" />
                </StackPanel>
              </Border>
              <Grid Margin="0,0,0,14">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center">
                  <TextBlock Text="SWITCH TARGET" Foreground="#5E5E66" FontSize="8.5" FontWeight="SemiBold" />
                  <TextBlock x:Name="ScopeText" Text="No active session detected" Foreground="#9A9AA2" FontSize="10" Margin="0,3,0,0" />
                </StackPanel>
                <ComboBox x:Name="ScopeBox" Grid.Column="1" Width="145" Height="30" Style="{StaticResource ScopeCombo}" SelectedIndex="0" VerticalAlignment="Center" AutomationProperties.Name="Switch target scope" AutomationProperties.HelpText="Choose whether account switching applies to this session or globally">
                  <ComboBoxItem Content="Global default" />
                  <ComboBoxItem Content="This session" />
                </ComboBox>
              </Grid>
              <Grid Margin="0,0,0,7">
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                <TextBlock Text="ACCOUNTS" Foreground="#5E5E66" FontSize="8.5" FontWeight="SemiBold" VerticalAlignment="Center" />
                <Border Grid.Column="1" Height="1" Background="#12FFFFFF" VerticalAlignment="Center" Margin="8,0,0,0" />
              </Grid>
              <StackPanel x:Name="AccountList" />
              <Border Background="#0FFFFFFF" CornerRadius="10" Padding="12,10" Margin="0,12,0,0">
                <StackPanel>
                  <TextBlock Text="ROTATION TRACKER" Foreground="#5E5E66" FontSize="8.5" FontWeight="SemiBold" />
                  <TextBlock x:Name="TrackingText" Text="Rate-limit events  0     Automatic rotations  0     Manual switches  0" Foreground="#9A9AA2" FontSize="10" TextWrapping="Wrap" Margin="0,7,0,0" />
                </StackPanel>
              </Border>
              <TextBlock x:Name="FooterText2" Text="Updated unknown  ·  Drag the title to move  ·  click USE to switch globally" Foreground="#5E5E66" FontSize="9" Margin="0,12,0,0" />
            </StackPanel>
          </ScrollViewer>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$script:Window = [System.Windows.Markup.XamlReader]::Parse($xaml)
foreach ($controlName in @('MinimizeButton', 'ToggleButton', 'CloseButton')) {
    Enable-ControlTransitions $script:Window.FindName($controlName)
}
$script:Window.Add_SourceInitialized({
    Enable-NativeBackdrop
})
$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\OpenCodeAccountWidget')
try { $script:HasMutex = $script:Mutex.WaitOne(0, $false) } catch { $script:HasMutex = $true }
if (-not $script:HasMutex) { exit 0 }

$script:Window.Add_Loaded({
    $workArea = [System.Windows.SystemParameters]::WorkArea
    Set-ResponsiveLayout
    $script:Window.Left = $workArea.Right - $script:Window.Width - 18
    $script:Window.Top = $workArea.Top + 18
    $settings = Read-JsonFile $script:SettingsFile
    # ponytail: tiny/mini mode retired - widget minimizes straight to tray
    $script:Minimized = $false
    $script:Expanded = [bool](Get-Prop $settings 'Expanded' $false)
    Set-ViewMode
    if ($null -ne $settings) {
        try {
            $left = [double](Get-Prop $settings 'Left' ([double]$script:Window.Left))
            $top = [double](Get-Prop $settings 'Top' ([double]$script:Window.Top))
            if ($left -gt $workArea.Left - 100 -and $left -lt $workArea.Right - 100) { $script:Window.Left = $left }
            if ($top -gt $workArea.Top - 50 -and $top -lt $workArea.Bottom - 50) { $script:Window.Top = $top }
        } catch { }
    }
    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds((Get-Config).PollMs)
    $script:Timer.Add_Tick({
        Sync-OpenCodeVisibility
        Update-Widget
    })
    $script:Timer.Start()
    Update-Widget

    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    $script:Tray.Icon = [System.Drawing.SystemIcons]::Application
    $script:Tray.Text = 'OpenCode Account Widget'
    $script:TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $showItem = $script:TrayMenu.Items.Add('Show widget')
    $showItem.Add_Click({ $script:Window.Show(); $script:Window.Activate() })
    $exitItem = $script:TrayMenu.Items.Add('Exit widget')
    $exitItem.Add_Click({
        $script:ForceExit = $true
        if ($null -ne $script:Tray) { $script:Tray.Visible = $false }
        $script:Window.Close()
        $script:App.Shutdown()
    })
    $script:Tray.ContextMenuStrip = $script:TrayMenu
    $script:Tray.Visible = $true
    $script:Tray.Add_DoubleClick({ Show-Widget })

    $shell = $script:Window.FindName('Shell')
    if ($null -ne $shell) {
        $shell.Opacity = 0
        $translate = New-Object System.Windows.Media.TranslateTransform
        $translate.Y = 8
        $shell.RenderTransform = $translate
    }
    $script:Window.Show()
    $script:Window.Activate()
    Sync-OpenCodeVisibility
    if ($null -ne $shell) {
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
        $fade.From = 0.0
        $fade.To = 1.0
        $fade.Duration = [TimeSpan]::FromMilliseconds(220)
        $fade.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
        $shell.BeginAnimation([System.Windows.FrameworkElement]::OpacityProperty, $fade)
        $rise = New-Object System.Windows.Media.Animation.DoubleAnimation
        $rise.From = 8.0
        $rise.To = 0.0
        $rise.Duration = [TimeSpan]::FromMilliseconds(220)
        $rise.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
        $translate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $rise)
    }
})

$script:Window.FindName('ToggleButton').Add_Click({ Set-Expanded (-not $script:Expanded) })
$script:Window.FindName('MinimizeButton').Add_Click({
    $script:Window.Hide()
    if ($null -ne $script:Tray) {
        $script:Tray.BalloonTipTitle = 'OpenCode Account Widget'
        $script:Tray.BalloonTipText = 'Minimized to tray. Use the tray icon to show it again.'
        $script:Tray.ShowBalloonTip(1500)
    }
})
$script:Window.FindName('Shell').Add_MouseEnter({ Set-ShellHover $true })
$script:Window.FindName('Shell').Add_MouseLeave({ Set-ShellHover $false })
$script:Window.FindName('CloseButton').Add_Click({
    $script:ForceExit = $true
    if ($null -ne $script:Tray) { $script:Tray.Visible = $false }
    $script:Window.Close()
    $script:App.Shutdown()
})
$script:Window.FindName('CompactPanel').Add_MouseLeftButtonDown({ Set-Expanded $true })
$script:Window.FindName('HeaderTitle').Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
        $script:Dragging = $true
        $script:DragOrigin = $eventArgs.GetPosition($script:Window)
        $script:WindowOrigin = New-Object System.Windows.Point($script:Window.Left, $script:Window.Top)
        $script:Window.CaptureMouse()
    }
})
$script:Window.FindName('HeaderSubtitle').Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
        $script:Dragging = $true
        $script:DragOrigin = $eventArgs.GetPosition($script:Window)
        $script:WindowOrigin = New-Object System.Windows.Point($script:Window.Left, $script:Window.Top)
        $script:Window.CaptureMouse()
    }
})
$script:Window.Add_MouseMove({
    param($sender, $eventArgs)
    if ($script:Dragging) { Move-Window $eventArgs.GetPosition($script:Window) }
})
$script:Window.Add_MouseLeftButtonUp({
    if ($script:Dragging) { $script:Dragging = $false; $script:Window.ReleaseMouseCapture(); Save-WindowPosition }
})
$script:Window.Add_Closing({
    param($sender, $eventArgs)
    Save-WindowPosition
    if (-not $script:ForceExit) {
        $eventArgs.Cancel = $true
        $script:Window.Hide()
    }
})
$script:App.Add_Exit({
    if ($null -ne $script:Timer) { $script:Timer.Stop() }
    Stop-BridgeProcess
    if ($null -ne $script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
    if ($null -ne $script:TrayMenu) { $script:TrayMenu.Dispose() }
})

try {
    $script:App.Run($script:Window)
} finally {
    if ($script:HasMutex -and $null -ne $script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { }
        $script:Mutex.Dispose()
    }
}
