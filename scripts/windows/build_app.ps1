param(
    [ValidateSet('Debug', 'Release')]
    [string]$Mode = 'Debug',
    [string]$ManifestKey = 'windows/latest.json',
    [string]$SecretsDirectory = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($SecretsDirectory)) {
    $secretDir = Join-Path $projectRoot '.secrets'
}
else {
    $secretDir = (Resolve-Path -LiteralPath $SecretsDirectory).Path
}

function Read-Secret([string]$Name, [bool]$Required) {
    $path = Join-Path $secretDir $Name
    if (-not (Test-Path -LiteralPath $path)) {
        if ($Required) {
            throw "Missing .secrets/$Name"
        }
        return ''
    }
    return (Get-Content -Raw -LiteralPath $path).Trim()
}

$values = [ordered]@{
    ARK_API_KEY         = Read-Secret 'ark_api_key' $true
    SPEECH_APP_ID       = Read-Secret 'speech_app_id' $true
    SPEECH_ACCESS_TOKEN = Read-Secret 'speech_access_token' $true
    UPDATE_TOS_REGION   = Read-Secret 'update_tos_region' $false
    UPDATE_TOS_BUCKET   = Read-Secret 'update_tos_bucket' $false
    UPDATE_TOS_ENDPOINT = Read-Secret 'update_tos_endpoint' $false
    UPDATE_TOS_AK       = Read-Secret 'update_tos_ak' $false
    UPDATE_TOS_SK       = Read-Secret 'update_tos_sk' $false
    UPDATE_TOS_MANIFEST_KEY = $ManifestKey
    UPDATE_SIGNING_PUBLIC_KEY = Read-Secret 'windows_update_signing_public_key' $true
    REPORT_API_URL = Read-Secret 'report_api_url' ($Mode -eq 'Release')
    REPORT_SUBMIT_TOKEN = Read-Secret 'report_submit_token' ($Mode -eq 'Release')
    REPORT_TLS_CA_BASE64 = Read-Secret 'report_tls_ca_base64' ($Mode -eq 'Release')
}

$arguments = @('build', 'windows', "--$($Mode.ToLowerInvariant())")
foreach ($entry in $values.GetEnumerator()) {
    $arguments += "--dart-define=$($entry.Key)=$($entry.Value)"
}

Push-Location $projectRoot
try {
    & (Join-Path $PSScriptRoot 'prepare_media_tools.ps1')
    & (Join-Path $PSScriptRoot 'build_cli.ps1')
    & flutter @arguments
    if ($LASTEXITCODE -ne 0) {
        throw 'Windows build failed.'
    }

    $artifact = Join-Path $projectRoot "build\windows\x64\runner\$Mode\ishkafel.exe"
    if (-not (Test-Path -LiteralPath $artifact)) {
        throw "Windows build completed but artifact is missing: $artifact"
    }
    # 独立工具只依赖纯 Dart 的 path；排除 Flutter 包的 native build hooks。
    # 保留 .dart_tool 中的相对 rootUri，编译期仍从同一份源码生成并注入只提交凭据。
    $diagnosticConfig = Get-Content (Join-Path $projectRoot '.dart_tool/package_config.json') -Raw | ConvertFrom-Json
    $diagnosticConfig.packages = @($diagnosticConfig.packages | Where-Object { $_.name -in @('ishkafel', 'path') })
    $diagnosticConfigPath = Join-Path $projectRoot '.dart_tool/diagnostics_packages.json'
    [System.IO.File]::WriteAllText($diagnosticConfigPath, ($diagnosticConfig | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    # dartdev 还会按入口文件位置扫描 hooks；纯 Dart 入口放在仓库同盘的独立临时目录。
    $diagnosticTemp = Join-Path (Split-Path $projectRoot -Parent) ('diagnostics-compiler-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $diagnosticTemp | Out-Null
    $diagnosticEntry = Join-Path $diagnosticTemp 'main.dart'
    Copy-Item -LiteralPath (Join-Path $projectRoot 'bin/ishkafel_diagnostics.dart') -Destination $diagnosticEntry
    $diagnosticArguments = @('compile', 'exe', "--packages=$diagnosticConfigPath", $diagnosticEntry, '-o', (Join-Path (Split-Path $artifact) 'ishkafel-diagnostics.exe'))
    foreach ($entry in $values.GetEnumerator()) {
        $diagnosticArguments += "--define=$($entry.Key)=$($entry.Value)"
    }
    try {
        & dart @diagnosticArguments
        if ($LASTEXITCODE -ne 0) { throw 'Diagnostic helper build failed.' }
    }
    finally {
        Remove-Item -LiteralPath $diagnosticEntry -Force
        Remove-Item -LiteralPath $diagnosticTemp
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'diagnostic_watchdog.ps1') -Destination (Split-Path $artifact) -Force
    Write-Output $artifact
}
finally {
    Pop-Location
}
