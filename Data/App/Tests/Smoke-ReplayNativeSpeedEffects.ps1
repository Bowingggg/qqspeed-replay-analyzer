param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_NativeSpeedEffects_'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
function Put-U32([byte[]]$D,[int]$O,[uint32]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}
function Put-F32([byte[]]$D,[int]$O,[single]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}
function Put-Marker([byte[]]$D,[int]$CountOffset){[Array]::Copy([byte[]](0x7E,0xA0,0x1E,0xC2),0,$D,$CountOffset-4,4)}
function Find-Replay([string]$Archive,[string]$Name){
    if(-not(Test-Path -LiteralPath $Archive -PathType Container)){return $null}
    $m=@(Get-ChildItem -LiteralPath $Archive -Recurse -File -Filter $Name -ErrorAction SilentlyContinue|Where-Object{$_.Name-eq$Name}|Select-Object -First 1)
    if($m.Count-eq0){return $null};return $m[0]
}
function Run-RealControl([string]$Name,[hashtable]$Expected,[string]$Archive,[string]$Telemetry,[string]$TempRoot){
    $f=Find-Replay $Archive $Name
    if($null-eq$f){return 'not-present'}
    $safe=($Name -replace '[^0-9A-Za-z\u4e00-\u9fff]+','_')
    $out=Join-Path $TempRoot $safe
    $dataDir=Split-Path -Parent $Archive;$sha=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToUpperInvariant();$short=$sha.Substring(0,16);$physical=Join-Path $dataDir ('PhysicalTelemetryCache\'+$short)
    $childOutput=@(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Telemetry -ReplayPath $f.FullName -OutDir $out -ReplaySha256 $sha -PhysicalCacheDir $physical -Force 2>&1)
    $childExit=$LASTEXITCODE
    foreach($line in $childOutput){Write-Host ([string]$line)}
    if($childExit-ne0){throw ($Name+' telemetry exited '+$childExit)}
    $sum=Get-Content -LiteralPath (Join-Path $out 'telemetry_summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if([int]$sum.schema_version-ne19-or[int]$sum.replay_native_speed_effect_timeline_schema_version-ne2-or[int]$sum.boost_effect_contract_version-ne3){throw ($Name+' schema mismatch: telemetry='+$sum.schema_version+' speedfx='+$sum.replay_native_speed_effect_timeline_schema_version+' boost='+$sum.boost_effect_contract_version)}
    $st=@($sum.streams|Where-Object{[bool]$_.speed_effect_state_available}|Sort-Object {[int]$_.native_speed_effect_segment_count} -Descending|Select-Object -First 1)
    if($st.Count-eq0){throw ($Name+' did not expose a native speed-effect stream.')}
    $s=$st[0]
    foreach($k in @($Expected.Keys)){
        $actual=[int]$s.$k;$want=[int]$Expected[$k]
        if($actual-ne$want){throw ($Name+' expected '+$k+'='+$want+', got '+$actual)}
    }
    if([string]$s.speed_effect_state_source-ne'replay_native_action_object_speed_effect_table_v2'){throw ($Name+' speed-effect source mismatch: '+[string]$s.speed_effect_state_source)}
    return 'ok'
}
try {
    . (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeDriftTimeline.ps1')
    . (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeSpeedEffects.ps1')

    # Synthetic mixed action contract: official action-object marker + Drift table + adjacent effect table.
    $sav=Join-Path $temp 'synthetic_native_speed_effects.sav'
    $bytes=New-Object byte[] 50000
    $driftOffset=36000
    Put-Marker $bytes $driftOffset
    Put-U32 $bytes $driftOffset 4
    $dp=@(@(1000,1),@(2000,0),@(2200,1),@(2800,0))
    for($i=0;$i-lt$dp.Count;$i++){Put-U32 $bytes ($driftOffset+4+5*$i) ([uint32]$dp[$i][0]);$bytes[$driftOffset+8+5*$i]=[byte]$dp[$i][1]}
    $effectOffset=$driftOffset+4+5*$dp.Count
    Put-U32 $bytes $effectOffset 12
    $er=@(
        @(1100,1,2001.0),@(1750,0,2001.0),
        @(3000,1,1.0),
        @(4050,1,2001.0),@(4580,1,2001.0),@(4700,0,2001.0),@(5230,0,2001.0),
        @(6300,0,1.0),
        @(7000,1,2001.0),@(7650,0,2001.0),
        @(8000,1,2003.0),@(10050,0,2003.0)
    )
    for($i=0;$i-lt$er.Count;$i++){$p=$effectOffset+4+9*$i;Put-U32 $bytes $p ([uint32]$er[$i][0]);$bytes[$p+4]=[byte]$er[$i][1];Put-F32 $bytes ($p+5) ([single]$er[$i][2])}
    Put-U32 $bytes 35000 ([uint32]3892314112)
    [IO.File]::WriteAllBytes($sav,$bytes)

    $rows=New-Object System.Collections.Generic.List[object]
    for($i=0;$i-le550;$i++){
        $t=$i*0.02;$shift=$false;$ctrl=$false;$contact=5
        if([Math]::Abs($t-1.0)-lt0.001-or[Math]::Abs($t-2.2)-lt0.001){$shift=$true}
        if([Math]::Abs($t-3.02)-lt0.001){$ctrl=$true}
        if($t-ge4.0-and$t-lt4.5){$contact=0}
        $rows.Add([pscustomobject]@{time_s=$t;contact_state=$contact;input_bool_candidate_64=$shift;input_bool_candidate_65=$ctrl;system_drift_state='unknown';system_drift_state_source='unresolved_not_found'})
    }
    $dc=@(Get-ReplayNativeDriftTimelineCandidates -ReplayPath $sav)
    $dr=Resolve-ReplayNativeDriftTimeline -Candidates $dc -Rows ($rows.ToArray())
    if(-not[bool]$dr.available-or[long]$dr.candidate.count_offset-ne$driftOffset){throw 'Synthetic native drift binding failed before speed-effect test.'}
    $fx=Resolve-ReplayNativeSpeedEffectTimeline -ReplayPath $sav -NativeDriftResolved $dr -Rows ($rows.ToArray())
    if(-not[bool]$fx.available){throw ('Synthetic native speed-effect table unavailable: '+[string]$fx.status)}
    if([long]$fx.count_offset-ne$effectOffset-or[int]$fx.table.record_count-ne12-or[int]$fx.table.interval_count-ne6){throw ('Synthetic speed-effect grammar mismatch: offset='+$fx.count_offset+' records='+$fx.table.record_count+' intervals='+$fx.table.interval_count)}
    if(-not[bool]$fx.nitro_semantic_valid-or[int]$fx.nitro_ctrl_match_count-ne1){throw ('Synthetic Nitro semantic gate failed: valid='+$fx.nitro_semantic_valid+' ctrl='+$fx.nitro_ctrl_match_count+'/'+$fx.nitro_code_interval_count)}
    $seg=Convert-ReplayNativeSpeedEffectsToSegments -Resolved $fx -Rows ($rows.ToArray()) -NativeDriftResolved $dr
    if([int]$seg.nitro_count-ne1-or[int]$seg.small_boost_count-ne1-or[int]$seg.air_boost_count-ne1-or[int]$seg.landing_boost_count-ne1-or[int]$seg.other_small_boost_count-ne1-or[int]$seg.map_propulsion_effect_count-ne1-or[int]$seg.unknown_speed_effect_count-ne0){
        throw ('Synthetic subtype contract failed: nitro='+$seg.nitro_count+' small='+$seg.small_boost_count+' air='+$seg.air_boost_count+' landing='+$seg.landing_boost_count+' other='+$seg.other_small_boost_count+' mapfx='+$seg.map_propulsion_effect_count+' unknown='+$seg.unknown_speed_effect_count)
    }
    $mapFx=@($seg.map_propulsion_effect_segments)
    if($mapFx.Count-ne1-or[Math]::Abs([double]$mapFx[0].effect_code-2003.0)-gt0.001-or[string]$mapFx[0].semantic_type-ne'map_propulsion_effect'){throw 'Synthetic code2003 map propulsion semantic promotion failed.'}

    # Zero-Drift scene contract: authoritative empty Drift table still anchors an independent code2003 propulsion table.
    $sceneSav=Join-Path $temp 'synthetic_scene_effect_no_drift.sav'
    $scene=New-Object byte[] 20000;$sceneDrift=12000
    Put-Marker $scene $sceneDrift;Put-U32 $scene $sceneDrift 0
    $sceneFx=$sceneDrift+4;Put-U32 $scene $sceneFx 2
    Put-U32 $scene ($sceneFx+4) 5000;$scene[$sceneFx+8]=1;Put-F32 $scene ($sceneFx+9) ([single]2003.0)
    Put-U32 $scene ($sceneFx+13) 7000;$scene[$sceneFx+17]=0;Put-F32 $scene ($sceneFx+18) ([single]2003.0)
    [IO.File]::WriteAllBytes($sceneSav,$scene)
    $sceneRows=@([pscustomobject]@{time_s=0.0;contact_state=5;input_bool_candidate_64=$false;input_bool_candidate_65=$false},[pscustomobject]@{time_s=10.0;contact_state=5;input_bool_candidate_64=$false;input_bool_candidate_65=$false})
    $sceneDc=@(Get-ReplayNativeDriftTimelineCandidates -ReplayPath $sceneSav)
    $sceneDr=Resolve-ReplayNativeDriftTimeline -Candidates $sceneDc -Rows $sceneRows
    if(-not[bool]$sceneDr.available-or-not[bool]$sceneDr.candidate.empty_table){throw 'Zero-Drift native action object was not retained as an authoritative empty table.'}
    $sceneResolved=Resolve-ReplayNativeSpeedEffectTimeline -ReplayPath $sceneSav -NativeDriftResolved $sceneDr -Rows $sceneRows
    $sceneSeg=Convert-ReplayNativeSpeedEffectsToSegments -Resolved $sceneResolved -Rows $sceneRows -NativeDriftResolved $sceneDr
    if(-not[bool]$sceneResolved.available-or[int]$sceneSeg.map_propulsion_effect_count-ne1-or[int]$sceneSeg.unknown_speed_effect_count-ne0){throw 'Zero-Drift code2003 map propulsion effect did not decode independently.'}

    $manifest=Get-Content -LiteralPath (Join-Path $AppDir 'app_manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if([int]$manifest.data_schemas.telemetry-ne19-or[int]$manifest.data_schemas.replay_native_speed_effect_timeline-ne2-or[int]$manifest.data_schemas.boost_effect_contract-ne3-or[int]$manifest.data_schemas.semantic_model_contract-ne4){throw ('Installed manifest does not expose telemetry19/native-speedfx2/boost3/semantic4. app='+[string]$manifest.app_version)}

    # Required historical real benchmarks.  Code2003 is now map propulsion, no longer unknown.
    $dataDir=Split-Path -Parent $AppDir;$archive=Join-Path $dataDir 'ReplayArchive';$tele=Join-Path $AppDir 'QQReplayTelemetry.ps1'
    $city203=Run-RealControl '十一城-车神2.03.sav' @{system_drift_segment_count=39;native_speed_effect_segment_count=86;nitro_segment_count=32;small_boost_segment_count=52;air_boost_segment_count=0;landing_boost_segment_count=0;other_small_boost_segment_count=2;map_propulsion_effect_segment_count=0;unknown_speed_effect_segment_count=0} $archive $tele $temp
    $city202=Run-RealControl '十一城-车神2.02.sav' @{system_drift_segment_count=39;native_speed_effect_segment_count=86;nitro_segment_count=32;small_boost_segment_count=53;air_boost_segment_count=0;landing_boost_segment_count=0;other_small_boost_segment_count=1;map_propulsion_effect_segment_count=0;unknown_speed_effect_segment_count=0} $archive $tele $temp
    $month=Run-RealControl '月牙湾-系统判定36次漂移.sav' @{system_drift_segment_count=36;native_speed_effect_segment_count=54;nitro_segment_count=0;small_boost_segment_count=0;air_boost_segment_count=0;landing_boost_segment_count=0;other_small_boost_segment_count=1;map_propulsion_effect_segment_count=53;unknown_speed_effect_segment_count=0} $archive $tele $temp
    $rose=Run-RealControl '玫瑰之恋.sav' @{system_drift_segment_count=22;native_speed_effect_segment_count=53;nitro_segment_count=11;small_boost_segment_count=16;air_boost_segment_count=13;landing_boost_segment_count=7;other_small_boost_segment_count=2;map_propulsion_effect_segment_count=4;unknown_speed_effect_segment_count=0} $archive $tele $temp
    $real=@($city203,$city202,$month,$rose)
    if(@($real|Where-Object{$_-ne'ok'}).Count-ne0){throw ('Required ReplayArchive benchmark missing: city203='+$city203+' city202='+$city202+' month='+$month+' rose='+$rose)}

    # Optional dedicated map-propulsion controls: validate them automatically once the user imports them into ReplayArchive.
    $scene1=Run-RealControl '恋恋千阳-特殊场景效果1.sav' @{system_drift_segment_count=0;native_speed_effect_segment_count=22;map_propulsion_effect_segment_count=19;unknown_speed_effect_segment_count=0} $archive $tele $temp
    $scene2=Run-RealControl '一路向黔-特殊场景效果2.sav' @{system_drift_segment_count=0;native_speed_effect_segment_count=14;map_propulsion_effect_segment_count=14;unknown_speed_effect_segment_count=0} $archive $tele $temp
    Write-Host ('[OK] Replay-Native Speed Effects v2 smoke passed. app='+[string]$manifest.app_version+' synthetic=native-effects/map-propulsion2003/zero-drift-scene real-benchmarks=4/4 scene-controls='+$scene1+'/'+$scene2+' production=native-when-validated unknown-codes=preserved')
    exit 0
}catch{
    Write-Host ('[FAILED] '+$_.Exception.Message)
    exit 2
}finally{
    try{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}catch{}
}
