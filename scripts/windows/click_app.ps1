param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][int]$X,
    [Parameter(Mandatory = $true)][int]$Y,
    [int]$WaitMilliseconds = 500
)

$ErrorActionPreference = 'Stop'
if ($X -lt 0 -or $X -gt 1439 -or $Y -lt 0 -or $Y -gt 899) {
    throw "Coordinate must be inside the 1440x900 baseline: ($X,$Y)"
}

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class IshkafelClickWindow {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);

    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}
'@

$process = Get-Process -Id $ProcessId -ErrorAction Stop
$process.Refresh()
if ($process.HasExited -or $process.MainWindowHandle -eq 0) {
    throw "Ishkafel process $ProcessId does not have a main window."
}

$handle = $process.MainWindowHandle
[IshkafelClickWindow]::ShowWindow($handle, 9) | Out-Null
[IshkafelClickWindow]::SetForegroundWindow($handle) | Out-Null
$oldContext = [IshkafelClickWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
try {
    $rect = [IshkafelClickWindow+RECT]::new()
    if (-not [IshkafelClickWindow]::GetClientRect($handle, [ref]$rect)) {
        throw 'GetClientRect failed.'
    }
    $origin = [IshkafelClickWindow+POINT]::new()
    if (-not [IshkafelClickWindow]::ClientToScreen($handle, [ref]$origin)) {
        throw 'ClientToScreen failed.'
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    $screenX = $origin.X + [Math]::Round($X * $width / 1440.0)
    $screenY = $origin.Y + [Math]::Round($Y * $height / 900.0)
    if (-not [IshkafelClickWindow]::SetCursorPos($screenX, $screenY)) {
        throw 'SetCursorPos failed.'
    }
    [IshkafelClickWindow]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [IshkafelClickWindow]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds $WaitMilliseconds
    Write-Output "Clicked baseline=($X,$Y) screen=($screenX,$screenY) client=${width}x${height}"
}
finally {
    if ($oldContext -ne [IntPtr]::Zero) {
        [IshkafelClickWindow]::SetThreadDpiAwarenessContext($oldContext) | Out-Null
    }
}
