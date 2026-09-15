$ErrorActionPreference = 'Stop'

Write-Output 'Security: this script does not read .secrets.'

$commands = @('git', 'ssh', 'flutter', 'dart', 'gh', 'cmake', 'ninja')
foreach ($name in $commands) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Missing development tool: $name"
    }
    Write-Output "$name => $($command.Source)"
}

git --version
ssh -V
flutter --version
dart --version
gh --version
cmake --version
ninja --version
flutter doctor -v

if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
}
