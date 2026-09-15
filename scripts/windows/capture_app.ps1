param(
    [string]$OutputPath = '',
    [int]$ProcessId = 0,
    [string]$ExecutablePath = '',
    [int]$WaitSeconds = 15
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot 'build\visual-baseline\windows-task-list.png'
}
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $ExecutablePath = Join-Path $projectRoot 'build\windows\x64\runner\Release\ishkafel.exe'
}

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class IshkafelCaptureWindow {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    public static int[] GetPhysicalClientBounds(IntPtr hWnd) {
        IntPtr oldContext = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            RECT client;
            if (!GetClientRect(hWnd, out client)) {
                throw new InvalidOperationException("GetClientRect failed.");
            }
            POINT origin = new POINT { X = client.Left, Y = client.Top };
            if (!ClientToScreen(hWnd, ref origin)) {
                throw new InvalidOperationException("ClientToScreen failed.");
            }
            int width = client.Right - client.Left;
            int height = client.Bottom - client.Top;
            return new int[] { origin.X, origin.Y, width, height };
        } finally {
            if (oldContext != IntPtr.Zero) {
                SetThreadDpiAwarenessContext(oldContext);
            }
        }
    }
}
'@

$startedHere = $false
$process = $null
try {
    if ($ProcessId -gt 0) {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
    } else {
        $ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
        $process = Start-Process -FilePath $ExecutablePath -PassThru
        $startedHere = $true
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    do {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
        if ($process.HasExited) {
            throw "ishkafel 在截图前退出，退出码：$($process.ExitCode)"
        }
    } while ($process.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq 0) {
        throw "等待 $WaitSeconds 秒后仍未找到 ishkafel 主窗口。"
    }

    $handle = $process.MainWindowHandle
    [IshkafelCaptureWindow]::ShowWindow($handle, 9) | Out-Null
    [IshkafelCaptureWindow]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds 500

    $windowRect = [IshkafelCaptureWindow+RECT]::new()
    if (-not [IshkafelCaptureWindow]::GetWindowRect($handle, [ref]$windowRect)) {
        throw 'GetWindowRect 失败。'
    }
    $width = $windowRect.Right - $windowRect.Left
    $height = $windowRect.Bottom - $windowRect.Top
    if ($width -lt 1100 -or $height -lt 880) {
        throw "窗口尺寸异常：${width}x${height}，无法与 1440x900 基准比较。"
    }

    $destination = [System.IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    $bounds = [IshkafelCaptureWindow]::GetPhysicalClientBounds($handle)
    $physical = [System.Drawing.Bitmap]::new($bounds[2], $bounds[3])
    $physicalGraphics = [System.Drawing.Graphics]::FromImage($physical)
    try {
        $physicalGraphics.CopyFromScreen(
            $bounds[0], $bounds[1], 0, 0,
            [System.Drawing.Size]::new($bounds[2], $bounds[3])
        )
        $output = [System.Drawing.Bitmap]::new(1440, 900)
        $outputGraphics = [System.Drawing.Graphics]::FromImage($output)
        try {
            $outputGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $outputGraphics.DrawImage($physical, 0, 0, 1440, 900)
            $output.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $outputGraphics.Dispose()
            $output.Dispose()
        }
    }
    finally {
        $physicalGraphics.Dispose()
        $physical.Dispose()
    }
    $capturedSize = "$($bounds[2])x$($bounds[3])@$($bounds[0]),$($bounds[1])"

    $image = [System.Drawing.Image]::FromFile($destination)
    try {
        Write-Output "Windows UI capture passed: $destination (client=$capturedSize)"
        Write-Output "SIZE=$($image.Width)x$($image.Height) SHA256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash)"
    }
    finally {
        $image.Dispose()
    }
}
finally {
    if ($startedHere -and $null -ne $process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
}
