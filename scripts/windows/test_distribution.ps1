param(
    [string]$DistributionDirectory = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$buildRoot = (Resolve-Path (Join-Path $projectRoot 'build')).Path
if ([string]::IsNullOrWhiteSpace($DistributionDirectory)) {
    $DistributionDirectory = Join-Path $buildRoot 'dist'
}
$DistributionDirectory = (Resolve-Path -LiteralPath $DistributionDirectory).Path

$metadataFiles = @(Get-ChildItem -LiteralPath $DistributionDirectory -File -Filter '*-distribution.json')
if ($metadataFiles.Count -ne 1) {
    throw "分发目录必须恰好有一份 distribution.json，实际：$($metadataFiles.Count)"
}
$metadata = Get-Content -Raw -LiteralPath $metadataFiles[0].FullName | ConvertFrom-Json
if ($metadata.product -ne 'ishkafel-windows' -or $metadata.architecture -ne 'x64') {
    throw 'distribution.json 的产品或架构不正确。'
}

foreach ($artifact in $metadata.artifacts) {
    $path = Join-Path $DistributionDirectory ([string]$artifact.file)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "分发产物缺失：$($artifact.file)"
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($actual -ne [string]$artifact.sha256) {
        throw "SHA-256 不匹配：$($artifact.file)"
    }
    if ((Get-Item -LiteralPath $path).Length -ne [long]$artifact.sizeBytes) {
        throw "文件大小不匹配：$($artifact.file)"
    }
}

$msixArtifact = @($metadata.artifacts | Where-Object { $_.type -eq 'msix' })
$portableArtifact = @($metadata.artifacts | Where-Object { $_.type -eq 'portable-zip' })
if ($msixArtifact.Count -ne 1 -or $portableArtifact.Count -ne 1) {
    throw '分发元数据必须恰好包含一个 MSIX 和一个便携 ZIP。'
}

$sdkManifest = Get-Content -Raw -LiteralPath (
    Join-Path $projectRoot 'third_party\windows_sdk\build_tools.json'
) | ConvertFrom-Json
$makeAppx = Join-Path $buildRoot (
    'cache\windows-sdk\' + [string]$sdkManifest.version + '\bin\' +
    [string]$sdkManifest.sdkBinVersion + '\' + [string]$sdkManifest.architecture +
    '\makeappx.exe'
)
if (-not (Test-Path -LiteralPath $makeAppx -PathType Leaf)) {
    throw '找不到已校验的 makeappx.exe；请先运行 package_app.ps1。'
}

$verifyRoot = Join-Path $buildRoot ('distribution-smoke-' + [Guid]::NewGuid().ToString('N'))
$resolvedVerify = [System.IO.Path]::GetFullPath($verifyRoot)
$allowedPrefix = $buildRoot.TrimEnd('\') + '\'
if (-not $resolvedVerify.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "拒绝在 build 目录之外创建或清理验证目录：$resolvedVerify"
}

try {
    & $makeAppx unpack /p (
        Join-Path $DistributionDirectory ([string]$msixArtifact[0].file)
    ) /d $resolvedVerify /o | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'MSIX 解包验证失败。' }

    $required = @(
        'AppxManifest.xml',
        'ishkafel.exe',
        'ishkafel_renderer.exe',
        'cli\bin\ishkafel.exe',
        'tools\ffmpeg.exe',
        'tools\ffprobe.exe',
        'licenses\ffmpeg\LICENSE.txt'
    )
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $resolvedVerify $relative) -PathType Leaf)) {
            throw "MSIX 缺少：$relative"
        }
    }
    $manifestPath = Join-Path $resolvedVerify 'AppxManifest.xml'
    [xml]$appxManifest = [IO.File]::ReadAllText(
        $manifestPath,
        [Text.Encoding]::UTF8
    )
    if ($appxManifest.Package.Identity.Version -ne [string]$metadata.msixVersion) {
        throw 'MSIX manifest 版本与 distribution.json 不一致。'
    }
    $cliAliasExtension = $appxManifest.SelectSingleNode(
        "//*[local-name()='Extension' and @Category='windows.appExecutionAlias' " +
        "and @Executable='cli\bin\ishkafel.exe']"
    )
    $cliAlias = if ($null -eq $cliAliasExtension) {
        $null
    } else {
        $cliAliasExtension.SelectSingleNode(
            ".//*[local-name()='ExecutionAlias' and @Alias='ishkafel.exe']"
        )
    }
    if ($null -eq $cliAliasExtension -or $null -eq $cliAlias) {
        throw 'MSIX 没有把包内 CLI 注册为 ishkafel.exe 应用执行别名。'
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $portablePath = Join-Path $DistributionDirectory ([string]$portableArtifact[0].file)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($portablePath)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace('/', '\') })
        $root = "ishkafel-windows-$($metadata.version)\"
        foreach ($relative in $required | Where-Object { $_ -ne 'AppxManifest.xml' }) {
            if ($entryNames -notcontains ($root + $relative)) {
                throw "便携 ZIP 缺少：$relative"
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    if ([bool]$metadata.signed) {
        $signature = Get-AuthenticodeSignature -LiteralPath (
            Join-Path $DistributionDirectory ([string]$msixArtifact[0].file)
        )
        if ($signature.Status -ne 'Valid') {
            throw "已标记签名的 MSIX 验签失败：$($signature.Status)"
        }
    }
    Write-Output (
        "Distribution smoke passed: version=$($metadata.version) " +
        "signed=$($metadata.signed) msix=$($msixArtifact[0].sizeBytes) bytes " +
        "portable=$($portableArtifact[0].sizeBytes) bytes"
    )
}
finally {
    if (Test-Path -LiteralPath $resolvedVerify) {
        Remove-Item -LiteralPath $resolvedVerify -Recurse -Force
    }
}
