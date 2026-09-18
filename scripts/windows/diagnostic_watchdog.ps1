param([Parameter(Mandatory=$true)][int]$AppPid, [Parameter(Mandatory=$true)][string]$LogDirectory)
$ErrorActionPreference = 'Stop'
try {
    $targetProcess = Get-Process -Id $AppPid -ErrorAction Stop
    $null = $targetProcess.Handle
    $history = New-Object System.Collections.ArrayList
    $reportFile = Join-Path $LogDirectory 'watchdog.json'
    if (Test-Path -LiteralPath $reportFile) {
        Copy-Item -LiteralPath $reportFile -Destination (Join-Path $LogDirectory 'watchdog.previous.json') -Force
    }
    while ($true) {
        $ended = $targetProcess.WaitForExit(5000)
        $targetProcess.Refresh()
        $sample = [ordered]@{ utc=[DateTime]::UtcNow.ToString('o'); pid=$AppPid; exited=$ended }
        if ($ended) { $sample.exitCode=$targetProcess.ExitCode }
        else {
            $sample.responding=$targetProcess.Responding
            $sample.workingSetBytes=$targetProcess.WorkingSet64
            $sample.cpuSeconds=$targetProcess.TotalProcessorTime.TotalSeconds
        }
        $null = $history.Add($sample)
        if ($history.Count -gt 120) { $history.RemoveAt(0) }
        [System.IO.Directory]::CreateDirectory($LogDirectory) | Out-Null
        [System.IO.File]::WriteAllText($reportFile, (ConvertTo-Json -InputObject @($history.ToArray()) -Depth 4 -Compress), [System.Text.UTF8Encoding]::new($false))
        if ($ended) { break }
    }
} catch {
    # 监测失败不得影响主应用；不把任意环境信息输出。
    exit 1
}
