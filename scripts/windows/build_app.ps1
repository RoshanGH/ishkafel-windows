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
    Write-Output $artifact
}
finally {
    Pop-Location
}
