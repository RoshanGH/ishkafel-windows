param(
    [switch]$SkipBuild,
    [string]$ExecutablePath = '',
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot 'process_compat.ps1')
$buildRoot = (Resolve-Path (Join-Path $projectRoot 'build')).Path

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build_cli.ps1') | Out-Host
}
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $ExecutablePath = Join-Path $projectRoot 'build\cli\windows_x64\bundle\bin\ishkafel.exe'
}
$ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path

$expectedExitCodes = [ordered]@{
    'analyze' = 2
    'apply' = 2
    'bgm' = 2
    'blank' = 2
    'candidates' = 2
    'clean' = 0
    'doctor' = 5
    'export' = 2
    'import' = 2
    'jianying' = 2
    'open' = 2
    'peek' = 2
    'review' = 2
    'script' = 2
    'skill' = 0
    'status' = 0
    'subtitle' = 2
    'tag-groups' = 5
    'task' = 2
    'task-copy' = 2
    'task-delete' = 2
    'task-rename' = 2
    'tasks' = 0
    'todo' = 2
    'unit' = 2
    'ui' = 2
    'voice' = 2
    'voices' = 0
}
$commands = @($expectedExitCodes.Keys)

if ($commands.Count -ne 28 -or ($commands | Select-Object -Unique).Count -ne 28) {
    throw 'CLI contract list must contain exactly 28 unique commands.'
}

$runRoot = Join-Path $buildRoot ('cli-contract-' + [Guid]::NewGuid().ToString('N'))
$chineseLabel = -join @([char]0x4E2D, [char]0x6587)
$dataDir = Join-Path $runRoot "$chineseLabel data"
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
    # Make environment-dependent probes deterministic: this contract checks
    # documented missing-environment exit codes, not the operator's own tools.
    $startInfo.EnvironmentVariables['USERPROFILE'] = $runRoot
    $startInfo.EnvironmentVariables['PATH'] = [Environment]::SystemDirectory
    $startInfo.Arguments = ConvertTo-ProcessArguments -ArgumentValues @(
        '--data-dir', $dataDir, $Command
    )

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Failed to start CLI probe: $Command" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
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
    $expectedHelp = -join @(
        [char]0x7AD6, [char]0x5C4F, [char]0x53E3, [char]0x64AD,
        [char]0x77ED, [char]0x89C6, [char]0x9891, [char]0x5DE5, [char]0x5177
    )
    $unknownCommand = -join @(
        [char]0x672A, [char]0x77E5, [char]0x547D, [char]0x4EE4
    )
    if ($LASTEXITCODE -ne 0 -or $help -notmatch [regex]::Escape($expectedHelp)) {
        throw 'Compiled CLI help did not preserve UTF-8 output.'
    }

    $results = @()
    foreach ($command in $commands) {
        $result = Invoke-CliProbe $command
        $combined = $result.Stdout + "`n" + $result.Stderr
        if ($combined.Contains($unknownCommand)) {
            throw "Registered command was rejected as unknown: $command`n$combined"
        }
        $expectedExitCode = [int]$expectedExitCodes[$command]
        if ($result.ExitCode -ne $expectedExitCode) {
            throw "Unexpected exit code for ${command}: $($result.ExitCode); " +
                "expected $expectedExitCode`n$combined"
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
