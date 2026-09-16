param([string]$ReportPath = '')

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$buildRoot = (Resolve-Path (Join-Path $projectRoot 'build')).Path
$packageName = 'RoshanGH.IshkafelWindows'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'MSIX developer lifecycle requires an Administrator PowerShell because the unsigned package contains executable activation.'
}
if (Get-AppxPackage -Name $packageName) {
    throw "Refusing to replace an existing installed package named $packageName. Uninstall it explicitly first."
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $buildRoot 'performance\windows-msix-lifecycle.json'
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
[System.IO.Directory]::CreateDirectory((Split-Path -Parent $ReportPath)) | Out-Null

$runRoot = Join-Path $buildRoot ('msix-lifecycle-' + [Guid]::NewGuid().ToString('N'))
$resolvedRunRoot = [System.IO.Path]::GetFullPath($runRoot)
$allowedPrefix = $buildRoot.TrimEnd('\') + '\'
if (-not $resolvedRunRoot.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to create or clean lifecycle data outside build: $resolvedRunRoot"
}
[System.IO.Directory]::CreateDirectory($resolvedRunRoot) | Out-Null
$distRoot = Join-Path $resolvedRunRoot 'dist'
$developerInitialRoot = Join-Path $resolvedRunRoot 'developer-initial'
$developerInitialMsix = Join-Path $resolvedRunRoot 'ishkafel-developer-initial.msix'
$upgradeRoot = Join-Path $resolvedRunRoot 'upgrade'
$upgradeMsix = Join-Path $resolvedRunRoot 'ishkafel-upgrade.msix'
$testData = Join-Path $resolvedRunRoot 'isolated-data'
$testLogs = Join-Path $resolvedRunRoot 'isolated-logs'
$appProcess = $null
$installedByScript = $false

function Get-InstalledPackage {
    return Get-AppxPackage -Name $packageName | Select-Object -First 1
}

function Remove-TestPackage {
    $package = Get-InstalledPackage
    if ($null -ne $package) {
        Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
    }
}

try {
    Write-Output 'Lifecycle: building unsigned developer distribution.'
    & (Join-Path $PSScriptRoot 'package_app.ps1') -SkipBuild -OutputDirectory $distRoot | Out-Host
    $metadataPath = @(Get-ChildItem -LiteralPath $distRoot -Filter '*-distribution.json' -File)
    if ($metadataPath.Count -ne 1) { throw 'Lifecycle distribution metadata is missing.' }
    $metadata = Get-Content -Raw -LiteralPath $metadataPath[0].FullName | ConvertFrom-Json
    if ([bool]$metadata.signed) { throw 'Developer lifecycle package should be unsigned.' }
    $msixArtifact = @($metadata.artifacts | Where-Object { $_.type -eq 'msix' })
    if ($msixArtifact.Count -ne 1) { throw 'Lifecycle distribution does not contain one MSIX.' }
    $initialMsix = Join-Path $distRoot ([string]$msixArtifact[0].file)

    $sdkManifest = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'third_party\windows_sdk\build_tools.json') | ConvertFrom-Json
    $sdkBin = Join-Path $buildRoot ('cache\windows-sdk\' + [string]$sdkManifest.version + '\bin\' + [string]$sdkManifest.sdkBinVersion + '\' + [string]$sdkManifest.architecture)
    $makeappx = Join-Path $sdkBin 'makeappx.exe'
    & $makeappx unpack /p $initialMsix /d $developerInitialRoot /o | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'makeappx could not unpack the developer package.' }
    $developerManifestPath = Join-Path $developerInitialRoot 'AppxManifest.xml'
    [xml]$developerManifest = [System.IO.File]::ReadAllText($developerManifestPath)
    $developerManifest.Package.Identity.Publisher =
        'CN=RoshanGH, OID.2.25.311729368913984317654407730594956997722=1'
    $developerManifest.Save($developerManifestPath)
    & $makeappx pack /d $developerInitialRoot /p $developerInitialMsix /o | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'makeappx could not create the unsigned developer package.' }
    $initialMsix = $developerInitialMsix

    Add-AppxPackage -Path $initialMsix -AllowUnsigned -ForceApplicationShutdown -ErrorAction Stop
    $installedByScript = $true
    Write-Output 'Lifecycle: initial package installed.'
    $installed = Get-InstalledPackage
    if ($null -eq $installed -or [string]$installed.Version -ne [string]$metadata.msixVersion) {
        throw 'Initial MSIX installation version does not match distribution metadata.'
    }

    $installedCli = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\ishkafel.exe'
    if (-not (Test-Path -LiteralPath $installedCli -PathType Leaf)) {
        throw 'MSIX installation did not register the ishkafel.exe CLI execution alias.'
    }
    $help = & $installedCli --help 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $help -notmatch 'ishkafel') {
        throw 'Installed CLI did not start or did not preserve expected help output.'
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $installed.InstallLocation 'ishkafel.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.EnvironmentVariables['ISHKAFEL_DATA_DIR'] = $testData
    $startInfo.EnvironmentVariables['ISHKAFEL_LOG_DIR'] = $testLogs
    $appProcess = [System.Diagnostics.Process]::new()
    $appProcess.StartInfo = $startInfo
    if (-not $appProcess.Start()) { throw 'Installed GUI did not start.' }
    Start-Sleep -Seconds 4
    $appProcess.Refresh()
    if ($appProcess.HasExited -or $appProcess.MainWindowHandle -eq 0) {
        throw 'Installed GUI did not stay alive with a main window.'
    }
    $appProcess.Kill()
    $appProcess.WaitForExit()
    $appProcess.Dispose()
    $appProcess = $null

    & $makeappx unpack /p $initialMsix /d $upgradeRoot /o | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'makeappx could not unpack the initial lifecycle package.' }
    $versionParts = ([string]$metadata.msixVersion).Split('.')
    $versionParts[3] = ([int]$versionParts[3] + 1).ToString()
    $upgradeVersion = $versionParts -join '.'
    $manifestPath = Join-Path $upgradeRoot 'AppxManifest.xml'
    [xml]$manifest = [System.IO.File]::ReadAllText($manifestPath)
    $manifest.Package.Identity.Version = $upgradeVersion
    $writerSettings = [System.Xml.XmlWriterSettings]::new()
    $writerSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $writerSettings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($manifestPath, $writerSettings)
    try { $manifest.Save($writer) } finally { $writer.Dispose() }
    & $makeappx pack /d $upgradeRoot /p $upgradeMsix /o | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'makeappx could not create the upgrade package.' }
    Add-AppxPackage -Path $upgradeMsix -AllowUnsigned -ForceApplicationShutdown -ErrorAction Stop
    Write-Output 'Lifecycle: upgrade package installed.'
    $upgraded = Get-InstalledPackage
    if ($null -eq $upgraded -or [string]$upgraded.Version -ne $upgradeVersion) {
        throw "MSIX upgrade did not reach version $upgradeVersion."
    }

    Remove-TestPackage
    $installedByScript = $false
    Write-Output 'Lifecycle: upgraded package uninstalled.'
    if (Get-InstalledPackage) { throw 'MSIX uninstall left the package installed.' }
    Add-AppxPackage -Path $initialMsix -AllowUnsigned -ForceApplicationShutdown -ErrorAction Stop
    $installedByScript = $true
    Write-Output 'Lifecycle: initial package reinstalled.'
    $recovered = Get-InstalledPackage
    if ($null -eq $recovered -or [string]$recovered.Version -ne [string]$metadata.msixVersion) {
        throw 'MSIX reinstall/recovery did not restore the initial package.'
    }
    Remove-TestPackage
    $installedByScript = $false

    $report = [ordered]@{
        generatedAt = [DateTime]::UtcNow.ToString('o')
        packageName = $packageName
        initialVersion = [string]$metadata.msixVersion
        upgradeVersion = $upgradeVersion
        installMode = 'AllowUnsigned developer lifecycle'
        productionSigningRequired = $true
        installedCliStarted = $true
        installedGuiStarted = $true
        upgraded = $true
        uninstalled = $true
        reinstalled = $true
        finalPackagePresent = [bool](Get-InstalledPackage)
    }
    [System.IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    Write-Output "MSIX lifecycle passed: install=$($metadata.msixVersion) upgrade=$upgradeVersion launch=true uninstall=true reinstall=true final-installed=false"
    Write-Output "Report: $ReportPath"
}
finally {
    if ($null -ne $appProcess) {
        if (-not $appProcess.HasExited) { $appProcess.Kill(); $appProcess.WaitForExit() }
        $appProcess.Dispose()
    }
    if ($installedByScript -or (Get-InstalledPackage)) { Remove-TestPackage }
    if (Test-Path -LiteralPath $resolvedRunRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedRunRoot -Recurse -Force
    }
}
