param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_NativeDrift_'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
function Put-U32([byte[]]$D,[int]$O,[uint32]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}
try {
    . (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeDriftTimeline.ps1')
    # --- Drift interval-boundary contract regression -----------------------------------------
    # Current 2026-09 replays write one interval's two boundary timestamps in either order
    # (measured: exactly one inverted pair on 3 of the 15 September corpus replays, none on the
    # other 12). The contract is the interval sequence - each consecutive record pair is one
    # interval, boundaries normalised to (min,max), interval starts never move backwards - not the
    # raw record order. An inverted pair must be accepted; a backward interval start must fail
    # closed.
    function New-Toggle([object[]]$Pairs,[int]$InvertPairIndex=-1){
        $n=$Pairs.Count*2
        $b=New-Object byte[] (4+5*$n)
        Put-U32 $b 0 ([uint32]$n)
        for($i=0;$i -lt $Pairs.Count;$i++){
            $a=[int]$Pairs[$i][0];$z=[int]$Pairs[$i][1]
            if($i -eq $InvertPairIndex){ $tmp=$a;$a=$z;$z=$tmp }
            Put-U32 $b (4+5*(2*$i)) ([uint32]$a);   $b[4+5*(2*$i)+4]=1
            Put-U32 $b (4+5*(2*$i+1)) ([uint32]$z); $b[4+5*(2*$i+1)+4]=0
        }
        return $b
    }
    $okPairs=@(@(1000,1500),@(2000,2600),@(3000,3700))
    $okBytes=New-Toggle -Pairs $okPairs
    $t1=RNDT-TryParseToggleTable -Data $okBytes -CountOffset 0
    if(-not[bool]$t1.valid){throw 'Drift contract: an ordered toggle table was rejected.'}
    if([int]$t1.inverted_pair_count -ne 0){throw 'Drift contract: an ordered table reported an inverted pair.'}
    if(@($t1.intervals).Count -ne 3 -or [long]$t1.intervals[1].start_ms -ne 2000 -or [long]$t1.intervals[1].end_ms -ne 2600){throw 'Drift contract: ordered interval values changed.'}
    $invBytes=New-Toggle -Pairs $okPairs -InvertPairIndex 1
    $t2=RNDT-TryParseToggleTable -Data $invBytes -CountOffset 0
    if(-not[bool]$t2.valid){throw 'Drift contract: a table with one inverted boundary pair was rejected (2026-09 regression).'}
    if([int]$t2.inverted_pair_count -ne 1){throw 'Drift contract: the inverted boundary pair was not reported as raw evidence.'}
    if([long]$t2.intervals[1].start_ms -ne 2000 -or [long]$t2.intervals[1].end_ms -ne 2600){throw 'Drift contract: an inverted pair was not normalised to (min,max).'}
    $cand=RNDT-NewCandidate -Data $invBytes -CountOffset 0 -Parsed $t2 -MarkerValid $false
    if([int]$cand.inverted_pair_count -ne 1){throw 'Drift contract: the candidate must publish the inverted-pair count.'}
    if([long]$cand.start_time_ms -ne 1000 -or [long]$cand.end_time_ms -ne 3700){throw 'Drift contract: candidate start/end time must come from the interval sequence.'}
    $badBytes=New-Toggle -Pairs @(@(1000,1500),@(900,1200),@(3000,3700))
    $t3=RNDT-TryParseToggleTable -Data $badBytes -CountOffset 0
    if([bool]$t3.valid){throw 'Drift contract: a backward interval START must fail closed.'}
    $badState=New-Toggle -Pairs $okPairs
    $badState[4+5+4]=1
    $t4=RNDT-TryParseToggleTable -Data $badState -CountOffset 0
    if([bool]$t4.valid){throw 'Drift contract: a non-alternating state byte must fail closed.'}
    $sav=Join-Path $temp 'synthetic_native_drift.sav'
    $bytes=New-Object byte[] 8192
    # Regression guard: arbitrary suffix bytes may form UInt32 values above Int32.MaxValue.
    # Scanner must reject them as impossible counts without throwing during the prefilter.
    Put-U32 $bytes 2400 ([uint32]3892314112)
    # True table: marker + count + 3 native active intervals.
    $countOffset=3000
    [Array]::Copy([byte[]](0x7E,0xA0,0x1E,0xC2),0,$bytes,$countOffset-4,4)
    Put-U32 $bytes $countOffset 6
    $pairs=@(@(1000,1),@(2200,0),@(3000,1),@(4200,0),@(5000,1),@(6200,0))
    for($i=0;$i-lt$pairs.Count;$i++){Put-U32 $bytes ($countOffset+4+5*$i) ([uint32]$pairs[$i][0]);$bytes[$countOffset+8+5*$i]=[byte]$pairs[$i][1]}
    # Decoy nested-style table with fewer matching starts: it may validate structurally but must lose ranking.
    $decoy=5000;Put-U32 $bytes $decoy 4
    $dp=@(@(1000,1),@(1800,0),@(3000,1),@(3600,0))
    for($i=0;$i-lt$dp.Count;$i++){Put-U32 $bytes ($decoy+4+5*$i) ([uint32]$dp[$i][0]);$bytes[$decoy+8+5*$i]=[byte]$dp[$i][1]}
    [IO.File]::WriteAllBytes($sav,$bytes)

    $rows=New-Object System.Collections.Generic.List[object]
    for($i=0;$i-le70;$i++){
        $t=$i/10.0;$shift=$false
        if($i-eq10-or$i-eq15-or$i-eq30-or$i-eq50){$shift=$true}
        $slip=$(if(($t-ge1-and$t-lt2.2)-or($t-ge3-and$t-lt4.2)-or($t-ge5-and$t-lt6.2)){0.55}else{0.02})
        $rows.Add([pscustomobject]@{time_s=$t;distance=($t*20.0);speed=20.0;slip=$slip;input_bool_candidate_64=$shift;system_drift_state='unknown';system_drift_state_source='unresolved_not_found'})
    }
    $c=@(Get-ReplayNativeDriftTimelineCandidates -ReplayPath $sav)
    $r=Resolve-ReplayNativeDriftTimeline -Candidates $c -Rows ($rows.ToArray())
    if(-not[bool]$r.available){throw ('Synthetic native timeline was not validated: '+[string]$r.status)}
    if([long]$r.candidate.count_offset-ne$countOffset-or[int]$r.candidate.interval_count-ne3){throw ('Wrong synthetic table selected: offset='+$r.candidate.count_offset+' intervals='+$r.candidate.interval_count)}
    if([int]$r.start_match_count-ne3-or[Math]::Abs([double]$r.start_match_fraction-1.0)-gt0.0001){throw ('Synthetic start matching regressed: '+$r.start_match_count+'/'+$r.candidate.interval_count)}
    if([int]$r.internal_shift_retriggers-ne1){throw ('Synthetic internal retrigger was not absorbed: '+$r.internal_shift_retriggers)}
    $segs=@(Convert-ReplayNativeDriftTimelineToSegments -Resolved $r -Rows ($rows.ToArray()) -TotalDistance 140.0 -Laps @())
    if($segs.Count-ne3){throw ('Synthetic native segments !=3: '+$segs.Count)}
    if(-not[bool]$rows[12].system_drift_state-or[bool]$rows[25].system_drift_state){throw 'Synthetic row-level native drift state labeling regressed.'}

    # Older native action-object layout: no 7EA01EC2 marker, but Drift table is directly paired
    # with a structurally valid adjacent native effect table. Shift is intentionally absent.
    $legacySav=Join-Path $temp 'synthetic_unmarked_native_action_pair.sav'
    $legacy=New-Object byte[] 8192;$lo=3000
    Put-U32 $legacy $lo 6
    for($i=0;$i-lt$pairs.Count;$i++){Put-U32 $legacy ($lo+4+5*$i) ([uint32]$pairs[$i][0]);$legacy[$lo+8+5*$i]=[byte]$pairs[$i][1]}
    $le=$lo+4+5*$pairs.Count;Put-U32 $legacy $le 2
    Put-U32 $legacy ($le+4) 6500;$legacy[$le+8]=1;[Array]::Copy([BitConverter]::GetBytes([single]1.0),0,$legacy,$le+9,4)
    Put-U32 $legacy ($le+13) 7600;$legacy[$le+17]=0;[Array]::Copy([BitConverter]::GetBytes([single]1.0),0,$legacy,$le+18,4)
    [IO.File]::WriteAllBytes($legacySav,$legacy)
    $noShift=New-Object System.Collections.Generic.List[object]
    foreach($rr in $rows){$noShift.Add([pscustomobject]@{time_s=$rr.time_s;distance=$rr.distance;speed=$rr.speed;slip=$rr.slip;input_bool_candidate_64=$false;system_drift_state='unknown';system_drift_state_source='unresolved_not_found'})}
    $lc=@(Get-ReplayNativeDriftTimelineCandidates -ReplayPath $legacySav)
    $lr=Resolve-ReplayNativeDriftTimeline -Candidates $lc -Rows ($noShift.ToArray())
    if(-not[bool]$lr.available-or[long]$lr.candidate.count_offset-ne$lo-or[bool]$lr.candidate.native_object_marker_valid){throw 'Unmarked native Drift+effect pair was not resolved as the older action-object layout.'}
    if(-not[bool]$lr.candidate.adjacent_effect_table_valid-or[string]$lr.validation_basis-ne'structural_drift_plus_adjacent_native_effect_pair'){throw ('Unmarked action-pair authority mismatch: '+[string]$lr.validation_basis)}
    if([int]$lr.shift_rise_count-ne0){throw 'Unmarked native action-pair fixture unexpectedly contains Shift rises.'}

    # Empty native Drift table is authoritative zero, not unavailable.  When multiple native
    # action objects are empty, the one structurally paired with the non-empty adjacent effect table wins.
    $emptySav=Join-Path $temp 'synthetic_empty_native_drift.sav'
    $empty=New-Object byte[] 8192;$eo=3000;$eo2=5000
    [Array]::Copy([byte[]](0x7E,0xA0,0x1E,0xC2),0,$empty,$eo-4,4);Put-U32 $empty $eo 0
    # Adjacent effect table: code2003 start/end => 2 records.
    Put-U32 $empty ($eo+4) 2;Put-U32 $empty ($eo+8) 1000;$empty[$eo+12]=1;[Array]::Copy([BitConverter]::GetBytes([single]2003.0),0,$empty,$eo+13,4)
    Put-U32 $empty ($eo+17) 2500;$empty[$eo+21]=0;[Array]::Copy([BitConverter]::GetBytes([single]2003.0),0,$empty,$eo+22,4)
    [Array]::Copy([byte[]](0x7E,0xA0,0x1E,0xC2),0,$empty,$eo2-4,4);Put-U32 $empty $eo2 0;Put-U32 $empty ($eo2+4) 0
    [IO.File]::WriteAllBytes($emptySav,$empty)
    $ec=@(Get-ReplayNativeDriftTimelineCandidates -ReplayPath $emptySav)
    $er=Resolve-ReplayNativeDriftTimeline -Candidates $ec -Rows ($rows.ToArray())
    if(-not[bool]$er.available-or-not[bool]$er.candidate.empty_table-or[int]$er.candidate.interval_count-ne0){throw 'Authoritative empty native Drift table was not preserved.'}
    if([long]$er.candidate.count_offset-ne$eo-or-not[bool]$er.candidate.adjacent_effect_table_valid-or[int]$er.candidate.adjacent_effect_record_count-ne2){throw 'Duplicate empty action-object ranking did not bind the paired native effect table.'}


    # Real integration regression when the labeled replay is present in the user's ReplayArchive.
    $dataDir=Split-Path -Parent $AppDir;$archive=Join-Path $dataDir 'ReplayArchive'
    $bench=$null
    if(Test-Path -LiteralPath $archive -PathType Container){$bench=@(Get-ChildItem -LiteralPath $archive -Recurse -File -Filter '月牙湾-系统判定36次漂移.sav' -ErrorAction SilentlyContinue|Select-Object -First 1)}
    $realStatus='not-present'
    if($null-ne$bench-and$bench.Count-gt0){
        $realOut=Join-Path $temp 'real_month_benchmark';$tele=Join-Path $AppDir 'QQReplayTelemetry.ps1'
        $realSha=(Get-FileHash -LiteralPath $bench[0].FullName -Algorithm SHA256).Hash.ToUpperInvariant();$realShort=$realSha.Substring(0,16);$realPhysical=Join-Path $dataDir ('PhysicalTelemetryCache\'+$realShort)
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tele -ReplayPath $bench[0].FullName -OutDir $realOut -ReplaySha256 $realSha -PhysicalCacheDir $realPhysical -Force
        if($LASTEXITCODE-ne0){throw ('Real benchmark telemetry exited '+$LASTEXITCODE)}
        $sum=Get-Content -LiteralPath (Join-Path $realOut 'telemetry_summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
        if([int]$sum.schema_version-ne19-or[int]$sum.drift_schema_version-ne5-or[int]$sum.lap_schema_version-ne2-or[int]$sum.replay_native_drift_timeline_schema_version-ne4){throw ('Real benchmark schema mismatch: telemetry='+$sum.schema_version+' drift='+$sum.drift_schema_version+' drift_timeline='+$sum.replay_native_drift_timeline_schema_version)}
        $st=@($sum.streams|Where-Object{[bool]$_.system_drift_state_available}|Sort-Object {[int]$_.system_drift_segment_count} -Descending|Select-Object -First 1)
        if($st.Count-eq0){throw 'Real benchmark did not expose a validated replay-native drift timeline.'}
        if([int]$st[0].system_drift_segment_count-ne36){throw ('Real benchmark expected 36 native drift intervals, got '+$st[0].system_drift_segment_count)}
        if([double]$st[0].native_drift_timeline_validation.start_match_fraction-lt0.97){throw ('Real benchmark start-match fraction too low: '+$st[0].native_drift_timeline_validation.start_match_fraction)}
        if([string]$st[0].system_drift_state_source-ne'replay_native_action_object_drift_table_v3'){throw 'Real benchmark native SystemDrift source mismatch.'}
        if(@($st[0].PSObject.Properties.Name)-contains'drift_segments'){throw 'v3 telemetry must not re-emit the retired drift_segments compatibility alias.'}
        $realStatus='36/36'
    }
    $manifest=Get-Content -LiteralPath (Join-Path $AppDir 'app_manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if([int]$manifest.data_schemas.telemetry-ne19-or[int]$manifest.data_schemas.drift_state_contract-ne5-or[int]$manifest.data_schemas.lap-ne2-or[int]$manifest.data_schemas.replay_native_drift_timeline-ne4){throw ('Installed manifest no longer exposes the replay-native drift contract: app='+[string]$manifest.app_version)}
    Write-Host ('[OK] Replay-Native Drift Timeline v3 smoke passed. app='+[string]$manifest.app_version+' synthetic=3/3 retrigger=absorbed real-month='+$realStatus+' production=marker-or-adjacent-native-pair-authority unmarked-legacy=validated empty-table=authoritative-zero shift=diagnostic-only fallback=none')
    exit 0
}catch{
    Write-Host ('[FAILED] '+$_.Exception.Message)
    exit 2
}finally{
    try{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}catch{}
}
