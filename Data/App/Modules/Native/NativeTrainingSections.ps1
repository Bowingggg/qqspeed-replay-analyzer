# Native Training Analysis v1.1  (Lap · Episode · Shared Spatial Comparison · Time Loss)
#
# DERIVED, NON-AUTHORITATIVE analysis. It answers "why was this lap / this corner slower than
# another lap or another replay of the same official map" from facts the native pipeline already
# published. It adds MEASUREMENT only.
#
# Authority rules (docs/ARCHITECTURE.md) this module obeys:
#   * Native actions (replay-native Drift table + Action Event Table + speed-effect tables) define
#     every driving-event fact. Geometry is used ONLY for position, distance, route difference,
#     spatial correspondence and comparison-window measurement, and may never define Drift, Boost,
#     Combo, action type, a score or a grade.
#   * Same-map A/B requires an AUTHORITATIVE, EQUAL ResourceMapID. Different resource map ids are
#     never compared (permanent regression, see Tests/Smoke-TrainingAnalysis.ps1). A comparison that
#     cannot be established is published as `unavailable` - never guessed, never forced.
#   * Shared spatial correspondence is built from the TWO REAL DRIVEN TRAJECTORIES only: official
#     world XY, sample order, heading compatibility and local spatial distance. There is NO official
#     reference line, NO CanonicalTrack, NO TrackTopology, NO synthetic centre line and NO fixed
#     template route anywhere in this module.
#   * TIME IS NEVER PART OF THE CORRESPONDENCE COST. The correspondence answers "which positions of
#     these two driven routes correspond"; time is only measured afterwards, on each side of a
#     window. Putting a timestamp in the cost would align a slow replay onto the wrong position.
#   * `unavailable` is not `0`. A quantity whose own authority is missing stays `null` with a status.
#
# Definition-only module: helpers are reused from NativeDrivingAnalysis.ps1 (NDA-*) and
# NativeDrivingEpisodes.ps1 (NDE-*), which the entry scripts load alongside this module.

# ---------------------------------------------------------------------------------------------
# Driven-trajectory control points
# ---------------------------------------------------------------------------------------------

# A lap's row window, clamped to the row array. `$null` means "no usable rows".
function NTA-LapRowWindow {
    param([object[]]$Rows,[int]$LapStart,[int]$LapEnd)
    $n=@($Rows).Count
    if($n-eq0){return $null}
    $s=[int]$LapStart;$e=[int]$LapEnd
    if($s-lt0){$s=0}
    if($e-ge$n){$e=$n-1}
    if($e-le$s){return $null}
    return [pscustomobject]@{start_i=$s;end_i=$e}
}

# Median inter-sample interval of one lap, used ONLY to derive the reconciliation tolerance. It is a
# measured property of the stream, never a tuned constant.
function NTA-MedianSampleIntervalS {
    param([object[]]$Rows,[int]$Start,[int]$End)
    $n=@($Rows).Count
    if($n-lt2){return 0.0}
    $s=[Math]::Max(0,$Start);$e=[Math]::Min($n-1,$End)
    $d=New-Object System.Collections.Generic.List[double]
    for($i=$s+1;$i-le$e;$i++){
        $dt=[double]$Rows[$i].t-[double]$Rows[$i-1].t
        if($dt-gt1e-6-and$dt-lt1.0){$d.Add($dt)}
        if($d.Count-ge400){break}
    }
    if($d.Count-eq0){return 0.0}
    return [double](NDA-Percentile ([double[]]$d.ToArray()) 0.5)
}

# One lap's driven route, resampled into spatially ordered control points.
#
# The resampling step is bounded twice - never finer than `MinStepM` and never coarser than
# `lap_distance / MaxPoints` - so a long lap can never make the correspondence cost grow without
# bound. This is the "downsample / simplify / bound" requirement: no full raw-frame matrix is
# reachable from here.
#
# A run of telemetry is broken by an invalid pose or by a `break_before` row (a respawn / teleport).
# Control points never bridge such a break: `block` numbers the runs, so a control point is never
# interpolated across one, and the tangent of a block endpoint stays inside its own run. The block
# number is deliberately NOT an admissibility gate for the correspondence itself - see the kernel.
function NTA-TrajectoryControlPoints {
    param(
        [object[]]$Rows,
        [int]$LapStart,
        [int]$LapEnd,
        [double]$MinStepM=4.0,
        [int]$MaxPoints=180
    )
    $rows=@($Rows)
    $out=New-Object System.Collections.Generic.List[object]
    $w=NTA-LapRowWindow $rows $LapStart $LapEnd
    if($null-eq$w){return @()}
    $block=-1
    $i=$w.start_i
    while($i-le$w.end_i){
        if(-not[bool]$rows[$i].pose_valid-or[bool]$rows[$i].break_before){$i++;continue}
        $rs=$i;$re=$i
        $j=$i+1
        while($j-le$w.end_i){
            if(-not[bool]$rows[$j].pose_valid-or[bool]$rows[$j].break_before){break}
            $re=$j;$j++
        }
        $i=$re+1
        if($re-le$rs){continue}
        $span=[double]$rows[$re].distance-[double]$rows[$rs].distance
        if($span-le1e-6){continue}
        $block++
        $maxP=[Math]::Max(1,[int]$MaxPoints)
        $step=[Math]::Max($MinStepM,($span/[double]$maxP))
        $count=[int][Math]::Ceiling($span/$step)
        if($count-lt1){$count=1}
        for($k=0;$k-le$count;$k++){
            $target=[double]$rows[$rs].distance+($span*($k/[double]$count))
            if($k-eq$count){$target=[double]$rows[$re].distance}
            $lo=$rs;$hi=$re
            while(($hi-$lo)-gt1){
                $m=[int](($lo+$hi)/2)
                if([double]$rows[$m].distance-le$target){$lo=$m}else{$hi=$m}
            }
            $r0=$rows[$lo]
            $r1=$(if($lo-lt$re){$rows[$lo+1]}else{$rows[$re]})
            $d0=[double]$r0.distance;$d1=[double]$r1.distance;$sp=$d1-$d0
            $f=0.0
            if($sp-gt1e-9){$f=($target-$d0)/$sp}
            if($f-lt0.0){$f=0.0}
            if($f-gt1.0){$f=1.0}
            $out.Add([pscustomobject]@{
                block=$block
                row_i=$lo
                d=$target
                t=([double]$r0.t+(([double]$r1.t-[double]$r0.t)*$f))
                x=([double]$r0.x+(([double]$r1.x-[double]$r0.x)*$f))
                y=([double]$r0.y+(([double]$r1.y-[double]$r0.y)*$f))
            })
        }
    }
    return @($out.ToArray())
}

# ---------------------------------------------------------------------------------------------
# Shared spatial correspondence kernel (deterministic: control points in, pairs out)
# ---------------------------------------------------------------------------------------------

# Shared spatial correspondence between two driven routes.
#
# Input: two ordered control-point sequences of the SAME authoritative ResourceMapID, in official
# world XY. Output: a monotonic, order-preserving set of corresponded pairs, the places where the
# correspondence breaks, and the components (maximal corresponded stretches) between those breaks.
#
# Guarantees - each one is a permanent regression in Tests/Smoke-TrainingAnalysis.ps1:
#   * monotonic        - the subject index and the baseline index never move backwards;
#   * order preserving - no match can cross an earlier match, so a route can never be read backwards;
#   * heading compatible - two positions that are close but driven in opposite directions are not
#                        the same point;
#   * bounded          - candidates are confined to a progress band, so the search is linear in the
#                        control-point count instead of the full raw-frame matrix;
#   * fail closed      - a region with no admissible counterpart stays UNMATCHED; coverage is never
#                        forced onto a nearest neighbour;
#   * time free        - `t` is carried through for later measurement and is never part of the cost.
#
# A pose-run boundary is a property of ONE side's sampling, never a reason to refuse a correspondence:
# the two sides' run counts are unrelated (one invalid row can split a lap into two runs while the
# other keeps one), so gating on them desynchronises the whole alignment. Runs only bound the
# interpolation of the control points themselves.
#
# Objective (lexicographic, the shape the section kernel used before this milestone): maximise the
# number of corresponded pairs, then minimise the total measured spatial separation. A pair is
# skipped only when no admissible counterpart is reachable without skipping one too, so nothing is
# ever force-paired.
function NTA-SharedCorrespondence {
    param(
        [AllowEmptyCollection()][object[]]$Subject=@(),
        [AllowEmptyCollection()][object[]]$Baseline=@(),
        [double]$MaxSeparationM=30.0,
        [double]$MaxHeadingDeltaDeg=80.0,
        [double]$BandProgress=0.06,
        [double]$MaxGapProgress=0.03
    )
    $A=@($Subject);$B=@($Baseline)
    $nA=$A.Count;$nB=$B.Count
    $stats=[ordered]@{
        algorithm='banded_monotone_spatial_alignment_v1'
        objective='maximise corresponded pairs, then minimise total measured spatial separation'
        time_in_cost=$false
        band_progress=$BandProgress
        max_separation_m=$MaxSeparationM
        max_heading_delta_deg=$MaxHeadingDeltaDeg
        max_gap_progress=$MaxGapProgress
        subject_control_points=$nA
        baseline_control_points=$nB
    }
    $fail=[pscustomobject][ordered]@{status='unavailable_no_control_points';pairs=@();components=@();breaks=@();lead=$null;trail=$null;stats=[pscustomobject]$stats}
    if($nA-lt2-or$nB-lt2){ return $fail }

    $dA0=[double]$A[0].d;$dA1=[double]$A[$nA-1].d
    $dB0=[double]$B[0].d;$dB1=[double]$B[$nB-1].d
    if($dA1-le$dA0-or$dB1-le$dB0){ return $fail }

    $ax=New-Object double[] $nA;$ay=New-Object double[] $nA;$au=New-Object double[] $nA
    $ablk=New-Object int[] $nA
    $spanA=$dA1-$dA0
    for($k=0;$k-lt$nA;$k++){
        $ax[$k]=[double]$A[$k].x;$ay[$k]=[double]$A[$k].y
        $au[$k]=(([double]$A[$k].d-$dA0)/$spanA)
        $ablk[$k]=[int]$A[$k].block
    }
    $bx=New-Object double[] $nB;$by=New-Object double[] $nB;$bu=New-Object double[] $nB
    $bblk=New-Object int[] $nB
    $spanB=$dB1-$dB0
    for($k=0;$k-lt$nB;$k++){
        $bx[$k]=[double]$B[$k].x;$by[$k]=[double]$B[$k].y
        $bu[$k]=(([double]$B[$k].d-$dB0)/$spanB)
        $bblk[$k]=[int]$B[$k].block
    }
    $ahx=New-Object double[] $nA;$ahy=New-Object double[] $nA
    for($k=0;$k-lt$nA;$k++){ $v=NTA-ControlTangent $ax $ay $ablk $k; $ahx[$k]=$v[0];$ahy[$k]=$v[1] }
    $bhx=New-Object double[] $nB;$bhy=New-Object double[] $nB
    for($k=0;$k-lt$nB;$k++){ $v=NTA-ControlTangent $bx $by $bblk $k; $bhx[$k]=$v[0];$bhy[$k]=$v[1] }

    # Prefix progress arrays: index i means "the first i control points have been consumed".
    $uaP=New-Object double[] ($nA+1)
    for($i=1;$i-le$nA;$i++){ $uaP[$i]=$au[$i-1] }
    $ubP=New-Object double[] ($nB+1)
    for($j=1;$j-le$nB;$j++){ $ubP[$j]=$bu[$j-1] }

    $pa=New-Object 'int[][]' ($nA+1)
    $pc=New-Object 'double[][]' ($nA+1)
    $pr=New-Object 'bool[][]' ($nA+1)
    $pch=New-Object 'byte[][]' ($nA+1)
    for($i=0;$i-le$nA;$i++){
        $pa[$i]=New-Object 'int[]' ($nB+1)
        $pc[$i]=New-Object 'double[]' ($nB+1)
        $pr[$i]=New-Object 'bool[]' ($nB+1)
        $pch[$i]=New-Object 'byte[]' ($nB+1)
    }
    $pr[0][0]=$true
    $eps=1e-12
    # The band is a monotone progress window, so both edges only ever move forward: the inner loop
    # visits O(control points * band) cells instead of the full square.
    $jLo=0;$jHi=-1
    for($i=0;$i-le$nA;$i++){
        $ua=$uaP[$i]
        $t1=$ua-$BandProgress
        while($jLo-le$nB-and$ubP[$jLo]-lt$t1){$jLo++}
        if($jHi-lt($jLo-1)){$jHi=$jLo-1}
        $t2=$ua+$BandProgress
        while(($jHi+1)-le$nB-and$ubP[$jHi+1]-le$t2){$jHi++}
        for($j=$jLo;$j-le$jHi;$j++){
            if($i-eq0-and$j-eq0){continue}
            $bp=-1;$bc=0.0;$ch=[byte]0
            if($i-gt0-and$pr[$i-1][$j]){ $bp=$pa[$i-1][$j];$bc=$pc[$i-1][$j];$ch=[byte]1 }
            if($j-gt0-and$pr[$i][$j-1]){
                $p2=$pa[$i][$j-1];$c2=$pc[$i][$j-1]
                if($p2-gt$bp-or($p2-eq$bp-and$c2-lt$bc-$eps)){ $bp=$p2;$bc=$c2;$ch=[byte]2 }
            }
            # A pose run boundary is NOT an admissibility gate. The run split above already guarantees
            # that no control point is interpolated ACROSS a break, which is what it is for. Making the
            # two sides' run NUMBERS match as well was measured to be actively harmful: a single
            # invalid pose row splits one lap into 3-5 runs while the other keeps 1-5, the numbering
            # desynchronises, and almost the whole lap stops corresponding (measured coverage fell to
            # 0.49 / 0.03 on real laps that are in fact the same route). The separation gate, the
            # heading gate, the progress band and the maximum progress gap below are what keep this
            # fail-closed.
            if($i-gt0-and$j-gt0-and$pr[$i-1][$j-1]){
                $dx=$ax[$i-1]-$bx[$j-1];$dy=$ay[$i-1]-$by[$j-1]
                $dd=[Math]::Sqrt($dx*$dx+$dy*$dy)
                if($dd-le$MaxSeparationM){
                    $hd=[Math]::Abs((NDA-AngleDeltaDeg $ahx[$i-1] $ahy[$i-1] $bhx[$j-1] $bhy[$j-1]))
                    if($hd-le$MaxHeadingDeltaDeg){
                        $p3=$pa[$i-1][$j-1]+1;$c3=$pc[$i-1][$j-1]+$dd
                        if($p3-gt$bp-or($p3-eq$bp-and$c3-lt$bc-$eps)){ $bp=$p3;$bc=$c3;$ch=[byte]3 }
                    }
                }
            }
            if($ch-ne[byte]0){ $pa[$i][$j]=$bp;$pc[$i][$j]=$bc;$pr[$i][$j]=$true;$pch[$i][$j]=$ch }
        }
    }
    if(-not$pr[$nA][$nB]){
        $stats.pair_count=0
        $fail.status='unavailable_no_monotone_correspondence'
        return $fail
    }
    $ia=New-Object System.Collections.Generic.List[int]
    $ib=New-Object System.Collections.Generic.List[int]
    $i=$nA;$j=$nB
    $guard=0
    $limit=$nA+$nB+4
    while(($i-gt0-or$j-gt0)-and$guard-lt$limit){
        $guard++
        $ch=$pch[$i][$j]
        if($ch-eq[byte]3){ $ia.Add($i-1);$ib.Add($j-1);$i--;$j-- }
        elseif($ch-eq[byte]1){ $i-- }
        elseif($ch-eq[byte]2){ $j-- }
        else{ break }
    }
    $ia.Reverse();$ib.Reverse()

    $pairs=New-Object System.Collections.Generic.List[object]
    $sepSum=0.0;$sepMax=0.0;$hdMax=0.0
    for($k=0;$k-lt$ia.Count;$k++){
        $ai=$ia[$k];$bi=$ib[$k]
        $dx=$ax[$ai]-$bx[$bi];$dy=$ay[$ai]-$by[$bi]
        $dd=[Math]::Sqrt($dx*$dx+$dy*$dy)
        $hd=[Math]::Abs((NDA-AngleDeltaDeg $ahx[$ai] $ahy[$ai] $bhx[$bi] $bhy[$bi]))
        $sepSum+=$dd
        if($dd-gt$sepMax){$sepMax=$dd}
        if($hd-gt$hdMax){$hdMax=$hd}
        $pairs.Add([pscustomobject][ordered]@{
            a_index=$ai;b_index=$bi
            a_block=$ablk[$ai];b_block=$bblk[$bi]
            a_progress=$au[$ai];b_progress=$bu[$bi]
            s=(($au[$ai]+$bu[$bi])/2.0)
            separation_m=$dd
            heading_delta_deg=$hd
            a_d=[double]$A[$ai].d;b_d=[double]$B[$bi].d
            a_t=[double]$A[$ai].t;b_t=[double]$B[$bi].t
            a_x=$ax[$ai];a_y=$ay[$ai]
            b_x=$bx[$bi];b_y=$by[$bi]
            break_after=$false
        })
    }
    $breaks=New-Object System.Collections.Generic.List[object]
    for($k=1;$k-lt$pairs.Count;$k++){
        $gapA=[double]$pairs[$k].a_progress-[double]$pairs[$k-1].a_progress
        $gapB=[double]$pairs[$k].b_progress-[double]$pairs[$k-1].b_progress
        $g=[Math]::Max($gapA,$gapB)
        if($g-gt$MaxGapProgress){
            $pairs[$k-1].break_after=$true
            $breaks.Add([pscustomobject][ordered]@{
                after_pair=$k-1
                gap_progress=$g
                gap_subject_progress=$gapA
                gap_baseline_progress=$gapB
                reason='correspondence_gap_exceeds_maximum'
            })
        }
    }
    # Components: the maximal stretches the two routes actually share. Windows never span a
    # component boundary, and a component is the only place a shared progress is defined.
    $components=New-Object System.Collections.Generic.List[object]
    $first=0
    for($k=0;$k-lt$pairs.Count;$k++){
        if(-not[bool]$pairs[$k].break_after-and$k-lt($pairs.Count-1)){continue}
        $sub=New-Object System.Collections.Generic.List[object]
        for($m=$first;$m-le$k;$m++){ $sub.Add($pairs[$m]) }
        $components.Add([pscustomobject][ordered]@{
            component_index=$components.Count+1
            first_pair=$first
            last_pair=$k
            pair_count=$sub.Count
            pairs=@($sub.ToArray())
            start_s=[double]$pairs[$first].s
            end_s=[double]$pairs[$k].s
            subject_start_progress=[double]$pairs[$first].a_progress
            subject_end_progress=[double]$pairs[$k].a_progress
            baseline_start_progress=[double]$pairs[$first].b_progress
            baseline_end_progress=[double]$pairs[$k].b_progress
            subject_start_d=[double]$pairs[$first].a_d
            subject_end_d=[double]$pairs[$k].a_d
            baseline_start_d=[double]$pairs[$first].b_d
            baseline_end_d=[double]$pairs[$k].b_d
        })
        $first=$k+1
    }
    $stats.pair_count=$pairs.Count
    $stats.component_count=$components.Count
    $stats.break_count=$breaks.Count
    $stats.mean_separation_m=$(if($pairs.Count-gt0){[Math]::Round(($sepSum/[double]$pairs.Count),3)}else{$null})
    $stats.max_separation_m=$(if($pairs.Count-gt0){[Math]::Round($sepMax,3)}else{$null})
    $stats.max_heading_delta_deg=$(if($pairs.Count-gt0){[Math]::Round($hdMax,2)}else{$null})
    $stats.subject_progress_start=$(if($pairs.Count-gt0){[Math]::Round([double]$pairs[0].a_progress,6)}else{$null})
    $stats.subject_progress_end=$(if($pairs.Count-gt0){[Math]::Round([double]$pairs[$pairs.Count-1].a_progress,6)}else{$null})
    $stats.baseline_progress_start=$(if($pairs.Count-gt0){[Math]::Round([double]$pairs[0].b_progress,6)}else{$null})
    $stats.baseline_progress_end=$(if($pairs.Count-gt0){[Math]::Round([double]$pairs[$pairs.Count-1].b_progress,6)}else{$null})
    $lead=$null;$trail=$null
    if($pairs.Count-gt0){
        $lead=[pscustomobject][ordered]@{
            subject_progress=[Math]::Round([double]$pairs[0].a_progress,6)
            baseline_progress=[Math]::Round([double]$pairs[0].b_progress,6)
            existed=(([double]$pairs[0].a_progress-gt1e-6)-or([double]$pairs[0].b_progress-gt1e-6))
        }
        $trail=[pscustomobject][ordered]@{
            subject_progress=[Math]::Round((1.0-[double]$pairs[$pairs.Count-1].a_progress),6)
            baseline_progress=[Math]::Round((1.0-[double]$pairs[$pairs.Count-1].b_progress),6)
            existed=(((1.0-[double]$pairs[$pairs.Count-1].a_progress)-gt1e-6)-or((1.0-[double]$pairs[$pairs.Count-1].b_progress)-gt1e-6))
        }
    }
    $status=$(if($pairs.Count-ge2){'ready'}else{'unavailable_insufficient_correspondence'})
    return [pscustomobject][ordered]@{
        status=$status
        pairs=@($pairs.ToArray())
        components=@($components.ToArray())
        breaks=@($breaks.ToArray())
        lead=$lead
        trail=$trail
        stats=[pscustomobject]$stats
    }
}

# Tangent of one control point, taken from its own block only, so a respawn can never produce a
# heading that does not exist. A single-point block falls back to a zero tangent, which the heading
# gate treats as a wildcard.
function NTA-ControlTangent([double[]]$X,[double[]]$Y,[int[]]$Block,[int]$K) {
    $n=@($X).Count
    $p=$K-1;$q=$K+1
    if($p-lt0){$p=0}
    if($q-ge$n){$q=$n-1}
    if($Block[$p]-ne$Block[$K]-or$Block[$q]-ne$Block[$K]){ $p=$K;$q=$K }
    return [double[]]@(($X[$q]-$X[$p]),($Y[$q]-$Y[$p]))
}

# Shared progress -> each side's own progress, interpolated along ONE component's pair sequence.
# Returns `$null` outside the component, so a caller can never read a value across a break.
function NTA-SharedProgressToSides {
    param([AllowEmptyCollection()][object[]]$Pairs=@(),[double]$S)
    $p=@($Pairs)
    if($p.Count-lt1){return $null}
    if($S-lt[double]$p[0].s-1e-9-or$S-gt[double]$p[$p.Count-1].s+1e-9){return $null}
    if($p.Count-eq1){
        return [pscustomobject][ordered]@{a=[double]$p[0].a_progress;b=[double]$p[0].b_progress;a_d=[double]$p[0].a_d;b_d=[double]$p[0].b_d}
    }
    $lo=0;$hi=$p.Count-1
    while(($hi-$lo)-gt1){$m=[int](($lo+$hi)/2);if([double]$p[$m].s-le$S){$lo=$m}else{$hi=$m}}
    $s0=[double]$p[$lo].s;$s1=[double]$p[$hi].s
    $f=0.0
    if($s1-$s0-gt1e-12){$f=(($S-$s0)/($s1-$s0))}
    if($f-lt0.0){$f=0.0}
    if($f-gt1.0){$f=1.0}
    return [pscustomobject][ordered]@{
        a=([double]$p[$lo].a_progress+(($p[$hi].a_progress-[double]$p[$lo].a_progress)*$f))
        b=([double]$p[$lo].b_progress+(($p[$hi].b_progress-[double]$p[$lo].b_progress)*$f))
        a_d=([double]$p[$lo].a_d+(($p[$hi].a_d-[double]$p[$lo].a_d)*$f))
        b_d=([double]$p[$lo].b_d+(($p[$hi].b_d-[double]$p[$lo].b_d)*$f))
    }
}

# One side's own progress -> shared progress inside one component. `$null` when the position has no
# counterpart in the component (it lies in a skipped stretch).
function NTA-SideProgressToShared {
    param([AllowEmptyCollection()][object[]]$Pairs=@(),[string]$Side='a',[double]$U)
    $p=@($Pairs)
    if($p.Count-lt1){return $null}
    $vals=New-Object double[] $p.Count
    for($k=0;$k-lt$p.Count;$k++){ $vals[$k]=$(if($Side-eq'b'){[double]$p[$k].b_progress}else{[double]$p[$k].a_progress}) }
    if($U-lt$vals[0]-1e-9-or$U-gt$vals[$p.Count-1]+1e-9){return $null}
    if($p.Count-eq1){return [double]$p[0].s}
    $lo=0;$hi=$p.Count-1
    while(($hi-$lo)-gt1){$m=[int](($lo+$hi)/2);if($vals[$m]-le$U){$lo=$m}else{$hi=$m}}
    $v0=$vals[$lo];$v1=$vals[$hi]
    $f=0.0
    if($v1-$v0-gt1e-12){$f=(($U-$v0)/($v1-$v0))}
    if($f-lt0.0){$f=0.0}
    if($f-gt1.0){$f=1.0}
    return ([double]$p[$lo].s+(($p[$hi].s-[double]$p[$lo].s)*$f))
}

# ---------------------------------------------------------------------------------------------
# Section production contract
# ---------------------------------------------------------------------------------------------

# Latency statistics from an episode's published exit timing. Only episodes that actually carry the
# measurement contribute; a missing measurement is never a zero.
function NTA-LatencyStats([AllowEmptyCollection()][object[]]$Episodes) {
    $vals=New-Object System.Collections.Generic.List[double]
    foreach($ep in @($Episodes)){
        if($null-eq$ep){continue}
        $v=$ep.exit_timing.drift_end_to_first_small_boost_ms
        if($null-eq$v){continue}
        $vals.Add([double]$v)
    }
    return [ordered]@{
        count=$vals.Count
        median_ms=$(if($vals.Count-gt0){[int][Math]::Round((NDA-Percentile ([double[]]$vals.ToArray()) 0.5),0)}else{$null})
        p90_ms=$(if($vals.Count-gt0){[int][Math]::Round((NDA-Percentile ([double[]]$vals.ToArray()) 0.9),0)}else{$null})
        min_ms=$(if($vals.Count-gt0){[int](($vals.ToArray()|Measure-Object -Minimum).Minimum)}else{$null})
        max_ms=$(if($vals.Count-gt0){[int](($vals.ToArray()|Measure-Object -Maximum).Maximum)}else{$null})
        source='logical-drift episodes in this section (drift end -> first native small-boost effect)'
    }
}

# Build the production section contract for one lap: identity, space, time, speed, native actions,
# latency and the observed trajectory.
#
# `available` is per quantity. A replay without a native action event table publishes the action
# fields as null with a status, and still publishes space/time/speed - availability never propagates.
function NTA-BuildSectionContract {
    param(
        [object[]]$Rows=@(),
        [object]$Section,
        [object]$Lap,
        [string]$StreamId,
        [string]$ResourceMapId,
        [object[]]$Episodes=@(),
        [bool]$ComboAvailable=$false,
        [bool]$ActionEventAvailable=$false,
        [bool]$DriftAvailable=$false,
        [bool]$EffectAvailable=$false
    )
    if($null-eq$Section){return $null}
    $si=[int]$Section.start_i;$ei=[int]$Section.end_i
    if($si-lt0-or$ei-ge$Rows.Count-or$ei-le$si){return $null}
    $matching=@($Episodes|Where-Object{
        $null-ne$_ -and [double]$_.time.start_t-lt[double]$Section.end_t -and [double]$_.time.end_t-gt[double]$Section.start_t
    })
    $driftMinutes=0.0
    foreach($ep in $matching){
        $a=[Math]::Max([double]$Section.start_t,[double]$ep.time.start_t)
        $b=[Math]::Min([double]$Section.end_t,[double]$ep.time.end_t)
        if($b-gt$a){$driftMinutes+=($b-$a)}
    }
    $cw=0;$wcw=0;$cww=0;$air=0;$land=0
    foreach($ep in $matching){
        $cw+=[int]$ep.native_actions.combo.cw
        $wcw+=[int]$ep.native_actions.combo.wcw
        $cww+=[int]$ep.native_actions.combo.cww
        $air+=[int]$ep.native_actions.air_boost_count
        $land+=[int]$ep.native_actions.landing_boost_count
    }
    $entry=NDA-AverageEdgeSpeed $Rows $si $ei $true
    $exit=NDA-AverageEdgeSpeed $Rows $si $ei $false
    $speeds=New-Object System.Collections.Generic.List[double]
    for($i=$si;$i-le$ei;$i++){
        if(-not[bool]$Rows[$i].pose_valid){continue}
        $v=[double]$Rows[$i].speed
        if(-not[double]::IsNaN($v)-and$v-ge0){$speeds.Add($v)}
    }
    $minV=$null;$avgV=$null
    if($speeds.Count-gt0){
        $minV=[double](($speeds.ToArray()|Measure-Object -Minimum).Minimum)
        $avgV=[double](($speeds.ToArray()|Measure-Object -Average).Average)
    }
    $dur=[Math]::Max(0.0,[double]$Rows[$ei].t-[double]$Rows[$si].t)
    $path=[Math]::Max(0.0,[double]$Rows[$ei].distance-[double]$Rows[$si].distance)
    return [ordered]@{
        section_id=[string]$Section.id
        lap=[int]$Lap.lap
        ordinal=[int]$Section.ordinal
        stream_id=$StreamId
        resource_map_id=$ResourceMapId
        kind=[string]$Section.kind
        direction=[string]$Section.direction
        authority='derived spatial container; native actions are read-only annotations'
        space=[ordered]@{
            entry=[ordered]@{x=(NDE-Round $Rows[$si].x 4);y=(NDE-Round $Rows[$si].y 4);z=(NDE-Round $Rows[$si].z 4);distance_m=(NDE-Round $Rows[$si].distance 3)}
            exit=[ordered]@{x=(NDE-Round $Rows[$ei].x 4);y=(NDE-Round $Rows[$ei].y 4);z=(NDE-Round $Rows[$ei].z 4);distance_m=(NDE-Round $Rows[$ei].distance 3)}
            path_length_m=[Math]::Round($path,3)
            heading_change_deg=$Section.heading_change_deg
            peak_local_turn_deg=$Section.peak_local_turn_deg
        }
        time=[ordered]@{
            start_t=[Math]::Round([double]$Rows[$si].t,4)
            end_t=[Math]::Round([double]$Rows[$ei].t,4)
            duration_s=[Math]::Round($dur,4)
        }
        speed=[ordered]@{
            entry_mps=$(NDE-Round $entry 3)
            min_mps=$(NDE-Round $minV 3)
            exit_mps=$(NDE-Round $exit 3)
            average_mps=$(NDE-Round $avgV 3)
            unit='m/s'
        }
        native_actions=[ordered]@{
            available=$ActionEventAvailable
            logical_drift_count=$(if($DriftAvailable){$matching.Count}else{$null})
            total_drift_duration_s=$(if($DriftAvailable){[Math]::Round($driftMinutes,4)}else{$null})
            cw=$(if($ComboAvailable){$cw}else{$null})
            wcw=$(if($ComboAvailable){$wcw}else{$null})
            cww=$(if($ComboAvailable){$cww}else{$null})
            air_boost=$(if($ComboAvailable){$air}else{$null})
            landing_boost=$(if($ComboAvailable){$land}else{$null})
            small_boost_native_effect_count=$(if($EffectAvailable){[int](@($matching|ForEach-Object{[int]$_.native_actions.small_boost_native_effect_count})|Measure-Object -Sum).Sum}else{$null})
            nitro_native_interval_count=$(if($EffectAvailable){[int](@($matching|ForEach-Object{[int]$_.native_actions.nitro_native_interval_count})|Measure-Object -Sum).Sum}else{$null})
            status=$(if($ComboAvailable){'game_facing_ready'}elseif($ActionEventAvailable){'variant_unvalidated'}else{'native_action_event_table_unavailable'})
        }
        latency=[ordered]@{
            authority='logical-drift episodes inside this section'
            boost_latency=(NTA-LatencyStats $matching)
        }
        trajectory=[ordered]@{
            source='production telemetry rows resampled at fixed distance steps'
            points=(NTA-SectionTrajectory $Rows $si $ei)
        }
        episode_ids=@($matching|ForEach-Object{[string]$_.id})
        derived=$true
    }
}

# Observed trajectory for a section: fixed-distance resampled world-XY points.
# Resolution is deliberately coarse (2.5 m) so the published contract stays small; the full row
# stream remains the authority and is never approximated away.
function NTA-SectionTrajectory {
    param([object[]]$Rows=@(),[int]$Start=0,[int]$End=0,[double]$StepM=2.5,[int]$MaxPoints=64)
    $out=New-Object System.Collections.Generic.List[object]
    if($End-le$Start-or$StepM-le0){return @()}
    $d0=[double]$Rows[$Start].distance;$d1=[double]$Rows[$End].distance
    if($d1-le$d0){return @()}
    $step=[Math]::Max($StepM,($d1-$d0)/[double]$MaxPoints)
    $target=$d0;$j=$Start
    while($target-le$d1+1e-6-and$out.Count-lt$MaxPoints){
        while(($j+1)-le$End-and[double]$Rows[$j+1].distance-lt$target){$j++}
        if(($j+1)-gt$End){break}
        $r0=$Rows[$j];$r1=$Rows[$j+1]
        $span=[double]$r1.distance-[double]$r0.distance
        if($span-le1e-8){$target+=$step;continue}
        $f=($target-[double]$r0.distance)/$span
        if($f-lt0){$f=0.0};if($f-gt1){$f=1.0}
        $valid=([bool]$r0.pose_valid-and[bool]$r1.pose_valid-and-not[bool]$r1.break_before)
        if($valid){
            $x=[double]$r0.x+([double]$r1.x-[double]$r0.x)*$f
            $y=[double]$r0.y+([double]$r1.y-[double]$r0.y)*$f
            $out.Add([pscustomobject][ordered]@{
                d=[Math]::Round($target,3)
                t=[Math]::Round([double]$r0.t+([double]$r1.t-[double]$r0.t)*$f,4)
                x=[Math]::Round($x,3);y=[Math]::Round($y,3)
            })
        }
        $target+=$step
    }
    return @($out.ToArray())
}

# A/B comparability gate. Comparison is allowed ONLY when both sides carry the SAME authoritative
# official ResourceMapID. Everything else is an explicit, named refusal.
function NTA-ComparisonGate {
    param(
        [object]$MapIdA,
        [object]$MapIdB,
        [string]$AuthorityA='',
        [string]$AuthorityB=''
    )
    $a=$null;$b=$null
    if($null-ne$MapIdA-and-not[string]::IsNullOrWhiteSpace([string]$MapIdA)){$a=[int]$MapIdA}
    if($null-ne$MapIdB-and-not[string]::IsNullOrWhiteSpace([string]$MapIdB)){$b=[int]$MapIdB}
    if($null-ne$a-and[string]$AuthorityA-ne''-and[string]$AuthorityA-ne'authoritative'){ $a=$null;$AuthorityA='non_authoritative' }
    if($null-ne$b-and[string]$AuthorityB-ne''-and[string]$AuthorityB-ne'authoritative'){ $b=$null;$AuthorityB='non_authoritative' }
    $ok=($null-ne$a-and$null-ne$b-and$a-eq$b)
    return [pscustomobject][ordered]@{
        comparable=$ok
        status=$(if($ok){'comparable_same_resource_map'}elseif($null-eq$a-or$null-eq$b){'unavailable_map_identity_not_authoritative'}else{'unavailable_different_resource_map'})
        resource_map_id_a=$a
        resource_map_id_b=$b
        rule='Comparison requires the SAME authoritative official ResourceMapID. A different or unresolved identity is never compared.'
    }
}
