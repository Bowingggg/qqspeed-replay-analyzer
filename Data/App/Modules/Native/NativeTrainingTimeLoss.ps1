# Native Training Analysis v1.1 - shared-window time-loss decomposition.
#
# DERIVED, NON-AUTHORITATIVE. Everything here is a MEASUREMENT over facts the native pipeline already
# published (native Drift / Action Event / speed-effect tables + official-map spatial sections).
#
# ================================ DELTA CONTRACT (the only one) ================================
#
#     delta = subject - baseline
#
#     delta > 0   ->  the subject is SLOWER / larger / more
#     delta < 0   ->  the subject is FASTER / smaller / less
#     delta == 0  ->  the same
#
# For time: `+0.420 s` is a time LOSS; `-0.180 s` is a time GAIN. There is exactly ONE direction in
# the whole product - lap totals, comparison windows, matched and unmatched windows, non-comparison
# stretches, residual, speed, drift duration, boost latency, route distance, observations, JSON and
# the interface all use `subject - baseline`. An earlier revision published the outer lap total as
# `subject - baseline` while the decomposition used `baseline - subject`; that inversion is what this
# milestone removes, and it is pinned by Tests/Smoke-TrainingAnalysis.ps1 (Case A/B/C/D).
#
# ======================== RECONCILIATION over SHARED COMPARISON WINDOWS ========================
#
# The decomposition is NO LONGER "lap A's own sections versus lap B's own independently detected
# sections". Two independent recordings (or two laps of one recording) place their section boundaries
# differently, so pairing them after the fact leaks a large, meaningless residual. Instead:
#
#   1. a SHARED SPATIAL CORRESPONDENCE is built from the two real driven trajectories (see
#      NativeTrainingSections.ps1: monotonic, order-preserving, heading-compatible, bounded,
#      fail-closed, and with time deliberately excluded from the cost);
#   2. the correspondence defines a SHARED PROGRESS on which ONE boundary set is built from the union
#      of BOTH sides' section boundaries;
#   3. every comparison window therefore has the SAME boundary semantics on both sides, and each side
#      measures its own elapsed time between those shared boundaries.
#
#     total_delta            = subject_lap_time - baseline_lap_time
#     matched_delta          = sum over windows whose correspondence is `matched`
#     unmatched_delta        = sum over windows whose correspondence is ambiguous / insufficient
#     non_comparison_delta   = (subject time OUTSIDE every window) - (baseline time outside every window)
#     residual               = total_delta - matched_delta - unmatched_delta - non_comparison_delta
#
# The residual is not a bookkeeping fudge: it is exactly the difference between two ways of
# measuring the same laps. The comparable stretches are measured with sub-sample interpolation,
# while a non-comparison stretch - the part of a lap the two routes do not share - is published as a
# whole telemetry-row span, because that is the only resolution at which it can be inspected row by
# row. The residual is that quantisation difference and is bounded by the number of non-comparison
# boundaries times the stream's own sample interval. The tolerance is DERIVED from those two measured
# quantities, never chosen for looking comfortable.

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

# THE delta. `Subject` first, `Baseline` second; the result is `subject - baseline`.
function NTA-Delta($Subject,$Baseline) {
    if($null-eq$Subject-or$null-eq$Baseline){return $null}
    $a=NDA-ToDouble $Subject ([double]::NaN);$b=NDA-ToDouble $Baseline ([double]::NaN)
    if([double]::IsNaN($a)-or[double]::IsNaN($b)){return $null}
    return [Math]::Round(($a-$b),4)
}

# `slower` when the subject needed more time, `faster` when it needed less. Never a score, never a
# grade, and never a claim about why.
function NTA-Direction($DeltaSeconds) {
    if($null-eq$DeltaSeconds){return 'unavailable'}
    $d=[double]$DeltaSeconds
    if([Math]::Abs($d)-lt0.0005){return 'equal'}
    if($d-gt0){return 'slower'}
    return 'faster'
}
function NTA-Classification($DeltaSeconds) {
    $dir=NTA-Direction $DeltaSeconds
    if($dir-eq'slower'){return 'loss'}
    if($dir-eq'faster'){return 'gain'}
    if($dir-eq'equal'){return 'equal'}
    return 'unavailable'
}
function NTA-DirectionWord($DeltaSeconds) {
    $dir=NTA-Direction $DeltaSeconds
    if($dir-eq'slower'){return '慢'}
    if($dir-eq'faster'){return '快'}
    if($dir-eq'equal'){return '持平'}
    return '不可用'
}

# Index of the telemetry row nearest to a time, searched inside one lap's own span.
function NTA-RowIndexAtTime([object[]]$Rows,[int]$LapStart,[int]$LapEnd,[double]$T) {
    $n=@($Rows).Count
    if($n-eq0){return -1}
    $ls=[Math]::Max(0,$LapStart);$le=[Math]::Min($n-1,$LapEnd)
    if($le-le$ls){return $ls}
    return (NDA-NearestTimeIndex $Rows $ls $le $T)
}

# Row quantisation of a time: the telemetry sample that carries it. Used ONLY for the non-comparison
# stretches, which are published as whole row spans.
function NTA-RowTimeAt([object[]]$Rows,[int]$LapStart,[int]$LapEnd,[double]$T) {
    $i=NTA-RowIndexAtTime $Rows $LapStart $LapEnd $T
    if($i-lt0){return $null}
    return [double]$Rows[$i].t
}

# Index of the telemetry row whose measured cumulative distance brackets a distance.
function NTA-RowIndexAtDistance([object[]]$Rows,[int]$LapStart,[int]$LapEnd,[double]$D) {
    $n=@($Rows).Count
    if($n-eq0){return -1}
    $s=[Math]::Max(0,$LapStart);$e=[Math]::Min($n-1,$LapEnd)
    if($e-le$s){return $s}
    if($D-le[double]$Rows[$s].distance){return $s}
    if($D-ge[double]$Rows[$e].distance){return $e}
    $lo=$s;$hi=$e
    while(($hi-$lo)-gt1){
        $m=[int](($lo+$hi)/2)
        if([double]$Rows[$m].distance-le$D){$lo=$m}else{$hi=$m}
    }
    return $lo
}

# Sub-sample interpolated telemetry time at a measured cumulative distance inside one lap.
function NTA-TimeAtLapDistance([object[]]$Rows,[int]$LapStart,[int]$LapEnd,[double]$D) {
    $i=NTA-RowIndexAtDistance $Rows $LapStart $LapEnd $D
    if($i-lt0){return $null}
    $n=@($Rows).Count
    $j=[Math]::Min($n-1,$i+1)
    $d0=[double]$Rows[$i].distance;$d1=[double]$Rows[$j].distance
    if($d1-$d0-le1e-9){return [double]$Rows[$i].t}
    $f=($D-$d0)/($d1-$d0)
    if($f-lt0.0){$f=0.0}
    if($f-gt1.0){$f=1.0}
    return ([double]$Rows[$i].t+(([double]$Rows[$j].t-[double]$Rows[$i].t)*$f))
}

# Measured cumulative distance at a telemetry time inside one lap (rows are time ordered).
function NTA-LapDistanceAtTime([object[]]$Rows,[int]$LapStart,[int]$LapEnd,[double]$T) {
    $n=@($Rows).Count
    if($n-eq0){return $null}
    $s=[Math]::Max(0,$LapStart);$e=[Math]::Min($n-1,$LapEnd)
    if($e-lt$s){return $null}
    if($T-le[double]$Rows[$s].t){return [double]$Rows[$s].distance}
    if($T-ge[double]$Rows[$e].t){return [double]$Rows[$e].distance}
    $lo=$s;$hi=$e
    while(($hi-$lo)-gt1){
        $m=[int](($lo+$hi)/2)
        if([double]$Rows[$m].t-le$T){$lo=$m}else{$hi=$m}
    }
    $t0=[double]$Rows[$lo].t;$t1=[double]$Rows[$hi].t
    if($t1-$t0-le1e-9){return [double]$Rows[$lo].distance}
    $f=($T-$t0)/($t1-$t0)
    return ([double]$Rows[$lo].distance+(([double]$Rows[$hi].distance-[double]$Rows[$lo].distance)*$f))
}

# World position of a shared-progress boundary, interpolated along ONE window's own pair sequence.
# Shared progress alone carries no coordinates: `NTA-SharedProgressToSides` returns distances and
# progresses only, so the published window position has to come from the pairs themselves. Publishing
# a missing coordinate as 0.0 would be a fabricated position, so an unmappable boundary returns
# `$null` instead.
function NTA-PairPointAt {
    param([AllowEmptyCollection()][object[]]$Pairs=@(),[double]$S,[string]$Side='a')
    $p=@($Pairs)
    if($p.Count-lt1){ return $null }
    $pick={
        param($pair)
        if($Side-eq'b'){ return [pscustomobject]@{x=[double]$pair.b_x;y=[double]$pair.b_y} }
        return [pscustomobject]@{x=[double]$pair.a_x;y=[double]$pair.a_y}
    }
    if($S-le[double]$p[0].s+1e-9){ $v=& $pick $p[0]; return [ordered]@{x=[Math]::Round($v.x,3);y=[Math]::Round($v.y,3)} }
    if($S-ge[double]$p[$p.Count-1].s-1e-9){ $v=& $pick $p[$p.Count-1]; return [ordered]@{x=[Math]::Round($v.x,3);y=[Math]::Round($v.y,3)} }
    $lo=0;$hi=$p.Count-1
    while(($hi-$lo)-gt1){ $m=[int](($lo+$hi)/2); if([double]$p[$m].s-le$S){$lo=$m}else{$hi=$m} }
    $s0=[double]$p[$lo].s;$s1=[double]$p[$hi].s
    $a=& $pick $p[$lo];$b=& $pick $p[$hi]
    $f=0.0
    if($s1-$s0-gt1e-12){ $f=($S-$s0)/($s1-$s0) }
    return [ordered]@{x=[Math]::Round(($a.x+(($b.x-$a.x)*$f)),3);y=[Math]::Round(($a.y+(($b.y-$a.y)*$f)),3)}
}

# Speed statistics of one window: entry / min / exit / average.
function NTA-WindowSpeed([object[]]$Rows,[int]$From,[int]$To) {
    if($From-lt0-or$To-le$From){return [ordered]@{entry_mps=$null;min_mps=$null;exit_mps=$null;average_mps=$null}}
    $vals=New-Object System.Collections.Generic.List[double]
    for($i=$From;$i-le$To;$i++){
        if(-not[bool]$Rows[$i].pose_valid){continue}
        $v=[double]$Rows[$i].speed
        if(-not[double]::IsNaN($v)-and$v-ge0){$vals.Add($v)}
    }
    $entry=NDA-AverageEdgeSpeed $Rows $From $To $true
    $exit=NDA-AverageEdgeSpeed $Rows $From $To $false
    $minV=$null;$avgV=$null
    if($vals.Count-gt0){
        $minV=[double](($vals.ToArray()|Measure-Object -Minimum).Minimum)
        $avgV=[double](($vals.ToArray()|Measure-Object -Average).Average)
    }
    return [ordered]@{
        entry_mps=$(if([double]::IsNaN($entry)){$null}else{[Math]::Round($entry,3)})
        min_mps=$(if($null-eq$minV){$null}else{[Math]::Round($minV,3)})
        exit_mps=$(if([double]::IsNaN($exit)){$null}else{[Math]::Round($exit,3)})
        average_mps=$(if($null-eq$avgV){$null}else{[Math]::Round($avgV,3)})
    }
}

# Native facts of one window, taken from the episodes the native Drift authority already defined.
# A window NEVER generates or re-labels a native action: an episode is assigned by its own drift
# start time, so "one side drifted, the other did not" stays a count difference instead of a forced
# pairing. `IncludeEnd` closes the last window of a side so no episode can fall off the end.
function NTA-WindowNativeSummary {
    param(
        [object[]]$Episodes=@(),
        [double]$T0=0.0,
        [double]$T1=0.0,
        [bool]$IncludeEnd=$false,
        [bool]$DriftAvailable=$true,
        [bool]$ComboAvailable=$true
    )
    $eps=New-Object System.Collections.Generic.List[object]
    foreach($ep in @($Episodes)){
        if($null-eq$ep){continue}
        $st=[double]$ep.time.start_t
        if($st-ge$T0-and($st-lt$T1-or($IncludeEnd-and$st-le$T1))){ $eps.Add($ep) }
    }
    $active=0.0;$cw=0;$wcw=0;$cww=0;$air=0;$land=0;$small=0;$nitro=0
    $lat=New-Object System.Collections.Generic.List[double]
    foreach($ep in $eps){
        $a=[Math]::Max($T0,[double]$ep.time.start_t);$b=[Math]::Min($T1,[double]$ep.time.end_t)
        if($b-gt$a){$active+=($b-$a)}
        $cv=$ep.native_actions.combo.cw;if($null-ne$cv){$cw+=[int]$cv}
        $wv=$ep.native_actions.combo.wcw;if($null-ne$wv){$wcw+=[int]$wv}
        $ww=$ep.native_actions.combo.cww;if($null-ne$ww){$cww+=[int]$ww}
        $av=$ep.native_actions.air_boost_count;if($null-ne$av){$air+=[int]$av}
        $lv=$ep.native_actions.landing_boost_count;if($null-ne$lv){$land+=[int]$lv}
        $sv=$ep.native_actions.small_boost_native_effect_count;if($null-ne$sv){$small+=[int]$sv}
        $nv=$ep.native_actions.nitro_native_interval_count;if($null-ne$nv){$nitro+=[int]$nv}
        $bv=$ep.exit_timing.drift_end_to_first_small_boost_ms
        if($null-ne$bv){$lat.Add([double]$bv)}
    }
    return [ordered]@{
        logical_drift_count=$(if($DriftAvailable){$eps.Count}else{$null})
        drift_active_s=$(if($DriftAvailable){[Math]::Round($active,4)}else{$null})
        cw=$(if($ComboAvailable){$cw}else{$null})
        wcw=$(if($ComboAvailable){$wcw}else{$null})
        cww=$(if($ComboAvailable){$cww}else{$null})
        air_boost=$(if($ComboAvailable){$air}else{$null})
        landing_boost=$(if($ComboAvailable){$land}else{$null})
        small_boost_native_effect_count=$small
        nitro_native_interval_count=$nitro
        boost_latency_median_ms=$(if($lat.Count-gt0){[int][Math]::Round((NDA-Percentile ([double[]]$lat.ToArray()) 0.5),0)}else{$null})
        episode_ids=@($eps|ForEach-Object{[string]$_.id})
    }
}

# Integer delta that stays `null` when either side is unavailable - never a silent 0.
function NTA-IntDelta($Subject,$Baseline) {
    if($null-eq$Subject-or$null-eq$Baseline){return $null}
    return ([int]$Subject-[int]$Baseline)
}

# ---------------------------------------------------------------------------------------------
# Shared comparison windows
# ---------------------------------------------------------------------------------------------

# Collect the boundary proposals on the SHARED progress of one component: the component's own ends
# plus the section boundaries of BOTH sides projected through the correspondence. The boundary set is
# therefore built once and used by both sides - this is what makes the two sides' windows identical
# instead of "12 sections here, 14 sections there, guess which one corresponds".
function NTA-ComponentBoundaries {
    param(
        [object]$Component,
        [object[]]$SubjectSections=@(),
        [object[]]$BaselineSections=@(),
        [object[]]$SubjectRows=@(),
        [int]$SubjectLapStart=0,[int]$SubjectLapEnd=0,[double]$SubjectD0=0.0,[double]$SubjectD1=1.0,
        [object[]]$BaselineRows=@(),
        [int]$BaselineLapStart=0,[int]$BaselineLapEnd=0,[double]$BaselineD0=0.0,[double]$BaselineD1=1.0
    )
    $list=New-Object System.Collections.Generic.List[double]
    $list.Add([double]$Component.start_s)
    $list.Add([double]$Component.end_s)
    $pairs=@($Component.pairs)
    $spanS=[Math]::Max(1e-9,($SubjectD1-$SubjectD0))
    $spanB=[Math]::Max(1e-9,($BaselineD1-$BaselineD0))
    foreach($sec in @($SubjectSections)){
        if($null-eq$sec-or$null-eq$sec.time){continue}
        foreach($T in @([double]$sec.time.start_t,[double]$sec.time.end_t)){
            $D=NTA-LapDistanceAtTime $SubjectRows $SubjectLapStart $SubjectLapEnd $T
            if($null-eq$D){continue}
            $U=(($D-$SubjectD0)/$spanS)
            if($U-lt-1e-9-or$U-gt1.0+1e-9){continue}
            $S=NTA-SideProgressToShared -Pairs $pairs -Side 'a' -U $U
            if($null-eq$S){continue}
            if($S-gt[double]$Component.start_s+1e-9-and$S-lt[double]$Component.end_s-1e-9){ $list.Add([double]$S) }
        }
    }
    foreach($sec in @($BaselineSections)){
        if($null-eq$sec-or$null-eq$sec.time){continue}
        foreach($T in @([double]$sec.time.start_t,[double]$sec.time.end_t)){
            $D=NTA-LapDistanceAtTime $BaselineRows $BaselineLapStart $BaselineLapEnd $T
            if($null-eq$D){continue}
            $U=(($D-$BaselineD0)/$spanB)
            if($U-lt-1e-9-or$U-gt1.0+1e-9){continue}
            $S=NTA-SideProgressToShared -Pairs $pairs -Side 'b' -U $U
            if($null-eq$S){continue}
            if($S-gt[double]$Component.start_s+1e-9-and$S-lt[double]$Component.end_s-1e-9){ $list.Add([double]$S) }
        }
    }
    return @($list.ToArray()|Sort-Object)
}

# One shared comparison window: the same shared-progress interval measured independently on each
# side. Everything in it is a measurement; nothing is a judgement.
function NTA-BuildComparisonWindow {
    param(
        [int]$Index,
        [double]$S0,[double]$S1,
        [object[]]$Pairs=@(),
        [object[]]$SubjectRows=@(),[int]$SubjectLapStart=0,[int]$SubjectLapEnd=0,
        [object[]]$BaselineRows=@(),[int]$BaselineLapStart=0,[int]$BaselineLapEnd=0,
        [object[]]$SubjectEpisodes=@(),[object[]]$BaselineEpisodes=@(),
        [bool]$SubjectDriftAvailable=$true,[bool]$SubjectComboAvailable=$true,
        [bool]$BaselineDriftAvailable=$true,[bool]$BaselineComboAvailable=$true,
        [double]$MaxSeparationM=30.0,[double]$MatchedSeparationM=15.0,
        [bool]$CloseSubjectEnd=$false,[bool]$CloseBaselineEnd=$false
    )
    $p0=NTA-SharedProgressToSides -Pairs $Pairs -S $S0
    $p1=NTA-SharedProgressToSides -Pairs $Pairs -S $S1
    if($null-eq$p0-or$null-eq$p1){return $null}
    $ta0=NTA-TimeAtLapDistance $SubjectRows $SubjectLapStart $SubjectLapEnd ([double]$p0.a_d)
    $ta1=NTA-TimeAtLapDistance $SubjectRows $SubjectLapStart $SubjectLapEnd ([double]$p1.a_d)
    $tb0=NTA-TimeAtLapDistance $BaselineRows $BaselineLapStart $BaselineLapEnd ([double]$p0.b_d)
    $tb1=NTA-TimeAtLapDistance $BaselineRows $BaselineLapStart $BaselineLapEnd ([double]$p1.b_d)
    if($null-eq$ta0-or$null-eq$ta1-or$null-eq$tb0-or$null-eq$tb1){return $null}
    $subTime=[double]$ta1-[double]$ta0
    $baseTime=[double]$tb1-[double]$tb0
    $subDist=[double]$p1.a_d-[double]$p0.a_d
    $baseDist=[double]$p1.b_d-[double]$p0.b_d
    $delta=$subTime-$baseTime
    $subSpeed=NTA-WindowSpeed $SubjectRows (NTA-RowIndexAtTime $SubjectRows $SubjectLapStart $SubjectLapEnd $ta0) (NTA-RowIndexAtTime $SubjectRows $SubjectLapStart $SubjectLapEnd $ta1)
    $baseSpeed=NTA-WindowSpeed $BaselineRows (NTA-RowIndexAtTime $BaselineRows $BaselineLapStart $BaselineLapEnd $tb0) (NTA-RowIndexAtTime $BaselineRows $BaselineLapStart $BaselineLapEnd $tb1)
    $subNat=NTA-WindowNativeSummary -Episodes $SubjectEpisodes -T0 $ta0 -T1 $ta1 -IncludeEnd $CloseSubjectEnd -DriftAvailable $SubjectDriftAvailable -ComboAvailable $SubjectComboAvailable
    $baseNat=NTA-WindowNativeSummary -Episodes $BaselineEpisodes -T0 $tb0 -T1 $tb1 -IncludeEnd $CloseBaselineEnd -DriftAvailable $BaselineDriftAvailable -ComboAvailable $BaselineComboAvailable
    $cps=New-Object System.Collections.Generic.List[object]
    foreach($p in @($Pairs)){
        if($null-eq$p){continue}
        if([double]$p.s-ge$S0-1e-9-and[double]$p.s-le$S1+1e-9){ $cps.Add($p) }
    }
    $sepMax=0.0;$sepSum=0.0
    foreach($p in $cps){
        $d=[double]$p.separation_m
        $sepSum+=$d
        if($d-gt$sepMax){$sepMax=$d}
    }
    $sepMean=$(if($cps.Count-gt0){$sepSum/[double]$cps.Count}else{0.0})
    $corrStatus='unmatched_insufficient_correspondence'
    if($cps.Count-ge2){
        if($sepMax-gt$MatchedSeparationM){$corrStatus='ambiguous_separation_exceeds_matched_threshold'}
        else{$corrStatus='matched'}
    }
    $confidence=0.0
    if($cps.Count-gt0-and$MaxSeparationM-gt0){ $confidence=[Math]::Max(0.0,[Math]::Min(1.0,(1.0-($sepMax/$MaxSeparationM)))) }
    return [pscustomobject][ordered]@{
        comparison_window_id=('W{0:D2}' -f $Index)
        delta_rule='delta = subject - baseline'
        correspondence=[ordered]@{
            status=$corrStatus
            confidence=[Math]::Round($confidence,4)
            pair_count=$cps.Count
            max_separation_m=[Math]::Round($sepMax,3)
            mean_separation_m=[Math]::Round($sepMean,3)
            matched_separation_threshold_m=$MatchedSeparationM
            max_separation_threshold_m=$MaxSeparationM
        }
        space=[ordered]@{
            subject=[ordered]@{
                start_progress=[Math]::Round([double]$p0.a,6);end_progress=[Math]::Round([double]$p1.a,6)
                start_distance_m=[Math]::Round([double]$p0.a_d,3);end_distance_m=[Math]::Round([double]$p1.a_d,3)
                distance_m=[Math]::Round($subDist,3)
                start=(NTA-PairPointAt -Pairs $cps -S $S0 -Side 'a')
                end=(NTA-PairPointAt -Pairs $cps -S $S1 -Side 'a')
            }
            baseline=[ordered]@{
                start_progress=[Math]::Round([double]$p0.b,6);end_progress=[Math]::Round([double]$p1.b,6)
                start_distance_m=[Math]::Round([double]$p0.b_d,3);end_distance_m=[Math]::Round([double]$p1.b_d,3)
                distance_m=[Math]::Round($baseDist,3)
                start=(NTA-PairPointAt -Pairs $cps -S $S0 -Side 'b')
                end=(NTA-PairPointAt -Pairs $cps -S $S1 -Side 'b')
            }
            delta_distance_m=[Math]::Round(($subDist-$baseDist),3)
        }
        time=[ordered]@{
            subject_s=[Math]::Round($subTime,4)
            baseline_s=[Math]::Round($baseTime,4)
            delta_s=[Math]::Round($delta,4)
            direction=(NTA-Direction $delta)
            classification=(NTA-Classification $delta)
        }
        speed=[ordered]@{
            subject=$subSpeed
            baseline=$baseSpeed
            delta=[ordered]@{
                entry_mps=(NTA-Delta $subSpeed.entry_mps $baseSpeed.entry_mps)
                min_mps=(NTA-Delta $subSpeed.min_mps $baseSpeed.min_mps)
                exit_mps=(NTA-Delta $subSpeed.exit_mps $baseSpeed.exit_mps)
                average_mps=(NTA-Delta $subSpeed.average_mps $baseSpeed.average_mps)
            }
        }
        native=[ordered]@{
            subject=$subNat
            baseline=$baseNat
            delta=[ordered]@{
                logical_drift_count=(NTA-IntDelta $subNat.logical_drift_count $baseNat.logical_drift_count)
                drift_active_s=(NTA-Delta $subNat.drift_active_s $baseNat.drift_active_s)
                cw=(NTA-IntDelta $subNat.cw $baseNat.cw)
                wcw=(NTA-IntDelta $subNat.wcw $baseNat.wcw)
                cww=(NTA-IntDelta $subNat.cww $baseNat.cww)
                air_boost=(NTA-IntDelta $subNat.air_boost $baseNat.air_boost)
                landing_boost=(NTA-IntDelta $subNat.landing_boost $baseNat.landing_boost)
                small_boost_native_effect_count=(NTA-IntDelta $subNat.small_boost_native_effect_count $baseNat.small_boost_native_effect_count)
                nitro_native_interval_count=(NTA-IntDelta $subNat.nitro_native_interval_count $baseNat.nitro_native_interval_count)
                boost_latency_median_ms=(NTA-IntDelta $subNat.boost_latency_median_ms $baseNat.boost_latency_median_ms)
            }
        }
        derived=$true
    }
}

# ---------------------------------------------------------------------------------------------
# Time-loss decomposition
# ---------------------------------------------------------------------------------------------

# The full comparison contract: shared correspondence, shared windows, an exact reconciliation and
# the separated loss / gain rankings, all under the single `delta = subject - baseline` rule.
function NTA-TimeLossBreakdown {
    param(
        [AllowEmptyCollection()][object[]]$SubjectSections=@(),
        [AllowEmptyCollection()][object[]]$BaselineSections=@(),
        [AllowEmptyCollection()][object[]]$SubjectRows=@(),
        [AllowEmptyCollection()][object[]]$BaselineRows=@(),
        [AllowEmptyCollection()][object[]]$SubjectEpisodes=@(),
        [AllowEmptyCollection()][object[]]$BaselineEpisodes=@(),
        [double]$SubjectLapDurationS=0.0,
        [double]$BaselineLapDurationS=0.0,
        [int]$SubjectLapStart=0,[int]$SubjectLapEnd=0,
        [int]$BaselineLapStart=0,[int]$BaselineLapEnd=0,
        [bool]$SubjectDriftAvailable=$true,[bool]$SubjectComboAvailable=$true,
        [bool]$BaselineDriftAvailable=$true,[bool]$BaselineComboAvailable=$true,
        [double]$MaxSeparationM=30.0,
        [double]$MatchedSeparationM=15.0,
        [double]$MaxHeadingDeltaDeg=80.0,
        [double]$BandProgress=0.06,
        [double]$MaxGapProgress=0.03,
        [double]$MinWindowSeparationM=8.0,
        [double]$MinCoverage=0.34,
        [int]$TopN=5,
        [int]$MaxControlPoints=180
    )
    $sr=@($SubjectRows);$br=@($BaselineRows)
    $totalDelta=[Math]::Round(($SubjectLapDurationS-$BaselineLapDurationS),4)
    $rule='total_delta = matched_delta + unmatched_delta + non_comparison_delta + residual, with delta = subject - baseline'

    $unavailable=[pscustomobject][ordered]@{
        status='comparison_unavailable_no_shared_correspondence'
        delta_rule='delta = subject - baseline; positive means the subject is slower / larger / more'
        total_delta_s=$totalDelta
        reconciliation=[ordered]@{
            matched_delta_s=$null;unmatched_delta_s=$null;non_comparison_delta_s=$null
            residual_s=$null;residual_abs_s=$null;residual_ratio=$null;tolerance_s=$null
            tolerance_basis='not applicable: no window could be established'
            status='unavailable';status_reason='the two trajectories share no monotonic admissible correspondence'
            rule=$rule
        }
        coverage=[ordered]@{subject=$null;baseline=$null;combined=$null;min_coverage=$MinCoverage}
        window_count=0;matched_window_count=0;unmatched_window_count=0
        windows=@();non_comparison_spans=@()
        correspondence=[pscustomobject][ordered]@{status='unavailable';algorithm='banded_monotone_spatial_alignment_v1';pair_count=0;component_count=0;break_count=0}
        top_loss_sections=@();top_gain_sections=@()
    }

    $cpSub=@(NTA-TrajectoryControlPoints $sr $SubjectLapStart $SubjectLapEnd -MaxPoints $MaxControlPoints)
    $cpBase=@(NTA-TrajectoryControlPoints $br $BaselineLapStart $BaselineLapEnd -MaxPoints $MaxControlPoints)
    $corr=NTA-SharedCorrespondence -Subject $cpSub -Baseline $cpBase -MaxSeparationM $MaxSeparationM -MaxHeadingDeltaDeg $MaxHeadingDeltaDeg -BandProgress $BandProgress -MaxGapProgress $MaxGapProgress
    if([string]$corr.status-ne'ready'-or@($corr.pairs).Count-lt2){
        $unavailable.correspondence=[pscustomobject]$corr.stats
        return $unavailable
    }
    $subD0=[double]$cpSub[0].d;$subD1=[double]$cpSub[$cpSub.Count-1].d
    $baseD0=[double]$cpBase[0].d;$baseD1=[double]$cpBase[$cpBase.Count-1].d
    $lapScaleM=[Math]::Max(1.0,((($subD1-$subD0)+($baseD1-$baseD0))/2.0))
    $minProgress=($MinWindowSeparationM/$lapScaleM)

    $windows=New-Object System.Collections.Generic.List[object]
    $compIntervalsSub=New-Object System.Collections.Generic.List[object]
    $compIntervalsBase=New-Object System.Collections.Generic.List[object]
    $idx=0
    $components=@($corr.components)
    for($ci=0;$ci-lt$components.Count;$ci++){
        $comp=$components[$ci]
        $isLastComponent=($ci-eq$components.Count-1)
        $pairsC=@($comp.pairs)
        $raw=@(NTA-ComponentBoundaries -Component $comp -SubjectSections $SubjectSections -BaselineSections $BaselineSections `
            -SubjectRows $sr -SubjectLapStart $SubjectLapStart -SubjectLapEnd $SubjectLapEnd -SubjectD0 $subD0 -SubjectD1 $subD1 `
            -BaselineRows $br -BaselineLapStart $BaselineLapStart -BaselineLapEnd $BaselineLapEnd -BaselineD0 $baseD0 -BaselineD1 $baseD1)
        $bounds=New-Object System.Collections.Generic.List[double]
        foreach($b in $raw){
            if($bounds.Count-eq0){$bounds.Add([double]$b);continue}
            if(([double]$b-[double]$bounds[$bounds.Count-1])-ge$minProgress){$bounds.Add([double]$b)}
        }
        # The two ends of a component are NOT optional: dropping one would leave a real stretch of the
        # shared progress outside every window, and the closed decomposition would then have to absorb
        # it in the residual. The minimum-separation merge may only thin INTERIOR boundaries.
        if($bounds.Count-gt0-and[Math]::Abs([double]$bounds[0]-[double]$comp.start_s)-gt1e-12){ $bounds.Insert(0,[double]$comp.start_s) }
        if($bounds.Count-gt0-and([double]$comp.end_s-[double]$bounds[$bounds.Count-1])-gt1e-12){ $bounds.Add([double]$comp.end_s) }
        if($bounds.Count-lt2){continue}
        for($k=0;$k-lt($bounds.Count-1);$k++){
            $idx++
            $isLastWindowOfSide=($isLastComponent-and$k-eq($bounds.Count-2))
            $w=NTA-BuildComparisonWindow -Index $idx -S0 ([double]$bounds[$k]) -S1 ([double]$bounds[$k+1]) -Pairs $pairsC `
                -SubjectRows $sr -SubjectLapStart $SubjectLapStart -SubjectLapEnd $SubjectLapEnd `
                -BaselineRows $br -BaselineLapStart $BaselineLapStart -BaselineLapEnd $BaselineLapEnd `
                -SubjectEpisodes $SubjectEpisodes -BaselineEpisodes $BaselineEpisodes `
                -SubjectDriftAvailable $SubjectDriftAvailable -SubjectComboAvailable $SubjectComboAvailable `
                -BaselineDriftAvailable $BaselineDriftAvailable -BaselineComboAvailable $BaselineComboAvailable `
                -MaxSeparationM $MaxSeparationM -MatchedSeparationM $MatchedSeparationM `
                -CloseSubjectEnd $isLastWindowOfSide -CloseBaselineEnd $isLastWindowOfSide
            if($null-ne$w){ $windows.Add($w) }
        }
        $sT0=NTA-TimeAtLapDistance $sr $SubjectLapStart $SubjectLapEnd ([double]$comp.subject_start_d)
        $sT1=NTA-TimeAtLapDistance $sr $SubjectLapStart $SubjectLapEnd ([double]$comp.subject_end_d)
        $bT0=NTA-TimeAtLapDistance $br $BaselineLapStart $BaselineLapEnd ([double]$comp.baseline_start_d)
        $bT1=NTA-TimeAtLapDistance $br $BaselineLapStart $BaselineLapEnd ([double]$comp.baseline_end_d)
        if($null-ne$sT0-and$null-ne$sT1){
            $compIntervalsSub.Add([pscustomobject]@{t0=[Math]::Min([double]$sT0,[double]$sT1);t1=[Math]::Max([double]$sT0,[double]$sT1)})
        }
        if($null-ne$bT0-and$null-ne$bT1){
            $compIntervalsBase.Add([pscustomobject]@{t0=[Math]::Min([double]$bT0,[double]$bT1);t1=[Math]::Max([double]$bT0,[double]$bT1)})
        }
    }

    if($windows.Count-eq0){
        $unavailable.correspondence=[pscustomobject]$corr.stats
        return $unavailable
    }

    # --- reconciliation ----------------------------------------------------------------------
    $matchedRaw=0.0;$unmatchedRaw=0.0;$matchedCount=0;$unmatchedCount=0
    foreach($w in $windows){
        if([string]$w.correspondence.status-eq'matched'){ $matchedRaw+=[double]$w.time.delta_s;$matchedCount++ }
        else { $unmatchedRaw+=[double]$w.time.delta_s;$unmatchedCount++ }
    }
    $matchedDelta=[Math]::Round($matchedRaw,4)
    $unmatchedDelta=[Math]::Round($unmatchedRaw,4)

    # Non-comparison stretches: the parts of each lap the two routes do not share. Measured as whole
    # telemetry-row spans (row quantised), because that is the resolution at which a user can inspect
    # them; the comparable stretches above are sub-sample interpolated. The difference between the
    # two measurement resolutions is exactly what the residual reports.
    function __ncSpans([object[]]$Rows,[int]$LapStart,[int]$LapEnd,[object[]]$Intervals){
        $out=New-Object System.Collections.Generic.List[object]
        $n=@($Rows).Count
        if($n-eq0){return @()}
        $t0=[double]$Rows[[Math]::Max(0,$LapStart)].t
        $t1=[double]$Rows[[Math]::Min($n-1,$LapEnd)].t
        if($t1-le$t0){return @()}
        $cursor=$t0
        foreach($iv in @($Intervals|Sort-Object {[double]$_.t0})){
            $a=[double]$iv.t0;$b=[double]$iv.t1
            if($a-gt$cursor+1e-9){
                $qa=NTA-RowTimeAt $Rows $LapStart $LapEnd $cursor
                $qb=NTA-RowTimeAt $Rows $LapStart $LapEnd $a
                if($null-ne$qa-and$null-ne$qb-and$qb-gt$qa){ $out.Add([pscustomobject][ordered]@{from_t=[Math]::Round($cursor,4);to_t=[Math]::Round($a,4);duration_s=[Math]::Round(([double]$qb-[double]$qa),4);status='not_corresponded'}) }
            }
            if($b-gt$cursor){$cursor=$b}
        }
        if($cursor-lt$t1-1e-9){
            $qa=NTA-RowTimeAt $Rows $LapStart $LapEnd $cursor
            $qb=NTA-RowTimeAt $Rows $LapStart $LapEnd $t1
            if($null-ne$qa-and$null-ne$qb-and$qb-gt$qa){ $out.Add([pscustomobject][ordered]@{from_t=[Math]::Round($cursor,4);to_t=[Math]::Round($t1,4);duration_s=[Math]::Round(([double]$qb-[double]$qa),4);status='not_corresponded'}) }
        }
        return @($out.ToArray())
    }
    $ncSub=@(__ncSpans $sr $SubjectLapStart $SubjectLapEnd @($compIntervalsSub.ToArray()))
    $ncBase=@(__ncSpans $br $BaselineLapStart $BaselineLapEnd @($compIntervalsBase.ToArray()))
    $ncSubTime=0.0;foreach($x in $ncSub){$ncSubTime+=[double]$x.duration_s}
    $ncBaseTime=0.0;foreach($x in $ncBase){$ncBaseTime+=[double]$x.duration_s}
    $ncDelta=[Math]::Round(($ncSubTime-$ncBaseTime),4)

    $residual=[Math]::Round(($totalDelta-$matchedDelta-$unmatchedDelta-$ncDelta),4)

    # Tolerance contract: DERIVED, never chosen. Every non-comparison boundary is resolved to the
    # nearest telemetry sample, so a span contributes at most two sample intervals, and the identity
    # spans both sides - hence `2 * spans * sample interval`. The two laps' own start/end boundaries
    # contribute the constant 2. A floor of two sample intervals covers the two sub-sample
    # interpolations of a fully corresponded lap (where the residual is 0 by construction).
    $sampleSub=NTA-MedianSampleIntervalS $sr $SubjectLapStart $SubjectLapEnd
    $sampleBase=NTA-MedianSampleIntervalS $br $BaselineLapStart $BaselineLapEnd
    $sampleInterval=[Math]::Max($sampleSub,$sampleBase)
    if($sampleInterval-le0){$sampleInterval=0.02}
    $ncBoundaries=(2*($ncSub.Count+$ncBase.Count))+2
    $tolerance=[Math]::Round(($ncBoundaries*$sampleInterval),4)
    $toleranceBasis=('2 sample intervals per non-comparison boundary ('+[string]($ncSub.Count+$ncBase.Count)+' spans) + 2 lap boundaries = '+[string]$ncBoundaries+' boundaries x '+[string][Math]::Round($sampleInterval,5)+' s measured sample interval')
    $comparableSub=0.0
    foreach($iv in @($compIntervalsSub.ToArray())){$comparableSub+=([double]$iv.t1-[double]$iv.t0)}
    $comparableBase=0.0
    foreach($iv in @($compIntervalsBase.ToArray())){$comparableBase+=([double]$iv.t1-[double]$iv.t0)}
    $coverageSub=$(if($SubjectLapDurationS-gt0){[Math]::Min(1.0,($comparableSub/$SubjectLapDurationS))}else{$null})
    $coverageBase=$(if($BaselineLapDurationS-gt0){[Math]::Min(1.0,($comparableBase/$BaselineLapDurationS))}else{$null})
    $coverage=$null
    if($null-ne$coverageSub-and$null-ne$coverageBase){$coverage=[Math]::Min($coverageSub,$coverageBase)}
    elseif($null-ne$coverageSub){$coverage=$coverageSub}
    elseif($null-ne$coverageBase){$coverage=$coverageBase}

    $residualAbs=[Math]::Round([Math]::Abs($residual),4)
    $ratio=$(if($tolerance-gt0){[Math]::Round(($residualAbs/$tolerance),4)}else{$null})
    $status='reconciled';$reason='the residual is inside the derived tolerance and the corresponded coverage is sufficient'
    if($residualAbs-gt$tolerance){
        $status='degraded_residual_exceeds_tolerance'
        $reason=('the residual '+[string]$residualAbs+' s exceeds the derived tolerance '+[string]$tolerance+' s')
    } elseif($null-eq$coverage-or$coverage-lt$MinCoverage){
        $status='degraded_low_correspondence_coverage'
        $reason=('only '+[string]$coverage+' of the laps is spatially corresponded, below the minimum '+[string]$MinCoverage)
    }

    # --- loss / gain are SEPARATED ------------------------------------------------------------
    # `top_loss_sections` is the windows the subject genuinely LOST time in, largest first, and
    # `top_gain_sections` the ones it genuinely GAINED in, largest magnitude first. `Sort-Object` is
    # ascending, so both keys are negated to get a descending ranking.
    $ranked=@($windows.ToArray()|Where-Object{$null-ne$_.time.delta_s})
    $loss=@($ranked|Where-Object{[double]$_.time.delta_s-gt0.0005}|Sort-Object @{Expression={-[double]$_.time.delta_s}},comparison_window_id|Select-Object -First ([Math]::Max(0,$TopN)))
    $gain=@($ranked|Where-Object{[double]$_.time.delta_s-lt-0.0005}|Sort-Object @{Expression={-[Math]::Abs([double]$_.time.delta_s)}},comparison_window_id|Select-Object -First ([Math]::Max(0,$TopN)))

    return [pscustomobject][ordered]@{
        status=$status
        delta_rule='delta = subject - baseline; positive means the subject is slower / larger / more'
        total_delta_s=$totalDelta
        reconciliation=[ordered]@{
            matched_delta_s=$matchedDelta
            unmatched_delta_s=$unmatchedDelta
            non_comparison_delta_s=$ncDelta
            residual_s=$residual
            residual_abs_s=$residualAbs
            residual_ratio=$ratio
            tolerance_s=$tolerance
            tolerance_basis=$toleranceBasis
            sample_interval_s=[Math]::Round($sampleInterval,5)
            status=$status
            status_reason=$reason
            rule=$rule
        }
        coverage=[ordered]@{
            subject=$(if($null-eq$coverageSub){$null}else{[Math]::Round($coverageSub,4)})
            baseline=$(if($null-eq$coverageBase){$null}else{[Math]::Round($coverageBase,4)})
            combined=$(if($null-eq$coverage){$null}else{[Math]::Round($coverage,4)})
            min_coverage=$MinCoverage
            definition='corresponded time of a lap divided by its published lap time; the combination is the smaller of the two'
        }
        window_count=$windows.Count
        matched_window_count=$matchedCount
        unmatched_window_count=$unmatchedCount
        windows=@($windows.ToArray())
        non_comparison_spans=@([pscustomobject][ordered]@{subject=$ncSub;baseline=$ncBase})
        correspondence=[pscustomobject]$corr.stats
        top_loss_sections=$loss
        top_gain_sections=$gain
    }
}

# ---------------------------------------------------------------------------------------------
# Derived observations (rule-based, explicitly NOT native facts)
# ---------------------------------------------------------------------------------------------

function NTA-FormatSignedSeconds($V,[int]$Digits) {
    if($null-eq$V){return 'n/a'}
    $d=[double]$V
    if($d-ge0){return ('+'+$d.ToString('F'+[string]$Digits))}
    return $d.ToString('F'+[string]$Digits)
}
function NTA-FormatSignedNumber($V,[int]$Digits) {
    if($null-eq$V){return 'n/a'}
    $d=[double]$V
    if($d-ge0){return ('+'+$d.ToString('F'+[string]$Digits))}
    return $d.ToString('F'+[string]$Digits)
}

# Observations are DERIVED, never native facts, and never a judgement.
#
# Every sentence obeys the single delta contract: the number printed is `subject - baseline`, and the
# word beside it is the direction of that SAME number - positive is 慢 (loss), negative is 快 (gain).
# `Causation` is never asserted: the sentence states a measured time difference beside the
# co-occurring measured differences, and nothing is ever called "because of".
function NTA-BuildObservations {
    param([object]$Breakdown,[string]$SubjectLabel,[string]$BaselineLabel,[int]$MaxObservations=8)
    $out=New-Object System.Collections.Generic.List[object]
    if($null-eq$Breakdown){return @()}
    $budget=[Math]::Max(0,$MaxObservations)
    $pairs=New-Object System.Collections.Generic.List[object]
    foreach($w in @($Breakdown.top_loss_sections)){
        $pairs.Add([pscustomobject]@{window=$w;scope='window_time_loss'})
        if($pairs.Count-ge$budget){break}
    }
    if($pairs.Count-lt$budget){
        foreach($w in @($Breakdown.top_gain_sections)){
            if($pairs.Count-ge$budget){break}
            $pairs.Add([pscustomobject]@{window=$w;scope='window_time_gain'})
        }
    }
    foreach($e in $pairs){
        $w=$e.window
        if($null-eq$w.time.delta_s){continue}
        $d=$w.native.delta
        $n=$w.native.subject
        $cw=$(if($null-eq$d.cw){'n/a'}else{([string][int]$d.cw)})
        $wcw=$(if($null-eq$d.wcw){'n/a'}else{([string][int]$d.wcw)})
        $cww=$(if($null-eq$d.cww){'n/a'}else{([string][int]$d.cww)})
        $dc=$(if($null-eq$d.logical_drift_count){'n/a'}else{([string][int]$d.logical_drift_count)})
        $bl=$(if($null-eq$d.boost_latency_median_ms){'n/a'}else{([string][int]$d.boost_latency_median_ms)+'ms'})
        $text=('{0} 在 {1} 段比基准 {2} {3} {4}s（差值 = {0} − {2}）；同段实测差异：入口速度 {5} m/s、最低速度 {6} m/s、出口速度 {7} m/s、漂移时长 {8}s、漂移次数 {9}、加速衔接中位 {10}、路线长度 {11}m、CW/WCW/CWW {12}/{13}/{14}。' -f `
            $SubjectLabel,[string]$w.comparison_window_id,$BaselineLabel,(NTA-DirectionWord $w.time.delta_s),(NTA-FormatSignedSeconds $w.time.delta_s 3),`
            (NTA-FormatSignedNumber $w.speed.delta.entry_mps 2),(NTA-FormatSignedNumber $w.speed.delta.min_mps 2),(NTA-FormatSignedNumber $w.speed.delta.exit_mps 2),`
            (NTA-FormatSignedNumber $d.drift_active_s 3),$dc,$bl,(NTA-FormatSignedNumber $w.space.delta_distance_m 2),$cw,$wcw,$cww)
        $out.Add([pscustomobject][ordered]@{
            kind='derived_observation'
            scope=[string]$e.scope
            window_id=[string]$w.comparison_window_id
            section_id=[string]$w.comparison_window_id
            delta_time_s=$w.time.delta_s
            direction=[string]$w.time.direction
            classification=[string]$w.time.classification
            text=$text
            evidence=[ordered]@{
                delta_time_s=$w.time.delta_s
                delta_entry_speed_mps=$w.speed.delta.entry_mps
                delta_min_speed_mps=$w.speed.delta.min_mps
                delta_exit_speed_mps=$w.speed.delta.exit_mps
                delta_drift_duration_s=$d.drift_active_s
                delta_drift_count=$d.logical_drift_count
                delta_boost_latency_ms=$d.boost_latency_median_ms
                delta_route_distance_m=$w.space.delta_distance_m
                delta_cw=$d.cw;delta_wcw=$d.wcw;delta_cww=$d.cww
                subject_native=$n
            }
            causation='not asserted: this is a co-occurrence of measured differences, not a proven cause'
        })
        if($out.Count-ge$budget){break}
    }
    if($out.Count-eq0){
        $scope='comparison_availability'
        $text=('{0} 与 {1} 之间没有可建立共享空间对应的比较窗口，无法给出亏时分解。' -f $SubjectLabel,$BaselineLabel)
        $out.Add([pscustomobject][ordered]@{
            kind='derived_observation';scope=$scope;window_id=$null;section_id=$null
            delta_time_s=$null;direction='unavailable';classification='unavailable'
            text=$text;evidence=$null;causation='not asserted'
        })
    }
    return @($out.ToArray())
}
