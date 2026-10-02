param()
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
$appDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$nativeMap=Join-Path $appDir 'QQNativeMap.ps1'
if(-not(Test-Path -LiteralPath $nativeMap -PathType Leaf)){throw 'QQNativeMap.ps1 missing'}
$text=Get-Content -LiteralPath $nativeMap -Raw -Encoding UTF8
$m=[regex]::Match($text,'(?s)\$cs=@"\r?\n(?<code>.*?)\r?\n"@')
if(-not$m.Success){throw 'Native Map C# core block not found'}
if(-not('QQOfficialMinimapGeometryCore' -as [type])){Add-Type -TypeDefinition $m.Groups['code'].Value -Language CSharp|Out-Null}
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_NativeMapModern_'+[Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $tmp|Out-Null
    $legacy=[QQOfficialMinimapGeometryCore]::SelfTest($tmp)
    $modern=[QQOfficialMinimapGeometryCore]::SelfTestModern($tmp)
    $reject=[QQOfficialMinimapGeometryCore]::SelfTestModernReject($tmp)
    $modern22=[QQOfficialMinimapGeometryCore]::SelfTestModern22($tmp)
    $reject22=[QQOfficialMinimapGeometryCore]::SelfTestModern22Reject($tmp)
    if([string]$legacy-ne'ok'){throw ('legacy selftest failed: '+[string]$legacy)}
    if([string]$modern-ne'ok'){throw ('modern selftest failed: '+[string]$modern)}
    if([string]$reject-ne'ok'){throw ('modern reject selftest failed: '+[string]$reject)}
    if([string]$modern22-ne'ok'){throw ('20.2.5.22 selftest failed: '+[string]$modern22)}
    if([string]$reject22-ne'ok'){throw ('20.2.5.22 reject selftest failed: '+[string]$reject22)}
} finally {Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue}
Write-Host '[OK] Native Map modern layout smoke passed. legacy=20.2.0.7 modern=20.2.5.23 modern22=20.2.5.22 reader=verified-av-tail-v1 fail-closed=signature-gated'
exit 0
