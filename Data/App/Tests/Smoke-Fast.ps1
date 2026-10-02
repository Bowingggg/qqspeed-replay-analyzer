param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}

# Fast Gate: the daily default validation gate.
#
# Contains every smoke that does NOT require a real replay tail scan, plus the
# module-boundary structure/encoding gate. Real replay evidence lives in
# Smoke-RealRegression.ps1; stage closure runs Smoke-Full.ps1.
$tests=@(
    'Smoke-NativeFirstArchitecture.ps1',
    'Smoke-MapIdentityContract.ps1',
    'Smoke-MapResolutionTiers.ps1',
    'Smoke-MapCatalogBuildCoverage.ps1',
    'Smoke-GameResourceBinding.ps1',
    'Smoke-MapDeclaredIdentity.ps1',
    'Smoke-UserConfirmedBinding.ps1',
    'Smoke-NativeSpeedSource.ps1',
    'Smoke-TelemetryFastPipeline.ps1',
    'Smoke-NativeMapModernLayout.ps1',
    'Smoke-PhysicalStreamAliasRejection.ps1',
    'Smoke-NativeEffectLowerBound.ps1',
    'Smoke-NativeDrivingSections.ps1',
    'Smoke-NativeDrivingEpisodes.ps1',
    'Smoke-AnalysisSegments.ps1',
    'Smoke-SegmentComparison.ps1',
    'Smoke-FrontendSegmentContract.ps1',
    'Smoke-FirstRunBootstrap.ps1',
    'Smoke-ReplayVisibility.ps1',
    'Smoke-TrainingAnalysis.ps1',
    'Smoke-CapabilityIndependence.ps1',
    'Smoke-ReplayLifecycle.ps1',
    'Smoke-ReplayReadContext.ps1',
    'Validate-ModuleBoundaries.ps1',
    # Publisher isolation: proves the public-release tooling cannot damage this repository and cannot
    # publish identity-bearing or credential content. No network, no push, fully sandboxed.
    'Smoke-PublisherIsolation.ps1'
)
$passed=0
$sw=[System.Diagnostics.Stopwatch]::StartNew()
foreach($name in $tests){
    $p=Join-Path (Join-Path $AppDir 'Tests') $name
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw ('Missing smoke: '+$name)}
    Write-Host ''
    Write-Host ('[Fast] '+$name)
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $p
    if($LASTEXITCODE-ne0){throw ($name+' failed with exit '+$LASTEXITCODE)}
    $passed++
}
$sw.Stop()
Write-Host ''
Write-Host ('[OK] Fast Gate passed. app=3.7.22 gate=fast tests='+$passed+'/'+$tests.Count+' real-replay=excluded structural=module-boundaries elapsed='+[Math]::Round($sw.Elapsed.TotalSeconds,1)+'s')
exit 0
