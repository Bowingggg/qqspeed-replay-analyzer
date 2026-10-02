param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}

# Real Regression gate: real replay evidence only.
#
# Run this when a change touches native parser / action / telemetry core:
#   ReplayNativeActionEvents, ReplayNativeActionCache, ReplayNativeDriftTimeline,
#   ReplayNativeSpeedEffects, combo action parsing, SAV action-object scanning or
#   real replay interpretation.
#
# These smokes each perform real replay tail scans / reads and are deliberately
# not part of the Fast Gate. Each smoke reports its own real/synthetic control
# status, so a machine without the replay archive degrades explicitly instead of
# failing.
$tests=@(
    'Smoke-MultiShadowPhysicalStreams.ps1',
    'Smoke-ReplayNativeActionEvents.ps1',
    'Smoke-ProductionNativeActionSemantics.ps1',
    'Smoke-NativeDrivingEpisodesReal.ps1',
    'Smoke-TrainingAnalysisReal.ps1',
    'Smoke-AnalysisClosureReal.ps1',
    'Smoke-ReplayNativeDriftTimeline.ps1',
    'Smoke-ReplayNativeSpeedEffects.ps1',
    'Smoke-ReplayNativeActionCache.ps1',
    'Smoke-ReplayNativeComboActions.ps1',
    'Smoke-Current2026Closure.ps1',
    'Smoke-MapCoverage.ps1',
    'Smoke-September2026ReplayReadiness.ps1'
)
$passed=0
$sw=[System.Diagnostics.Stopwatch]::StartNew()
foreach($name in $tests){
    $p=Join-Path (Join-Path $AppDir 'Tests') $name
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw ('Missing smoke: '+$name)}
    Write-Host ''
    Write-Host ('[Real] '+$name)
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $p
    if($LASTEXITCODE-ne0){throw ($name+' failed with exit '+$LASTEXITCODE)}
    $passed++
}
$sw.Stop()
Write-Host ''
Write-Host ('[OK] Real Regression gate passed. app=3.7.21 gate=real-regression tests='+$passed+'/'+$tests.Count+' evidence=real-replay elapsed='+[Math]::Round($sw.Elapsed.TotalSeconds,1)+'s')
exit 0
