param(
    [ValidateSet('Debug', 'Release')]
    [string]$Mode = 'Release',
    [string]$BundleDirectory = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($BundleDirectory)) {
    $bundleDir = Join-Path $projectRoot "build\windows\x64\runner\$Mode"
} else {
    $bundleDir = (Resolve-Path -LiteralPath $BundleDirectory).Path
}

$ffmpeg = Join-Path $bundleDir 'tools\ffmpeg.exe'
$ffprobe = Join-Path $bundleDir 'tools\ffprobe.exe'
foreach ($tool in @($ffmpeg, $ffprobe)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Bundled media tool is missing. Build Windows first: $tool"
    }
}

function Invoke-MediaTool {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = & $Executable @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Media command failed with exit code $exitCode`: $Executable $($Arguments -join ' ')`n$($output -join "`n")"
    }
    return $output
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
        } finally {
            $algorithm.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

$runDir = Join-Path $projectRoot ("build\media-smoke-" + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($runDir) | Out-Null
$segmentA = Join-Path $runDir 'segment-a.mp4'
$segmentB = Join-Path $runDir 'segment-b.mp4'
$framePath = Join-Path $runDir 'frame.png'
$audioPath = Join-Path $runDir 'audio.wav'
$joinedPath = Join-Path $runDir 'joined.mp4'

try {
    Invoke-MediaTool $ffmpeg @(
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'testsrc2=size=320x568:rate=30:duration=2',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
        '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'libx264', '-preset', 'veryfast',
        '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '128k', '-shortest',
        '-movflags', '+faststart', $segmentA
    ) | Out-Null

    Invoke-MediaTool $ffmpeg @(
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'color=c=0x2457C5:size=320x568:rate=30:duration=2',
        '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=48000:duration=2',
        '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'libx264', '-preset', 'veryfast',
        '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '128k', '-shortest',
        '-movflags', '+faststart', $segmentB
    ) | Out-Null

    Invoke-MediaTool $ffmpeg @(
        '-hide_banner', '-loglevel', 'error', '-y', '-ss', '0.5', '-i', $segmentA,
        '-frames:v', '1', $framePath
    ) | Out-Null

    Invoke-MediaTool $ffmpeg @(
        '-hide_banner', '-loglevel', 'error', '-y', '-i', $segmentA,
        '-map', '0:a:0', '-vn', '-c:a', 'pcm_s16le', $audioPath
    ) | Out-Null

    Invoke-MediaTool $ffmpeg @(
        '-hide_banner', '-loglevel', 'error', '-y', '-i', $segmentA, '-i', $segmentB,
        '-filter_complex', '[0:v:0][0:a:0][1:v:0][1:a:0]concat=n=2:v=1:a=1[v][a]',
        '-map', '[v]', '-map', '[a]', '-c:v', 'libx264', '-preset', 'veryfast',
        '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart',
        $joinedPath
    ) | Out-Null

    $probeText = (Invoke-MediaTool $ffprobe @(
        '-v', 'error', '-show_entries',
        'format=duration:stream=index,codec_type,width,height,avg_frame_rate,sample_rate',
        '-of', 'json', $joinedPath
    )) -join "`n"
    $probe = $probeText | ConvertFrom-Json
    $video = @($probe.streams | Where-Object { $_.codec_type -eq 'video' })
    $audio = @($probe.streams | Where-Object { $_.codec_type -eq 'audio' })
    if ($video.Count -ne 1 -or $audio.Count -ne 1) {
        throw "Joined video must contain exactly one video stream and one audio stream.`n$probeText"
    }
    if ($video[0].width -ne 320 -or $video[0].height -ne 568) {
        throw "Unexpected joined dimensions: $($video[0].width)x$($video[0].height)"
    }
    if ($video[0].avg_frame_rate -ne '30/1') {
        throw "Unexpected joined frame rate: $($video[0].avg_frame_rate)"
    }
    if ($audio[0].sample_rate -ne '48000') {
        throw "Unexpected joined audio sample rate: $($audio[0].sample_rate)"
    }
    $duration = [double]::Parse(
        [string]$probe.format.duration,
        [Globalization.CultureInfo]::InvariantCulture
    )
    if ($duration -lt 3.8 -or $duration -gt 4.3) {
        throw "Unexpected joined duration: $duration seconds"
    }

    $pngBytes = [IO.File]::ReadAllBytes($framePath)
    $pngSignature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
    if ($pngBytes.Length -lt 1024) {
        throw "Extracted frame is unexpectedly small: $($pngBytes.Length) bytes"
    }
    for ($index = 0; $index -lt $pngSignature.Length; $index++) {
        if ($pngBytes[$index] -ne $pngSignature[$index]) {
            throw 'Extracted frame is not a PNG file.'
        }
    }

    $wavBytes = [IO.File]::ReadAllBytes($audioPath)
    if ($wavBytes.Length -lt 4096 -or [Text.Encoding]::ASCII.GetString($wavBytes, 0, 4) -ne 'RIFF') {
        throw 'Extracted audio is not a non-empty WAV file.'
    }

    Write-Output "Media pipeline smoke passed: 320x568 @ 30fps, duration=$([Math]::Round($duration, 3))s, audio=48000Hz"
    Write-Output "joined.mp4 SHA256=$(Get-Sha256 $joinedPath) bytes=$((Get-Item -LiteralPath $joinedPath).Length)"
    Write-Output "frame.png SHA256=$(Get-Sha256 $framePath) bytes=$($pngBytes.Length)"
    Write-Output "audio.wav SHA256=$(Get-Sha256 $audioPath) bytes=$($wavBytes.Length)"
} finally {
    if (Test-Path -LiteralPath $runDir -PathType Container) {
        Remove-Item -LiteralPath $runDir -Recurse -Force
    }
}
