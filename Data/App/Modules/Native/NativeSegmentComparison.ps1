# Native segment comparison v1  (symmetric same-map A/B over ONE shared core world interval)
#
# DERIVED, NON-AUTHORITATIVE comparison contract. It answers, per automatic analysis segment:
# "did the subject need more time / more distance here, and by how much". Crossing-time and shared
# space are measured on ONE common CORE world interval; native corner metrics (entry/min/exit/recovery)
# are measured on each side's OWN semantic Drift/recovery window so route correspondence cannot
# move a speed or recovery endpoint. For a paired corner TWO symmetric windows are published:
# the CORE interval keeps the EARLIER mapped Drift start and stops at the EARLIER mapped natural
# recovery end; the FINAL interval keeps the same start and extends to the LATER mapped natural
# recovery end (still hard-cut by the next independent Drift). Core measures corner handling; final
# measures the net result after each side's single/double-spray recovery strategy has played out.
#
# Authority rules (docs/ARCHITECTURE.md) this module obeys:
#   * The two sides are corresponded in the official world XY of the real driven trajectory, by the
#     already-validated monotone / order-preserving / heading-gated / bounded / fail-closed kernel
#     `NTA-SharedCorrespondence` (NativeTrainingSections.ps1). No canonical track, no track
#     topology, no map matcher and no official reference line is introduced, and TIME IS NEVER PART
#     OF THE MATCHING COST - a time difference is a measurement RESULT, not an input.
#   * The window set is built in a CANONICAL side order, so compare(A,B) and compare(B,A) publish
#     exactly the same world intervals and every signed metric negates. That is the swap contract.
#   * Native actions are never copied between sides. A side without a native Drift keeps its
#     Drift metrics UNAVAILABLE (null); route / time / speed comparison still runs.
#   * Same-map identity is an explicit gate and it does not consult basemap availability.
#
# Definition-only module. Requires NativeDrivingAnalysis.ps1 (NDA-*), NativeDrivingEpisodes.ps1
# (NDE-*), NativeTrainingSections.ps1 (NTA-*), NativeTrainingTimeLoss.ps1 (NTA-* row helpers) and
# NativeAnalysisSegments.ps1 (NAS-*) to be loaded first.
$script:NscContractName = 'native_segment_comparison_v1'
# Gameplay source (TencentCar.h::SetXiaoPen): one small-boost acceleration effect has a 0.25 s
# lifetime. Comparison metrics may use this ONLY as a measurement fallback when the selected stream
# cannot observe native speed-effect state at all; it never changes segment ownership or drawing.
$script:NscMinimumSmallBoostTailS = 0.25

# The measurement contract's metric table. Published verbatim with every window so a consumer never
# has to guess what a number means, where it came from, or whether it is native or derived.
function NSC-MetricDefinitions {
    return @(
        [pscustomobject]@{id='time_s';unit='s';definition='CORE crossing time of the shared world interval; for paired corners this is the core interval from the earlier mapped Drift start to the earlier mapped natural recovery end, interpolated at both boundaries on each side';authority='derived_measurement_of_native_drift_and_native_effect_intervals'}
        [pscustomobject]@{id='entry_speed_mps';unit='m/s';definition='three-sample median speed centered on this side native Drift start when present; otherwise centered on the shared interval entry';authority='native_drift_start_anchor_plus_production_telemetry_speed'}
        [pscustomobject]@{id='min_corner_speed_mps';unit='m/s';definition='minimum measured speed between the shared interval entry and the final native Drift end of this corner';authority='derived_measurement_over_the_native_drift_interval'}
        [pscustomobject]@{id='exit_speed_mps';unit='m/s';definition='maximum measured speed from this side final native Drift end through this side own recovery metric end; shared A/B geometry never changes this value';authority='native_drift_end_plus_own_recovery_window_plus_production_telemetry_speed'}
        [pscustomobject]@{id='drift_distance_m';unit='m';definition='trajectory distance travelled while a native Drift interval was active inside this segment (sum over the segment own native Drift intervals)';authority='native_drift_intervals_measured_on_production_telemetry'}
        [pscustomobject]@{id='recovery_distance_m';unit='m';definition='this side own trajectory distance from final native Drift end to its recovery metric end; shared A/B geometry never truncates it';authority='native_recovery_end_or_gameplay_minimum_small_boost_tail_when_effect_state_unobservable'}
        [pscustomobject]@{id='total_distance_m';unit='m';definition='this side own trajectory distance from first native Drift start through its recovery metric end';authority='native_drift_start_plus_own_recovery_metric_end'}
    )
}

# --- small published-value helpers (ASCII) ----------------------------------------------------

function NSC-DefaultMetricDefinition {
    param([string]$Id)
    foreach($d in @(NSC-MetricDefinitions)){ if([string]$d.id -eq $Id){ return $d } }
    return $null
}
function NSC-MetricValue {
    param($Subject,$Baseline)
    $s=NAS-Num $Subject
    $b=NAS-Num $Baseline
    $delta=$null
    if($null-ne$s-and$null-ne$b){ $delta=[math]::Round(($s-$b),4) }
    return [pscustomobject][ordered]@{
        subject=NAS-Round $s 4
        baseline=NAS-Round $b 4
        delta=$delta
        available=($null-ne$s-or$null-ne$b)
    }
}


# Peak production-telemetry speed inside ONE side's own semantic time window. This helper never
# receives a shared-space boundary, so A/B route mapping cannot move the exit-speed sample.
function NSC-MaxSpeedBetweenTimes {
    param(
        [AllowEmptyCollection()][object[]]$Rows=@(),
        [double]$StartT=0.0,
        [double]$EndT=0.0,
        [int]$Low=0,
        [int]$High=0
    )
    $r=@($Rows)
    if($r.Count-eq0-or$EndT-lt$StartT){ return $null }
    $lo=[math]::Max(0,[math]::Min($r.Count-1,$Low))
    $hi=[math]::Max($lo,[math]::Min($r.Count-1,$High))
    $i0=NTA-RowIndexAtTime $r $lo $hi $StartT
    $i1=NTA-RowIndexAtTime $r $lo $hi $EndT
    if($i0-lt0-or$i1-lt$i0){ return $null }
    $max=$null
    for($i=$i0;$i-le$i1;$i++){
        if(-not[bool]$r[$i].pose_valid){ continue }
        $v=NAS-Num $r[$i].speed
        if($null-eq$v-or$v-lt0.0){ continue }
        if($null-eq$max-or$v-gt$max){ $max=$v }
    }
    if($null-eq$max){ return $null }
    return [Math]::Round([double]$max,3)
}

# --- trajectory helpers ----------------------------------------------------------------------

# Normalised progress of a measured cumulative distance inside one control-point sequence.
# Out of range -> $null (fail closed): a boundary that the trajectory never reached is not moved
# to the nearest reachable point just to produce a number.
function NSC-ProgressOfDistance {
    param([AllowEmptyCollection()][object[]]$ControlPoints=@(),[object]$Distance)
    $cp=@($ControlPoints)
    if($cp.Count-lt2){ return $null }
    $d=NAS-Num $Distance
    if($null-eq$d){ return $null }
    $d0=[double]$cp[0].d
    $d1=[double]$cp[$cp.Count-1].d
    if($d1-$d0-le1e-9){ return $null }
    if($d-lt$d0-1e-6-or$d-gt$d1+1e-6){ return $null }
    $u=($d-$d0)/($d1-$d0)
    if($u-lt0.0){$u=0.0}
    if($u-gt1.0){$u=1.0}
    return $u
}

# Interpolated world position (x,y) and time at a measured cumulative distance.
function NSC-PointAtDistance {
    param([AllowEmptyCollection()][object[]]$ControlPoints=@(),[object]$Distance)
    $cp=@($ControlPoints)
    $d=NAS-Num $Distance
    if($cp.Count-lt1-or$null-eq$d){ return $null }
    if($cp.Count-eq1){ return [pscustomobject][ordered]@{x=[double]$cp[0].x;y=[double]$cp[0].y;t=[double]$cp[0].t;d=[double]$cp[0].d} }
    if($d-le[double]$cp[0].d){ return [pscustomobject][ordered]@{x=[double]$cp[0].x;y=[double]$cp[0].y;t=[double]$cp[0].t;d=[double]$cp[0].d} }
    $last=$cp.Count-1
    if($d-ge[double]$cp[$last].d){ return [pscustomobject][ordered]@{x=[double]$cp[$last].x;y=[double]$cp[$last].y;t=[double]$cp[$last].t;d=[double]$cp[$last].d} }
    $lo=0;$hi=$last
    while(($hi-$lo)-gt1){ $m=[int](($lo+$hi)/2); if([double]$cp[$m].d-le$d){$lo=$m}else{$hi=$m} }
    $a=$cp[$lo];$b=$cp[$hi]
    $da=[double]$a.d;$db=[double]$b.d
    $f=0.0
    if($db-$da-gt1e-12){ $f=($d-$da)/($db-$da) }
    return [pscustomobject][ordered]@{
        x=([double]$a.x+(([double]$b.x-[double]$a.x)*$f))
        y=([double]$a.y+(([double]$b.y-[double]$a.y)*$f))
        t=([double]$a.t+(([double]$b.t-[double]$a.t)*$f))
        d=$d
    }
}

# --- identity gate ---------------------------------------------------------------------------

# Same-map comparability. Deliberately independent of the basemap: an authoritative identity is
# sufficient even when no official map render exists, and a real identity conflict fails closed.
function NSC-IdentityGate {
    param([object]$SideA,[object]$SideB)
    $ra=NAS-IntOrNull (NAS-Prop $SideA 'resource_map_id')
    $rb=NAS-IntOrNull (NAS-Prop $SideB 'resource_map_id')
    $ga=NAS-IntOrNull (NAS-Prop $SideA 'game_map_id')
    $gb=NAS-IntOrNull (NAS-Prop $SideB 'game_map_id')
    $na=[string](NAS-Prop $SideA 'map_name')
    $nb=[string](NAS-Prop $SideB 'map_name')
    $rule='authoritative ResourceMapID, else authoritative GameMapID, else exact same official map name; the basemap render is never consulted'
    if($null-ne$ra-and$null-ne$rb){
        if($ra-eq$rb){ return [pscustomobject][ordered]@{comparable=$true;status='comparable_same_resource_map';basis='resource_map_id';resource_map_id=$ra;game_map_id=$(if($null-ne$ga-and$ga-eq$gb){$ga}else{$null});rule=$rule} }
        return [pscustomobject][ordered]@{comparable=$false;status='unavailable_conflicting_resource_map';basis='resource_map_id';resource_map_id=$null;game_map_id=$null;rule=$rule}
    }
    if($null-ne$ga-and$null-ne$gb){
        if($ga-eq$gb){ return [pscustomobject][ordered]@{comparable=$true;status='comparable_same_game_map';basis='game_map_id';resource_map_id=$null;game_map_id=$ga;rule=$rule} }
        return [pscustomobject][ordered]@{comparable=$false;status='unavailable_conflicting_game_map';basis='game_map_id';resource_map_id=$null;game_map_id=$null;rule=$rule}
    }
    $keyA=[string](NAS-Prop $SideA 'map_name_key')
    $keyB=[string](NAS-Prop $SideB 'map_name_key')
    if(-not [string]::IsNullOrWhiteSpace($keyA) -and $keyA -eq $keyB){
        return [pscustomobject][ordered]@{comparable=$true;status='comparable_exact_same_map_name';basis='exact_same_map_name';resource_map_id=$null;game_map_id=$null;rule=$rule}
    }
    return [pscustomobject][ordered]@{comparable=$false;status='unavailable_map_identity_not_authoritative';basis='unresolved';resource_map_id=$null;game_map_id=$null;rule=$rule}
}

# --- corner anchors on the shared progress axis ----------------------------------------------

# One side's corner intervals expressed on the shared progress axis. `Side` is 'a' for the
# canonical first side and 'b' for the canonical second side.
function NSC-CornerAnchors {
    param(
        [AllowEmptyCollection()][object[]]$Segments=@(),
        [AllowEmptyCollection()][object[]]$ControlPoints=@(),
        [AllowEmptyCollection()][object[]]$Pairs=@(),
        [object[]]$Rows=@(),
        [int]$RowStart=0,
        [int]$RowEnd=0,
        [string]$Side='a'
    )
    $out=New-Object System.Collections.Generic.List[object]
    foreach($seg in @($Segments)){
        if($null-eq$seg){ continue }
        $startT=NAS-Num (NAS-Prop $seg 'start_t')
        $driftEndT=NAS-Num (NAS-Prop $seg 'drift_end_t')
        $recEndT=NAS-Num (NAS-Prop $seg 'recovery_end_t')
        $nextT=NAS-Num (NAS-Prop $seg 'next_drift_start_t')
        $dStart=NTA-LapDistanceAtTime $Rows $RowStart $RowEnd $startT
        $dDriftEnd=NTA-LapDistanceAtTime $Rows $RowStart $RowEnd $driftEndT
        $dRecEnd=NTA-LapDistanceAtTime $Rows $RowStart $RowEnd $recEndT
        $dNext=$null
        if($null-ne$nextT){ $dNext=NTA-LapDistanceAtTime $Rows $RowStart $RowEnd $nextT }
        $uStart=NSC-ProgressOfDistance -ControlPoints $ControlPoints -Distance $dStart
        $uRecEnd=NSC-ProgressOfDistance -ControlPoints $ControlPoints -Distance $dRecEnd
        $uNext=NSC-ProgressOfDistance -ControlPoints $ControlPoints -Distance $dNext
        $sStart=$null;$sEnd=$null;$sNext=$null;$status='ready';$reason=''
        if($null-eq$uStart-or$null-eq$uRecEnd){
            $status='unmatched';$reason='segment_boundary_outside_the_shared_correspondence_window'
        } else {
            $sStart=NTA-SideProgressToShared -Pairs $Pairs -Side $Side -U $uStart
            $sEnd=NTA-SideProgressToShared -Pairs $Pairs -Side $Side -U $uRecEnd
            if($null-eq$sStart-or$null-eq$sEnd-or$sEnd-lt$sStart){ $status='unmatched';$reason='segment_boundary_has_no_shared_counterpart' }
            elseif($null-ne$uNext){ $sNext=NTA-SideProgressToShared -Pairs $Pairs -Side $Side -U $uNext }
        }
        $out.Add([pscustomobject][ordered]@{
            status=$status
            reason=$reason
            side=$Side
            segment=$seg
            start_t=$startT
            drift_end_t=$driftEndT
            recovery_end_t=$recEndT
            next_drift_start_t=$nextT
            d_start=NAS-Round $dStart 3
            d_drift_end=NAS-Round $dDriftEnd 3
            d_recovery_end=NAS-Round $dRecEnd 3
            s_start=NAS-Round $sStart 8
            s_end=NAS-Round $sEnd 8
            s_next_drift_start=NAS-Round $sNext 8
        })
    }
    return @($out.ToArray())
}

# Monotone pairing of the two sides' corners on the shared progress axis: maximise the number of
# pairs, then minimise the total anchor distance. Same shape as the action crosswalk matcher, and
# it runs in CANONICAL order, which is what makes the pairing (and therefore the window set)
# independent of which side the caller called "subject".
function NSC-PairCorners {
    param(
        [AllowEmptyCollection()][object[]]$Left=@(),
        [AllowEmptyCollection()][object[]]$Right=@(),
        [double]$AnchorToleranceProgress=0.02
    )
    $a=New-Object System.Collections.Generic.List[object]
    foreach($x in @($Left)){ if([string]$x.status-eq'ready'){ $a.Add($x) } }
    $b=New-Object System.Collections.Generic.List[object]
    foreach($y in @($Right)){ if([string]$y.status-eq'ready'){ $b.Add($y) } }
    $n=$a.Count;$m=$b.Count
    $pairs=New-Object System.Collections.Generic.List[object]
    if($n-eq0-or$m-eq0){ return @($pairs.ToArray()) }
    $cnt=New-Object 'int[][]' ($n+1); $err=New-Object 'double[][]' ($n+1); $ch=New-Object 'byte[][]' ($n+1)
    for($i=0;$i-le$n;$i++){ $cnt[$i]=New-Object 'int[]' ($m+1); $err[$i]=New-Object 'double[]' ($m+1); $ch[$i]=New-Object 'byte[]' ($m+1) }
    for($i=0;$i-le$n;$i++){ for($j=0;$j-le$m;$j++){ $err[$i][$j]=[double]::PositiveInfinity } }
    $err[0][0]=0.0
    for($i=0;$i-le$n;$i++){
        for($j=0;$j-le$m;$j++){
            if($i-eq0-and$j-eq0){ continue }
            $bc=-1;$be=[double]::PositiveInfinity;$bch=[byte]0
            if($i-gt0){ $c=$cnt[$i-1][$j];$e=$err[$i-1][$j]; if(($c-gt$bc)-or(($c-eq$bc)-and($e-lt$be))){$bc=$c;$be=$e;$bch=[byte]1} }
            if($j-gt0){ $c=$cnt[$i][$j-1];$e=$err[$i][$j-1]; if(($c-gt$bc)-or(($c-eq$bc)-and($e-lt$be))){$bc=$c;$be=$e;$bch=[byte]2} }
            if($i-gt0-and$j-gt0){
                $dd=[math]::Abs([double]$a[$i-1].s_start-[double]$b[$j-1].s_start)
                if($dd-le$AnchorToleranceProgress){
                    $c=$cnt[$i-1][$j-1]+1;$e=$err[$i-1][$j-1]+$dd
                    if(($c-gt$bc)-or(($c-eq$bc)-and($e-lt$be))){$bc=$c;$be=$e;$bch=[byte]3}
                }
            }
            $cnt[$i][$j]=$bc;$err[$i][$j]=$be;$ch[$i][$j]=$bch
        }
    }
    $i=$n;$j=$m
    while(($i-gt0)-or($j-gt0)){
        $c=$ch[$i][$j]
        if($c-eq3){
            $pairs.Add([pscustomobject][ordered]@{
                a_index=$i-1;b_index=$j-1
                a=$a[$i-1];b=$b[$j-1]
                anchor_delta_progress=[math]::Round(([double]$a[$i-1].s_start-[double]$b[$j-1].s_start),8)
            })
            $i--;$j--
        } elseif($c-eq1){ $i-- } elseif($c-eq2){ $j-- } else { break }
    }
    return @($pairs.ToArray() | Sort-Object { [int]$_.a_index })
}

# --- window construction ---------------------------------------------------------------------

# The candidate window set: one window per paired corner plus one per unpaired corner, so a corner
# that only one side drove still gets a route/time/speed comparison. Every window is clipped by the
# next independent Drift start of the sides it covers (the hard cut) and then the set is made
# monotone and non-overlapping, which is what "the same world interval" means for A->B and B->A.
function NSC-BuildWindows {
    param(
        [AllowEmptyCollection()][object[]]$CornerPairs=@(),
        [AllowEmptyCollection()][object[]]$AnchorsLeft=@(),
        [AllowEmptyCollection()][object[]]$AnchorsRight=@(),
        [object]$SharedInterval=$null,
        [string]$WindowPrefix='S'
    )
    $raw=New-Object System.Collections.Generic.List[object]
    if($null-ne$SharedInterval){
        $raw.Add([pscustomobject]@{
            s_lo=[double]$SharedInterval.s_start
            s_hi=[double]$SharedInterval.s_end
            a_corner=$null
            b_corner=$null
            paired=$false
            source='custom_path_shared_world_interval'
        })
    } else {
        foreach($p in @($CornerPairs)){
            # Primary efficiency window for a paired corner:
            #   * keep the earlier mapped Drift start so an early/late entry choice remains part of
            #     the comparison;
            #   * cap the window at the earlier mapped NATURAL recovery end so a longer single/double
            #     spray tail cannot enlarge the primary time window for both sides.
            # Own-side exit speed / recovery distance / total distance are measured separately and
            # therefore retain the complete natural recovery of each replay.
            $raw.Add([pscustomobject]@{
                s_lo=[math]::Min([double]$p.a.s_start,[double]$p.b.s_start)
                s_hi=[math]::Min([double]$p.a.s_end,[double]$p.b.s_end)
                final_s_hi=[math]::Max([double]$p.a.s_end,[double]$p.b.s_end)
                a_corner=$p.a
                b_corner=$p.b
                paired=$true
                source='paired_corner'
                a_natural_start=[double]$p.a.s_start
                a_natural_end=[double]$p.a.s_end
                b_natural_start=[double]$p.b.s_start
                b_natural_end=[double]$p.b.s_end
            })
        }
        $pairedA=@{}; foreach($p in @($CornerPairs)){ $pairedA[[string]$p.a.segment.segment_index]=$true }
        $pairedB=@{}; foreach($p in @($CornerPairs)){ $pairedB[[string]$p.b.segment.segment_index]=$true }
        foreach($x in @($AnchorsLeft)){
            if([string]$x.status-ne'ready'){ continue }
            if($pairedA.ContainsKey([string]$x.segment.segment_index)){ continue }
            $raw.Add([pscustomobject]@{s_lo=[double]$x.s_start;s_hi=[double]$x.s_end;a_corner=$x;b_corner=$null;paired=$false;source='unpaired_corner_subject_only'})
        }
        foreach($y in @($AnchorsRight)){
            if([string]$y.status-ne'ready'){ continue }
            if($pairedB.ContainsKey([string]$y.segment.segment_index)){ continue }
            $raw.Add([pscustomobject]@{s_lo=[double]$y.s_start;s_hi=[double]$y.s_end;a_corner=$null;b_corner=$y;paired=$false;source='unpaired_corner_baseline_only'})
        }
    }
    $windows=New-Object System.Collections.Generic.List[object]
    $ordered=@($raw.ToArray() | Sort-Object s_lo,s_hi)
    $previousHigh=$null
    $index=0
    foreach($r in $ordered){
        $lo=[double]$r.s_lo
        $hi=[double]$r.s_hi
        $rawFinalHi=NAS-Num (NAS-Prop $r 'final_s_hi')
        $finalHi=$(if($null-ne$rawFinalHi){[double]$rawFinalHi}else{$hi})
        # hard cut: neither the core nor final window may cross the next independent Drift start of
        # either side. The final union is therefore still attributable to this corner rather than the
        # next driving operation.
        $cut=$null
        foreach($c in @($r.a_corner,$r.b_corner)){
            if($null-eq$c){ continue }
            $sn=NAS-Num $c.s_next_drift_start
            if($null-ne$sn-and$sn-gt$lo+1e-9){
                if($null-eq$cut-or$sn-lt$cut){ $cut=$sn }
            }
        }
        $cutApplied=$false
        $finalCutApplied=$false
        if($null-ne$cut-and$hi-gt$cut+1e-9){ $hi=$cut; $cutApplied=$true }
        if($null-ne$cut-and$finalHi-gt$cut+1e-9){ $finalHi=$cut; $finalCutApplied=$true }
        if($finalHi-lt$hi){$finalHi=$hi}
        if($null-ne$previousHigh-and$lo-lt$previousHigh+1e-9){ $lo=$previousHigh }
        if($hi-le$lo+1e-9){ continue }
        if($finalHi-lt$hi){$finalHi=$hi}
        $index++
        $windows.Add([pscustomobject][ordered]@{
            window_id=('{0}{1:D2}' -f $WindowPrefix,$index)
            source=$r.source
            paired=[bool]$r.paired
            s_start=[math]::Round($lo,8)
            s_end=[math]::Round($hi,8)
            s_span=[math]::Round(($hi-$lo),8)
            final_s_end=[math]::Round($finalHi,8)
            final_s_span=[math]::Round(($finalHi-$lo),8)
            hard_cut_applied=$cutApplied
            final_hard_cut_applied=$finalCutApplied
            hard_cut_t=NAS-Round $cut 4
            subject_corner=$r.a_corner
            baseline_corner=$r.b_corner
            natural_bounds=$(if([bool]$r.paired){[ordered]@{
                subject_start=NAS-Round (NAS-Num (NAS-Prop $r 'a_natural_start')) 8
                subject_end=NAS-Round (NAS-Num (NAS-Prop $r 'a_natural_end')) 8
                baseline_start=NAS-Round (NAS-Num (NAS-Prop $r 'b_natural_start')) 8
                baseline_end=NAS-Round (NAS-Num (NAS-Prop $r 'b_natural_end')) 8
                entry_rule='earlier_mapped_native_drift_start'
                core_end_rule='earlier_mapped_natural_recovery_end'
                final_end_rule='later_mapped_natural_recovery_end_hard_cut_by_next_drift'
            }}else{$null})
        })
        $previousHigh=$hi
    }
    return @($windows.ToArray())
}

# --- per-side measurement of one window ------------------------------------------------------

# Measure EVERY metric of one side over one shared progress interval, using that side's own rows.
# A metric that its own side cannot support stays `$null` - it is never borrowed from the other side
# and never replaced by zero.
function NSC-MeasureSide {
    param(
        [object]$Window=$null,
        [object]$Corner=$null,
        [AllowEmptyCollection()][object[]]$ControlPoints=@(),
        [AllowEmptyCollection()][object[]]$Pairs=@(),
        [AllowEmptyCollection()][object[]]$Rows=@(),
        [int]$RowStart=0,
        [int]$RowEnd=0,
        [string]$Side='a',
        [string]$StreamRole='',
        [bool]$SpeedEffectStateAvailable=$true
    )
    $s0=[double]$Window.s_start
    $s1=[double]$Window.s_end
    $status='comparable'
    $reason=''
    $d0=$null;$d1=$null;$t0=$null;$t1=$null;$i0=-1;$i1=-1;$speed=$null;$p0=$null;$p1=$null
    $sides=NTA-SharedProgressToSides -Pairs $Pairs -S $s0
    $sidesEnd=$null
    if($null-eq$sides){ $status='not_comparable';$reason='window_start_has_no_shared_counterpart' }
    else {
        $d0=$(if($Side-eq'b'){ [double]$sides.b_d } else { [double]$sides.a_d })
        $sidesEnd=NTA-SharedProgressToSides -Pairs $Pairs -S $s1
        if($null-eq$sidesEnd){ $status='not_comparable';$reason='window_end_has_no_shared_counterpart' }
        else {
            $d1=$(if($Side-eq'b'){ [double]$sidesEnd.b_d } else { [double]$sidesEnd.a_d })
            if($null-eq$d0-or$null-eq$d1-or$d1-lt$d0){ $status='not_comparable';$reason='window_has_no_monotone_distance_span' }
            else {
                $t0=NTA-TimeAtLapDistance $Rows $RowStart $RowEnd $d0
                $t1=NTA-TimeAtLapDistance $Rows $RowStart $RowEnd $d1
                if($null-eq$t0-or$null-eq$t1-or$t1-lt$t0){ $status='not_comparable';$reason='window_boundaries_are_outside_the_measured_trajectory' }
                else {
                    $i0=NTA-RowIndexAtDistance $Rows $RowStart $RowEnd $d0
                    $i1=NTA-RowIndexAtDistance $Rows $RowStart $RowEnd $d1
                    $speed=NTA-WindowSpeed $Rows $i0 $i1
                    # For a shared/custom boundary use an instantaneous-but-robust 3-sample median.
                    # A native corner below overrides entry speed with the exact native Drift start.
                    $entryBoundary=NDA-MedianBoundarySpeed $Rows $i0 $RowStart $RowEnd
                    $exitBoundary=NDA-MedianBoundarySpeed $Rows $i1 $RowStart $RowEnd
                    $p0=NSC-PointAtDistance -ControlPoints $ControlPoints -Distance $d0
                    $p1=NSC-PointAtDistance -ControlPoints $ControlPoints -Distance $d1
                }
            }
        }
    }
    $ready=($status-eq'comparable')
    $result=[pscustomobject][ordered]@{
        status=$status
        reason=$reason
        time_s=$(if($ready){[math]::Round(($t1-$t0),4)}else{$null})
        entry_speed_mps=$(if($ready-and-not[double]::IsNaN($entryBoundary)){[Math]::Round($entryBoundary,3)}else{$null})
        exit_window_speed_mps=$(if($ready-and-not[double]::IsNaN($exitBoundary)){[Math]::Round($exitBoundary,3)}else{$null})
        min_window_speed_mps=$(if($ready){$speed.min_mps}else{$null})
        average_speed_mps=$(if($ready){$speed.average_mps}else{$null})
        distance_m=$(if($ready){[math]::Round(($d1-$d0),3)}else{$null})
        start_distance_m=$(if($ready){[math]::Round($d0,3)}else{$null})
        end_distance_m=$(if($ready){[math]::Round($d1,3)}else{$null})
        start_t=$(if($ready){[math]::Round($t0,4)}else{$null})
        end_t=$(if($ready){[math]::Round($t1,4)}else{$null})
        start_point=$p0
        end_point=$p1
        drift_count=$null
        drift_duration_s=$null
        drift_distance_m=$null
        inter_drift_gap_distance_m=$null
        recovery_distance_m=$null
        total_distance_m=$null
        exit_speed_mps=$null
        min_corner_speed_mps=$null
        recovery_available=$null
        recovery_end_reason=$null
        recovery_end_t=$null
        recovery_metric_end_t=$null
        recovery_metric_source=$null
        exit_speed_source=$null
        segment_index=$null
        row_start=$i0
        row_end=$i1
    }
    if(-not $ready-or$null-eq$Corner){ return $result }
    $seg=$Corner.segment
    $result.segment_index=NAS-IntOrNull (NAS-Prop $seg 'segment_index')
    $result.recovery_available=[bool](NAS-Prop $seg 'recovery_available')
    $result.recovery_end_reason=[string](NAS-Prop $seg 'recovery_stop_reason')
    $result.recovery_end_t=NAS-Num (NAS-Prop $seg 'recovery_end_t')
    $result.drift_count=NAS-IntOrNull (NAS-Prop $seg 'drift_count')
    $result.drift_duration_s=NAS-Num (NAS-Prop $seg 'drift_duration_s')
    # native Drift-active distance: sum over the segment's own native Drift intervals, so a merged
    # segment reports the distance actually driven while a Drift was active - the merge gap is not
    # counted as drift distance.
    $active=0.0;$activeOk=$true
    foreach($iv in @(NAS-Prop $seg 'drift_intervals')){
        $a=NTA-LapDistanceAtTime $Rows $RowStart $RowEnd (NAS-Num (NAS-Prop $iv 'start_t'))
        $b=NTA-LapDistanceAtTime $Rows $RowStart $RowEnd (NAS-Num (NAS-Prop $iv 'end_t'))
        if($null-eq$a-or$null-eq$b){ $activeOk=$false; break }
        if($b-gt$a){ $active+=($b-$a) }
    }
    if($activeOk){ $result.drift_distance_m=[math]::Round($active,3) }
    # Diagnostic/test helper only (never a UI metric): the distance travelled BETWEEN the segment's
    # own native Drift intervals. A merged segment is drift + inter-drift gap + recovery, NOT
    # drift + recovery, and the published drift distance stays "native Drift-active distance".
    if($activeOk){
        $ivs=@(NAS-Prop $seg 'drift_intervals')
        if($ivs.Count-gt1){
            $firstStart=NTA-LapDistanceAtTime $Rows $RowStart $RowEnd (NAS-Num (NAS-Prop $ivs[0] 'start_t'))
            $lastEnd=NTA-LapDistanceAtTime $Rows $RowStart $RowEnd (NAS-Num (NAS-Prop $ivs[$ivs.Count-1] 'end_t'))
            if($null-ne$firstStart-and$null-ne$lastEnd){
                $gap=[math]::Round((($lastEnd-$firstStart)-$active),3)
                if($gap-lt0.0){$gap=0.0}
                $result.inter_drift_gap_distance_m=$gap
            }
        } else { $result.inter_drift_gap_distance_m=0.0 }
    }
    $driftEndT=NAS-Num (NAS-Prop $seg 'drift_end_t')
    $nativeRecEndT=NAS-Num (NAS-Prop $seg 'recovery_end_t')
    $nextDriftT=NAS-Num (NAS-Prop $seg 'next_drift_start_t')
    $metricRecEndT=$nativeRecEndT
    $metricRecSource='native_segment_end'

    # Metric-only minimum tail. A local/native stream with an OBSERVABLE speed-effect table that
    # says "no code2001" stays at Drift end (this preserves the nitro-only / no-small-boost field
    # fix). When effect state is not observable at all, or a low-frequency shadow carries no
    # small-boost/nitro evidence, use the game's 0.25 s single-small-boost lifetime as the minimum
    # measurable exit tail. This does NOT change the segment, map line, common comparison window or
    # recovery ownership; it only prevents an unobservable single-spray exit from becoming 0 m.
    if(-not[bool]$result.recovery_available){
        $recovery=NAS-Prop $seg 'recovery'
        $evidence=NAS-Prop $recovery 'evidence'
        $smallCount=NAS-IntOrNull (NAS-Prop $evidence 'small_boost_candidate_count')
        $nitroCount=NAS-IntOrNull (NAS-Prop $evidence 'nitro_candidate_count')
        if($null-eq$smallCount){$smallCount=0}
        if($null-eq$nitroCount){$nitroCount=0}
        $unobservable=(-not$SpeedEffectStateAvailable)
        $lowFreqNoEffect=([string]$StreamRole-eq'network_low_frequency'-and$smallCount-eq0-and$nitroCount-eq0)
        if(($unobservable-or$lowFreqNoEffect)-and$null-ne$driftEndT){
            $metricRecEndT=$driftEndT+$script:NscMinimumSmallBoostTailS
            if($null-ne$nextDriftT-and$metricRecEndT-gt$nextDriftT){$metricRecEndT=$nextDriftT}
            if(@($Rows).Count-gt0){
                $lastRowIndex=@($Rows).Count-1
                $streamEnd=NAS-Num $Rows[$lastRowIndex].t
                if($null-ne$streamEnd-and$metricRecEndT-gt$streamEnd){$metricRecEndT=$streamEnd}
            }
            if($metricRecEndT-gt$driftEndT+1e-6){$metricRecSource='gameplay_min_small_boost_tail_0p25s'}
            else{$metricRecEndT=$driftEndT;$metricRecSource='native_drift_end_no_tail'}
        } else {
            $metricRecEndT=$driftEndT
            $metricRecSource='native_drift_end_no_tail'
        }
    } elseif($null-ne$nativeRecEndT) {
        $metricRecSource='native_small_boost_recovery_end'
    }
    $result.recovery_metric_end_t=NAS-Round $metricRecEndT 4
    $result.recovery_metric_source=$metricRecSource

    # Recovery metrics are measured on THIS SIDE's own semantic time axis. They intentionally do
    # not use d0/d1 or any mapped shared-space boundary. Extend only the row search bound needed to
    # reach this side's own metric end (e.g. a 0.25 s low-frequency fallback across a lap edge).
    $metricRowEnd=$RowEnd
    if($null-ne$metricRecEndT-and@($Rows).Count-gt0){
        $ri=NTA-RowIndexAtTime $Rows $RowStart (@($Rows).Count-1) $metricRecEndT
        if($ri-gt$metricRowEnd){$metricRowEnd=$ri}
    }
    $dDriftEnd=NTA-LapDistanceAtTime $Rows $RowStart $metricRowEnd $driftEndT
    $dMetricRecEnd=NTA-LapDistanceAtTime $Rows $RowStart $metricRowEnd $metricRecEndT
    $dSegStart=NTA-LapDistanceAtTime $Rows $RowStart $metricRowEnd (NAS-Num (NAS-Prop $seg 'start_t'))
    if($null-ne$dDriftEnd-and$null-ne$dMetricRecEnd-and$dMetricRecEnd-ge$dDriftEnd){ $result.recovery_distance_m=[math]::Round(($dMetricRecEnd-$dDriftEnd),3) }
    if($null-ne$dSegStart-and$null-ne$dMetricRecEnd-and$dMetricRecEnd-ge$dSegStart){ $result.total_distance_m=[math]::Round(($dMetricRecEnd-$dSegStart),3) }

    # Entry speed remains the native Drift-start 3-sample median. Minimum corner speed remains the
    # true minimum over the native Drift span. "Exit speed" is a different semantic: the FASTEST
    # measured moment from final Drift end through this side's own small-boost recovery end. Nitro
    # may overlap and influence the real speed, but it can never extend the measurement window.
    $iDriftStart=NTA-RowIndexAtTime $Rows $RowStart $metricRowEnd (NAS-Num (NAS-Prop $seg 'start_t'))
    $iDriftEnd=NTA-RowIndexAtTime $Rows $RowStart $metricRowEnd $driftEndT
    if($iDriftStart-ge0-and$iDriftEnd-ge$iDriftStart){
        $cornerSpeed=NTA-WindowSpeed $Rows $iDriftStart $iDriftEnd
        $nativeEntry=NDA-MedianBoundarySpeed $Rows $iDriftStart $RowStart $metricRowEnd
        if(-not[double]::IsNaN($nativeEntry)){ $result.entry_speed_mps=[Math]::Round($nativeEntry,3) }
        $result.min_corner_speed_mps=$cornerSpeed.min_mps
        if($null-ne$metricRecEndT-and$null-ne$driftEndT-and$metricRecEndT-gt$driftEndT+1e-6){
            $peakExit=NSC-MaxSpeedBetweenTimes -Rows $Rows -StartT $driftEndT -EndT $metricRecEndT -Low $RowStart -High $metricRowEnd
            if($null-ne$peakExit){
                $result.exit_speed_mps=[Math]::Round([double]$peakExit,3)
                $result.exit_speed_source='own_recovery_window_peak'
            }
        }
        if($null-eq$result.exit_speed_mps){
            $nativeExit=NDA-MedianBoundarySpeed $Rows $iDriftEnd $RowStart $metricRowEnd
            if(-not[double]::IsNaN($nativeExit)){ $result.exit_speed_mps=[Math]::Round($nativeExit,3);$result.exit_speed_source='native_drift_end_median_fallback' }
        }
    }
    return $result
}

# --- the published comparison contract -------------------------------------------------------

# Build one symmetric A/B comparison from two prepared sides.
#
# Side shape (all properties optional except `key`):
#   key               canonical ordering key (content-derived; e.g. sha16 + stream id + lap)
#   label             display label, echoed only
#   resource_map_id / game_map_id / map_name / map_name_key   identity gate inputs
#   map_authority     'authoritative' | 'unresolved'
#   segments          this lap's NAS segments (from NAS-BuildContract laps[].segments)
#   rows              typed production telemetry rows
#   lap_start_i / lap_end_i   row window of the requested lap
#   lap_end_t         the lap's own end time (used only to extend the row window for a cross-lap tail)
function NSC-BuildComparison {
    param(
        [Parameter(Mandatory=$true)][object]$SubjectA,
        [Parameter(Mandatory=$true)][object]$SubjectB,
        [string]$LabelA='A',
        [string]$LabelB='B',
        [string]$Mode='auto',
        # Custom path: {side_key=<canonical key of the side the interval was drawn on>; start_d; end_d}
        [object]$CustomInterval=$null,
        [double]$MaxSeparationM=30.0,
        [double]$MatchedSeparationM=15.0,
        [double]$MaxHeadingDeltaDeg=80.0,
        [double]$BandProgress=0.06,
        [double]$MaxGapProgress=0.03,
        [int]$MaxControlPoints=180,
        [double]$AnchorToleranceProgress=0.02,
        [double]$MinCoverage=0.2
    )
    $gate=NSC-IdentityGate -SideA $SubjectA -SideB $SubjectB
    $base=[ordered]@{
        schema_version=4
        contract=$script:NscContractName
        architecture='native_first_v1'
        authority='replay_native_action_object_drift_table_v3 + replay_native_action_object_speed_effect_table_v2 + official world XY driven trajectory'
        derived=$true
        mode=$Mode
        delta_rule='delta = subject - baseline; positive means the subject needed more time / travelled further'
        window_rule='paired corners publish two canonical intervals with one shared start: core ends at the earlier mapped natural recovery end; final ends at the later mapped natural recovery end, hard-cut by the next independent Drift. A->B and B->A use the SAME intervals and every signed result negates'
        swap_contract='compare(A,B) and compare(B,A) publish identical world intervals; delta(B,A) = -delta(A,B)'
        subject=[ordered]@{label=$LabelA;key=[string](NAS-Prop $SubjectA 'key');role='subject'}
        baseline=[ordered]@{label=$LabelB;key=[string](NAS-Prop $SubjectB 'key');role='baseline'}
        gate=$gate
        status='comparison_unavailable'
        reason=''
        correspondence=$null
        coverage=[ordered]@{subject=$null;baseline=$null;combined=$null;minimum_required=$MinCoverage}
        window_count=0
        matched_window_count=0
        unpaired_window_count=0
        windows=@()
        metrics=@(NSC-MetricDefinitions)
        limits=[ordered]@{
            no_score=$true
            no_grade=$true
            time_never_in_correspondence_cost=$true
            native_actions_are_never_copied_between_sides=$true
            native_corner_metrics_ignore_shared_route_boundaries=$true
            paired_primary_time_stops_at_shorter_natural_recovery=$true
            paired_final_time_extends_to_longer_natural_recovery=$true
            final_time_never_crosses_next_independent_drift=$true
            earlier_drift_entry_is_preserved_in_primary_time=$true
            basemap_availability_is_not_a_prerequisite=$true
            unmatched_stays_unmatched=$true
        }
    }
    if(-not [bool]$gate.comparable){
        $base.reason=[string]$gate.status
        return [pscustomobject]$base
    }
    if([string]::IsNullOrWhiteSpace([string](NAS-Prop $SubjectA 'key')) -or [string]::IsNullOrWhiteSpace([string](NAS-Prop $SubjectB 'key'))){
        $base.reason='both sides must publish a canonical ordering key'
        return [pscustomobject]$base
    }

    # 1. canonical order - the ONLY place sign and pairing are decided
    $keyA=[string](NAS-Prop $SubjectA 'key')
    $keyB=[string](NAS-Prop $SubjectB 'key')
    $xAIsSubject=$true
    $X=$SubjectA;$Y=$SubjectB
    if([string]::CompareOrdinal($keyA,$keyB)-gt0){ $xAIsSubject=$false;$X=$SubjectB;$Y=$SubjectA }
    $base.canonical_order=[ordered]@{first=[string](NAS-Prop $X 'key');second=[string](NAS-Prop $Y 'key')}

    # 2. extend each side's row window to the end of its own segment tails (a cross-lap tail is part
    #    of its segment and must be measurable; the lap boundary never truncates it)
    $xWin=NSC-ExtendedRowWindow -Side $X
    $yWin=NSC-ExtendedRowWindow -Side $Y
    if(-not [bool]$xWin.ready-or-not [bool]$yWin.ready){
        $base.reason='one side has no measurable row window'
        return [pscustomobject]$base
    }
    $cpX=@(NTA-TrajectoryControlPoints $X.rows $xWin.start_i $xWin.end_i -MaxPoints $MaxControlPoints)
    $cpY=@(NTA-TrajectoryControlPoints $Y.rows $yWin.start_i $yWin.end_i -MaxPoints $MaxControlPoints)
    $corr=NTA-SharedCorrespondence -Subject $cpX -Baseline $cpY -MaxSeparationM $MaxSeparationM -MaxHeadingDeltaDeg $MaxHeadingDeltaDeg -BandProgress $BandProgress -MaxGapProgress $MaxGapProgress
    $base.correspondence=[pscustomobject][ordered]@{
        algorithm='banded_monotone_spatial_alignment_v1'
        status=[string]$corr.status
        pair_count=[int]$corr.stats.pair_count
        component_count=$(if($null-ne$corr.stats.component_count){[int]$corr.stats.component_count}else{0})
        break_count=$(if($null-ne$corr.stats.break_count){[int]$corr.stats.break_count}else{0})
        mean_separation_m=$corr.stats.mean_separation_m
        max_separation_m=$(if($corr.status-eq'ready'){$corr.stats.max_separation_m}else{$MaxSeparationM})
        max_heading_delta_deg=$(if($corr.status-eq'ready'){$corr.stats.max_heading_delta_deg}else{$MaxHeadingDeltaDeg})
        time_in_cost=$false
        subject_control_points=@($cpX).Count
        baseline_control_points=@($cpY).Count
    }
    if([string]$corr.status-ne'ready'){
        $base.reason=[string]$corr.status
        return [pscustomobject]$base
    }
    $pairs=@($corr.pairs)

    # 3. corner anchors on the shared axis, then the monotone pairing
    $anchorsX=@(NSC-CornerAnchors -Segments @(NAS-Prop $X 'segments') -ControlPoints $cpX -Pairs $pairs -Rows $X.rows -RowStart $xWin.start_i -RowEnd $xWin.end_i -Side 'a')
    $anchorsY=@(NSC-CornerAnchors -Segments @(NAS-Prop $Y 'segments') -ControlPoints $cpY -Pairs $pairs -Rows $Y.rows -RowStart $yWin.start_i -RowEnd $yWin.end_i -Side 'b')
    $cornerPairs=@(NSC-PairCorners -Left $anchorsX -Right $anchorsY -AnchorToleranceProgress $AnchorToleranceProgress)

    # 4. windows
    $shared=$null
    if($Mode-eq'custom'){
        if($null-eq$CustomInterval){ $base.reason='custom mode requires an interval'; return [pscustomobject]$base }
        $sideKey=[string](NAS-Prop $CustomInterval 'side_key')
        if($sideKey-eq[string](NAS-Prop $X 'key')){
            $u0=NSC-ProgressOfDistance -ControlPoints $cpX -Distance (NAS-Num (NAS-Prop $CustomInterval 'start_d'))
            $u1=NSC-ProgressOfDistance -ControlPoints $cpX -Distance (NAS-Num (NAS-Prop $CustomInterval 'end_d'))
            $s0=NTA-SideProgressToShared -Pairs $pairs -Side 'a' -U $u0
            $s1=NTA-SideProgressToShared -Pairs $pairs -Side 'a' -U $u1
        } elseif($sideKey-eq[string](NAS-Prop $Y 'key')){
            $u0=NSC-ProgressOfDistance -ControlPoints $cpY -Distance (NAS-Num (NAS-Prop $CustomInterval 'start_d'))
            $u1=NSC-ProgressOfDistance -ControlPoints $cpY -Distance (NAS-Num (NAS-Prop $CustomInterval 'end_d'))
            $s0=NTA-SideProgressToShared -Pairs $pairs -Side 'b' -U $u0
            $s1=NTA-SideProgressToShared -Pairs $pairs -Side 'b' -U $u1
        } else {
            $base.reason='custom interval side is not one of the two compared sides'
            return [pscustomobject]$base
        }
        if($null-eq$s0-or$null-eq$s1-or$s1-le$s0){
            $base.reason='custom interval does not map onto the shared correspondence'
            return [pscustomobject]$base
        }
        $shared=[pscustomobject]@{s_start=[math]::Min($s0,$s1);s_end=[math]::Max($s0,$s1)}
    }
    $windows=@(NSC-BuildWindows -CornerPairs $cornerPairs -AnchorsLeft $anchorsX -AnchorsRight $anchorsY -SharedInterval $shared)

    # 5. measure both sides over each window and publish the signed metrics
    $out=New-Object System.Collections.Generic.List[object]
    $subjectSpan=0.0;$baselineSpan=0.0;$combinedSpan=0.0
    foreach($win in $windows){
        $measureX=NSC-MeasureSide -Window $win -Corner $win.subject_corner -ControlPoints $cpX -Pairs $pairs -Rows $X.rows -RowStart $xWin.start_i -RowEnd $xWin.end_i -Side 'a' -StreamRole ([string](NAS-Prop $X 'stream_role')) -SpeedEffectStateAvailable ([bool](NAS-Prop $X 'speed_effect_state_available'))
        $measureY=NSC-MeasureSide -Window $win -Corner $win.baseline_corner -ControlPoints $cpY -Pairs $pairs -Rows $Y.rows -RowStart $yWin.start_i -RowEnd $yWin.end_i -Side 'b' -StreamRole ([string](NAS-Prop $Y 'stream_role')) -SpeedEffectStateAvailable ([bool](NAS-Prop $Y 'speed_effect_state_available'))
        # FINAL net window: same spatial start as core, but continue to the later natural recovery
        # endpoint. Measure it as pure shared-space crossing time (Corner=$null) so own-side native
        # speed/distance metrics remain independent of this union boundary.
        $finalWin=[pscustomobject]@{s_start=[double]$win.s_start;s_end=[double]$win.final_s_end}
        $finalX=NSC-MeasureSide -Window $finalWin -Corner $null -ControlPoints $cpX -Pairs $pairs -Rows $X.rows -RowStart $xWin.start_i -RowEnd $xWin.end_i -Side 'a' -StreamRole ([string](NAS-Prop $X 'stream_role')) -SpeedEffectStateAvailable ([bool](NAS-Prop $X 'speed_effect_state_available'))
        $finalY=NSC-MeasureSide -Window $finalWin -Corner $null -ControlPoints $cpY -Pairs $pairs -Rows $Y.rows -RowStart $yWin.start_i -RowEnd $yWin.end_i -Side 'b' -StreamRole ([string](NAS-Prop $Y 'stream_role')) -SpeedEffectStateAvailable ([bool](NAS-Prop $Y 'speed_effect_state_available'))
        $mSubject=$(if($xAIsSubject){$measureX}else{$measureY})
        $mBaseline=$(if($xAIsSubject){$measureY}else{$measureX})
        $fSubject=$(if($xAIsSubject){$finalX}else{$finalY})
        $fBaseline=$(if($xAIsSubject){$finalY}else{$finalX})
        $cSubject=$(if($xAIsSubject){$win.subject_corner}else{$win.baseline_corner})
        $cBaseline=$(if($xAIsSubject){$win.baseline_corner}else{$win.subject_corner})
        $status='comparable'
        $reason=''
        if([string]$measureX.status-ne'comparable'-or [string]$measureY.status-ne'comparable'){
            $status='not_comparable'
            $reason=$(if([string]$measureX.status-ne'comparable'){[string]$measureX.reason}else{[string]$measureY.reason})
        } else {
            $subjectSpan+=[double]$measureX.distance_m
            $baselineSpan+=[double]$measureY.distance_m
            $combinedSpan+=[double]$win.s_span
        }
        $metricList=New-Object System.Collections.Generic.List[object]
        $tvTime=NSC-MetricValue $mSubject.time_s $mBaseline.time_s
        $metricList.Add([pscustomobject][ordered]@{id='time_s';value=$tvTime;definition=(NSC-DefaultMetricDefinition 'time_s').definition;authority=(NSC-DefaultMetricDefinition 'time_s').authority;unit='s'})
        $metricList.Add([pscustomobject][ordered]@{id='entry_speed_mps';value=(NSC-MetricValue $mSubject.entry_speed_mps $mBaseline.entry_speed_mps);definition=(NSC-DefaultMetricDefinition 'entry_speed_mps').definition;authority=(NSC-DefaultMetricDefinition 'entry_speed_mps').authority;unit='m/s'})
        $metricList.Add([pscustomobject][ordered]@{id='min_corner_speed_mps';value=(NSC-MetricValue $mSubject.min_corner_speed_mps $mBaseline.min_corner_speed_mps);definition=(NSC-DefaultMetricDefinition 'min_corner_speed_mps').definition;authority=(NSC-DefaultMetricDefinition 'min_corner_speed_mps').authority;unit='m/s'})
        $metricList.Add([pscustomobject][ordered]@{id='exit_speed_mps';value=(NSC-MetricValue $mSubject.exit_speed_mps $mBaseline.exit_speed_mps);definition=(NSC-DefaultMetricDefinition 'exit_speed_mps').definition;authority=(NSC-DefaultMetricDefinition 'exit_speed_mps').authority;unit='m/s'})
        $metricList.Add([pscustomobject][ordered]@{id='drift_distance_m';value=(NSC-MetricValue $mSubject.drift_distance_m $mBaseline.drift_distance_m);definition=(NSC-DefaultMetricDefinition 'drift_distance_m').definition;authority=(NSC-DefaultMetricDefinition 'drift_distance_m').authority;unit='m'})
        $metricList.Add([pscustomobject][ordered]@{id='recovery_distance_m';value=(NSC-MetricValue $mSubject.recovery_distance_m $mBaseline.recovery_distance_m);definition=(NSC-DefaultMetricDefinition 'recovery_distance_m').definition;authority=(NSC-DefaultMetricDefinition 'recovery_distance_m').authority;unit='m'})
        $metricList.Add([pscustomobject][ordered]@{id='total_distance_m';value=(NSC-MetricValue $mSubject.total_distance_m $mBaseline.total_distance_m);definition=(NSC-DefaultMetricDefinition 'total_distance_m').definition;authority=(NSC-DefaultMetricDefinition 'total_distance_m').authority;unit='m'})
        $timeDelta=NAS-Num $tvTime.delta
        $direction='unavailable'
        if($null-ne$timeDelta){
            $direction='equal'
            if([math]::Abs($timeDelta)-gt0.0005){ $direction=$(if($timeDelta-gt0){'slower'}else{'faster'}) }
        }
        $finalSubjectT=$(if([string]$fSubject.status-eq'comparable'){NAS-Num $fSubject.time_s}else{$null})
        $finalBaselineT=$(if([string]$fBaseline.status-eq'comparable'){NAS-Num $fBaseline.time_s}else{$null})
        $finalDelta=$null;$finalDirection='unavailable';$subjectGain=$null;$gainDirection='unavailable'
        if($null-ne$finalSubjectT-and$null-ne$finalBaselineT){
            $finalDelta=[math]::Round(($finalSubjectT-$finalBaselineT),4)
            $finalDirection='equal'
            if([math]::Abs($finalDelta)-gt0.0005){$finalDirection=$(if($finalDelta-gt0){'slower'}else{'faster'})}
            if($null-ne$timeDelta){
                # Positive = subject gained time versus baseline during the recovery-strategy tail.
                # core_delta - final_delta = baseline_tail_time - subject_tail_time.
                $subjectGain=[math]::Round(($timeDelta-$finalDelta),4)
                $gainDirection='equal'
                if([math]::Abs($subjectGain)-gt0.0005){$gainDirection=$(if($subjectGain-gt0){'subject_gain'}else{'subject_loss'})}
            }
        }
        $out.Add([pscustomobject][ordered]@{
            window_id=[string]$win.window_id
            status=$status
            reason=$reason
            source=[string]$win.source
            corner_paired=[bool]$win.paired
            corner=[ordered]@{
                subject_segment_index=$(if($null-ne$cSubject){NAS-IntOrNull (NAS-Prop $cSubject.segment 'segment_index')}else{$null})
                baseline_segment_index=$(if($null-ne$cBaseline){NAS-IntOrNull (NAS-Prop $cBaseline.segment 'segment_index')}else{$null})
                subject_drift_count=$(if($null-ne$cSubject){NAS-IntOrNull (NAS-Prop $cSubject.segment 'drift_count')}else{$null})
                baseline_drift_count=$(if($null-ne$cBaseline){NAS-IntOrNull (NAS-Prop $cBaseline.segment 'drift_count')}else{$null})
                # The native interval that identifies this corner on each side. A consumer that already
                # holds its own automatic segment list joins on the native Drift start, never on an
                # index and never on a timestamp ratio.
                subject_start_t=$(if($null-ne$cSubject){NAS-Round $cSubject.start_t 4}else{$null})
                baseline_start_t=$(if($null-ne$cBaseline){NAS-Round $cBaseline.start_t 4}else{$null})
                subject_drift_end_t=$(if($null-ne$cSubject){NAS-Round $cSubject.drift_end_t 4}else{$null})
                baseline_drift_end_t=$(if($null-ne$cBaseline){NAS-Round $cBaseline.drift_end_t 4}else{$null})
                subject_recovery_end_t=$(if($null-ne$cSubject){NAS-Round $cSubject.recovery_end_t 4}else{$null})
                baseline_recovery_end_t=$(if($null-ne$cBaseline){NAS-Round $cBaseline.recovery_end_t 4}else{$null})
            }
            space=[ordered]@{
                shared_start=$win.s_start
                shared_end=$win.s_end
                shared_span=$win.s_span
                final_shared_end=$win.final_s_end
                final_shared_span=$win.final_s_span
                hard_cut_applied=[bool]$win.hard_cut_applied
                final_hard_cut_applied=[bool]$win.final_hard_cut_applied
                hard_cut_t=$win.hard_cut_t
                core_window_rule=$(if([bool]$win.paired){'earlier mapped Drift start -> earlier mapped natural recovery end'}else{'single available natural corner interval'})
                final_window_rule=$(if([bool]$win.paired){'same shared start -> later mapped natural recovery end; hard-cut by next independent Drift'}else{'same as single available natural corner interval'})
                natural_bounds=$win.natural_bounds
                subject=[ordered]@{
                    distance_m=$mSubject.distance_m
                    start_distance_m=$mSubject.start_distance_m
                    end_distance_m=$mSubject.end_distance_m
                    start=$mSubject.start_point
                    end=$mSubject.end_point
                }
                baseline=[ordered]@{
                    distance_m=$mBaseline.distance_m
                    start_distance_m=$mBaseline.start_distance_m
                    end_distance_m=$mBaseline.end_distance_m
                    start=$mBaseline.start_point
                    end=$mBaseline.end_point
                }
            }
            # `time` remains the v1-v3 CORE alias for compatibility. New consumers should use
            # core_time + final_time + recovery_strategy explicitly.
            time=[ordered]@{subject_s=$mSubject.time_s;baseline_s=$mBaseline.time_s;delta_s=$timeDelta;direction=$direction}
            core_time=[ordered]@{subject_s=$mSubject.time_s;baseline_s=$mBaseline.time_s;delta_s=$timeDelta;direction=$direction}
            final_time=[ordered]@{subject_s=NAS-Round $finalSubjectT 4;baseline_s=NAS-Round $finalBaselineT 4;delta_s=$finalDelta;direction=$finalDirection;available=($null-ne$finalDelta)}
            recovery_strategy=[ordered]@{
                subject_tail_s=$(if($null-ne$finalSubjectT-and$null-ne$mSubject.time_s){[math]::Round(($finalSubjectT-[double]$mSubject.time_s),4)}else{$null})
                baseline_tail_s=$(if($null-ne$finalBaselineT-and$null-ne$mBaseline.time_s){[math]::Round(($finalBaselineT-[double]$mBaseline.time_s),4)}else{$null})
                subject_net_gain_s=$subjectGain
                direction=$gainDirection
                definition='change in A-B time gap from core end to final end; positive subject_net_gain_s means subject gains time during the extra recovery-strategy span'
            }
            speed=[ordered]@{
                subject=[ordered]@{entry_mps=$mSubject.entry_speed_mps;min_mps=$mSubject.min_window_speed_mps;exit_window_mps=$mSubject.exit_window_speed_mps;average_mps=$mSubject.average_speed_mps}
                baseline=[ordered]@{entry_mps=$mBaseline.entry_speed_mps;min_mps=$mBaseline.min_window_speed_mps;exit_window_mps=$mBaseline.exit_window_speed_mps;average_mps=$mBaseline.average_speed_mps}
            }
            native=[ordered]@{
                subject=[ordered]@{segment_index=$mSubject.segment_index;drift_count=$mSubject.drift_count;drift_duration_s=$mSubject.drift_duration_s;drift_distance_m=$mSubject.drift_distance_m;inter_drift_gap_distance_m=$mSubject.inter_drift_gap_distance_m;recovery_distance_m=$mSubject.recovery_distance_m;total_distance_m=$mSubject.total_distance_m;exit_speed_mps=$mSubject.exit_speed_mps;min_corner_speed_mps=$mSubject.min_corner_speed_mps;recovery_end_t=$mSubject.recovery_end_t;recovery_end_reason=$mSubject.recovery_end_reason;recovery_available=$mSubject.recovery_available;recovery_metric_end_t=$mSubject.recovery_metric_end_t;recovery_metric_source=$mSubject.recovery_metric_source;exit_speed_source=$mSubject.exit_speed_source}
                baseline=[ordered]@{segment_index=$mBaseline.segment_index;drift_count=$mBaseline.drift_count;drift_duration_s=$mBaseline.drift_duration_s;drift_distance_m=$mBaseline.drift_distance_m;inter_drift_gap_distance_m=$mBaseline.inter_drift_gap_distance_m;recovery_distance_m=$mBaseline.recovery_distance_m;total_distance_m=$mBaseline.total_distance_m;exit_speed_mps=$mBaseline.exit_speed_mps;min_corner_speed_mps=$mBaseline.min_corner_speed_mps;recovery_end_t=$mBaseline.recovery_end_t;recovery_end_reason=$mBaseline.recovery_end_reason;recovery_available=$mBaseline.recovery_available;recovery_metric_end_t=$mBaseline.recovery_metric_end_t;recovery_metric_source=$mBaseline.recovery_metric_source;exit_speed_source=$mBaseline.exit_speed_source}
            }
            metrics=@($metricList.ToArray())
        })
    }

    for($k=0;$k-lt$out.Count;$k++){ $out[$k].window_id=('S{0:D2}' -f ($k+1)) }
    $matched=@($out.ToArray() | Where-Object { [string]$_.status -eq 'comparable' }).Count
    $unpaired=@($out.ToArray() | Where-Object { [string]$_.status -eq 'comparable' -and -not [bool]$_.corner_paired }).Count
    $corrSpan=0.0
    if($pairs.Count-gt1){ $corrSpan=[math]::Abs([double]$pairs[$pairs.Count-1].s-[double]$pairs[0].s) }
    # Coverage is CORRESPONDENCE coverage (how much of the shorter driven route has an admissible
    # counterpart), not "how much of the route lies inside a comparison window": the window set only
    # covers the corners both sides actually drove, so a route-wide ratio would be meaningless.
    $coverageSubject=$null;$coverageBaseline=$null;$combined=$null
    if(@($cpX).Count-gt0){ $coverageSubject=[math]::Round(([double]$corr.stats.pair_count/[double]@($cpX).Count),4) }
    if(@($cpY).Count-gt0){ $coverageBaseline=[math]::Round(([double]$corr.stats.pair_count/[double]@($cpY).Count),4) }
    if($null-ne$coverageSubject-and$null-ne$coverageBaseline){ $combined=[math]::Min([double]$coverageSubject,[double]$coverageBaseline) }
    $windowCoverage=$null
    if($corrSpan-gt1e-9){ $windowCoverage=[math]::Round(($combinedSpan/$corrSpan),4) }
    $base.coverage=[ordered]@{subject=$coverageSubject;baseline=$coverageBaseline;combined=$combined;minimum_required=$MinCoverage;window_span_ratio=$windowCoverage;definition='matched correspondence pairs over the shorter side control-point count; window_span_ratio is reported separately and is not a gate'}
    $base.window_count=$out.Count
    $base.matched_window_count=$matched
    $base.unpaired_window_count=$unpaired
    $base.windows=@($out.ToArray())
    $base.status='ready'
    $base.reason='same authoritative map identity; comparison windows built in canonical side order'
    if($out.Count-eq0){
        $base.status='comparison_unavailable'
        $base.reason='no comparable shared world interval'
    } elseif($null-ne$combined-and$combined-lt$MinCoverage){
        $base.status='degraded_low_correspondence_coverage'
        $base.reason='shared correspondence coverage below the minimum'
    }
    return [pscustomobject]$base
}

# Extend one side's lap row window to cover its own segment tails (a cross-lap segment tail is part
# of that segment and must be measurable).
function NSC-ExtendedRowWindow {
    param([Parameter(Mandatory=$true)][object]$Side)
    $rows=@(NAS-Prop $Side 'rows')
    $ls=NAS-IntOrNull (NAS-Prop $Side 'lap_start_i')
    $le=NAS-IntOrNull (NAS-Prop $Side 'lap_end_i')
    if($rows.Count-lt2-or$null-eq$ls-or$null-eq$le){ return [pscustomobject]@{ready=$false;start_i=0;end_i=0} }
    $ls=[math]::Max(0,[math]::Min($rows.Count-1,$ls))
    $le=[math]::Max($ls,[math]::Min($rows.Count-1,$le))
    $tailEnd=$null
    foreach($seg in @(NAS-Prop $Side 'segments')){
        $v=NAS-Num (NAS-Prop $seg 'recovery_end_t')
        if($null-ne$v-and($null-eq$tailEnd-or$v-gt$tailEnd)){ $tailEnd=$v }
    }
    if($null-ne$tailEnd){
        $i=NTA-RowIndexAtTime $rows $ls ($rows.Count-1) $tailEnd
        if($i-gt$le){ $le=$i }
    }
    return [pscustomobject]@{ready=$true;start_i=$ls;end_i=$le}
}
