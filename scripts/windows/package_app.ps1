param(
    [switch]$SkipBuild,
    [string]$OutputDirectory = '',
    [string]$PfxPath = '',
    [string]$SigningPassword = '',
    [switch]$RequireSigning
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$releaseRoot = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$sdkManifestPath = Join-Path $projectRoot 'third_party\windows_sdk\build_tools.json'
$manifestTemplatePath = Join-Path $projectRoot 'packaging\windows\AppxManifest.xml.in'

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

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Assert-LastExitCode([string]$Message) {
    if ($LASTEXITCODE -ne 0) {
        throw $Message
    }
}

function New-TileImage(
    [string]$IconPath,
    [string]$Destination,
    [int]$Width,
    [int]$Height
) {
    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::new(
        $Width,
        $Height,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $icon = $null
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $side = [Math]::Max(16, [Math]::Floor([Math]::Min($Width, $Height) * 0.78))
        $x = [Math]::Floor(($Width - $side) / 2)
        $y = [Math]::Floor(($Height - $side) / 2)
        $icon = [System.Drawing.Icon]::new($IconPath, $side, $side)
        $graphics.DrawIcon($icon, [System.Drawing.Rectangle]::new($x, $y, $side, $side))
        $bitmap.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($null -ne $icon) { $icon.Dispose() }
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Resolve-SdkTools([object]$SdkManifest) {
    if ([string]$SdkManifest.archiveUrl -notlike 'https://api.nuget.org/*') {
        throw 'Windows SDK Build Tools 只允许从 api.nuget.org 下载。'
    }
    $cacheRoot = Join-Path $projectRoot 'build\cache\windows-sdk'
    $archive = Join-Path $cacheRoot (
        'microsoft.windows.sdk.buildtools.' + [string]$SdkManifest.version + '.nupkg'
    )
    $extractRoot = Join-Path $cacheRoot ([string]$SdkManifest.version)
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null

    $expected = ([string]$SdkManifest.archiveSha256).ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{64}$') {
        throw 'Windows SDK Build Tools 清单里的 archiveSha256 无效。'
    }
    $needsDownload = -not (Test-Path -LiteralPath $archive)
    if (-not $needsDownload) {
        $needsDownload = (Get-Sha256 $archive) -ne $expected
    }
    if ($needsDownload) {
        $partial = "$archive.download"
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        Invoke-WebRequest -Uri ([string]$SdkManifest.archiveUrl) -OutFile $partial -UseBasicParsing
        if ((Get-Sha256 $partial) -ne $expected) {
            Remove-Item -LiteralPath $partial -Force
            throw 'Windows SDK Build Tools 下载文件 SHA-256 不匹配。'
        }
        Move-Item -LiteralPath $partial -Destination $archive -Force
    }
    if ((Get-Sha256 $archive) -ne $expected) {
        throw 'Windows SDK Build Tools 缓存文件 SHA-256 不匹配。'
    }

    $binRoot = Join-Path $extractRoot (
        'bin\' + [string]$SdkManifest.sdkBinVersion + '\' + [string]$SdkManifest.architecture
    )
    $makeAppx = Join-Path $binRoot 'makeappx.exe'
    $signTool = Join-Path $binRoot 'signtool.exe'
    if (-not (Test-Path -LiteralPath $makeAppx) -or -not (Test-Path -LiteralPath $signTool)) {
        if (Test-Path -LiteralPath $extractRoot) {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($archive, $extractRoot)
    }
    if (-not (Test-Path -LiteralPath $makeAppx) -or -not (Test-Path -LiteralPath $signTool)) {
        throw 'Windows SDK Build Tools 包里没有找到 makeappx.exe / signtool.exe。'
    }
    return [pscustomobject]@{ MakeAppx = $makeAppx; SignTool = $signTool }
}

function Invoke-SignFile(
    [string]$SignTool,
    [string]$Certificate,
    [string]$Password,
    [string]$Path
) {
    $arguments = @('sign', '/fd', 'SHA256', '/f', $Certificate)
    if (-not [string]::IsNullOrEmpty($Password)) {
        $arguments += @('/p', $Password)
    }
    $arguments += $Path
    & $SignTool @arguments | Out-Null
    Assert-LastExitCode "签名失败：$Path"
    & $SignTool verify /pa $Path | Out-Null
    Assert-LastExitCode "签名验证失败：$Path"
}

Push-Location $projectRoot
try {
    if (-not $SkipBuild) {
        & (Join-Path $PSScriptRoot 'build_app.ps1') -Mode Release | Out-Host
    }

    $pubspec = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pubspec.yaml')
    $versionMatch = [regex]::Match($pubspec, '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$')
    if (-not $versionMatch.Success) {
        throw 'pubspec.yaml 的 version 必须是 major.minor.patch+build 格式。'
    }
    $productVersion = "$($versionMatch.Groups[1].Value).$($versionMatch.Groups[2].Value).$($versionMatch.Groups[3].Value)"
    $msixVersion = "$productVersion.$($versionMatch.Groups[4].Value)"

    $requiredFiles = @(
        'ishkafel.exe',
        'ishkafel_renderer.exe',
        'cli\bin\ishkafel.exe',
        'tools\ffmpeg.exe',
        'tools\ffprobe.exe',
        'licenses\ffmpeg\LICENSE.txt',
        'licenses\ffmpeg\NOTICE.md',
        'licenses\ffmpeg\manifest.json'
    )
    foreach ($relative in $requiredFiles) {
        $candidate = Join-Path $releaseRoot $relative
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Release 目录不完整，缺少：$relative"
        }
    }

    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $OutputDirectory = Join-Path $projectRoot 'build\dist'
    }
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

    $sdkManifest = Get-Content -Raw -LiteralPath $sdkManifestPath | ConvertFrom-Json
    $sdk = Resolve-SdkTools $sdkManifest

    if ([string]::IsNullOrWhiteSpace($PfxPath)) {
        $defaultPfx = Join-Path $projectRoot '.secrets\windows_signing.pfx'
        if (Test-Path -LiteralPath $defaultPfx) { $PfxPath = $defaultPfx }
    }
    if ([string]::IsNullOrEmpty($SigningPassword)) {
        $passwordFile = Join-Path $projectRoot '.secrets\windows_signing_password'
        if (Test-Path -LiteralPath $passwordFile) {
            $SigningPassword = (Get-Content -Raw -LiteralPath $passwordFile).Trim()
        }
    }
    $signed = -not [string]::IsNullOrWhiteSpace($PfxPath)
    if ($RequireSigning -and -not $signed) {
        throw '未提供 Windows 代码签名证书；RequireSigning 禁止生成未签名产物。'
    }

    $publisher = 'CN=RoshanGH'
    if ($signed) {
        $PfxPath = (Resolve-Path -LiteralPath $PfxPath).Path
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $PfxPath,
            $SigningPassword,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
        )
        try { $publisher = $certificate.Subject } finally { $certificate.Dispose() }
    }

    $token = [Guid]::NewGuid().ToString('N')
    $stagingRoot = Join-Path $OutputDirectory ".ishkafel-dist-$token"
    $payloadRoot = Join-Path $stagingRoot "ishkafel-windows-$productVersion"
    $packageRoot = Join-Path $stagingRoot 'msix'
    New-Item -ItemType Directory -Force -Path $payloadRoot, $packageRoot | Out-Null
    Get-ChildItem -LiteralPath $releaseRoot -Force |
        Copy-Item -Destination $payloadRoot -Recurse -Force
    Get-ChildItem -LiteralPath $payloadRoot -Recurse -File -Filter '*.pdb' | Remove-Item -Force

    if ($signed) {
        $binaries = Get-ChildItem -LiteralPath $payloadRoot -Recurse -File |
            Where-Object { $_.Extension -in @('.exe', '.dll') }
        foreach ($binary in $binaries) {
            Invoke-SignFile $sdk.SignTool $PfxPath $SigningPassword $binary.FullName
        }
    }

    Get-ChildItem -LiteralPath $payloadRoot -Force |
        Copy-Item -Destination $packageRoot -Recurse -Force
    $assets = Join-Path $packageRoot 'Assets'
    New-Item -ItemType Directory -Force -Path $assets | Out-Null
    $iconPath = Join-Path $projectRoot 'windows\runner\resources\app_icon.ico'
    New-TileImage $iconPath (Join-Path $assets 'Square44x44Logo.png') 44 44
    New-TileImage $iconPath (Join-Path $assets 'Square150x150Logo.png') 150 150
    New-TileImage $iconPath (Join-Path $assets 'Square310x310Logo.png') 310 310
    New-TileImage $iconPath (Join-Path $assets 'Wide310x150Logo.png') 310 150
    New-TileImage $iconPath (Join-Path $assets 'StoreLogo.png') 50 50

    $manifest = ([System.IO.File]::ReadAllText(
        $manifestTemplatePath,
        [System.Text.Encoding]::UTF8
    )).
        Replace('@PUBLISHER@', [System.Security.SecurityElement]::Escape($publisher)).
        Replace('@VERSION@', $msixVersion)
    Write-Utf8NoBom (Join-Path $packageRoot 'AppxManifest.xml') $manifest

    $portableName = "ishkafel-windows-$productVersion-x64-portable.zip"
    $msixName = "ishkafel-windows-$productVersion-x64.msix"
    $portableTemp = Join-Path $stagingRoot $portableName
    $msixTemp = Join-Path $stagingRoot $msixName
    Compress-Archive -LiteralPath $payloadRoot -DestinationPath $portableTemp -CompressionLevel Optimal
    & $sdk.MakeAppx pack /d $packageRoot /p $msixTemp /o | Out-Host
    Assert-LastExitCode 'makeappx.exe 没能生成 MSIX。'

    if ($signed) {
        Invoke-SignFile $sdk.SignTool $PfxPath $SigningPassword $msixTemp
        $auth = Get-AuthenticodeSignature -LiteralPath $msixTemp
        if ($auth.Status -ne 'Valid') {
            throw "MSIX Authenticode 状态不是 Valid：$($auth.Status)"
        }
    }

    $portableHash = Get-Sha256 $portableTemp
    $msixHash = Get-Sha256 $msixTemp
    $readmeName = "ishkafel-windows-$productVersion-README.txt"
    $readmeTemp = Join-Path $stagingRoot $readmeName
    $signingLine = if ($signed) {
        "签名：已使用 $publisher 签名并验证。"
    } else {
        '签名：未签名开发产物。公开分发前必须用受信任证书或 Microsoft Store 签名。'
    }
    Write-Utf8NoBom $readmeTemp @"
ishkafel Windows $productVersion

$signingLine

- $msixName：Windows 正式安装格式；未签名时仅用于打包验证，不能直接作为公开安装包。
- $portableName：内部验证用便携包，解压完整目录后运行 ishkafel.exe。
- 包内包含 GUI、CLI、字幕渲染器以及固定版本 FFmpeg/ffprobe 和对应许可材料。
- Windows SDK Build Tools：$($sdkManifest.version)，许可：$($sdkManifest.licenseUrl)
"@

    $metadataName = "ishkafel-windows-$productVersion-distribution.json"
    $metadataTemp = Join-Path $stagingRoot $metadataName
    $metadata = [ordered]@{
        product = 'ishkafel-windows'
        version = $productVersion
        msixVersion = $msixVersion
        architecture = 'x64'
        signed = $signed
        publisher = $publisher
        windowsSdkBuildTools = [string]$sdkManifest.version
        artifacts = @(
            [ordered]@{
                file = $msixName
                type = 'msix'
                sizeBytes = (Get-Item -LiteralPath $msixTemp).Length
                sha256 = $msixHash
            },
            [ordered]@{
                file = $portableName
                type = 'portable-zip'
                sizeBytes = (Get-Item -LiteralPath $portableTemp).Length
                sha256 = $portableHash
            }
        )
    } | ConvertTo-Json -Depth 5
    Write-Utf8NoBom $metadataTemp $metadata

    $sumsName = "ishkafel-windows-$productVersion-SHA256SUMS.txt"
    $sumsTemp = Join-Path $stagingRoot $sumsName
    Write-Utf8NoBom $sumsTemp "$msixHash  $msixName`r`n$portableHash  $portableName`r`n"

    $finalFiles = @($portableTemp, $msixTemp, $readmeTemp, $metadataTemp, $sumsTemp)
    foreach ($file in $finalFiles) {
        Move-Item -LiteralPath $file -Destination (Join-Path $OutputDirectory (Split-Path -Leaf $file)) -Force
    }
    Write-Output "Windows 分发产物已生成：$OutputDirectory"
    Write-Output "  $msixName"
    Write-Output "  $portableName"
    if (-not $signed) {
        Write-Warning '未提供 Windows 代码签名证书；当前 MSIX 是未签名开发产物。'
    }
}
finally {
    Pop-Location
    if ($null -ne $stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
