param(
    [int]$DurationSeconds = 60,
    [string]$ExecutablePath = '',
    [string]$ReportPath = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$buildRoot = (Resolve-Path (Join-Path $projectRoot 'build')).Path
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $ExecutablePath = Join-Path $buildRoot 'windows\x64\runner\Release\ishkafel.exe'
}
$ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $buildRoot 'performance\windows-app-stability.json'
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
[System.IO.Directory]::CreateDirectory((Split-Path -Parent $ReportPath)) | Out-Null

$runRoot = Join-Path $buildRoot ('app-stability-' + [Guid]::NewGuid().ToString('N'))
$appData = Join-Path $runRoot '隔离 AppData'
$dataDir = Join-Path $runRoot '隔离 Data'
$logDir = Join-Path $runRoot '隔离 Logs'
$resolvedRunRoot = [System.IO.Path]::GetFullPath($runRoot)
$allowedPrefix = $buildRoot.TrimEnd('\') + '\'
if (-not $resolvedRunRoot.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to create or clean stability data outside build: $resolvedRunRoot"
}
[System.IO.Directory]::CreateDirectory($appData) | Out-Null

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $ExecutablePath
$startInfo.UseShellExecute = $false
$startInfo.Environment['APPDATA'] = $appData
$startInfo.Environment['LOCALAPPDATA'] = (Join-Path $runRoot 'LocalAppData')
$startInfo.Environment['ISHKAFEL_DATA_DIR'] = $dataDir
$startInfo.Environment['ISHKAFEL_LOG_DIR'] = $logDir
$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$samples = @()

try {
    if (-not $process.Start()) { throw 'Failed to start Ishkafel stability process.' }
    $windowDeadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 200
        $process.Refresh()
        if ($process.HasExited) {
            throw "Ishkafel exited during startup with code $($process.ExitCode)."
        }
    } while ($process.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $windowDeadline)
    if ($process.MainWindowHandle -eq 0) { throw 'Ishkafel did not create a main window.' }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $DurationSeconds) {
        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) {
            throw "Ishkafel exited during stability sampling with code $($process.ExitCode)."
        }
        $samples += [ordered]@{
            second = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
            workingSetMiB = [Math]::Round($process.WorkingSet64 / 1MB, 1)
            privateMemoryMiB = [Math]::Round($process.PrivateMemorySize64 / 1MB, 1)
            peakWorkingSetMiB = [Math]::Round($process.PeakWorkingSet64 / 1MB, 1)
            handles = $process.HandleCount
        }
    }
    $watch.Stop()
    if ($samples.Count -lt [Math]::Max(1, $DurationSeconds - 2)) {
        throw "Too few stability samples: $($samples.Count)."
    }

    $first = $samples[0]
    $last = $samples[-1]
    $logPath = Join-Path $logDir 'ishkafel.log'
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        throw "Persistent application log was not created in isolated APPDATA: $logPath"
    }
    $logText = [System.IO.File]::ReadAllText($logPath)
    $report = [ordered]@{
        generatedAt = [DateTime]::UtcNow.ToString('o')
        durationSeconds = $DurationSeconds
        processId = $process.Id
        survived = -not $process.HasExited
        samples = $samples.Count
        initialWorkingSetMiB = $first.workingSetMiB
        finalWorkingSetMiB = $last.workingSetMiB
        workingSetGrowthMiB = [Math]::Round($last.workingSetMiB - $first.workingSetMiB, 1)
        PeakWorkingSet64 = $process.PeakWorkingSet64
        peakWorkingSetMiB = [Math]::Round($process.PeakWorkingSet64 / 1MB, 1)
        initialHandles = $first.handles
        finalHandles = $last.handles
        logBytes = ([System.Text.Encoding]::UTF8.GetByteCount($logText))
    }
    [System.IO.File]::WriteAllText(
        $ReportPath,
        ($report | ConvertTo-Json -Depth 5),
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Output (
        "Application stability passed: duration=${DurationSeconds}s " +
        "working-set=$($first.workingSetMiB)->$($last.workingSetMiB)MiB " +
        "peak=$($report.peakWorkingSetMiB)MiB handles=$($first.handles)->$($last.handles)"
    )
    Write-Output "Report: $ReportPath"
}
finally {
    if (-not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
    }
    $process.Dispose()
    if (Test-Path -LiteralPath $resolvedRunRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedRunRoot -Recurse -Force
    }
}
