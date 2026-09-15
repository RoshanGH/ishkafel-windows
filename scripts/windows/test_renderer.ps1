param(
    [ValidateSet('Debug', 'Release')]
    [string]$Mode = 'Release'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$bundleDir = Join-Path $projectRoot "build\windows\x64\runner\$Mode"
$renderer = Join-Path $bundleDir 'ishkafel_renderer.exe'
if (-not (Test-Path -LiteralPath $renderer -PathType Leaf)) {
    throw "Subtitle renderer is missing. Build Windows first: $renderer"
}

$runDir = Join-Path $projectRoot ("build\renderer-smoke-" + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($runDir) | Out-Null
$pngPath = Join-Path $runDir '中文 字幕.png'
$specPath = Join-Path $runDir 'renderer-spec.json'
$spec = [ordered]@{
    protocolVersion = 1
    width = 540
    height = 960
    fontFamily = 'Ishkafel Subtitle'
    fontSize = 52
    marginV = 96
    strokePercent = 9
    r = 1.0
    g = 1.0
    b = 1.0
    box = $false
    emitBox = $false
    items = @([ordered]@{ text = 'Windows 原生字幕测试'; out = $pngPath })
}
[IO.File]::WriteAllText(
    $specPath,
    ($spec | ConvertTo-Json -Depth 5 -Compress),
    [Text.UTF8Encoding]::new($false)
)

$rendererOutput = & $renderer $specPath 2>&1
$rendererExitCode = $LASTEXITCODE
if ($rendererExitCode -ne 0) {
    throw "Subtitle renderer failed with exit code $rendererExitCode`n$($rendererOutput -join "`n")"
}
if (-not (Test-Path -LiteralPath $pngPath -PathType Leaf)) {
    throw "Subtitle renderer did not produce PNG: $pngPath"
}

$bytes = [IO.File]::ReadAllBytes($pngPath)
$pngSignature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
if ($bytes.Length -lt 33) {
    throw "Subtitle PNG is unexpectedly small: $($bytes.Length) bytes"
}
for ($index = 0; $index -lt $pngSignature.Length; $index++) {
    if ($bytes[$index] -ne $pngSignature[$index]) {
        throw 'Subtitle renderer output is not a PNG file.'
    }
}

$sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $pngPath).Hash
Write-Output "Renderer smoke passed: $pngPath"
Write-Output "SHA256=$sha256 bytes=$($bytes.Length)"
