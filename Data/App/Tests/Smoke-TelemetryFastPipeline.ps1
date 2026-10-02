param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_FastPipeline_'+[Guid]::NewGuid().ToString('N'))
$sav=Join-Path $temp 'synthetic_fastpipe.sav'
$directOut=Join-Path $temp 'direct'
$telemetryOut=Join-Path $temp 'telemetry'
$physicalCache=Join-Path $temp 'persistent_physical'
$stride=230;$records=240
New-Item -ItemType Directory -Force -Path $temp | Out-Null
function Put-U32([byte[]]$D,[int]$O,[uint32]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}
function Put-I32([byte[]]$D,[int]$O,[int]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}
function Put-F32([byte[]]$D,[int]$O,[single]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}
try {
    # A minimal but production-shaped 2026 physical stream. No native action suffix is added;
    # semantic modules must remain unavailable rather than inventing fallback facts.
    $bytes=New-Object byte[] ($stride*$records+512)
    for($i=0;$i-lt$records;$i++){
        $b=$i*$stride
        Put-U32 $bytes $b ([uint32]($i*17))
        Put-F32 $bytes ($b+8) 0;Put-F32 $bytes ($b+12) 0;Put-F32 $bytes ($b+16) 0;Put-F32 $bytes ($b+20) 1
        Put-F32 $bytes ($b+24) ([single]($i*0.20));Put-F32 $bytes ($b+28) ([single]([Math]::Sin($i/30.0)*2.0));Put-F32 $bytes ($b+32) 0
        Put-I32 $bytes ($b+52) 5
        for($c=0;$c-lt6;$c++){$bytes[$b+60+$c]=[byte]$(if((($i+$c)%23)-lt4){1}else{0})}
        Put-I32 $bytes ($b+76) $(if($i-lt120){1}else{2})
        Put-F32 $bytes ($b+173) 11.765;Put-F32 $bytes ($b+177) 0;Put-F32 $bytes ($b+181) 0
    }
    [IO.File]::WriteAllBytes($sav,$bytes)
    $sha=(Get-FileHash -LiteralPath $sav -Algorithm SHA256).Hash.ToUpperInvariant()

    . (Join-Path $AppDir 'Modules\Telemetry\Telemetry.CSharpCore.ps1')
    Initialize-TelemetryCSharpCore -AppDir $AppDir
    [QQReplayPortable]::ExtractFastFromDelimited($sav,$directOut)
    $m=Get-Content -LiteralPath (Join-Path $directOut 'manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $rep=@($m.replays)[0];$stream=@($rep.streams|Where-Object{[bool]$_.primary_by_record_count}|Select-Object -First 1)[0]
    Require ($null-ne$stream) 'Fast extractor did not return a primary stream.'
    Require ([string]$stream.physical_transport -eq 'qpf_v1') 'Fast extractor physical transport is not qpf_v1.'
    Require (-not[string]::IsNullOrWhiteSpace([string]$stream.fastbin)) 'Fast extractor did not emit a qpf path.'
    Require ($null-eq$stream.csv -or [string]::IsNullOrWhiteSpace([string]$stream.csv)) 'Fast extractor unexpectedly wrote compatibility physical CSV.'
    $qpf=Join-Path $directOut ([string]$stream.fastbin).Replace('/','\')
    Require ([QQReplayPortable]::ValidateFastBin($qpf)) 'qpf_v1 structural validation failed.'
    $fast=[QQReplayPortable]::LoadFastRows($qpf,[string]$stream.profile,[string]$stream.stream_id)
    Require ($fast.Count-ge200) ('qpf_v1 row count unexpectedly low: '+$fast.Count)
    Require ([string]$fast[0].speed_source -eq 'replay_linear_velocity') 'qpf_v1 lost authoritative 2026 replay linear velocity.'
    Require ($null-ne$fast[0].contact_state -and [int]$fast[0].contact_state-eq5) 'qpf_v1 lost contact_state.'
    Require ($null-ne$fast[150].lap_index -and [int]$fast[150].lap_index-eq2) 'qpf_v1 lost lap_index.'
    $fast[0].distance=1.25;$fast[0].system_drift_state=$false;$fast[0].system_drift_state_source='smoke';$fast[0].nitro_active=$true
    $logicalProbe=Join-Path $temp 'logical_probe.csv'
    [QQReplayPortable]::WriteLogicalCsv($logicalProbe,$fast)
    $lp=@(Import-Csv -LiteralPath $logicalProbe)
    Require ($lp.Count-eq$fast.Count) 'Typed logical CSV writer row count mismatch.'
    foreach($col in @('time_s','contact_state','lap_index','system_drift_state','nitro_active','speed_effect_state_source')){Require ($lp[0].PSObject.Properties.Name -contains $col) ('Typed logical CSV missing '+$col)}
    Require ([string]$lp[0].nitro_active -eq 'True') 'Typed logical CSV did not preserve semantic row flags.'

    $tele=Join-Path $AppDir 'QQReplayTelemetry.ps1'
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tele -ReplayPath $sav -OutDir $telemetryOut -ReplaySha256 $sha -PhysicalCacheDir $physicalCache -Force
    Require ($LASTEXITCODE-eq0) ('First telemetry fast-pipeline run failed: '+$LASTEXITCODE)
    $s1=Get-Content -LiteralPath (Join-Path $telemetryOut 'telemetry_summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $p1=Get-Content -LiteralPath (Join-Path $telemetryOut 'pipeline_profile.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $e1=Get-Content -LiteralPath (Join-Path $telemetryOut 'native_action_evidence_summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Require ([string]$s1.physical_transport_contract-eq'qpf_v1') 'Telemetry summary qpf_v1 contract missing.'
    Require ([string]$s1.physical_cache_mode-eq'rebuilt') 'First telemetry run must rebuild physical cache.'
    Require ([string]$p1.contract-eq'telemetry_pipeline_profile_v1') 'Pipeline profile contract missing.'
    Require ([string]$e1.contract-eq'native_action_evidence_summary_v1') 'Compact native-action evidence contract missing.'
    $pm=Get-Content -LiteralPath (Join-Path $physicalCache 'manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $ps=@($pm.replays[0].streams|Select-Object -First 1)[0]
    $cachedQpf=Join-Path $physicalCache ([string]$ps.fastbin).Replace('/','\')
    Require (Test-Path -LiteralPath $cachedQpf -PathType Leaf) 'Persistent qpf cache file missing.'
    $hash1=(Get-FileHash -LiteralPath $cachedQpf -Algorithm SHA256).Hash
    $ticks1=(Get-Item -LiteralPath $cachedQpf).LastWriteTimeUtc.Ticks

    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tele -ReplayPath $sav -OutDir $telemetryOut -ReplaySha256 $sha -PhysicalCacheDir $physicalCache -Force
    Require ($LASTEXITCODE-eq0) ('Second telemetry fast-pipeline run failed: '+$LASTEXITCODE)
    $s2=Get-Content -LiteralPath (Join-Path $telemetryOut 'telemetry_summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $p2=Get-Content -LiteralPath (Join-Path $telemetryOut 'pipeline_profile.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Require ([string]$s2.physical_cache_mode-eq'reuse') 'Second -Force telemetry run did not reuse physical qpf cache.'
    Require ([string]$p2.physical_cache_mode-eq'reuse') 'Second pipeline profile did not report physical cache reuse.'
    $hash2=(Get-FileHash -LiteralPath $cachedQpf -Algorithm SHA256).Hash
    $ticks2=(Get-Item -LiteralPath $cachedQpf).LastWriteTimeUtc.Ticks
    Require ($hash2-eq$hash1) 'Reused qpf cache content changed unexpectedly.'
    Require ($ticks2-eq$ticks1) 'Reused qpf cache was rewritten unexpectedly.'

    Write-Host ('[OK] Telemetry Fast Pipeline v1 smoke passed. transport=qpf_v1 rows='+$fast.Count+' first='+[string]$p1.total_ms+'ms second='+[string]$p2.total_ms+'ms cache=reused evidence=ready')
    exit 0
}catch{
    Write-Host ('[FAILED] '+$_.Exception.Message)
    Write-Host ('位置: '+$_.InvocationInfo.PositionMessage)
    exit 2
}finally{
    try{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}catch{}
}
