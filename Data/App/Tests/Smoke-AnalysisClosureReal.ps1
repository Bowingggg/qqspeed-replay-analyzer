param()
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
$appDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dataDir=Split-Path -Parent $appDir
$root=Split-Path -Parent $dataDir
$outputDir=Join-Path $root 'Output'
. (Join-Path $appDir 'Modules\Native\NativeDrivingAnalysis.ps1')
. (Join-Path $appDir 'Modules\Native\NativeDrivingEpisodes.ps1')
. (Join-Path $appDir 'Modules\Native\NativeTrainingSections.ps1')
. (Join-Path $appDir 'Modules\Native\NativeTrainingTimeLoss.ps1')
. (Join-Path $appDir 'Modules\Native\NativeAnalysisSegments.ps1')
. (Join-Path $appDir 'Modules\Native\NativeSegmentComparison.ps1')
. (Join-Path $appDir 'Tests\September2026Corpus.ps1')
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}
function Approx([double]$A,[double]$B,[double]$Tol){return ([Math]::Abs($A-$B)-le$Tol)}
function Real-ReadJson([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)-or-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    try{return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json)}catch{return $null}
}
function Real-AirIntervals([string]$TelemetryPath,$Stream){
    if($null-eq$Stream-or[string]::IsNullOrWhiteSpace([string]$Stream.csv)){return @()}
    $csv=Join-Path (Split-Path -Parent $TelemetryPath) ([string]$Stream.csv)
    if(-not(Test-Path -LiteralPath $csv -PathType Leaf)){return @()}
    try{return @(NAS-ValidatedAirIntervalsFromRows -Rows @(Import-Csv -LiteralPath $csv -Encoding UTF8))}catch{return @()}
}
$sw=[System.Diagnostics.Stopwatch]::StartNew()

# =============================================================================================
# Smoke-AnalysisClosureReal - REAL-replay evidence for the Analysis Closure v1 contracts.
#
# It exercises the segmentation and comparison contracts on the actual corpus in this workspace:
#   * the published `segment_analysis` block is recomputed from the replay's own telemetry summary
#     and must match, so the artifact can never be a stale cache;
#   * every available recovery tail is owned by a post-Drift code2001 small-boost-class effect,
#     never by standard Nitro/code1, and never past the next independent Drift;
#   * the multi-shadow contract still holds (1 local + N network, and no native action ownership
#     leaks into a network shadow);
#   * a real same-map pair produces identical world intervals and exactly negated deltas.
#
# No file name, SHA or offset is special-cased anywhere below: the corpus is enumerated, the
# same-map pair is found by authoritative ResourceMapID, and every number is recomputed.
# =============================================================================================

$allowedReasons=@('native_small_boost_end','next_drift_hard_cut','airborne_hard_cut','no_native_recovery_effect')

# ---- 1. corpus census -----------------------------------------------------------------------
$corpus=@(Get-September2026Corpus -ProjectRoot $root)
Require ($corpus.Count-ge3) ('the real replay corpus is missing: only '+[string]$corpus.Count+' entries')
$analysed=New-Object System.Collections.Generic.List[object]
foreach($e in $corpus){
    $telPath=Join-Path $dataDir ('Telemetry\'+[string]$e.sha16+'\telemetry_summary.json')
    $tel=Real-ReadJson $telPath
    if($null-ne$tel){ $analysed.Add([pscustomobject]@{entry=$e;telemetry=$tel;telemetry_path=$telPath}) }
}
Require ($analysed.Count-ge3) ('only '+[string]$analysed.Count+' of '+[string]$corpus.Count+' corpus replays have a telemetry summary; the real segmentation evidence is missing')

# ---- 2. recompute the segmentation contract from every analysed replay ----------------------
$swSeg=[System.Diagnostics.Stopwatch]::StartNew()
$segChecked=0;$segTotal=0;$nitroOnlyExcluded=0
foreach($a in @($analysed.ToArray())){
    $tel=$a.telemetry
    foreach($s in @($tel.streams)){
        if($null-eq$s){continue}
        # The published logical native Drift actions, taken from the replay's own action authority.
        $groups=@()
        if($null-ne$s.production_actions-and$null-ne$s.production_actions.drift){ $groups=@($s.production_actions.drift.groups) }
        if($groups.Count-eq0){ continue }
        $laps=@($s.laps)
        $eps=New-Object System.Collections.Generic.List[object]
        $idx=0
        foreach($g in $groups){
            if($null-eq$g){continue}
            $idx++
            $st=[double]$g.start_ms/1000.0
            $lapNo=$null
            foreach($l in $laps){ if($null-ne$l-and$st-ge[double]$l.start_t-1e-6-and$st-le[double]$l.end_t+1e-6){ $lapNo=[int]$l.lap;break } }
            if($null-eq$lapNo-and$laps.Count-gt0){ $lapNo=[int]$laps[0].lap }
            $eps.Add([pscustomobject]@{id=('L'+[string]$lapNo+'-D'+[string]$idx);lap=$lapNo;logical_drift_index=$idx
                time=[pscustomobject]@{start_t=$st;end_t=([double]$g.end_ms/1000.0)}})
        }
        $airIntervals=@(Real-AirIntervals -TelemetryPath $a.telemetry_path -Stream $s)
        $recomputed=NAS-BuildContract -Episodes @($eps.ToArray()) -EffectIntervals @($s.native_speed_effect_segments) -AirborneIntervals $airIntervals -Laps $laps
        Require ([string]$recomputed.contract-eq'native_analysis_segments_v1') 'the recomputed segmentation contract name must be stable'
        Require ([int]$recomputed.segment_count-gt0) ('recomputation produced no segment for stream '+[string]$s.id)
        $segTotal+=[int]$recomputed.segment_count
        $lapSum=0
        foreach($l in @($recomputed.laps)){ $lapSum+=[int]$l.segment_count }
        Require ($lapSum-eq[int]$recomputed.segment_count) ('per-lap segment counts must sum to the stream total on '+[string]$s.id)
        for($k=0;$k-lt@($recomputed.segments).Count;$k++){
            $seg=@($recomputed.segments)[$k]
            Require ($allowedReasons-contains[string]$seg.recovery_stop_reason) ('unknown recovery reason '+[string]$seg.recovery_stop_reason+' on '+[string]$s.id)
            Require ([double]$seg.recovery_end_t-ge[double]$seg.drift_end_t-1e-6) ('a recovery end may never precede its Drift end on '+[string]$s.id)
            Require ([double]$seg.start_t-le[double]$seg.drift_end_t+1e-6) ('a segment may never end before it starts on '+[string]$s.id)
            Require ([int]$seg.drift_count-ge1) ('a segment must own at least one logical Drift on '+[string]$s.id)
            $ev=$seg.recovery.evidence
            $nitroCandidates=$(if($null-ne$ev){[int]$ev.nitro_candidate_count}else{0})
            $smallCandidates=$(if($null-ne$ev){[int]$ev.small_boost_candidate_count}else{0})
            if([bool]$seg.recovery_available){
                Require ($null-ne$seg.recovery.chosen) ('an available recovery tail must publish its chosen native effect on '+[string]$s.id)
                Require ([string]$seg.recovery.chosen.semantic_type-ne'nitro') ('Nitro/code1 must never own a recovery tail on '+[string]$s.id)
            }
            if($nitroCandidates-gt0-and$smallCandidates-eq0){
                $nitroOnlyExcluded++
                Require (-not[bool]$seg.recovery_available) ('a Nitro-only post-Drift interval must not create recovery on '+[string]$s.id)
                Require (Approx ([double]$seg.recovery_end_t) ([double]$seg.drift_end_t) 1e-6) ('a Nitro-only segment must end at native Drift end on '+[string]$s.id)
            }
            if($null-ne$seg.next_drift_start_t){
                Require ([double]$seg.recovery_end_t-le[double]$seg.next_drift_start_t+1e-6) ('a recovery end may never cross the next independent Drift start on '+[string]$s.id)
                Require ([double]$seg.next_drift_start_t-gt[double]$seg.start_t) ('the next Drift start must be after the current segment start on '+[string]$s.id)
            }
            if($null-ne$seg.airborne_hard_cut_t-and[bool]$seg.recovery_available){
                Require ([double]$seg.recovery_end_t-le[double]$seg.airborne_hard_cut_t+1e-6) ('an owned recovery may never cross sustained native airborne onset on '+[string]$s.id)
            }
            if($k-gt0){
                $prev=@($recomputed.segments)[$k-1]
                $gap=[double]$seg.start_t-[double]$prev.drift_end_t
                Require ($gap-ge[double]$recomputed.drift_merge_gap_s-1e-6) ('two consecutive segments may not be closer than the merge gap (got '+[string]$gap+' s on '+[string]$s.id+')')
            }
        }
        $again=NAS-BuildContract -Episodes @($eps.ToArray()) -EffectIntervals @($s.native_speed_effect_segments) -AirborneIntervals $airIntervals -Laps $laps
        Require ((@($again.segments)|ConvertTo-Json -Depth 12 -Compress)-eq(@($recomputed.segments)|ConvertTo-Json -Depth 12 -Compress)) ('the segmentation contract must be deterministic on '+[string]$s.id)
        $segChecked++
    }
}
Require ($segChecked-gt0) 'no stream in the analysed corpus produced a segmentation contract'
Require ($segTotal-gt0) 'the real corpus produced no segment at all'
$swSeg.Stop()

# ---- 3. the published artifact must equal the recomputation ---------------------------------
$publishedChecked=0
foreach($f in @(Get-ChildItem -LiteralPath $outputDir -Filter '*_analysis.json' -File -ErrorAction SilentlyContinue)){
    $j=Real-ReadJson $f.FullName
    if($null-eq$j-or$null-eq$j.segment_analysis-or[int]$j.schema_version-ne29){ continue }
    $sha=([string]$j.replay_sha256).Trim().ToUpperInvariant()
    if($sha.Length-lt16){ continue }
    $telPath=Join-Path $dataDir ('Telemetry\'+$sha.Substring(0,16)+'\telemetry_summary.json')
    $tel=Real-ReadJson $telPath
    if($null-eq$tel){ continue }
    foreach($es in @($j.segment_analysis.streams)){
        if($null-eq$es-or[string]$es.status-ne'ready'){ continue }
        $s=$null
        foreach($x in @($tel.streams)){ if([string]$x.id-eq[string]$es.id){ $s=$x;break } }
        if($null-eq$s){ continue }
        $groups=@()
        if($null-ne$s.production_actions-and$null-ne$s.production_actions.drift){ $groups=@($s.production_actions.drift.groups) }
        $laps=@($s.laps)
        $eps=New-Object System.Collections.Generic.List[object]
        $idx=0
        foreach($g in $groups){
            if($null-eq$g){continue}
            $idx++
            $st=[double]$g.start_ms/1000.0
            $lapNo=$null
            foreach($l in $laps){ if($null-ne$l-and$st-ge[double]$l.start_t-1e-6-and$st-le[double]$l.end_t+1e-6){ $lapNo=[int]$l.lap;break } }
            $eps.Add([pscustomobject]@{id=('L'+[string]$lapNo+'-D'+[string]$idx);lap=$lapNo;logical_drift_index=$idx
                time=[pscustomobject]@{start_t=$st;end_t=([double]$g.end_ms/1000.0)}})
        }
        $airIntervals=@(Real-AirIntervals -TelemetryPath $telPath -Stream $s)
        $recomputed=NAS-BuildContract -Episodes @($eps.ToArray()) -EffectIntervals @($s.native_speed_effect_segments) -AirborneIntervals $airIntervals -Laps $laps
        Require ([int]$es.segment_count-eq[int]$recomputed.segment_count) ('the published segment count must equal a fresh recomputation for stream '+[string]$es.id)
        Require (@($es.segments).Count-eq@($recomputed.segments).Count) ('the published segment list must equal a fresh recomputation for stream '+[string]$es.id)
        for($k=0;$k-lt@($es.segments).Count;$k++){
            $p=@($es.segments)[$k];$r=@($recomputed.segments)[$k]
            Require (Approx ([double]$p.start_t) ([double]$r.start_t) 1e-6) 'the published segment start must equal the recomputation'
            Require (Approx ([double]$p.drift_end_t) ([double]$r.drift_end_t) 1e-6) 'the published Drift end must equal the recomputation'
            Require (Approx ([double]$p.recovery_end_t) ([double]$r.recovery_end_t) 1e-6) 'the published recovery end must equal the recomputation'
            Require ([string]$p.recovery_stop_reason-eq[string]$r.recovery_stop_reason) 'the published recovery reason must equal the recomputation'
        }
        $publishedChecked++
    }
}
Require ($publishedChecked-gt0) 'no current segment_analysis block could be verified against a recomputation (analysis schema 29 artifact missing; rebuild derived analysis)'

# ---- 4. multi-shadow non-regression --------------------------------------------------------
$multiChecked=0
foreach($a in @($analysed.ToArray())){
    $tel=$a.telemetry
    $physical=[int]$tel.physical_stream_count
    $logical=[int]$tel.logical_stream_count
    $streams=@($tel.streams)
    Require ($physical-ge1) ('physical stream count must be positive for '+[string]$a.entry.sha16)
    Require ($logical-eq$streams.Count) ('logical_stream_count must equal the number of published streams for '+[string]$a.entry.sha16)
    Require ($logical-ge1-and$logical-le$physical) ('logical streams must be between 1 and the physical count for '+[string]$a.entry.sha16)
    $local=@($streams|Where-Object{[string]$_.role-eq'local_high_frequency'})
    Require ($local.Count-eq1) ('exactly one local_high_frequency stream is required for '+[string]$a.entry.sha16)
    Require ([string]$local[0].native_action_event_ownership-eq'local_authoritative_shadow') 'the local shadow must own the replay-native action event table'
    $net=@($streams|Where-Object{[string]$_.role-eq'network_low_frequency'})
    foreach($n in $net){
        Require ([string]$n.native_action_event_ownership-eq'unavailable_non_local_shadow') ('a network shadow must never own native actions ('+[string]$a.entry.sha16+')')
        Require ($null-eq$n.native_action_event_count) 'a network shadow must publish a null native action count'
        Require (@($n.native_action_event_histogram.PSObject.Properties).Count-eq0) 'a network shadow must publish an empty native action histogram'
        Require (@($n.native_action_event_timeline).Count-eq0) 'a network shadow must publish an empty native action timeline'
        Require (-not[bool]$n.production_actions.game_facing_available) 'a network shadow must not publish a game-facing action list'
    }
    if($net.Count-gt0){ $multiChecked++ }
}
Require ($multiChecked-gt0) 'the corpus contains no multi-shadow replay to verify (1 local + N network)'
foreach($a in @($analysed.ToArray()|Where-Object{@($_.telemetry.streams|Where-Object{[string]$_.role-eq'network_low_frequency'}).Count-gt0})){
    Require ([int]$a.telemetry.logical_stream_count-gt1) 'a multi-shadow replay must publish more than one logical shadow'
}

# ---- 5. real same-map A/B ------------------------------------------------------------------
$candidates=New-Object System.Collections.Generic.List[object]
foreach($f in @(Get-ChildItem -LiteralPath $outputDir -Filter '*_analysis.json' -File -ErrorAction SilentlyContinue)){
    $j=Real-ReadJson $f.FullName
    if($null-eq$j-or$null-eq$j.segment_analysis-or[int]$j.schema_version-ne29){ continue }
    if($null-eq$j.resource_map_id){ continue }
    $candidates.Add([pscustomobject]@{file=$f.FullName;name=$f.Name;json=$j})
}
$pair=$null
for($i=0;$i-lt$candidates.Count-and$null-eq$pair;$i++){
    for($k=$i+1;$k-lt$candidates.Count;$k++){
        if([int]$candidates[$i].json.resource_map_id-eq[int]$candidates[$k].json.resource_map_id){ $pair=@($candidates[$i],$candidates[$k]); break }
    }
}
Require ($null-ne$pair) 'the same-map A/B real corpus is missing: no two published analyses share an authoritative ResourceMapID'
function New-RealSide($Candidate,[int]$LapNo){
    $j=$Candidate.json
    $telPath=Join-Path $root ([string]$j.telemetry_summary)
    $tel=Real-ReadJson $telPath
    if($null-eq$tel){ throw ('telemetry missing for '+$Candidate.name) }
    $s=@($tel.streams|Where-Object{[string]$_.role-eq'local_high_frequency'})
    $st=$(if($s.Count-gt0){$s[0]}else{@($tel.streams)[0]})
    $csv=Join-Path (Split-Path -Parent $telPath) ([string]$st.csv)
    Require (Test-Path -LiteralPath $csv -PathType Leaf) ('telemetry rows missing for '+$Candidate.name)
    $rows=@(NDA-LoadRows $csv)
    Require ($rows.Count-gt2) ('telemetry rows unusable for '+$Candidate.name)
    $segments=@()
    foreach($es in @($j.segment_analysis.streams)){
        if([string]$es.id-eq[string]$st.id){ foreach($l in @($es.laps)){ if([int]$l.lap-eq$LapNo){ $segments=@($l.segments) } } }
    }
    $lap=@($st.laps|Where-Object{[int]$_.lap-eq$LapNo})
    Require ($lap.Count-eq1) ('lap '+[string]$LapNo+' is missing in '+$Candidate.name)
    $ls=NTA-RowIndexAtTime $rows 0 ($rows.Count-1) ([double]$lap[0].start_t)
    $le=NTA-RowIndexAtTime $rows 0 ($rows.Count-1) ([double]$lap[0].end_t)
    $mapName=[string]$j.map_name
    return [pscustomobject][ordered]@{
        key=(([string]$j.replay_sha256).Trim().ToUpperInvariant()+':local:'+[string]$LapNo)
        label=$Candidate.name
        resource_map_id=$j.resource_map_id;game_map_id=$j.game_map_id;map_name=$mapName
        map_name_key=($mapName.ToLowerInvariant()-replace '\s','')
        segments=$segments;rows=$rows;lap_start_i=$ls;lap_end_i=$le
    }
}
$jA=$pair[0].json;$jB=$pair[1].json
$telA=Real-ReadJson (Join-Path $root ([string]$jA.telemetry_summary))
$telB=Real-ReadJson (Join-Path $root ([string]$jB.telemetry_summary))
$lapsA=@();foreach($s in @($telA.streams)){foreach($l in @($s.laps)){ if($lapsA-notcontains[int]$l.lap){$lapsA+=[int]$l.lap} }}
$lapsB=@();foreach($s in @($telB.streams)){foreach($l in @($s.laps)){ if($lapsB-notcontains[int]$l.lap){$lapsB+=[int]$l.lap} }}
$commonLap=@($lapsA|Where-Object{$lapsB-contains$_}|Sort-Object)
Require ($commonLap.Count-ge1) 'the same-map pair shares no lap number'
$lapNo=[int]$commonLap[0]
$sideA=New-RealSide $pair[0] $lapNo
$sideB=New-RealSide $pair[1] $lapNo
Require (@($sideA.segments).Count-gt0-and@($sideB.segments).Count-gt0) 'the real same-map pair published no segment for the shared lap'
$swAb=[System.Diagnostics.Stopwatch]::StartNew()
$ab=NSC-BuildComparison -SubjectA $sideA -SubjectB $sideB -LabelA 'A' -LabelB 'B'
Require ([string]$ab.gate.status-eq'comparable_same_resource_map') 'the real pair must pass the authoritative same-map gate'
Require ([string]$ab.status-eq'ready') ('the real A/B must be ready, got '+[string]$ab.status+' / '+[string]$ab.reason)
Require ([int]$ab.window_count-gt0) 'the real A/B must publish at least one window'
Require ([int]$ab.matched_window_count-gt0) 'the real A/B must publish at least one comparable window'
Require (-not[bool]$ab.correspondence.time_in_cost) 'time must never enter the real correspondence cost'
Require ([double]$ab.coverage.combined-gt0.0) 'the real correspondence must cover part of the route'
$ba=NSC-BuildComparison -SubjectA $sideB -SubjectB $sideA -LabelA 'B' -LabelB 'A'
Require ([int]$ba.window_count-eq[int]$ab.window_count) 'swapping the real pair must not change the window count'
$negated=0
for($k=0;$k-lt[int]$ab.window_count;$k++){
    $wf=@($ab.windows)[$k];$wr=@($ba.windows)[$k]
    Require (Approx ([double]$wf.space.shared_start) ([double]$wr.space.shared_start) 1e-9) 'A->B and B->A must share the world interval start'
    Require (Approx ([double]$wf.space.shared_end) ([double]$wr.space.shared_end) 1e-9) 'A->B and B->A must share the world interval end'
    if($null-ne$wf.time.delta_s-and$null-ne$wr.time.delta_s){
        Require (Approx ([double]$wf.time.delta_s) (-1.0*[double]$wr.time.delta_s) 1e-9) 'the real time delta must negate exactly under swap'
        $negated++
    }
    foreach($m in @($wf.metrics)){
        Require (-not[string]::IsNullOrWhiteSpace([string]$m.definition)) 'every real metric must publish a definition'
        Require (-not[string]::IsNullOrWhiteSpace([string]$m.authority)) 'every real metric must publish an authority'
    }
    if($null-ne$wf.space.subject.distance_m){ Require ([double]$wf.space.subject.distance_m-ge0.0) 'a real subject distance can never be negative' }
    if($null-ne$wf.native.subject.drift_distance_m){ Require ([double]$wf.native.subject.drift_distance_m-ge0.0) 'a real drift distance can never be negative' }
    # Merged-Drift distance invariant: a segment is drift + inter-drift gap + recovery, and the
    # published drift distance is the native Drift-ACTIVE distance only.
    $nSub=$wf.native.subject
    if($null-ne$nSub.total_distance_m-and$null-ne$nSub.drift_distance_m-and$null-ne$nSub.recovery_distance_m){
        $gap=$(if($null-eq$nSub.inter_drift_gap_distance_m){0.0}else{[double]$nSub.inter_drift_gap_distance_m})
        Require ([double]$gap-ge0.0) 'the inter-drift gap distance can never be negative'
        Require (Approx ([double]$nSub.total_distance_m) ([double]$nSub.drift_distance_m+$gap+[double]$nSub.recovery_distance_m) 0.05) ('total must equal drift + inter-drift gap + recovery on window '+[string]$wf.window_id)
        if([int]$nSub.drift_count -eq 1){ Require (Approx $gap 0.0 1e-6) 'a single-Drift segment has no inter-drift gap distance' }
    }
}
Require ($negated-gt0) 'at least one real window must publish a time delta to prove the swap contract'
$ab2=NSC-BuildComparison -SubjectA $sideA -SubjectB $sideB -LabelA 'A' -LabelB 'B'
Require ((@($ab.windows)|ConvertTo-Json -Depth 16 -Compress)-eq(@($ab2.windows)|ConvertTo-Json -Depth 16 -Compress)) 'the real comparison must be deterministic'

# ---- 6. the real API entry point (the same handler the HTTP route calls) ----------------------
# Covers the wiring the endpoint adds on top of the contract: analysis file -> telemetry summary ->
# stream selection -> row loading -> segment contract -> comparison, plus the refusal when no real
# counterpart exists.
$labelsPath=Join-Path $dataDir 'replay_labels.json'
$manualMapNamesPath=Join-Path $dataDir 'manual_map_names.json'
$replayArchiveRoot=Join-Path $dataDir 'ReplayArchive'
$frontendDiagDir=Join-Path $dataDir 'Diagnostics\Frontend'
. (Join-Path $appDir 'Modules\Frontend\Frontend.Backend.ps1')
function Real-B64([string]$Text){ return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
$apiReq=[pscustomobject]@{
    subject_file_b64=(Real-B64 $pair[0].name);subject_lap=[string]$lapNo
    compare_file_b64=(Real-B64 $pair[1].name);compare_lap=[string]$lapNo
    compare_stream='';mode='auto'
}
$apiRes=Invoke-SegmentComparisonLocal $apiReq
Require ([bool]$apiRes.ok) ('the comparison endpoint must succeed on a real pair, error='+[string]$apiRes.error)
Require ([string]$apiRes.comparison.contract-eq'native_segment_comparison_v1') 'the endpoint must return the published comparison contract'
Require ([string]$apiRes.comparison.status-eq'ready') 'the endpoint comparison must be ready on a real same-map pair'
Require ([int]$apiRes.comparison.window_count-eq[int]$ab.window_count) 'the endpoint must produce the same window set as the direct contract call'
for($k=0;$k-lt[int]$ab.window_count;$k++){
    $wd=@($ab.windows)[$k];$wa=@($apiRes.comparison.windows)[$k]
    Require (Approx ([double]$wd.space.shared_start) ([double]$wa.space.shared_start) 1e-9) 'the endpoint must use the same world intervals'
    Require (Approx ([double]$wd.space.shared_end) ([double]$wa.space.shared_end) 1e-9) 'the endpoint must use the same world intervals'
}
$apiSwap=Invoke-SegmentComparisonLocal ([pscustomobject]@{
    subject_file_b64=(Real-B64 $pair[1].name);subject_lap=[string]$lapNo
    compare_file_b64=(Real-B64 $pair[0].name);compare_lap=[string]$lapNo
    compare_stream='';mode='auto'})
Require ([bool]$apiSwap.ok) 'the swapped endpoint request must succeed'
for($k=0;$k-lt[int]$ab.window_count;$k++){
    $wf=@($apiRes.comparison.windows)[$k];$wr=@($apiSwap.comparison.windows)[$k]
    Require (Approx ([double]$wf.space.shared_start) ([double]$wr.space.shared_start) 1e-9) 'the endpoint must keep the world interval under swap'
    if($null-ne$wf.time.delta_s-and$null-ne$wr.time.delta_s){
        Require (Approx ([double]$wf.time.delta_s) (-1.0*[double]$wr.time.delta_s) 1e-9) 'the endpoint must negate the delta under swap'
    }
}
$apiNoTarget=Invoke-SegmentComparisonLocal ([pscustomobject]@{subject_file_b64=(Real-B64 $pair[0].name);subject_lap=[string]$lapNo;compare_file_b64='';compare_stream='';compare_lap='';mode='auto'})
Require (-not[bool]$apiNoTarget.ok) 'the endpoint must refuse a comparison with no real counterpart'
$apiBadStream=Invoke-SegmentComparisonLocal ([pscustomobject]@{subject_file_b64=(Real-B64 $pair[0].name);subject_lap=[string]$lapNo;compare_file_b64='';compare_stream='shadow_network_99';compare_lap=[string]$lapNo;mode='auto'})
Require (-not[bool]$apiBadStream.ok) 'the endpoint must fail closed on an unknown stream selector'

$swAb.Stop()
Write-Host ('[OK] Analysis Closure real regression passed. corpus='+[string]$corpus.Count+' analysed='+[string]$analysed.Count+' streams_segmented='+[string]$segChecked+' segments='+[string]$segTotal+' nitro_only_excluded='+[string]$nitroOnlyExcluded+' published_verified='+[string]$publishedChecked+' multi_shadow='+[string]$multiChecked+' ab_lap='+[string]$lapNo+' ab_windows='+[string]$ab.window_count+' ab_matched='+[string]$ab.matched_window_count+' ab_negated='+[string]$negated+' ab_coverage='+[string]$ab.coverage.combined+' seg_ms='+[string][Math]::Round($swSeg.Elapsed.TotalMilliseconds,0)+' ab_ms='+[string][Math]::Round($swAb.Elapsed.TotalMilliseconds,0)+' measured_ms='+[string][Math]::Round(($swSeg.Elapsed.TotalMilliseconds+$swAb.Elapsed.TotalMilliseconds),0))
exit 0
