param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}

# Fast-gate wrapper for the Node harness that evaluates the real frontend source.
# The frontend is the product contract for the automatic segment list, the recovery end and the
# analysis-vs-redraw split, so it is regression-tested directly instead of being asserted as text.
$harness=Join-Path (Join-Path $AppDir 'Tests\frontend') 'segment_contract.mjs'
if(-not(Test-Path -LiteralPath $harness -PathType Leaf)){ throw ('frontend contract harness is missing: '+$harness) }

$node=Get-Command node -ErrorAction SilentlyContinue
if($null-eq$node){
    Write-Host '[SKIP] node is not available on this machine, so the frontend contract harness was NOT run.'
    exit 0
}
& $node.Source $harness
$rc=$LASTEXITCODE
if($rc-ne0){ throw ('frontend contract harness failed with exit '+[string]$rc) }
exit 0
