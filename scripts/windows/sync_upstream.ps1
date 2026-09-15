param(
    [switch]$Push
)

$ErrorActionPreference = 'Stop'

if (& git status --porcelain) {
    throw 'Working tree is not clean; refusing upstream sync.'
}

& git fetch upstream main
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to fetch upstream/main.'
}

$upstreamSha = (& git rev-parse upstream/main).Trim()
$mainSha = (& git rev-parse main).Trim()

function Test-UpstreamIncluded {
    & git merge-base --is-ancestor upstream/main main
    $exitCode = $LASTEXITCODE
    if ($exitCode -gt 1) {
        throw 'Unable to compare main with upstream/main.'
    }
    return $exitCode -eq 0
}

if ($upstreamSha -eq $mainSha -or (Test-UpstreamIncluded)) {
    Write-Output 'Windows main already contains upstream/main.'
    exit 0
}

$branch = "sync/macos-$($upstreamSha.Substring(0, 7))"
& git switch main
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to switch to main.'
}
& git switch -C $branch
if ($LASTEXITCODE -ne 0) {
    throw "Unable to create sync branch: $branch"
}

& git merge --no-edit upstream/main
if ($LASTEXITCODE -ne 0) {
    & git merge --abort
    throw 'Mac upstream merge conflicted; manual adaptation is required.'
}

if ($Push) {
    & git push --force-with-lease origin $branch
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to push sync branch: $branch"
    }
}

Write-Output $branch
