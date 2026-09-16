param(
    [int]$FullHdSeconds = 8,
    [int]$FourKSeconds = 3,
    [string]$FfmpegPath = '',
    [string]$FfprobePath = '',
    [string]$ReportPath = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot 'process_compat.ps1')
$buildRoot = (Resolve-Path (Join-Path $projectRoot 'build')).Path
$releaseRoot = Join-Path $buildRoot 'windows\x64\runner\Release'
if ([string]::IsNullOrWhiteSpace($FfmpegPath)) {
    $FfmpegPath = Join-Path $releaseRoot 'tools\ffmpeg.exe'
}
if ([string]::IsNullOrWhiteSpace($FfprobePath)) {
    $FfprobePath = Join-Path $releaseRoot 'tools\ffprobe.exe'
}
$FfmpegPath = (Resolve-Path -LiteralPath $FfmpegPath).Path
$FfprobePath = (Resolve-Path -LiteralPath $FfprobePath).Path
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $buildRoot 'performance\windows-media-baseline.json'
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
[System.IO.Directory]::CreateDirectory((Split-Path -Parent $ReportPath)) | Out-Null

$cases = @(
    [pscustomobject]@{ Name = '1080p'; Width = 1080; Height = 1920; Seconds = $FullHdSeconds },
    [pscustomobject]@{ Name = '4K'; Width = 2160; Height = 3840; Seconds = $FourKSeconds }
)

$runRoot = Join-Path $buildRoot ('media-benchmark-' + [Guid]::NewGuid().ToString('N'))
$chineseLabel = -join @([char]0x4E2D, [char]0x6587)
$mediaRoot = Join-Path $runRoot "$chineseLabel performance"
$resolvedRunRoot = [System.IO.Path]::GetFullPath($runRoot)
$allowedPrefix = $buildRoot.TrimEnd('\') + '\'
if (-not $resolvedRunRoot.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to create or clean benchmark data outside build: $resolvedRunRoot"
}
[System.IO.Directory]::CreateDirectory($mediaRoot) | Out-Null

function Invoke-MeasuredProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 900
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = ConvertTo-ProcessArguments -ArgumentValues $Arguments

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $peak = 0L
    try {
        if (-not $process.Start()) { throw "Failed to start: $Executable" }
        # Short probes can finish before the first timed poll. Sample once
        # immediately so their peak memory does not incorrectly become zero.
        $process.Refresh()
        $peak = [Math]::Max($peak, $process.PeakWorkingSet64)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(200)) {
            $process.Refresh()
            $peak = [Math]::Max($peak, $process.PeakWorkingSet64)
            if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                $process.Kill()
                $process.WaitForExit()
                throw "Process timed out after $TimeoutSeconds seconds: $Executable"
            }
        }
        $process.Refresh()
        $peak = [Math]::Max($peak, $process.PeakWorkingSet64)
        $watch.Stop()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Process failed with exit code $($process.ExitCode): $Executable`n$stderr"
        }
        return [pscustomobject]@{
            Seconds = $watch.Elapsed.TotalSeconds
            PeakWorkingSet64 = $peak
            Stdout = $stdout
            Stderr = $stderr
        }
    }
    finally {
        $process.Dispose()
    }
}

try {
    $results = @()
    foreach ($case in $cases) {
        if ($case.Seconds -lt 1) { throw "$($case.Name) duration must be positive." }
        $output = Join-Path $mediaRoot ("$($case.Name)-$($case.Seconds)s.mp4")
        $arguments = @(
            '-hide_banner', '-loglevel', 'error', '-y',
            '-f', 'lavfi', '-i',
            "testsrc2=size=$($case.Width)x$($case.Height):rate=30:duration=$($case.Seconds)",
            '-f', 'lavfi', '-i',
            "sine=frequency=440:sample_rate=48000:duration=$($case.Seconds)",
            '-map', '0:v:0', '-map', '1:a:0',
            '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
            '-profile:v', 'high', '-pix_fmt', 'yuv420p',
            '-c:a', 'aac', '-b:a', '192k', '-shortest', '-movflags', '+faststart',
            $output
        )
        $measurement = Invoke-MeasuredProcess -Executable $FfmpegPath -Arguments $arguments
        $probeText = & $FfprobePath -v error -count_frames -show_entries `
            'format=duration:stream=codec_type,width,height,avg_frame_rate,sample_rate,nb_read_frames' `
            -of json $output
        if ($LASTEXITCODE -ne 0) { throw "ffprobe failed for $($case.Name)." }
        $probe = ($probeText -join "`n") | ConvertFrom-Json
        $video = @($probe.streams | Where-Object { $_.codec_type -eq 'video' })
        $audio = @($probe.streams | Where-Object { $_.codec_type -eq 'audio' })
        if ($video.Count -ne 1 -or $audio.Count -ne 1) {
            throw "$($case.Name) output does not contain one video and one audio stream."
        }
        if ($video[0].width -ne $case.Width -or $video[0].height -ne $case.Height) {
            throw "$($case.Name) dimensions are incorrect."
        }
        if ($video[0].avg_frame_rate -ne '30/1' -or $audio[0].sample_rate -ne '48000') {
            throw "$($case.Name) frame rate or audio sample rate is incorrect."
        }
        $expectedFrames = 30 * $case.Seconds
        if ([int]$video[0].nb_read_frames -ne $expectedFrames) {
            throw "$($case.Name) frame count is $($video[0].nb_read_frames), expected $expectedFrames."
        }
        $results += [ordered]@{
            name = $case.Name
            width = $case.Width
            height = $case.Height
            sourceSeconds = $case.Seconds
            encodeSeconds = [Math]::Round($measurement.Seconds, 3)
            realtimeFactor = [Math]::Round($case.Seconds / $measurement.Seconds, 3)
            frames = $expectedFrames
            audioSampleRate = 48000
            peakWorkingSetMiB = [Math]::Round($measurement.PeakWorkingSet64 / 1MB, 1)
            outputBytes = (Get-Item -LiteralPath $output).Length
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $output).Hash
        }
    }

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpu = Get-CimInstance Win32_VideoController |
        Sort-Object { if ($null -eq $_.AdapterRAM) { 0 } else { [uint64]$_.AdapterRAM } } -Descending |
        Select-Object -First 1
    $report = [ordered]@{
        generatedAt = [DateTime]::UtcNow.ToString('o')
        operatingSystem = [Environment]::OSVersion.VersionString
        cpu = [string]$cpu.Name
        logicalProcessors = [int]$cpu.NumberOfLogicalProcessors
        memoryGiB = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        gpu = [string]$gpu.Name
        ffmpeg = $FfmpegPath
        codec = 'libx264 veryfast crf=20, aac 192k, 30fps, 48kHz'
        results = $results
    }
    [System.IO.File]::WriteAllText(
        $ReportPath,
        ($report | ConvertTo-Json -Depth 6),
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Output "Media performance baseline passed: $ReportPath"
    foreach ($result in $results) {
        Write-Output (
            "  $($result.name): encode=$($result.encodeSeconds)s " +
            "realtime=$($result.realtimeFactor)x peak=$($result.peakWorkingSetMiB)MiB"
        )
    }
}
finally {
    if (Test-Path -LiteralPath $resolvedRunRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedRunRoot -Recurse -Force
    }
}
