$ErrorActionPreference='Stop'

$appDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir=Split-Path -Parent $appDir
$projectRoot=Split-Path -Parent $dataDir
$frontend=Join-Path $appDir 'QQReplayFrontend.ps1'

if(-not(Test-Path -LiteralPath $frontend -PathType Leaf)) {
    throw 'Internal frontend script is missing.'
}

New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot 'Output') | Out-Null

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $frontend
exit $LASTEXITCODE
