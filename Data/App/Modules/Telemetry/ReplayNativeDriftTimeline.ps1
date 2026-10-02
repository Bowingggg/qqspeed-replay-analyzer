# Replay-native drift timeline decoder.
# Definition-only module: no runtime actions at import scope.

function RNDT-ReadU32([byte[]]$Data,[int]$Offset){
    return [BitConverter]::ToUInt32($Data,$Offset)
}
function RNDT-Hex4([byte[]]$Data,[int]$Offset){
    if($Offset-lt0-or($Offset+4)-gt$Data.Length){return $null}
    return (($Data[$Offset..($Offset+3)]|ForEach-Object{$_.ToString('X2')}) -join '')
}
function RNDT-ProbeAdjacentEffectTable([byte[]]$Data,[long]$CountOffset){
    if($CountOffset-lt0-or($CountOffset+4)-gt$Data.Length){return [pscustomobject]@{valid=$false;record_count=0;interval_count=0;end_exclusive=$CountOffset}}
    [uint32]$countU32=[BitConverter]::ToUInt32($Data,[int]$CountOffset)
    if($countU32-gt5000){return [pscustomobject]@{valid=$false;record_count=[uint64]$countU32;interval_count=0;end_exclusive=$CountOffset}}
    $count=[int]$countU32;[long]$end=$CountOffset+4L+9L*$count
    if($end-gt$Data.Length){return [pscustomobject]@{valid=$false;record_count=$count;interval_count=0;end_exclusive=$end}}
    $open=@{};$prev=-1L;$intervals=0
    for($i=0;$i-lt$count;$i++){
        $q=[int]($CountOffset+4L+9L*$i);$tm=[long][BitConverter]::ToUInt32($Data,$q);$state=[int]$Data[$q+4]
        $bits=[BitConverter]::ToInt32($Data,$q+5);$code=[double][BitConverter]::ToSingle($Data,$q+5)
        if(($state-ne0-and$state-ne1)-or$tm-lt$prev-or$tm-gt600000-or[double]::IsNaN($code)-or[double]::IsInfinity($code)-or[Math]::Abs($code)-gt10000000){return [pscustomobject]@{valid=$false;record_count=$count;interval_count=$intervals;end_exclusive=$end}}
        $key=[string]$bits;if(-not$open.ContainsKey($key)){$open[$key]=0}
        if($state-eq1){$open[$key]=[int]$open[$key]+1}else{if([int]$open[$key]-le0){return [pscustomobject]@{valid=$false;record_count=$count;interval_count=$intervals;end_exclusive=$end}};$open[$key]=[int]$open[$key]-1;$intervals++}
        $prev=$tm
    }
    foreach($k in @($open.Keys)){if([int]$open[$k]-ne0){return [pscustomobject]@{valid=$false;record_count=$count;interval_count=$intervals;end_exclusive=$end}}}
    return [pscustomobject]@{valid=$true;record_count=$count;interval_count=$intervals;end_exclusive=$end}
}
# Structural Drift-table validation.
#
# Record shape (unchanged): `u32 count`, then `count * { u32 time_ms; u8 state }`, the state byte
# alternating 1,0 starting at 1. Two consecutive records are the two boundaries of one Drift
# interval.
#
# The authoritative contract is the *interval sequence*, not the raw record order. The container
# does not guarantee which boundary of an interval is written first: current 2026-09 replays
# contain pairs whose first-written timestamp is the later one (measured: 3 of the 15
# September-2026 corpus replays carry exactly one such inverted pair each; every other pair in
# the whole corpus is written in order). Validating the raw record times as non-decreasing
# rejects the newest - and in those replays only - native action-object Drift block, so
# production either finds no Drift table at all or silently selects a stale block earlier in the
# same file whose `code2001` effects do not align with the action event table.
#
# This keeps the ordering invariant the previous rule enforced for in-order pairs, expressed on
# the interval sequence:
#   interval[k].start >= interval[k-1].start        (interval starts never move backwards)
# plus the unchanged state-alternation, time-bound, positive-interval and span guards. Record
# times are still published verbatim; only the interval endpoints are normalised to
# (min, max) of the pair.
#
# Rationale for allowing overlap: a boundary pair written out of order can place an interval's
# start slightly before the previous interval's end (measured: 1 of 65 pairs in one corpus replay,
# 0 in the other 14, largest overlap 143 ms). Requiring strict non-overlap rejected the only
# authoritative native action-object block of that replay, which is the same failure this function
# was widened to fix. Non-decreasing interval starts remain enforced and are what keeps a decoy
# table from being accepted.
function RNDT-TryParseToggleTable([byte[]]$Data,[long]$CountOffset,[bool]$AllowEmpty=$false){
    if($CountOffset-lt0-or($CountOffset+4)-gt$Data.Length){return [pscustomobject]@{valid=$false}}
    [uint32]$countU32=RNDT-ReadU32 $Data ([int]$CountOffset)
    if($countU32-gt1000-or($countU32%2)-ne0){return [pscustomobject]@{valid=$false}}
    $count=[int]$countU32
    if($count-eq0-and-not$AllowEmpty){return [pscustomobject]@{valid=$false}}
    [long]$end=$CountOffset+4L+5L*$count
    if($end-gt$Data.Length){return [pscustomobject]@{valid=$false}}
    $records=New-Object System.Collections.Generic.List[object]
    $intervals=New-Object System.Collections.Generic.List[object]
    [long]$prevIntervalStart=-1L;$positive=0;$invertedPairCount=0
    for($i=0;$i-lt$count;$i++){
        $q=[int]($CountOffset+4L+5L*$i)
        $t=[long](RNDT-ReadU32 $Data $q);$state=[int]$Data[$q+4]
        $expected=$(if(($i%2)-eq0){1}else{0})
        if($state-ne$expected-or$t-gt600000){return [pscustomobject]@{valid=$false}}
        $records.Add([pscustomobject][ordered]@{time_ms=$t;state=$state})
        if(($i%2)-eq1){
            $a=[long]$records[$i-1].time_ms
            $start=[Math]::Min($a,$t);$stop=[Math]::Max($a,$t)
            if($a-gt$t){$invertedPairCount++}
            if($start-lt$prevIntervalStart){return [pscustomobject]@{valid=$false}}
            if($stop-gt$start){$positive++}
            $prevIntervalStart=$start
            $intervals.Add([pscustomobject][ordered]@{start_ms=$start;end_ms=$stop;duration_ms=($stop-$start)})
        }
    }
    if($count-gt0){
        if($positive-lt[Math]::Max(1,[int][Math]::Floor($intervals.Count/2))){return [pscustomobject]@{valid=$false}}
        $firstStart=[long]$intervals[0].start_ms
        $lastEnd=[long]$intervals[$intervals.Count-1].end_ms
        if(($lastEnd-$firstStart)-lt300){return [pscustomobject]@{valid=$false}}
    }
    return [pscustomobject][ordered]@{valid=$true;count=$count;end_exclusive=$end;records=$records.ToArray();intervals=$intervals.ToArray();inverted_pair_count=$invertedPairCount}
}
function RNDT-MarkerAt([byte[]]$Data,[long]$CountOffset){
    if($CountOffset-lt4){return $false}
    $o=[int]$CountOffset
    return ($Data[$o-4]-eq0x7E-and$Data[$o-3]-eq0xA0-and$Data[$o-2]-eq0x1E-and$Data[$o-1]-eq0xC2)
}
function RNDT-NewCandidate([byte[]]$Data,[long]$CountOffset,[object]$Parsed,[bool]$MarkerValid){
    $adj=RNDT-ProbeAdjacentEffectTable -Data $Data -CountOffset ([long]$Parsed.end_exclusive)
    $records=@($Parsed.records);$intervals=@($Parsed.intervals);$count=[int]$Parsed.count
    return [pscustomobject][ordered]@{
        count_offset=$CountOffset;end_exclusive=[long]$Parsed.end_exclusive;record_count=$count;interval_count=$intervals.Count
        object_marker_hex=$(if($MarkerValid){'7EA01EC2'}else{RNDT-Hex4 $Data ([int]$CountOffset-4)});native_object_marker_valid=$MarkerValid
        structural_table_valid=$true;empty_table=($count-eq0);legacy_unmarked_action_pair=(-not$MarkerValid-and[bool]$adj.valid)
        adjacent_effect_table_valid=[bool]$adj.valid;adjacent_effect_record_count=[int]$adj.record_count;adjacent_effect_interval_count=[int]$adj.interval_count;adjacent_effect_end_exclusive=[long]$adj.end_exclusive
        # A pair whose first-written timestamp is the later boundary. Published as raw structural
        # evidence: it is what distinguishes the current 2026-09 tables from the older ones, and a
        # regression must be able to see it without re-reading the replay.
        inverted_pair_count=[int]$Parsed.inverted_pair_count
        # Interval-derived, so an inverted boundary pair cannot leak a reversed span into the
        # recorded start/end times.
        start_time_ms=$(if($intervals.Count-gt0){[long]$intervals[0].start_ms}else{$null});end_time_ms=$(if($intervals.Count-gt0){[long]$intervals[$intervals.Count-1].end_ms}else{$null})
        records=$records;intervals=$intervals;source='replay_native_action_object_drift_table_v3'
    }
}
function Get-ReplayNativeDriftTimelineCandidates {
    param(
        [string]$ReplayPath='',
        [int]$TailBytes=196608,
        # Preloaded replay bytes (or a full-length buffer reconstructed from the cached raw tail).
        # The scan window and every structural rule are unchanged; only the byte source differs.
        [byte[]]$Data=$null
    )
    if($null-eq$Data){
        if([string]::IsNullOrWhiteSpace($ReplayPath)){throw 'Native drift candidate scanner requires -ReplayPath or -Data.'}
        if(-not(Test-Path -LiteralPath $ReplayPath -PathType Leaf)){throw ('Replay not found: '+$ReplayPath)}
        [byte[]]$data=[IO.File]::ReadAllBytes($ReplayPath)
    } else {[byte[]]$data=$Data}
    $scanStart=[Math]::Max(0,$data.Length-[Math]::Max(32768,$TailBytes))
    $out=New-Object System.Collections.Generic.List[object]
    $seen=New-Object 'System.Collections.Generic.HashSet[long]'

    # Positive Drift tables exist in both marked and older unmarked native action-object layouts.
    # For the older layout, the structurally adjacent valid speed-effect table is the native pairing proof.
    for($o=$scanStart;$o -le ($data.Length-14);$o++){
        [uint32]$countU32=RNDT-ReadU32 $data $o
        if($countU32-lt4-or$countU32-gt1000-or($countU32%2)-ne0){continue}
        $parsed=RNDT-TryParseToggleTable -Data $data -CountOffset $o -AllowEmpty $false
        if(-not[bool]$parsed.valid){continue}
        $marked=RNDT-MarkerAt -Data $data -CountOffset $o
        $cand=RNDT-NewCandidate -Data $data -CountOffset $o -Parsed $parsed -MarkerValid $marked
        $out.Add($cand);[void]$seen.Add([long]$o)
    }

    # Empty Drift is meaningful only when the native action-object marker identifies the table.
    # Marker-linked one-interval tables are also accepted here even though the generic structural scan starts at 2 intervals.
    [byte[]]$marker=@(0x7E,0xA0,0x1E,0xC2)
    for($m=$scanStart;$m -le ($data.Length-8);$m++){
        if($data[$m]-ne$marker[0]-or$data[$m+1]-ne$marker[1]-or$data[$m+2]-ne$marker[2]-or$data[$m+3]-ne$marker[3]){continue}
        $o=[long]$m+4L
        if($seen.Contains($o)){continue}
        $parsed=RNDT-TryParseToggleTable -Data $data -CountOffset $o -AllowEmpty $true
        if(-not[bool]$parsed.valid){continue}
        $out.Add((RNDT-NewCandidate -Data $data -CountOffset $o -Parsed $parsed -MarkerValid $true));[void]$seen.Add($o)
    }
    return @($out.ToArray())
}
function RNDT-AsBool($Value){
    if($null-eq$Value){return $false}
    if($Value-is[bool]){return [bool]$Value}
    $s=[string]$Value
    return ($s-eq'True'-or$s-eq'true'-or$s-eq'1')
}
function Get-ReplayNativeShiftRiseTimes {
    param([Parameter(Mandatory=$true)][object[]]$Rows)
    $out=New-Object System.Collections.Generic.List[double]
    $prev=$false
    foreach($r in @($Rows)){
        $cur=RNDT-AsBool $r.input_bool_candidate_64
        if($cur-and-not$prev){$out.Add([double]$r.time_s)}
        $prev=$cur
    }
    return @($out.ToArray())
}
function RNDT-IsNear([double]$A,[double]$B,[double]$ToleranceS){return ([Math]::Abs($A-$B)-le$ToleranceS)}
function Resolve-ReplayNativeDriftTimeline {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Candidates,
        [Parameter(Mandatory=$true)][object[]]$Rows,
        [long[]]$ExcludedCountOffsets=@(),
        [double]$StartToleranceMs=34.0
    )
    $rises=@(Get-ReplayNativeShiftRiseTimes -Rows $Rows)
    $tol=$StartToleranceMs/1000.0

    # Authority is structural: marker-linked native action object, or a valid Drift table
    # directly paired with a valid adjacent native speed-effect table. Shift rises are diagnostic only.
    # Therefore do not run the O(candidate * drift * shift) diagnostic scorer over structural
    # decoys that can never become authoritative. Real replays may contain many such suffix
    # lookalikes; filtering them first keeps native semantic resolution bounded.
    $eligible=New-Object System.Collections.Generic.List[object]
    $rejected=New-Object System.Collections.Generic.List[object]
    foreach($c in @($Candidates)){
        if($ExcludedCountOffsets -contains [long]$c.count_offset){continue}
        $intervals=@($c.intervals)
        $markerAuthority=[bool]$c.native_object_marker_valid
        $pairedAuthority=([bool]$c.structural_table_valid-and[bool]$c.adjacent_effect_table_valid-and$intervals.Count-gt0)
        if($markerAuthority-or$pairedAuthority){$eligible.Add($c)}else{$rejected.Add($c)}
    }
    if($eligible.Count-eq0){
        $bestRejected=$null
        if($rejected.Count-gt0){
            $bestRejected=@($rejected.ToArray()|Sort-Object @{Expression={$(if([bool]$_.adjacent_effect_table_valid){100000}else{0})+[int]$_.adjacent_effect_record_count*10000.0+[int]$_.interval_count};Descending=$true}|Select-Object -First 1)
            if($bestRejected.Count-gt0){$bestRejected=$bestRejected[0]}else{$bestRejected=$null}
        }
        return [pscustomobject][ordered]@{available=$false;status=$(if($Candidates.Count-eq0){'native_action_object_drift_table_not_found'}else{'native_action_object_drift_table_not_validated'});shift_rise_count=$rises.Count;best_candidate=$bestRejected;ranked=@();eligible_candidate_count=0;rejected_candidate_count=$rejected.Count}
    }

    $ranked=New-Object System.Collections.Generic.List[object]
    foreach($c in $eligible.ToArray()){
        $matched=0;$internal=0;$outside=0
        $intervals=@($c.intervals)
        foreach($iv in $intervals){
            $s=[double]$iv.start_ms/1000.0
            $near=$false
            foreach($rt in $rises){if(RNDT-IsNear $rt $s $tol){$near=$true;break}}
            if($near){$matched++}
        }
        foreach($rt in $rises){
            $inside=$false;$atStart=$false
            foreach($iv in $intervals){
                $s=[double]$iv.start_ms/1000.0;$e=[double]$iv.end_ms/1000.0
                if(RNDT-IsNear $rt $s $tol){$atStart=$true;$inside=$true;break}
                if($rt-gt$s-and$rt-lt$e){$inside=$true;break}
            }
            if($inside){if(-not$atStart){$internal++}}else{$outside++}
        }
        $frac=$(if($intervals.Count-gt0){$matched/[double]$intervals.Count}else{1.0})
        $markerAuthority=[bool]$c.native_object_marker_valid
        $pairedAuthority=([bool]$c.structural_table_valid-and[bool]$c.adjacent_effect_table_valid-and$intervals.Count-gt0)
        $basis=$(if($markerAuthority){'native_object_marker_and_table_structure'}elseif($pairedAuthority){'structural_drift_plus_adjacent_native_effect_pair'}else{'none'})
        $ranked.Add([pscustomobject][ordered]@{
            candidate=$c;accepted=$true;validation_basis=$basis
            shift_rise_count=$rises.Count;start_match_count=$matched;start_match_fraction=[Math]::Round($frac,6)
            internal_shift_retriggers=$internal;outside_shift_rises=$outside;adjacent_effect_table_valid=[bool]$c.adjacent_effect_table_valid;adjacent_effect_record_count=[int]$c.adjacent_effect_record_count
            score=(1000000+$(if($markerAuthority){250000}else{0})+$(if([bool]$c.adjacent_effect_table_valid){100000}else{0})+[int]$c.adjacent_effect_record_count*10000.0+$matched*1000.0+$frac*100.0+$intervals.Count)
        })
    }
    $ordered=@($ranked.ToArray()|Sort-Object @{Expression='score';Descending=$true},@{Expression={ [int]$_.candidate.interval_count };Descending=$true})
    $best=$ordered[0]
    return [pscustomobject][ordered]@{
        available=$true;status=$(if([int]$best.candidate.interval_count-eq0){'replay_native_drift_table_validated_empty'}else{'replay_native_drift_table_validated'})
        source='replay_native_action_object_drift_table_v3';validation_basis=[string]$best.validation_basis;candidate=$best.candidate
        shift_rise_count=$best.shift_rise_count;start_match_count=$best.start_match_count;start_match_fraction=$best.start_match_fraction
        internal_shift_retriggers=$best.internal_shift_retriggers;outside_shift_rises=$best.outside_shift_rises;ranked=@($ordered|Select-Object -First 8)
        eligible_candidate_count=$eligible.Count;rejected_candidate_count=$rejected.Count
    }
}
function RNDT-NearestRowIndex([object[]]$Rows,[double]$TimeS){
    if($Rows.Count-eq0){return -1}
    $lo=0;$hi=$Rows.Count-1
    while($lo-lt$hi){$m=[int][Math]::Floor(($lo+$hi)/2.0);if([double]$Rows[$m].time_s-lt$TimeS){$lo=$m+1}else{$hi=$m}}
    $best=$lo
    if($best-gt0-and[Math]::Abs([double]$Rows[$best-1].time_s-$TimeS)-lt[Math]::Abs([double]$Rows[$best].time_s-$TimeS)){$best--}
    return $best
}
function Convert-ReplayNativeDriftTimelineToSegments {
    param(
        [Parameter(Mandatory=$true)][object]$Resolved,
        [Parameter(Mandatory=$true)][object[]]$Rows,
        [double]$TotalDistance=0.0,
        [object[]]$Laps=@()
    )
    if(-not[bool]$Resolved.available-or$Rows.Count-eq0){return @()}
    foreach($r in $Rows){$r.system_drift_state=$false;$r.system_drift_state_source='replay_native_action_object_drift_table_v3'}
    $out=New-Object System.Collections.Generic.List[object]
    $id=1
    foreach($iv in @($Resolved.candidate.intervals)){
        $startS=[double]$iv.start_ms/1000.0;$endS=[double]$iv.end_ms/1000.0
        $si=RNDT-NearestRowIndex $Rows $startS;$ei=RNDT-NearestRowIndex $Rows $endS
        if($si-lt0-or$ei-lt0){continue};if($ei-lt$si){$tmp=$si;$si=$ei;$ei=$tmp}
        $peakI=$si;$peak=-1.0;$sumSlip=0.0;$cnt=0;$minSpeed=[double]::PositiveInfinity;$maxSpeed=0.0
        for($j=$si;$j-le$ei;$j++){
            $t=[double]$Rows[$j].time_s
            if($t-ge$startS-and$t-lt$endS){$Rows[$j].system_drift_state=$true}
            $sl=[Math]::Abs([double]$Rows[$j].slip)*180.0/[Math]::PI
            if($sl-gt$peak){$peak=$sl;$peakI=$j};$sumSlip+=$sl;$cnt++
            $sp=[double]$Rows[$j].speed;if($sp-lt$minSpeed){$minSpeed=$sp};if($sp-gt$maxSpeed){$maxSpeed=$sp}
        }
        if([double]::IsInfinity($minSpeed)){$minSpeed=0.0}
        $startP=$(if($TotalDistance-gt0){[double]$Rows[$si].distance/$TotalDistance}else{0.0})
        $endP=$(if($TotalDistance-gt0){[double]$Rows[$ei].distance/$TotalDistance}else{0.0})
        $peakP=$(if($TotalDistance-gt0){[double]$Rows[$peakI].distance/$TotalDistance}else{0.0})
        $lapNo=1
        foreach($lp in @($Laps)){if($startS-le[double]$lp.end_t-and$endS-ge[double]$lp.start_t){$lapNo=[int]$lp.lap;break}}
        $out.Add([ordered]@{
            id=$id;start_t=[Math]::Round($startS,4);peak_t=[Math]::Round([double]$Rows[$peakI].time_s,4);end_t=[Math]::Round($endS,4);duration_s=[Math]::Round(($endS-$startS),4)
            start_p=[Math]::Round($startP,6);peak_p=[Math]::Round($peakP,6);end_p=[Math]::Round($endP,6);start_distance=[Math]::Round([double]$Rows[$si].distance,3);end_distance=[Math]::Round([double]$Rows[$ei].distance,3);route_length=[Math]::Round(([double]$Rows[$ei].distance-[double]$Rows[$si].distance),3)
            entry_speed=[Math]::Round([double]$Rows[$si].speed,3);min_speed=[Math]::Round($minSpeed,3);max_speed=[Math]::Round($maxSpeed,3);exit_speed=[Math]::Round([double]$Rows[$ei].speed,3)
            max_abs_slip_deg=[Math]::Round([Math]::Max(0.0,$peak),2);avg_abs_slip_deg=[Math]::Round($(if($cnt-gt0){$sumSlip/$cnt}else{0.0}),2);confidence=1.0;lap=$lapNo
            source='replay_native_action_object_drift_table_v3';semantic_type='replay_native_system_drift_interval';system_drift_state_confirmed=$true;authoritative_for_system_drift=$true
            native_start_ms=[long]$iv.start_ms;native_end_ms=[long]$iv.end_ms;native_table_count_offset=[long]$Resolved.candidate.count_offset;native_object_marker_hex=[string]$Resolved.candidate.object_marker_hex
        });$id++
    }
    return @($out.ToArray())
}
