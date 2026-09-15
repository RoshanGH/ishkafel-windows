param(
    [ValidateSet('Debug', 'Release')]
    [string]$Mode = 'Debug'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$secretDir = Join-Path $projectRoot '.secrets'

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
}

$arguments = @('build', 'windows', "--$($Mode.ToLowerInvariant())")
foreach ($entry in $values.GetEnumerator()) {
    $arguments += "--dart-define=$($entry.Key)=$($entry.Value)"
}

Push-Location $projectRoot
try {
    & (Join-Path $PSScriptRoot 'build_cli.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw 'Windows CLI build failed before app packaging.'
    }
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
