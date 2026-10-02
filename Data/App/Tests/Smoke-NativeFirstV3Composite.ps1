param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}

# Compatibility wrapper. Historical entry point kept so existing scripts,
# shortcuts and muscle memory keep working.
#
# Gate definitions live in exactly one place:
#   Smoke-Fast.ps1            -> daily default (no real replay scans)
#   Smoke-RealRegression.ps1  -> real replay evidence
#   Smoke-Full.ps1            -> Fast + Real (stage closure)
#
# This file no longer holds its own test list; it delegates to the Full Gate.
$full=Join-Path (Join-Path $AppDir 'Tests') 'Smoke-Full.ps1'
if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw 'Missing gate: Smoke-Full.ps1'}

& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $full
if($LASTEXITCODE-ne0){throw ('Full Gate failed with exit '+[string]$LASTEXITCODE)}

Write-Host ''
Write-Host '[OK] Native-First v3 composite smoke passed (compat wrapper -> Full Gate). app=3.7.21 architecture=native_first_v1'
exit 0
