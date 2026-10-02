param()
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
$appDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $appDir 'Modules\Native\NativeDrivingAnalysis.ps1')
. (Join-Path $appDir 'Modules\Native\NativeDrivingEpisodes.ps1')
. (Join-Path $appDir 'Modules\Native\NativeTrainingSections.ps1')
. (Join-Path $appDir 'Modules\Native\NativeTrainingTimeLoss.ps1')
. (Join-Path $appDir 'Modules\Native\NativeAnalysisSegments.ps1')
. (Join-Path $appDir 'Modules\Native\NativeSegmentComparison.ps1')
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}
function Approx([double]$A,[double]$B,[double]$Tol){return ([Math]::Abs($A-$B)-le$Tol)}

# =============================================================================================
# Smoke-SegmentComparison - the symmetric same-map A/B contract.
#
# SYNTHETIC CONTRACT. The two "replays" below are generated routes, so the whole comparison
# contract (canonical window set, swap invariance, one-side-no-Drift participation, custom path,
# identity gate, fail-closed correspondence) is testable without a real replay or the game install.
# Real-replay evidence lives in Tests/Smoke-AnalysisClosureReal.ps1.
# =============================================================================================

# --- synthetic route: a thin stadium (two straights 2R apart, opposite headings) --------------
function Stadium-Point([double]$S,[double]$L,[double]$R){
    $arc=[math]::PI*$R
    $P=2.0*$L+2.0*$arc
    $s=$S
    while($s-ge$P){ $s-=$P }
    while($s-lt0.0){ $s+=$P }
    if($s-lt$L){ return @($s,0.0) }
    if($s-lt($L+$arc)){ $th=(($s-$L)/$R)-[math]::PI/2.0; return @(($L+$R*[math]::Cos($th)),($R+$R*[math]::Sin($th))) }
    if($s-lt(2.0*$L+$arc)){ return @(($L-($s-$L-$arc)),(2.0*$R)) }
    $th=[math]::PI/2.0+(($s-2.0*$L-$arc)/$R)
    return @(($R*[math]::Cos($th)),($R+$R*[math]::Sin($th)))
}
function New-StadiumRows {
    param([double]$Straight=200.0,[double]$Radius=5.0,[double]$BaseSpeed=30.0,[double]$SpeedAmp=5.0,[double]$XOffset=0.0,[double]$YOffset=0.0,[int]$Lap=1,[double]$StepM=1.0)
    $P=2.0*$Straight+2.0*[math]::PI*$Radius
    $rows=New-Object System.Collections.Generic.List[object]
    $t=0.0;$s=0.0;$prev=$null
    while($s-le$P+1e-9){
        $pt=Stadium-Point $s $Straight $Radius
        $v=$BaseSpeed+$SpeedAmp*[math]::Sin(2.0*[math]::PI*$s/$P)
        if($null-ne$prev){ $t+=(($s-$prev)/$v) }
        $rows.Add([pscustomobject]@{
            t=$t;x=($pt[0]+$XOffset);y=($pt[1]+$YOffset);z=0.0;distance=$s;speed=$v
            pose_valid=$true;break_before=$false;lap_index=$Lap;has_lap_index=$true
        })
        $prev=$s;$s+=$StepM
    }
    return @($rows.ToArray())
}
function New-Figure8Rows {
    param([double]$A=100.0,[double]$B=80.0,[int]$Steps=600,[double]$BaseSpeed=30.0,[double]$XAmp=1.0,[double]$YBmp=1.0)
    $pts=New-Object System.Collections.Generic.List[object]
    for($k=0;$k-le$Steps;$k++){
        $u=2.0*[math]::PI*($k/[double]$Steps)
        $pts.Add(@(($XAmp*$A*[math]::Sin($u)),($YBmp*$B/2.0*[math]::Sin(2.0*$u))))
    }
    $rows=New-Object System.Collections.Generic.List[object]
    $t=0.0;$d=0.0
    for($k=0;$k-lt$pts.Count;$k++){
        if($k-gt0){
            $seg=[math]::Sqrt([math]::Pow(($pts[$k][0]-$pts[$k-1][0]),2)+[math]::Pow(($pts[$k][1]-$pts[$k-1][1]),2))
            $d+=$seg
            $t+=($seg/$BaseSpeed)
        }
        $rows.Add([pscustomobject]@{
            t=$t;x=$pts[$k][0];y=$pts[$k][1];z=0.0;distance=$d;speed=$BaseSpeed
            pose_valid=$true;break_before=$false;lap_index=1;has_lap_index=$true
        })
    }
    return @($rows.ToArray())
}
# Same shadowing hazard as New-SegmentsFromDistanceSpec: the parameters must not reuse the
# script-scope names $Rows / $D.
function New-TimeAtDistance($RowSet2,[double]$TargetD){
    $last=@($RowSet2).Count-1
    if($TargetD-le[double]$RowSet2[0].distance){ return [double]$RowSet2[0].t }
    if($TargetD-ge[double]$RowSet2[$last].distance){ return [double]$RowSet2[$last].t }
    for($i=1;$i-le$last;$i++){
        if([double]$RowSet2[$i].distance-ge$TargetD){
            $a=$RowSet2[$i-1];$b=$RowSet2[$i]
            $span=[double]$b.distance-[double]$a.distance
            $f=0.0
            if($span-gt1e-12){ $f=($TargetD-[double]$a.distance)/$span }
            return ([double]$a.t+(([double]$b.t-[double]$a.t)*$f))
        }
    }
    return [double]$RowSet2[$last].t
}
# Build NAS segments from DISTANCE specs so the test states corners in route terms.
#
# SPEC SHAPE: specs are passed as a STRING, one spec per ';'-separated group and four comma
# separated distances per group (start, drift end, effect start, effect end):
#     $specPeak  = '50,62,63,67'
#     $spec      = '50,62,63,67;150,162,163,170'
# A string is deliberate. Array arguments bind unpredictably here: PowerShell unwraps exactly one
# array level into an untyped parameter, and `@(@(a,b,c,d))` collapses back to the inner array, so
# a single-corner spec cannot be expressed as nested arrays at all. Writing that form silently made
# $Spec the four scalars 50/62/63/67, produced four malformed episodes with no effect interval, and
# returned ZERO segments (`$sp.Count` is 1 on a scalar, so the effect branch never runs). A ';'
# separated string has no such ambiguity, and an empty group ('' for "no effect") is preserved.
#
# $RowSet / $TargetD must NOT be named $Rows / $D: PowerShell resolves an unqualified variable in
# a callee by walking the CALLER scopes, so a parameter named $Rows is shadowed by any script-scope
# $Rows (this file has a section named exactly that) and the distance lookup reads the wrong object.
function New-SegmentsFromDistanceSpec {
    param($RowSet,[string]$Spec)
    $groups=@($Spec.Split(';') | Where-Object { $_.Trim() -ne '' })
    $eps=New-Object System.Collections.Generic.List[object]
    $eff=New-Object System.Collections.Generic.List[object]
    $idx=0
    foreach($group in $groups){
        $sp=@($group.Split(',') | ForEach-Object { [double]$_ })
        $idx++
        $eps.Add([pscustomobject]@{id=('L1-D'+$idx.ToString('D2'));lap=1;logical_drift_index=$idx
            time=[pscustomobject]@{start_t=(New-TimeAtDistance $RowSet $sp[0]);end_t=(New-TimeAtDistance $RowSet $sp[1])}})
        if($sp.Count-ge4-and$sp[3]-gt0.0){
            $eff.Add([pscustomobject]@{effect_code=2001;semantic_type='drift_small_boost'
                start_t=(New-TimeAtDistance $RowSet $sp[2]);end_t=(New-TimeAtDistance $RowSet $sp[3]);native_end_ms=0})
        }
    }
    $laps=@([pscustomobject]@{lap=1;start_t=[double]$RowSet[0].t;end_t=[double]$RowSet[(@($RowSet).Count-1)].t})
    $contract=NAS-BuildContract -Episodes @($eps.ToArray()) -EffectIntervals @($eff.ToArray()) -Laps $laps
    return @(@($contract.laps | Where-Object { $_.lap -eq 1 })[0].segments)
}
function New-Side {
    param([string]$Key,[string]$Label,$Rows,$Segments,[object]$ResourceMapId=87,[object]$GameMapId=187,[string]$MapName='320',[string]$StreamRole='local_high_frequency',[bool]$SpeedEffectStateAvailable=$true)
    return [pscustomobject][ordered]@{
        key=$Key;label=$Label
        resource_map_id=$ResourceMapId;game_map_id=$GameMapId;map_name=$MapName;map_name_key=([string]$MapName)
        rows=$Rows;lap_start_i=0;lap_end_i=(@($Rows).Count-1);segments=$Segments
        stream_role=$StreamRole;speed_effect_state_available=$SpeedEffectStateAvailable
    }
}

# --- fixtures --------------------------------------------------------------------------------
$rowsA=New-StadiumRows -BaseSpeed 30.0
$rowsB=New-StadiumRows -BaseSpeed 28.0 -YOffset 2.0
$spec='50,62,63,67;150,162,163,170'
$segsA=New-SegmentsFromDistanceSpec -Rows $rowsA -Spec $spec
$segsB=New-SegmentsFromDistanceSpec -Rows $rowsB -Spec $spec
Require ($segsA.Count-eq2) 'the synthetic side A must produce two segments'
Require ($segsB.Count-eq2) 'the synthetic side B must produce two segments'
foreach($s in @($segsA)){ Require ([bool]$s.recovery_available) 'a segment with a native boost must publish a recovery end' }
$sideA=New-Side -Key 'aaa' -Label 'A' -Rows $rowsA -Segments $segsA
$sideB=New-Side -Key 'bbb' -Label 'B' -Rows $rowsB -Segments $segsB

# ---- 1. same-map success, one shared world interval set -------------------------------------
$ab=NSC-BuildComparison -SubjectA $sideA -SubjectB $sideB -LabelA 'A' -LabelB 'B'
Require ([string]$ab.status-eq'ready') ('same-map comparison must be ready, got '+[string]$ab.status+' / '+[string]$ab.reason)
Require ([string]$ab.contract-eq'native_segment_comparison_v1') 'the comparison contract name must be stable'
Require ([int]$ab.schema_version-eq4) 'segment comparison schema must publish v4 core/final timing plus recovery-strategy decomposition'
Require ([string]$ab.delta_rule -like 'delta = subject - baseline*') 'the single delta contract must be published'
Require ([string]$ab.gate.status-eq'comparable_same_resource_map') 'the gate must accept the same authoritative ResourceMapID'
Require ([int]$ab.window_count-eq2) ('two corners must produce two windows, got '+[string]$ab.window_count)
Require ([int]$ab.matched_window_count-eq2) 'both windows must be comparable'
Require ([int]$ab.unpaired_window_count-eq0) 'no window may be unpaired when both sides drove the corner'
Require (-not [bool]$ab.correspondence.time_in_cost) 'time must never be part of the correspondence cost'
Require ([int]$ab.correspondence.pair_count-gt100) ('the thin stadium must correspond fully, pairs='+[string]$ab.correspondence.pair_count)
Require ([int]$ab.correspondence.component_count-eq1) 'a fully corresponded route must be one component'

# ---- 2. every window publishes the seven metrics with a definition and an authority ----------
$expectedMetrics=@('time_s','entry_speed_mps','min_corner_speed_mps','exit_speed_mps','drift_distance_m','recovery_distance_m','total_distance_m')
foreach($w in @($ab.windows)){
    $ids=@($w.metrics | ForEach-Object { [string]$_.id })
    foreach($m in $expectedMetrics){ Require ($ids-contains$m) ('window '+[string]$w.window_id+' is missing metric '+$m) }
    foreach($m in @($w.metrics)){
        Require (-not [string]::IsNullOrWhiteSpace([string]$m.definition)) ('metric '+[string]$m.id+' must publish a definition')
        Require (-not [string]::IsNullOrWhiteSpace([string]$m.authority)) ('metric '+[string]$m.id+' must publish an authority')
    }
    Require ($null-ne$w.time.subject_s-and$null-ne$w.time.baseline_s) 'a comparable window must measure both sides'
    Require ($null-ne$w.space.subject.distance_m-and$null-ne$w.space.baseline.distance_m) 'a comparable window must publish both sides distances'
    Require ([double]$w.space.subject.distance_m-ge0.0) 'a subject distance can never be negative'
    Require ([double]$w.space.baseline.distance_m-ge0.0) 'a baseline distance can never be negative'
    Require ([double]$w.native.subject.total_distance_m-ge0.0) 'a total distance can never be negative'
    Require ([double]$w.native.subject.drift_distance_m-ge0.0) 'a drift distance can never be negative'
    Require ([double]$w.native.subject.recovery_distance_m-ge0.0) 'a recovery distance can never be negative'
    $driftStart=@($w.metrics | Where-Object { $_.id -eq 'drift_distance_m' })[0].value.subject
    $recovery=@($w.metrics | Where-Object { $_.id -eq 'recovery_distance_m' })[0].value.subject
    $total=@($w.metrics | Where-Object { $_.id -eq 'total_distance_m' })[0].value.subject
    # A merged Drift segment is drift + inter-drift gap + recovery; the published drift distance is
    # the native Drift-ACTIVE distance only, so the gap is its own diagnostic term.
    $gap=$w.native.subject.inter_drift_gap_distance_m
    if($null-eq$gap){ $gap=0.0 }
    Require (Approx ([double]$total) ([double]$driftStart+[double]$gap+[double]$recovery) 0.02) 'total distance must equal drift + inter-drift gap + recovery distance'
    if([int]$w.native.subject.drift_count -eq 1){ Require (Approx ([double]$gap) 0.0 1e-6) 'a single-Drift segment has no inter-drift gap distance' }
}
$first=@($ab.windows)[0]
Require ([double]$first.speed.subject.entry_mps-gt0.0) 'entry speed must be a real measured speed'
Require ([double]$first.native.subject.exit_speed_mps-gt0.0) 'exit speed must be a real measured speed'
Require ([double]$first.native.subject.min_corner_speed_mps-le[double]$first.speed.subject.entry_mps+1e-6) 'the minimum corner speed cannot exceed the entry speed'
# Boundary helper semantics: native ENTRY uses a centered 3-sample median, not the old one-sided
# 8-sample average. (Exit speed is tested separately below as the peak of the own recovery window.)
# Inject asymmetric neighbours so the estimators differ visibly.
$probeRows=New-Object System.Collections.Generic.List[object]
for($i=0;$i-lt12;$i++){
    $v=100.0
    if($i-eq3){$v=10.0}elseif($i-eq4){$v=20.0}elseif($i-eq5){$v=90.0}elseif($i-eq8){$v=80.0}elseif($i-eq9){$v=30.0}elseif($i-eq10){$v=40.0}
    $probeRows.Add([pscustomobject]@{pose_valid=$true;speed=$v})
}
$entryProbe=NDA-MedianBoundarySpeed -Rows @($probeRows.ToArray()) -Center 4 -Low 0 -High 11
$exitProbe=NDA-MedianBoundarySpeed -Rows @($probeRows.ToArray()) -Center 9 -Low 0 -High 11
Require (Approx ([double]$entryProbe) 20.0 1e-9) 'native entry boundary speed must be the median of center +/-1 sample'
Require (Approx ([double]$exitProbe) 40.0 1e-9) 'native exit boundary speed must be the median of center +/-1 sample'
$legacyEntry=NDA-AverageEdgeSpeed -Rows @($probeRows.ToArray()) -Start 4 -End 11 -FromStart $true
Require (-not (Approx ([double]$entryProbe) ([double]$legacyEntry) 1e-9)) 'native boundary speed must not fall back to the former 8-sample edge average'

# Exit/recovery metrics are OWN-SIDE semantic measurements, never products of the shared A/B
# route boundary. Make the native recovery speed peak obvious, then measure the same corner through
# two different shared windows: exit speed and recovery distance must stay identical.
$rowsPeak=New-StadiumRows -BaseSpeed 30.0 -SpeedAmp 0.0
# One distance spec must reach the helper as ONE entry. `@(@(...))` does NOT nest here: an array
# literal argument is flattened by the parameter binder, so the helper would read four scalar specs.
# Binding the single spec to a variable first is the form the other call sites already use.
$specPeak='50,62,63,67'
$segsPeak=New-SegmentsFromDistanceSpec -Rows $rowsPeak -Spec $specPeak
foreach($r in @($rowsPeak)){
    $d=[double]$r.distance
    if($d-ge62.0-and$d-le67.0){ $r.speed=20.0+(($d-62.0)*5.0) }
    if([math]::Abs($d-65.0)-lt0.01){ $r.speed=60.0 }
}
$cpPeak=@(NTA-TrajectoryControlPoints $rowsPeak 0 (@($rowsPeak).Count-1) -MaxPoints 2000)
$corrPeak=NTA-SharedCorrespondence -Subject $cpPeak -Baseline $cpPeak
Require ([string]$corrPeak.status-eq'ready') 'peak-speed self correspondence must be ready'
$pairsPeak=@($corrPeak.pairs)
$anchorsPeak=@(NSC-CornerAnchors -Segments $segsPeak -ControlPoints $cpPeak -Pairs $pairsPeak -Rows $rowsPeak -RowStart 0 -RowEnd (@($rowsPeak).Count-1) -Side 'a')
Require ($anchorsPeak.Count-eq1-and[string]$anchorsPeak[0].status-eq'ready') 'peak-speed corner anchor must be ready'
$cornerPeak=$anchorsPeak[0]
$midS=[double]$cornerPeak.s_start+(([double]$cornerPeak.s_end-[double]$cornerPeak.s_start)*0.55)
$shortWin=[pscustomobject]@{s_start=[double]$cornerPeak.s_start;s_end=$midS}
$fullWin=[pscustomobject]@{s_start=[double]$cornerPeak.s_start;s_end=[double]$cornerPeak.s_end}
$mShort=NSC-MeasureSide -Window $shortWin -Corner $cornerPeak -ControlPoints $cpPeak -Pairs $pairsPeak -Rows $rowsPeak -RowStart 0 -RowEnd (@($rowsPeak).Count-1) -Side 'a' -StreamRole 'local_high_frequency' -SpeedEffectStateAvailable $true
$mFull=NSC-MeasureSide -Window $fullWin -Corner $cornerPeak -ControlPoints $cpPeak -Pairs $pairsPeak -Rows $rowsPeak -RowStart 0 -RowEnd (@($rowsPeak).Count-1) -Side 'a' -StreamRole 'local_high_frequency' -SpeedEffectStateAvailable $true
Require (Approx ([double]$mShort.exit_speed_mps) 60.0 1e-6) 'exit speed must be the peak inside the own native recovery window'
Require (Approx ([double]$mShort.exit_speed_mps) ([double]$mFull.exit_speed_mps) 1e-9) 'shared-route window length must not change own-side exit speed'
Require (Approx ([double]$mShort.recovery_distance_m) ([double]$mFull.recovery_distance_m) 1e-9) 'shared-route window length must not change own-side recovery distance'
Require ([string]$mShort.exit_speed_source-eq'own_recovery_window_peak') 'exit speed must declare own recovery-window authority'

# Paired-corner primary time must NOT let the longer recovery strategy choose the comparison end.
# This models the field case "double spray vs single spray": both sides keep their own full recovery
# metrics, but the main time comparison stops at the earlier natural recovery end. The earlier Drift
# entry is intentionally retained so an early/late entry choice remains part of corner efficiency.
$coreRowsLong=New-StadiumRows -BaseSpeed 31.0 -SpeedAmp 0.0
$coreRowsShort=New-StadiumRows -BaseSpeed 30.0 -SpeedAmp 0.0 -YOffset 2.0
$specLong='50,62,63,75'
$specShort='50,62,63,67'
$coreSegLong=New-SegmentsFromDistanceSpec -Rows $coreRowsLong -Spec $specLong
$coreSegShort=New-SegmentsFromDistanceSpec -Rows $coreRowsShort -Spec $specShort
$coreSideLong=New-Side -Key 'aaa-core-long' -Label 'LONG' -Rows $coreRowsLong -Segments $coreSegLong
$coreSideShort=New-Side -Key 'bbb-core-short' -Label 'SHORT' -Rows $coreRowsShort -Segments $coreSegShort
$coreCmp=NSC-BuildComparison -SubjectA $coreSideLong -SubjectB $coreSideShort -LabelA 'LONG' -LabelB 'SHORT'
Require ([string]$coreCmp.status-eq'ready') ('single-vs-double-spray core comparison must be ready: '+[string]$coreCmp.reason)
Require ([int]$coreCmp.window_count-eq1) 'single-vs-double-spray fixture must produce one paired window'
$coreW=@($coreCmp.windows)[0]
Require ([bool]$coreW.corner_paired) 'single-vs-double-spray fixture must pair the same corner'
Require ([string]$coreW.space.core_window_rule -like '*earlier mapped natural recovery end*') 'paired primary time must publish the shorter-recovery cap rule'
$coreNatural=$coreW.space.natural_bounds
Require ($null-ne$coreNatural) 'paired primary time must publish both natural bounds for audit'
$coreExpectedStart=[math]::Min([double]$coreNatural.subject_start,[double]$coreNatural.baseline_start)
$coreExpectedEnd=[math]::Min([double]$coreNatural.subject_end,[double]$coreNatural.baseline_end)
Require (Approx ([double]$coreW.space.shared_start) $coreExpectedStart 1e-8) 'primary time must retain the earlier mapped Drift start'
Require (Approx ([double]$coreW.space.shared_end) $coreExpectedEnd 1e-8) 'primary time must stop at the earlier mapped natural recovery end'
$coreExpectedFinal=[math]::Max([double]$coreNatural.subject_end,[double]$coreNatural.baseline_end)
Require (Approx ([double]$coreW.space.final_shared_end) $coreExpectedFinal 1e-8) 'final net time must extend to the later mapped natural recovery end'
Require ([double]$coreW.space.final_shared_end-ge[double]$coreW.space.shared_end) 'final window cannot end before the core window'
Require ($null-ne$coreW.final_time.delta_s) 'paired corner must publish a final net time delta'
Require ($null-ne$coreW.recovery_strategy.subject_net_gain_s) 'paired corner must publish recovery-strategy net gain'
Require (Approx ([double]$coreW.recovery_strategy.subject_net_gain_s) ([double]$coreW.core_time.delta_s-[double]$coreW.final_time.delta_s) 1e-9) 'recovery gain must equal core delta minus final delta'
Require (Approx ([double]$coreW.final_time.delta_s) (([double]$coreW.core_time.delta_s)+([double]$coreW.recovery_strategy.subject_tail_s-[double]$coreW.recovery_strategy.baseline_tail_s)) 1e-9) 'final delta must equal core delta plus the two sides tail-time difference'
Require ([double]$coreW.native.subject.recovery_distance_m-gt[double]$coreW.native.baseline.recovery_distance_m+1.0) 'the longer recovery side must keep its own longer recovery metric'
Require ([double]$coreW.space.subject.distance_m-lt[double]$coreW.native.subject.total_distance_m-1.0) 'the longer recovery tail must be excluded from primary time while remaining in own-side metrics'
$coreSwap=NSC-BuildComparison -SubjectA $coreSideShort -SubjectB $coreSideLong -LabelA 'SHORT' -LabelB 'LONG'
$coreWS=@($coreSwap.windows)[0]
Require (Approx ([double]$coreW.space.shared_start) ([double]$coreWS.space.shared_start) 1e-9) 'core-window start must be swap invariant'
Require (Approx ([double]$coreW.space.shared_end) ([double]$coreWS.space.shared_end) 1e-9) 'core-window end must be swap invariant'
Require (Approx ([double]$coreW.space.final_shared_end) ([double]$coreWS.space.final_shared_end) 1e-9) 'final-window end must be swap invariant'
Require (Approx ([double]$coreW.time.delta_s) (-1.0*[double]$coreWS.time.delta_s) 1e-9) 'core-window time delta must negate under swap'
Require (Approx ([double]$coreW.final_time.delta_s) (-1.0*[double]$coreWS.final_time.delta_s) 1e-9) 'final-window time delta must negate under swap'
Require (Approx ([double]$coreW.recovery_strategy.subject_net_gain_s) (-1.0*[double]$coreWS.recovery_strategy.subject_net_gain_s) 1e-9) 'recovery-strategy gain must negate under swap'

# A low-frequency side can lack observable native effect state even when the driven exit contains a
# single spray. Its metric layer gets the gameplay-minimum 0.25 s tail, while the strict published
# segment STILL says recovery unavailable. A local/observable no-code2001 side stays at 0 m so the
# earlier nitro-only ownership fix cannot regress.
$rowsNoEffect=New-StadiumRows -BaseSpeed 25.0 -SpeedAmp 0.0
# No effect interval: the group carries empty fields instead of a fourth distance. 0 is never a
# real route distance, so the effect branch keys on the parsed value rather than on field count.
$specNoEffect='50,62,,'
$segsNoEffect=New-SegmentsFromDistanceSpec -Rows $rowsNoEffect -Spec $specNoEffect
$sideNoEffectLocal=New-Side -Key 'nolocal' -Label 'NL' -Rows $rowsNoEffect -Segments $segsNoEffect -StreamRole 'local_high_frequency' -SpeedEffectStateAvailable $true
$sideNoEffectNet=New-Side -Key 'nonet' -Label 'NN' -Rows $rowsNoEffect -Segments $segsNoEffect -StreamRole 'network_low_frequency' -SpeedEffectStateAvailable $false
$refEffect=New-Side -Key 'refeffect' -Label 'R' -Rows $rowsA -Segments $segsA
$cmpNoLocal=NSC-BuildComparison -SubjectA $refEffect -SubjectB $sideNoEffectLocal -LabelA 'R' -LabelB 'NL'
$cmpNoNet=NSC-BuildComparison -SubjectA $refEffect -SubjectB $sideNoEffectNet -LabelA 'R' -LabelB 'NN'
$localNo=@($cmpNoLocal.windows | Where-Object { $null-ne$_.native.baseline.segment_index })[0].native.baseline
$netNo=@($cmpNoNet.windows | Where-Object { $null-ne$_.native.baseline.segment_index })[0].native.baseline
Require (-not[bool]$localNo.recovery_available) 'observable no-code2001 segment must remain recovery-unavailable'
Require (Approx ([double]$localNo.recovery_distance_m) 0.0 1e-6) 'observable no-code2001 segment must not invent a recovery tail'
Require (-not[bool]$netNo.recovery_available) 'metric fallback must not rewrite strict native segment ownership'
Require ([double]$netNo.recovery_distance_m-gt0.0) 'unobservable low-frequency single-spray metric must not collapse to 0 m'
Require ([string]$netNo.recovery_metric_source-eq'gameplay_min_small_boost_tail_0p25s') 'low-frequency fallback must declare the 0.25 s gameplay source'

# A is the faster side here (higher base speed), so the subject needs LESS time.
Require ([double]$first.time.delta_s-lt0.0) 'a faster subject must publish a negative time delta'
Require ([string]$first.time.direction-eq'faster') 'the direction word must follow the delta sign'

# ---- 3. swap invariance: identical world intervals, exactly negated deltas -------------------
$ba=NSC-BuildComparison -SubjectA $sideB -SubjectB $sideA -LabelA 'B' -LabelB 'A'
Require ([string]$ba.status-eq'ready') 'the swapped comparison must also be ready'
Require ([int]$ba.window_count-eq[int]$ab.window_count) 'swapping A/B must not change the window count'
Require ([string]$ba.canonical_order.first-eq[string]$ab.canonical_order.first) 'the canonical side order must not depend on the caller arguments'
Require ([string]$ba.canonical_order.second-eq[string]$ab.canonical_order.second) 'the canonical side order must not depend on the caller arguments'
for($k=0;$k-lt[int]$ab.window_count;$k++){
    $wf=@($ab.windows)[$k];$wr=@($ba.windows)[$k]
    Require ([string]$wf.window_id-eq[string]$wr.window_id) 'the swapped comparison must publish the same window ids'
    Require (Approx ([double]$wf.space.shared_start) ([double]$wr.space.shared_start) 1e-9) 'A->B and B->A must use the SAME world interval start'
    Require (Approx ([double]$wf.space.shared_end) ([double]$wr.space.shared_end) 1e-9) 'A->B and B->A must use the SAME world interval end'
    Require (Approx ([double]$wf.space.subject.distance_m) ([double]$wr.space.baseline.distance_m) 1e-6) 'the subject of one direction must equal the baseline distance of the other'
    for($m=0;$m-lt@($wf.metrics).Count;$m++){
        $mf=@($wf.metrics)[$m];$mr=@($wr.metrics)[$m]
        Require ([string]$mf.id-eq[string]$mr.id) 'the swapped comparison must publish the metrics in the same order'
        if($null-ne$mf.value.delta){
            Require ($null-ne$mr.value.delta) 'a delta present in one direction must be present in the other'
            Require (Approx ([double]$mf.value.delta) (-1.0*[double]$mr.value.delta) 1e-9) ('metric '+[string]$mf.id+' must negate exactly under swap on window '+[string]$wf.window_id)
        }
    }
    Require (Approx ([double]$wf.time.delta_s) (-1.0*[double]$wr.time.delta_s) 1e-9) 'the window time delta must negate exactly under swap'
}

# ---- 4. determinism -------------------------------------------------------------------------
$ab2=NSC-BuildComparison -SubjectA $sideA -SubjectB $sideB -LabelA 'A' -LabelB 'B'
Require (((@($ab.windows) | ConvertTo-Json -Depth 16 -Compress)) -eq ((@($ab2.windows) | ConvertTo-Json -Depth 16 -Compress))) 'the comparison must be deterministic'

# ---- 5. one side has no Drift: route / time / speed comparison still runs -------------------
$specBextra='50,62,63,67;150,162,163,170;300,312,313,318'
$segsBextra=New-SegmentsFromDistanceSpec -Rows $rowsB -Spec $specBextra
$sideBextra=New-Side -Key 'bbb' -Label 'B' -Rows $rowsB -Segments $segsBextra
$oneSided=NSC-BuildComparison -SubjectA $sideA -SubjectB $sideBextra -LabelA 'A' -LabelB 'B'
Require ([string]$oneSided.status-eq'ready') 'a corner only one side drove must not disable the comparison'
Require ([int]$oneSided.window_count-eq3) ('three corners must produce three windows, got '+[string]$oneSided.window_count)
Require ([int]$oneSided.unpaired_window_count-eq1) 'exactly one window must be unpaired'
$unpaired=@($oneSided.windows | Where-Object { -not [bool]$_.corner_paired })[0]
Require ($null-ne$unpaired.time.subject_s-and$null-ne$unpaired.time.baseline_s) 'an unpaired corner must still measure both sides time'
Require ([double]$unpaired.speed.subject.entry_mps-gt0.0) 'an unpaired corner must still measure the other side speed'
Require ([double]$unpaired.space.subject.distance_m-gt0.0) 'an unpaired corner must still measure the other side route'
$noDriftSide=$(if($null-eq$unpaired.native.subject.segment_index){$unpaired.native.subject}else{$unpaired.native.baseline})
Require ($null-eq$noDriftSide.drift_distance_m) 'a side without a native Drift must publish drift distance as unavailable, never as 0'
Require ($null-eq$noDriftSide.exit_speed_mps) 'a side without a native Drift must publish exit speed as unavailable'
Require ($null-eq$noDriftSide.recovery_distance_m) 'a side without a native Drift must publish recovery distance as unavailable'
# and the swap of that case must still be invariant
$oneSidedSwap=NSC-BuildComparison -SubjectA $sideBextra -SubjectB $sideA -LabelA 'B' -LabelB 'A'
for($k=0;$k-lt[int]$oneSided.window_count;$k++){
    $wf=@($oneSided.windows)[$k];$wr=@($oneSidedSwap.windows)[$k]
    Require (Approx ([double]$wf.space.shared_start) ([double]$wr.space.shared_start) 1e-9) 'an unpaired corner must keep the same world interval under swap'
    Require (Approx ([double]$wf.space.shared_end) ([double]$wr.space.shared_end) 1e-9) 'an unpaired corner must keep the same world interval under swap'
    if($null-ne$wf.time.delta_s){ Require (Approx ([double]$wf.time.delta_s) (-1.0*[double]$wr.time.delta_s) 1e-9) 'an unpaired corner must still negate under swap' }
}

# ---- 6. custom path maps onto ONE shared world interval -------------------------------------
$custom=@{side_key='aaa';start_d=150.0;end_d=172.0}
$custAB=NSC-BuildComparison -SubjectA $sideA -SubjectB $sideB -Mode custom -CustomInterval $custom
Require ([string]$custAB.status-eq'ready') ('a custom interval must be comparable, got '+[string]$custAB.status+' / '+[string]$custAB.reason)
Require ([int]$custAB.window_count-eq1) 'a custom interval must produce exactly one window'
Require ([string](@($custAB.windows)[0]).source-eq'custom_path_shared_world_interval') 'a custom window must say where it came from'
$custSwap=NSC-BuildComparison -SubjectA $sideB -SubjectB $sideA -Mode custom -CustomInterval $custom
Require (Approx ([double](@($custAB.windows)[0]).space.shared_start) ([double](@($custSwap.windows)[0]).space.shared_start) 1e-9) 'a custom interval must map to the same world interval in both directions'
Require (Approx ([double](@($custAB.windows)[0]).space.shared_end) ([double](@($custSwap.windows)[0]).space.shared_end) 1e-9) 'a custom interval must map to the same world interval in both directions'
Require (Approx ([double](@($custAB.windows)[0]).time.delta_s) (-1.0*[double](@($custSwap.windows)[0]).time.delta_s) 1e-9) 'a custom interval must negate under swap'
Require (Approx ([double](@($custAB.windows)[0]).space.subject.distance_m) 22.0 3.0) 'a custom interval must measure the chosen route distance, not a timestamp ratio'
$custBad=NSC-BuildComparison -SubjectA $sideA -SubjectB $sideB -Mode custom -CustomInterval @{side_key='zzz';start_d=150.0;end_d=172.0}
Require ([string]$custBad.status-eq'comparison_unavailable') 'a custom interval naming an unknown side must fail closed'

# ---- 7. no next-Drift leakage ----------------------------------------------------------------
# Corner one's recovery is longer than the gap to the next Drift, so the native hard cut must bound
# the measured window: nothing from the next corner may enter this window.
$specTight='50,62,65,80;72,84,85,90'
$segsTight=New-SegmentsFromDistanceSpec -Rows $rowsA -Spec $specTight
Require ([string]$segsTight[0].recovery_stop_reason-eq'next_drift_hard_cut') 'a recovery reaching past the next Drift must be hard cut in the segmentation'
$sideTight=New-Side -Key 'aaa' -Label 'A' -Rows $rowsA -Segments $segsTight
$tight=@(NSC-BuildComparison -SubjectA $sideTight -SubjectB $sideTight -LabelA 'A' -LabelB 'A')
Require ($tight.Count-eq1) 'a self comparison must still produce exactly one contract object'
$tightC=$tight[0]
Require ([string]$tightC.status-eq'ready') 'a self comparison of a hard-cut side must be ready'
$w0=@($tightC.windows)[0]
Require ($null-ne$w0.space.subject.end_distance_m) 'a comparable window must publish the measured end distance'
Require ([double]$w0.space.subject.end_distance_m-le72.5) ('no window may leak across the next independent Drift start, end='+[string]$w0.space.subject.end_distance_m)
Require ([double]$w0.space.baseline.end_distance_m-le72.5) 'no window may leak across the next independent Drift start on either side'
Require ([int]$w0.native.subject.drift_count-eq1) 'the first window must own exactly its own logical Drift'

# ---- 8. geometry traps: parallel opposite-heading straights and a self-crossing route --------
$a2b=NTA-SharedCorrespondence -Subject @(NTA-TrajectoryControlPoints $rowsA 0 (@($rowsA).Count-1) -MaxPoints 180) -Baseline @(NTA-TrajectoryControlPoints $rowsB 0 (@($rowsB).Count-1) -MaxPoints 180)
Require ([string]$a2b.status-eq'ready') 'the thin stadium must correspond'
foreach($p in @($a2b.pairs)){
    Require ([double]$p.heading_delta_deg-le80.0) ('a pair must respect the heading gate, got '+[string]$p.heading_delta_deg)
    Require ([double]$p.separation_m-le30.0) 'a pair must respect the separation gate'
    Require ([math]::Abs([double]$p.a_progress-[double]$p.b_progress)-le0.08) 'a pair must stay inside the progress band (no jump to the other straight)'
}
for($k=1;$k-lt@($a2b.pairs).Count;$k++){
    $prev=@($a2b.pairs)[$k-1];$cur=@($a2b.pairs)[$k]
    Require ([double]$cur.a_progress-ge[double]$prev.a_progress-1e-9) 'the correspondence must be monotone on the subject side'
    Require ([double]$cur.b_progress-ge[double]$prev.b_progress-1e-9) 'the correspondence must be monotone on the baseline side'
}
$f8a=New-Figure8Rows -A 100.0 -B 80.0
$f8b=New-Figure8Rows -A 98.0 -B 78.0
$f8=NTA-SharedCorrespondence -Subject @(NTA-TrajectoryControlPoints $f8a 0 (@($f8a).Count-1) -MaxPoints 180) -Baseline @(NTA-TrajectoryControlPoints $f8b 0 (@($f8b).Count-1) -MaxPoints 180)
Require ([string]$f8.status-eq'ready') 'a self-crossing route must still correspond'
foreach($p in @($f8.pairs)){ Require ([double]$p.heading_delta_deg-le80.0) 'a self-crossing route must respect the heading gate' }
for($k=1;$k-lt@($f8.pairs).Count;$k++){
    $prev=@($f8.pairs)[$k-1];$cur=@($f8.pairs)[$k]
    Require ([double]$cur.a_progress-ge[double]$prev.a_progress-1e-9) 'a self-crossing route must stay monotone'
    Require ([math]::Abs([double]$cur.a_progress-[double]$cur.b_progress)-le0.08) 'a self-crossing route must never pair across the crossing'
}

# ---- 9. time is never part of the correspondence cost ---------------------------------------
# Permute one side's timestamps (keeping the driven geometry and distance order intact) and the
# correspondence must be bit-identical. A time-based matcher would move.
$perm=New-Object System.Collections.Generic.List[object]
$n=@($rowsB).Count
foreach($r in @($rowsB)){
    $perm.Add([pscustomobject]@{t=(([double]$r.t)*0.5+1000.0);x=$r.x;y=$r.y;z=$r.z;distance=$r.distance;speed=$r.speed;pose_valid=$true;break_before=$false;lap_index=1;has_lap_index=$true})
}
$permCorr=NTA-SharedCorrespondence -Subject @(NTA-TrajectoryControlPoints $rowsA 0 (@($rowsA).Count-1) -MaxPoints 180) -Baseline @(NTA-TrajectoryControlPoints @($perm.ToArray()) 0 ($n-1) -MaxPoints 180)
Require ([int]$permCorr.stats.pair_count-eq[int]$a2b.stats.pair_count) 'a pure time permutation must not change the pair count'
for($k=0;$k-lt@($a2b.pairs).Count;$k++){
    $p=@($a2b.pairs)[$k];$q=@($permCorr.pairs)[$k]
    Require ([int]$p.a_index-eq[int]$q.a_index-and[int]$p.b_index-eq[int]$q.b_index) 'a pure time permutation must not change which positions correspond'
}

# ---- 10. identity gate: authoritative same-map without a basemap, and real conflicts ---------
$gateA=NSC-IdentityGate -SideA (New-Side -Key 'a' -Label 'A' -Rows $rowsA -Segments $segsA -ResourceMapId 87 -GameMapId 187) -SideB (New-Side -Key 'b' -Label 'B' -Rows $rowsB -Segments $segsB -ResourceMapId 87 -GameMapId 187)
Require ([bool]$gateA.comparable) 'the same authoritative ResourceMapID must be comparable'
$gateNoIds=NSC-IdentityGate -SideA (New-Side -Key 'a' -Label 'A' -Rows $rowsA -Segments $segsA -ResourceMapId $null -GameMapId $null -MapName '320') -SideB (New-Side -Key 'b' -Label 'B' -Rows $rowsB -Segments $segsB -ResourceMapId $null -GameMapId $null -MapName '320')
Require ([bool]$gateNoIds.comparable) 'an exact same official map name must be comparable when no id is authoritative'
Require ([string]$gateNoIds.basis-eq'exact_same_map_name') 'the name fallback must say so'
$gateGame=NSC-IdentityGate -SideA (New-Side -Key 'a' -Label 'A' -Rows $rowsA -Segments $segsA -ResourceMapId $null -GameMapId 187 -MapName '320') -SideB (New-Side -Key 'b' -Label 'B' -Rows $rowsB -Segments $segsB -ResourceMapId $null -GameMapId 187 -MapName '320')
Require ([bool]$gateGame.comparable) 'the same authoritative GameMapID must be comparable'
$gateNameConflict=NSC-IdentityGate -SideA (New-Side -Key 'a' -Label 'A' -Rows $rowsA -Segments $segsA -ResourceMapId $null -GameMapId $null -MapName '320') -SideB (New-Side -Key 'b' -Label 'B' -Rows $rowsB -Segments $segsB -ResourceMapId $null -GameMapId $null -MapName 'OTHER-MAP')
Require (-not[bool]$gateNameConflict.comparable) 'a different official map name must fail closed'
$gateConflict=NSC-IdentityGate -SideA (New-Side -Key 'a' -Label 'A' -Rows $rowsA -Segments $segsA -ResourceMapId 87 -GameMapId 187) -SideB (New-Side -Key 'b' -Label 'B' -Rows $rowsB -Segments $segsB -ResourceMapId 88 -GameMapId 187)
Require (-not[bool]$gateConflict.comparable) 'two different ResourceMapIDs must fail closed even when the GameMapID agrees'
Require ([string]$gateConflict.status-eq'unavailable_conflicting_resource_map') 'a resource-map conflict must name itself'
$conflictC=NSC-BuildComparison -SubjectA (New-Side -Key 'a' -Label 'A' -Rows $rowsA -Segments $segsA -ResourceMapId 87) -SubjectB (New-Side -Key 'b' -Label 'B' -Rows $rowsB -Segments $segsB -ResourceMapId 88)
Require ([string]$conflictC.status-eq'comparison_unavailable') 'an identity conflict must refuse the comparison'
Require ([int]$conflictC.window_count-eq0) 'a refused comparison publishes no windows'

# ---- 11. insufficient overlap fails closed --------------------------------------------------
$farRows=New-StadiumRows -BaseSpeed 30.0 -YOffset 200.0
$sideFar=New-Side -Key 'bbb' -Label 'B' -Rows $farRows -Segments (New-SegmentsFromDistanceSpec -Rows $farRows -Spec $spec)
$far=NSC-BuildComparison -SubjectA $sideA -SubjectB $sideFar -LabelA 'A' -LabelB 'B'
Require ([string]$far.status-eq'comparison_unavailable') 'two routes with no admissible counterpart must fail closed'
Require ([string]$far.reason -like 'unavailable_*') 'a fail-closed comparison must name the correspondence status'
Require ([int]$far.window_count-eq0) 'a fail-closed comparison publishes no windows'

# ---- 12. cross-lap segment tail is measured, not truncated ----------------------------------
$twoLapRows=New-Object System.Collections.Generic.List[object]
$boundaryRow=$null
$lf=0.0
foreach($r in @($rowsA)){
    $lap=1
    if([double]$r.distance-gt190.0){ $lap=2 }
    if($lap-eq2-and$null-eq$boundaryRow){ $boundaryRow=[double]$r.distance }
    $twoLapRows.Add([pscustomobject]@{t=$r.t;x=$r.x;y=$r.y;z=$r.z;distance=$r.distance;speed=$r.speed;pose_valid=$true;break_before=$false;lap_index=$lap;has_lap_index=$true})
}
$rowsLap=@($twoLapRows.ToArray())
$lapEndIdx=0
for($i=0;$i-lt$rowsLap.Count;$i++){ if([int]$rowsLap[$i].lap_index-eq1){ $lapEndIdx=$i } }
$epsCross=@(
    [pscustomobject]@{id='L1-D01';lap=1;logical_drift_index=1;time=[pscustomobject]@{start_t=(New-TimeAtDistance $rowsLap 185.0);end_t=(New-TimeAtDistance $rowsLap 205.0)}}
)
$effCross=@([pscustomobject]@{effect_code=2001;semantic_type='drift_small_boost';start_t=(New-TimeAtDistance $rowsLap 206.0);end_t=(New-TimeAtDistance $rowsLap 212.0);native_end_ms=0})
$lapsCross=@([pscustomobject]@{lap=1;start_t=[double]$rowsLap[0].t;end_t=[double]$rowsLap[$lapEndIdx].t},[pscustomobject]@{lap=2;start_t=[double]$rowsLap[$lapEndIdx+1].t;end_t=[double]$rowsLap[$rowsLap.Count-1].t})
$crossContract=NAS-BuildContract -Episodes $epsCross -EffectIntervals $effCross -Laps $lapsCross
$crossSegs=@(@($crossContract.laps | Where-Object { $_.lap -eq 1 })[0].segments)
Require ($crossSegs.Count-eq1) 'the cross-lap fixture must produce one lap-1 segment'
Require ([bool]$crossSegs[0].crosses_lap_boundary) 'a drift spanning the lap boundary must be flagged'
Require (Approx ([double]$crossSegs[0].recovery_end_t) (New-TimeAtDistance $rowsLap 212.0) 0.02) 'the cross-lap recovery must not be truncated at the lap boundary'
$sideCross=[pscustomobject][ordered]@{key='ccc';label='C';resource_map_id=87;game_map_id=187;map_name='320';map_name_key='320';rows=$rowsLap;lap_start_i=0;lap_end_i=$lapEndIdx;segments=$crossSegs}
$crossCompare=NSC-BuildComparison -SubjectA $sideCross -SubjectB $sideCross -LabelA 'C' -LabelB 'C'
Require ([string]$crossCompare.status-eq'ready') 'a cross-lap segment must still produce a comparable window'
$cw=@($crossCompare.windows)[0]
Require ([double]$cw.space.subject.end_distance_m-gt[double]$boundaryRow) ('the measured cross-lap window must extend past the lap boundary, end='+[string]$cw.space.subject.end_distance_m+' boundary='+[string]$boundaryRow+' windows='+[string](@($crossCompare.windows).Count)+' s_end='+[string]$cw.space.shared_end)
Require ([double]$cw.native.subject.total_distance_m-ge26.5) ('the cross-lap total distance must cover start -> recovery end, total='+[string]$cw.native.subject.total_distance_m)

Write-Host '[OK] Segment comparison contract passed. cases=same-map/core-window-shorter-recovery-cap/seven-metrics/own-side-recovery-metrics/swap-invariant-exact/identical-world-interval/determinism/one-side-no-drift/custom-path/custom-side-fail-closed/next-drift-no-leak/parallel-opposite-heading/self-crossing/time-free-correspondence/identity-gate/basemap-not-a-prerequisite/conflict-fail-closed/insufficient-overlap-fail-closed/cross-lap-tail'
exit 0
