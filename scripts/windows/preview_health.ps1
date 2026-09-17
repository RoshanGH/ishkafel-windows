param(
    [string]$TaskId = '',
    [int]$DurationSeconds = 60,
    [string]$ExecutablePath = '',
    [string]$LogPath = '',
    [string]$AnalyzeLogPath = '',
    [string]$DartExecutable = 'dart'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot 'process_compat.ps1')
$script:previewHealthExitCode = 1

function Invoke-PreviewHealthAnalyzer {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    Push-Location $projectRoot
    try {
        & $DartExecutable run tool/preview_health.dart $resolved
        $script:previewHealthExitCode = $LASTEXITCODE
        if ($script:previewHealthExitCode -eq 0) {
            Write-Output 'Preview health analysis passed.'
        }
        else {
            Write-Output "Preview health analysis failed (exit=$script:previewHealthExitCode)."
        }
    }
    finally {
        Pop-Location
    }
}

if (-not [string]::IsNullOrWhiteSpace($AnalyzeLogPath)) {
    Invoke-PreviewHealthAnalyzer -Path $AnalyzeLogPath
    exit $script:previewHealthExitCode
}

if ([string]::IsNullOrWhiteSpace($TaskId)) {
    throw 'Provide -TaskId, or use -AnalyzeLogPath to analyze an existing playback log.'
}
if ($DurationSeconds -lt 20) {
    throw 'Real playback must run for at least 20 seconds to collect enough samples.'
}

if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $ExecutablePath = Join-Path $projectRoot 'build\windows\x64\runner\Release\ishkafel.exe'
}
$ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    if (-not [string]::IsNullOrWhiteSpace($env:ISHKAFEL_LOG_DIR)) {
        $LogPath = Join-Path $env:ISHKAFEL_LOG_DIR 'ishkafel.log'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:ISHKAFEL_STORAGE_ROOT)) {
        $LogPath = Join-Path $env:ISHKAFEL_STORAGE_ROOT 'logs\ishkafel.log'
    }
    else {
        $storageRoot = $null
        try {
            $storageRoot = (Get-ItemProperty `
                -Path 'HKCU:\Software\RoshanGH\Ishkafel' `
                -Name 'StorageRoot' `
                -ErrorAction Stop).StorageRoot
        }
        catch {
            $storageRoot = $null
        }
        if (-not [string]::IsNullOrWhiteSpace($storageRoot)) {
            $LogPath = Join-Path $storageRoot 'logs\ishkafel.log'
        }
        else {
            $LogPath = Join-Path $env:APPDATA 'com.jichuang\ishkafel\logs\ishkafel.log'
        }
    }
}
$LogPath = [System.IO.Path]::GetFullPath($LogPath)
$trackReadyMarker = -join @(
    [char]0x753B,
    [char]0x9762,
    [char]0x8F68,
    [char]0x6362,
    [char]0x6E90
)

function Read-LogSince {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$Offset
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($Offset -lt 0 -or $Offset -gt $bytes.LongLength) { $Offset = 0 }
    $count = [int]($bytes.LongLength - $Offset)
    if ($count -le 0) { return '' }
    return [System.Text.Encoding]::UTF8.GetString($bytes, [int]$Offset, $count)
}

if (-not ('IshkafelPreviewHealthWindow' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class IshkafelPreviewHealthWindow {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public InputUnion value;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion {
        [FieldOffset(0)]
        public KEYBDINPUT keyboard;

        [FieldOffset(0)]
        public MOUSEINPUT mouse;

        [FieldOffset(0)]
        public HARDWAREINPUT hardware;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort virtualKey;
        public ushort scanCode;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT {
        public uint message;
        public ushort parameterLow;
        public ushort parameterHigh;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint count, INPUT[] inputs, int size);

    public static bool SendSpace() {
        var inputs = new INPUT[2];
        inputs[0].type = 1;
        inputs[0].value.keyboard.virtualKey = 0x20;
        inputs[1].type = 1;
        inputs[1].value.keyboard.virtualKey = 0x20;
        inputs[1].value.keyboard.flags = 0x0002;
        return SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT))) == 2;
    }
}
'@
}

function Send-PlaybackSpace {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

    $Process.Refresh()
    if ($Process.HasExited -or $Process.MainWindowHandle -eq 0) {
        throw 'Ishkafel does not have a main window that can receive the playback shortcut.'
    }
    $handle = $Process.MainWindowHandle
    [IshkafelPreviewHealthWindow]::ShowWindow($handle, 9) | Out-Null
    if (-not [IshkafelPreviewHealthWindow]::SetForegroundWindow($handle)) {
        throw 'Failed to focus the Ishkafel window before sending playback input.'
    }
    Start-Sleep -Milliseconds 300
    if (-not [IshkafelPreviewHealthWindow]::SendSpace()) {
        throw 'Windows SendInput failed to send the Space key.'
    }
}

$sameExecutable = @(
    Get-Process -Name 'ishkafel' -ErrorAction SilentlyContinue | Where-Object {
        try {
            [string]::Equals(
                [System.IO.Path]::GetFullPath($_.Path),
                $ExecutablePath,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
        catch { $false }
    }
)
foreach ($existing in $sameExecutable) {
    [void]$existing.CloseMainWindow()
    if (-not $existing.WaitForExit(10000)) {
        $existing.Kill()
        $existing.WaitForExit()
    }
}

$otherInstances = @(
    Get-Process -Name 'ishkafel' -ErrorAction SilentlyContinue | Where-Object {
        try {
            -not [string]::Equals(
                [System.IO.Path]::GetFullPath($_.Path),
                $ExecutablePath,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
        catch { $true }
    }
)
if ($otherInstances.Count -gt 0) {
    throw "Another Ishkafel instance is running (PID $($otherInstances.Id -join ', ')). Close it before preview health testing."
}

$initialOffset = if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
    (Get-Item -LiteralPath $LogPath).Length
}
else { 0 }

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $ExecutablePath
$startInfo.Arguments = ConvertTo-ProcessArguments -ArgumentValues @("--task=$TaskId")
$startInfo.UseShellExecute = $false
$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$playLog = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("ishkafel-preview-health-$([Guid]::NewGuid().ToString('N')).log")

try {
    if (-not $process.Start()) { throw 'Failed to start Ishkafel.' }
    $windowDeadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 200
        $process.Refresh()
        if ($process.HasExited) {
            throw "Ishkafel exited during startup (exit=$($process.ExitCode))."
        }
    } while ($process.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $windowDeadline)
    if ($process.MainWindowHandle -eq 0) { throw 'Ishkafel did not create a main window within 30 seconds.' }

    Write-Output "Opening task $TaskId and waiting for preview tracks..."
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) {
            throw "Ishkafel exited while waiting for preview tracks (exit=$($process.ExitCode))."
        }
        $startupLog = Read-LogSince -Path $LogPath -Offset $initialOffset
    } while (-not $startupLog.Contains($trackReadyMarker) -and [DateTime]::UtcNow -lt $readyDeadline)
    if (-not $startupLog.Contains($trackReadyMarker)) {
        throw "Preview tracks were not ready within 90 seconds. Log: $LogPath"
    }
    Start-Sleep -Seconds 2

    $playOffset = (Get-Item -LiteralPath $LogPath).Length
    Write-Output "Playing real preview for $DurationSeconds seconds..."
    Send-PlaybackSpace -Process $process
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $DurationSeconds) {
        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) {
            throw "Ishkafel exited during real playback (exit=$($process.ExitCode))."
        }
    }
    Send-PlaybackSpace -Process $process
    Start-Sleep -Seconds 1

    $playText = Read-LogSince -Path $LogPath -Offset $playOffset
    [System.IO.File]::WriteAllText(
        $playLog,
        $playText,
        [System.Text.UTF8Encoding]::new($false)
    )
    Invoke-PreviewHealthAnalyzer -Path $playLog
}
finally {
    if (-not $process.HasExited) {
        [void]$process.CloseMainWindow()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            $process.WaitForExit()
        }
    }
    $process.Dispose()
    if (Test-Path -LiteralPath $playLog -PathType Leaf) {
        Remove-Item -LiteralPath $playLog -Force
    }
}

exit $script:previewHealthExitCode
