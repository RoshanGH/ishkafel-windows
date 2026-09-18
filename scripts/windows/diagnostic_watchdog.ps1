param([Parameter(Mandatory=$true)][int]$AppPid, [Parameter(Mandatory=$true)][string]$LogDirectory)
$ErrorActionPreference = 'Stop'
$stage = 'attach'
try {
    # 桌面环境中的系统模块自动发现可能阻塞；监测只使用 Framework 自带 API。
    $targetProcess = [System.Diagnostics.Process]::GetProcessById($AppPid)
    $null = $targetProcess.Handle
    $history = [System.Collections.ArrayList]::new()
    $null = [System.Reflection.Assembly]::LoadWithPartialName('System.Web.Extensions')
    $serializer = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $reportFile = [System.IO.Path]::Combine($LogDirectory, 'watchdog.json')
    $stage = 'rotate'
    if ([System.IO.File]::Exists($reportFile)) {
        [System.IO.File]::Copy($reportFile, [System.IO.Path]::Combine($LogDirectory, 'watchdog.previous.json'), $true)
    }
    while ($true) {
        $stage = 'sample'
        $ended = $targetProcess.WaitForExit(0)
        $targetProcess.Refresh()
        $sample = [ordered]@{ utc=[DateTime]::UtcNow.ToString('o'); pid=$AppPid; watchdogPid=$PID; exited=$ended }
        if ($ended) { $sample.exitCode=$targetProcess.ExitCode }
        else {
            $sample.responding=$targetProcess.Responding
            $sample.workingSetBytes=$targetProcess.WorkingSet64
            $sample.cpuSeconds=$targetProcess.TotalProcessorTime.TotalSeconds
        }
        $null = $history.Add($sample)
        if ($history.Count -gt 120) { $history.RemoveAt(0) }
        $stage = 'write'
        $null = [System.IO.Directory]::CreateDirectory($LogDirectory)
        [System.IO.File]::WriteAllText($reportFile, $serializer.Serialize($history.ToArray()), [System.Text.UTF8Encoding]::new($false))
        if ($ended) { break }
        $stage = 'wait'
        $null = $targetProcess.WaitForExit(5000)
    }
} catch {
    # 只报阶段、异常类型和 HRESULT，不输出含路径或环境内容的异常消息。
    [Console]::Error.WriteLine(('watchdog stage={0} type={1} hresult={2}' -f $stage, $_.Exception.GetType().Name, $_.Exception.HResult))
    exit 1
}
