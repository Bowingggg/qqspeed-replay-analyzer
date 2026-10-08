param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}

# Full Gate: stage-closure validation. Composes the Fast Gate and the Real
# Regression gate without duplicating any test logic.
$gates=@(
    'Smoke-Fast.ps1',
    'Smoke-RealRegression.ps1'
)
$sw=[System.Diagnostics.Stopwatch]::StartNew()
foreach($g in $gates){
    $p=Join-Path (Join-Path $AppDir 'Tests') $g
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw ('Missing gate: '+$g)}
    Write-Host ''
    Write-Host ('[Gate] '+$g)
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $p
    if($LASTEXITCODE-ne0){throw ($g+' failed with exit '+$LASTEXITCODE)}
}
$sw.Stop()
Write-Host ''
Write-Host ('[OK] Full Gate passed. app=3.7.24 gate=full composition=fast+real-regression elapsed='+[Math]::Round($sw.Elapsed.TotalSeconds,1)+'s architecture=native_first_v1 native-map=20.2.5.23-verified-av-tail native-driving=sections-v1/detector-v3 frontend-ab=monotonic-dp-v2/common-gate-preview-v2 action-audit=evidence-v1 telemetry-fast=qpf-v1/profile-v1/evidence-v1 native-action-cache=raw-evidence-v1/tail-window/lower-bound-fix real-native-benchmarks=required')
exit 0
