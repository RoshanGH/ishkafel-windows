param(
    [switch]$SkipBuild,
    [string]$ExecutablePath = '',
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$buildRoot = (Resolve-Path (Join-Path $projectRoot 'build')).Path

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build_cli.ps1') | Out-Host
}
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $ExecutablePath = Join-Path $projectRoot 'build\cli\windows_x64\bundle\bin\ishkafel.exe'
}
$ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path

$commands = @(
    'analyze',
    'apply',
    'bgm',
    'blank',
    'candidates',
    'clean',
    'doctor',
    'export',
    'import',
    'jianying',
    'open',
    'peek',
    'review',
    'script',
    'skill',
    'status',
    'subtitle',
    'tag-groups',
    'task',
    'task-copy',
    'task-delete',
    'task-rename',
    'tasks',
    'todo',
    'unit',
    'ui',
    'voice',
    'voices'
)

if ($commands.Count -ne 28 -or ($commands | Select-Object -Unique).Count -ne 28) {
    throw 'CLI contract list must contain exactly 28 unique commands.'
}

$runRoot = Join-Path $buildRoot ('cli-contract-' + [Guid]::NewGuid().ToString('N'))
$dataDir = Join-Path $runRoot '中文 数据'
$resolvedRunRoot = [System.IO.Path]::GetFullPath($runRoot)
$allowedPrefix = $buildRoot.TrimEnd('\') + '\'
if (-not $resolvedRunRoot.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to create or clean CLI contract data outside build: $resolvedRunRoot"
}
[System.IO.Directory]::CreateDirectory($dataDir) | Out-Null

function Invoke-CliProbe {
    param([Parameter(Mandatory = $true)][string]$Command)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $startInfo.ArgumentList.Add('--data-dir')
    $startInfo.ArgumentList.Add($dataDir)
    $startInfo.ArgumentList.Add($Command)

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Failed to start CLI probe: $Command" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "CLI probe timed out after $TimeoutSeconds seconds: $Command"
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            Command = $Command
            ExitCode = $process.ExitCode
            Stdout = $stdout
            Stderr = $stderr
        }
    }
    finally {
        $process.Dispose()
    }
}

try {
    $help = & $ExecutablePath --help 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $help -notmatch '竖屏口播短视频工具') {
        throw 'Compiled CLI help did not preserve UTF-8 output.'
    }

    $results = @()
    foreach ($command in $commands) {
        $result = Invoke-CliProbe $command
        $combined = $result.Stdout + "`n" + $result.Stderr
        if ($combined.Contains('未知命令')) {
            throw "Registered command was rejected as unknown: $command`n$combined"
        }
        if ($result.ExitCode -lt 0 -or $result.ExitCode -gt 5) {
            throw "Unexpected exit code for ${command}: $($result.ExitCode)`n$combined"
        }
        $results += $result
    }

    foreach ($jsonCommand in @('voices', 'tasks', 'status')) {
        $result = $results | Where-Object { $_.Command -eq $jsonCommand }
        if ($result.ExitCode -ne 0) {
            throw "$jsonCommand should succeed against an empty isolated data directory."
        }
        try {
            $null = $result.Stdout | ConvertFrom-Json
        }
        catch {
            throw "$jsonCommand did not emit valid JSON: $($result.Stdout)"
        }
    }

    $failed = @($results | Where-Object { $_.ExitCode -ne 0 }).Count
    Write-Output (
        "CLI contract passed: commands=$($commands.Count) success=$($commands.Count - $failed) " +
        "expected-errors=$failed data-path='$dataDir'"
    )
    foreach ($result in $results) {
        Write-Output ("  {0,-12} exit={1}" -f $result.Command, $result.ExitCode)
    }
}
finally {
    if (Test-Path -LiteralPath $resolvedRunRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedRunRoot -Recurse -Force
    }
}
