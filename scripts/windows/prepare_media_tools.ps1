param(
    [string]$ArchivePath = '',
    [string]$ExpectedSha256 = '',
    [string]$OutputDirectory = '',
    [string]$CacheDirectory = '',
    [string]$ManifestPath = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Get-Sha256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $algorithm.ComputeHash($stream)
            return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $algorithm.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $projectRoot 'third_party\ffmpeg\windows\manifest.json'
}
$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
    $ExpectedSha256 = [string]$manifest.archiveSha256
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot 'build\vendor\ffmpeg'
}
if ([string]::IsNullOrWhiteSpace($CacheDirectory)) {
    $CacheDirectory = Join-Path $projectRoot 'build\cache\ffmpeg'
}

$expected = $ExpectedSha256.Trim().ToLowerInvariant()
if ($expected -notmatch '^[0-9a-f]{64}$') {
    throw "Expected SHA-256 must contain exactly 64 hexadecimal characters: $ExpectedSha256"
}

$downloaded = $false
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    New-Item -ItemType Directory -Force -Path $CacheDirectory | Out-Null
    $ArchivePath = Join-Path $CacheDirectory "ffmpeg-$($manifest.version)-essentials_build.zip"
    $needsDownload = -not (Test-Path -LiteralPath $ArchivePath)
    if (-not $needsDownload) {
        $cachedHash = Get-Sha256 $ArchivePath
        $needsDownload = $cachedHash -ne $expected
    }
    if ($needsDownload) {
        $partial = "$ArchivePath.download"
        if (Test-Path -LiteralPath $partial) {
            Remove-Item -LiteralPath $partial -Force
        }
        Invoke-WebRequest -Uri ([string]$manifest.archiveUrl) -OutFile $partial -UseBasicParsing
        Move-Item -LiteralPath $partial -Destination $ArchivePath -Force
        $downloaded = $true
    }
}

$actual = Get-Sha256 $ArchivePath
if ($actual -ne $expected) {
    throw "FFmpeg archive SHA-256 mismatch. Expected $expected but got $actual"
}

$parent = Split-Path -Parent $OutputDirectory
if ([string]::IsNullOrWhiteSpace($parent)) {
    $parent = (Get-Location).Path
}
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$token = [Guid]::NewGuid().ToString('N')
$extract = Join-Path $parent "ffmpeg-extract-$token"
$staging = Join-Path $parent "ffmpeg-staging-$token"
$backup = Join-Path $parent "ffmpeg-backup-$token"

try {
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extract -Force

    $ffmpeg = @(Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'ffmpeg.exe')
    $ffprobe = @(Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'ffprobe.exe')
    if ($ffmpeg.Count -ne 1 -or $ffprobe.Count -ne 1) {
        throw "FFmpeg archive must contain exactly one ffmpeg.exe and one ffprobe.exe"
    }

    $license = @(Get-ChildItem -LiteralPath $extract -Recurse -File | Where-Object {
        $_.Name -in @('LICENSE', 'LICENSE.txt', 'COPYING.GPLv3')
    } | Select-Object -First 1)
    if ($license.Count -ne 1) {
        throw 'FFmpeg archive does not contain a redistributable license file'
    }

    $readme = @(Get-ChildItem -LiteralPath $extract -Recurse -File | Where-Object {
        $_.Name -in @('README.txt', 'README.md')
    } | Select-Object -First 1)

    $tools = Join-Path $staging 'tools'
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    Copy-Item -LiteralPath $ffmpeg[0].FullName -Destination (Join-Path $tools 'ffmpeg.exe')
    Copy-Item -LiteralPath $ffprobe[0].FullName -Destination (Join-Path $tools 'ffprobe.exe')
    Copy-Item -LiteralPath $license[0].FullName -Destination (Join-Path $staging 'LICENSE.txt')
    if ($readme.Count -eq 1) {
        Copy-Item -LiteralPath $readme[0].FullName -Destination (Join-Path $staging 'DISTRIBUTION-README.txt')
    }
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $staging 'manifest.json')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'third_party\ffmpeg\windows\NOTICE.md') -Destination (Join-Path $staging 'NOTICE.md')

    if (Test-Path -LiteralPath $OutputDirectory) {
        Move-Item -LiteralPath $OutputDirectory -Destination $backup
    }
    try {
        Move-Item -LiteralPath $staging -Destination $OutputDirectory
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
    }
    catch {
        if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $OutputDirectory)) {
            Move-Item -LiteralPath $backup -Destination $OutputDirectory
        }
        throw
    }

    $source = if ($downloaded) { 'downloaded' } else { 'cached/local' }
    Write-Output "Prepared FFmpeg $($manifest.version) from $source archive: $OutputDirectory"
}
finally {
    if (Test-Path -LiteralPath $extract) {
        Remove-Item -LiteralPath $extract -Recurse -Force
    }
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
    if (Test-Path -LiteralPath $backup) {
        Remove-Item -LiteralPath $backup -Recurse -Force
    }
}
