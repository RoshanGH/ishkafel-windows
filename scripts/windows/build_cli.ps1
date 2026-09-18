$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

Push-Location $projectRoot
try {
    & dart build cli --target bin/ishkafel.dart
    if ($LASTEXITCODE -ne 0) {
        throw 'Windows CLI build failed.'
    }

    $bundleRoot = Join-Path $projectRoot 'build\cli\windows_x64\bundle'
    $expected = Join-Path $bundleRoot 'bin\ishkafel.exe'
    $candidates = @(
        Get-ChildItem -LiteralPath $bundleRoot -Filter 'ishkafel.exe' -File -Recurse -ErrorAction SilentlyContinue
    )
    if ($candidates.Count -ne 1 -or $candidates[0].FullName -ne $expected) {
        $found = ($candidates.FullName -join ', ')
        throw "CLI artifact must exist only at $expected; found: $found"
    }

    $shim = Join-Path $expected '..\ishkafel.cmd'
    $shimBody = @'
@echo off
chcp 65001 >nul
"%~dp0ishkafel.exe" %*
'@
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::GetFullPath($shim),
        $shimBody,
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Output $expected
}
finally {
    Pop-Location
}
