param()
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
$appDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $appDir 'Modules\Native\NativeDrivingAnalysis.ps1')
. (Join-Path $appDir 'Modules\Native\NativeDrivingEpisodes.ps1')
. (Join-Path $appDir 'Modules\Native\NativeTrainingSections.ps1')
. (Join-Path $appDir 'Modules\Native\NativeTrainingTimeLoss.ps1')
. (Join-Path $appDir 'Modules\Native\NativeTrainingAnalysis.ps1')
function Require([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message}}
function Approx([double]$A,[double]$B,[double]$Tol){return ([Math]::Abs($A-$B)-le$Tol)}

# ---------------------------------------------------------------------------
# Native Training Analysis v1.1 -- shared spatial comparison + delta contract.
#
# Fast Gate, synthetic. It pins the contracts that must never regress:
#   * ONE delta contract everywhere: delta = subject - baseline, so positive means the subject is
#     SLOWER. The outer lap total and the decomposition total must be the same number (Case A);
#   * a slower subject section is +1.0 s / direction `slower` / classification `loss` (Case B) and a
#     faster one is -1.0 s / `faster` / `gain` (Case C);
#   * a natural-language observation never contradicts its own sign (Case D);
#   * `top_loss_sections` only contains real time loss and `top_gain_sections` only real gain;
#   * the shared spatial correspondence is monotonic, order preserving, heading compatible, bounded
#     and fail-closed - nothing is ever force-paired, and an unmatched region stays unmatched;
#   * the decomposition RECONCILES: matched + unmatched + non_comparison + residual == total;
#   * comparing A vs B and B vs A negates every signed metric (swap invariant);
#   * two replays of DIFFERENT or unresolved official ResourceMapID are NEVER compared (permanent);
#   * `unavailable` is published as null, never as 0.
# ---------------------------------------------------------------------------

# --- synthetic builders ---------------------------------------------------------------------

function New-Control([int]$Block,[double]$D,[double]$T,[double]$X,[double]$Y){
    return [pscustomobject]@{block=$Block;row_i=0;d=$D;t=$T;x=$X;y=$Y}
}
# A straight driven route of `Length` metres, `Count` control points, at a constant lateral offset.
function New-LineControls([double]$Length,[int]$Count,[double]$Y=0.0){
    $out=New-Object System.Collections.Generic.List[object]
    for($k=0;$k-lt$Count;$k++){
        $f=$k/[double]($Count-1)
        $out.Add((New-Control 0 ($f*$Length) $f ($f*$Length) $Y))
    }
    return @($out.ToArray())
}
# The same route driven in the opposite direction: same positions, reversed order.
function New-ReversedControls([double]$Length,[int]$Count){
    $out=New-Object System.Collections.Generic.List[object]
    for($k=0;$k-lt$Count;$k++){
        $f=$k/[double]($Count-1)
        $out.Add((New-Control 0 ($f*$Length) $f ($Length-$f*$Length) 0.0))
    }
    return @($out.ToArray())
}
# Production-shaped telemetry rows: monotone time, monotone measured distance, valid poses.
function New-RowsFromCourse([double[]]$Distances,[double[]]$Times,[double]$Y=0.0){
    $out=New-Object System.Collections.Generic.List[object]
    for($i=0;$i-lt$Distances.Count;$i++){
        $out.Add([pscustomobject]@{
            t=[double]$Times[$i];x=[double]$Distances[$i];y=$Y;z=0.0;distance=[double]$Distances[$i]
            speed=0.0;pose_valid=$true;break_before=$false;lap_index=1
        })
    }
    return @($out.ToArray())
}
# A constant-speed lap: `Length` metres in `LapSeconds`, sampled in `Steps` intervals.
function New-ConstantSpeedRows([double]$Length,[double]$LapSeconds,[int]$Steps,[double]$Y=0.0){
    $d=New-Object System.Collections.Generic.List[double]
    $t=New-Object System.Collections.Generic.List[double]
    for($i=0;$i-le$Steps;$i++){
        $f=$i/[double]$Steps
        $d.Add($f*$Length);$t.Add($f*$LapSeconds)
    }
    $rows=New-RowsFromCourse ([double[]]$d.ToArray()) ([double[]]$t.ToArray()) $Y
    for($i=0;$i-lt$rows.Count;$i++){ $rows[$i].speed=($Length/$LapSeconds) }
    return $rows
}
function New-SplitSections([string]$Prefix,[int]$Lap,[double]$StartT,[double]$EndT,[int]$Parts){
    $out=New-Object System.Collections.Generic.List[object]
    $span=$EndT-$StartT
    for($k=1;$k-le$Parts;$k++){
        $s=$StartT+($span*(($k-1)/[double]$Parts))
        $e=$StartT+($span*($k/[double]$Parts))
        $out.Add([pscustomobject][ordered]@{
            section_id=($Prefix+'-S'+$k.ToString('D2'));lap=$Lap
            time=[ordered]@{start_t=[Math]::Round($s,4);end_t=[Math]::Round($e,4);duration_s=[Math]::Round($e-$s,4)}
        })
    }
    return @($out.ToArray())
}
function New-TrainingObject([int]$MapId,[string]$StreamId,$LapRecord,[object[]]$Sections){
    return [ordered]@{
        contract='native_training_analysis_v1'
        resource_map_id=$MapId
        map_authority='authoritative'
        primary_stream_id=$StreamId
        laps=@($LapRecord)
        sections=@($Sections)
        episode_streams=@()
        status='ready'
    }
}
function New-LapRecord([string]$StreamId,[int]$Lap,[double]$LapTimeS,[double]$DistanceM){
    return [ordered]@{
        lap=$Lap;stream_id=$StreamId
        time=[ordered]@{lap_start_s=0.0;lap_end_s=$LapTimeS;lap_time_s=$LapTimeS}
        distance=[ordered]@{total_distance_m=$DistanceM}
        native=[ordered]@{available=$true;logical_drift_count=0}
        actions=[ordered]@{available=$true;game_facing_available=$true}
    }
}

# --- 1. shared spatial correspondence: monotonic, order preserving, bounded ------------------
$straight=New-LineControls -Length 600.0 -Count 61 -Y 0.0
$offset=New-LineControls -Length 600.0 -Count 61 -Y 2.0
$corr=NTA-SharedCorrespondence -Subject $straight -Baseline $offset
Require ([string]$corr.status -eq 'ready') ('two parallel routes must correspond, got '+[string]$corr.status)
Require (@($corr.pairs).Count -eq 61) ('every control point has a counterpart here, got '+[string]@($corr.pairs).Count)
$prevA=-1;$prevB=-1
foreach($p in @($corr.pairs)){
    Require ([int]$p.a_index -gt $prevA) 'the correspondence must be monotonic in the subject index'
    Require ([int]$p.b_index -gt $prevB) 'the correspondence must be monotonic in the baseline index'
    $prevA=[int]$p.a_index;$prevB=[int]$p.b_index
    Require ([Math]::Abs([double]$p.a_progress-[double]$p.b_progress) -le 0.0600001) 'the correspondence must stay inside the declared progress band'
}
Require ([int]$corr.stats.component_count -eq 1) 'a fully corresponded route must be one component'
Require (-not [bool]$corr.stats.time_in_cost) 'time must never take part in the correspondence cost'

# Heading compatibility: the same positions driven in OPPOSITE directions are not the same place.
$reversed=New-ReversedControls -Length 600.0 -Count 61
$opposite=NTA-SharedCorrespondence -Subject $straight -Baseline $reversed
Require (@($opposite.pairs).Count -eq 0) 'positions driven in opposite directions must never be corresponded'

# Bounded hard gate: two routes that are far apart have no admissible counterpart at all.
$far=New-LineControls -Length 600.0 -Count 61 -Y 200.0
$noMatch=NTA-SharedCorrespondence -Subject $straight -Baseline $far
Require (@($noMatch.pairs).Count -eq 0) 'routes beyond the maximum separation must never be corresponded'
Require ([string]$noMatch.status -like 'unavailable*') 'a correspondence with no admissible pair must fail closed'

# Fail closed on a real gap: a displaced middle section must split the correspondence in two.
$gapList=New-Object System.Collections.Generic.List[object]
for($k=0;$k-lt61;$k++){
    $f=$k/60.0
    $y=$(if($f-gt0.4-and$f-lt0.6){200.0}else{0.0})
    $gapList.Add((New-Control 0 ($f*600.0) $f ($f*600.0) $y))
}
$gapCorr=NTA-SharedCorrespondence -Subject $straight -Baseline @($gapList.ToArray())
Require ([int]$gapCorr.stats.break_count -ge 1) 'a displaced stretch must break the correspondence'
Require ([int]$gapCorr.stats.component_count -eq 2) ('a single displaced stretch must produce two components, got '+[string]$gapCorr.stats.component_count)

# --- 1b. a pose-run boundary must NOT break the correspondence ------------------------------
# One invalid pose row splits its side into two runs while the other side keeps one. The runs are a
# property of one side's sampling and their NUMBERS are unrelated, so gating a match on "same run"
# desynchronises the whole alignment: on real laps that dropped the corresponded coverage from ~1.0
# to 0.49 / 0.03 while the two laps were in fact the same route.
$splitList=New-Object System.Collections.Generic.List[object]
for($k=0;$k-lt61;$k++){
    $f=$k/60.0
    $splitList.Add((New-Control $(if($k-ge30){1}else{0}) ($f*600.0) $f ($f*600.0) 0.0))
}
$splitCorr=NTA-SharedCorrespondence -Subject $straight -Baseline @($splitList.ToArray())
Require (@($splitCorr.pairs).Count -eq 61) ('a pose-run boundary must not stop the correspondence, got '+[string]@($splitCorr.pairs).Count+' of 61 pairs')
Require ([int]$splitCorr.stats.break_count -eq 0) 'a pose-run boundary inside one route must not create a correspondence break'

# --- 2. DELTA CONTRACT -- Case A: subject 60.174 s against baseline 56.801 s -----------------
$rowsSubject=New-ConstantSpeedRows -Length 600.0 -LapSeconds 60.174 -Steps 600
$rowsBaseline=New-ConstantSpeedRows -Length 600.0 -LapSeconds 56.801 -Steps 600
$secSubject=New-SplitSections 'L1' 1 0.0 60.174 3
$secBaseline=New-SplitSections 'L2' 2 0.0 56.801 3
$bdA=NTA-TimeLossBreakdown -SubjectSections $secSubject -BaselineSections $secBaseline `
    -SubjectRows $rowsSubject -BaselineRows $rowsBaseline `
    -SubjectLapDurationS 60.174 -BaselineLapDurationS 56.801 `
    -SubjectLapStart 0 -SubjectLapEnd ($rowsSubject.Count-1) -BaselineLapStart 0 -BaselineLapEnd ($rowsBaseline.Count-1)
Require ([double]$bdA.total_delta_s -gt 0) 'the slower subject must publish a POSITIVE total delta'
Require (Approx ([double]$bdA.total_delta_s) 3.373 0.0006) ('Case A: expected +3.373 s, got '+[string]$bdA.total_delta_s)
Require (Approx ([double]$bdA.reconciliation.matched_delta_s) 3.373 0.01) ('Case A: the decomposition must carry the same magnitude, got '+[string]$bdA.reconciliation.matched_delta_s)
$sumA=[double]$bdA.reconciliation.matched_delta_s+[double]$bdA.reconciliation.unmatched_delta_s+[double]$bdA.reconciliation.non_comparison_delta_s+[double]$bdA.reconciliation.residual_s
Require (Approx $sumA ([double]$bdA.total_delta_s) 0.001) ('Case A: matched+unmatched+non_comparison+residual must close to the total: '+[string]$sumA+' vs '+[string]$bdA.total_delta_s)
Require ([string]$bdA.reconciliation.status -eq 'reconciled') ('Case A: a clean comparison must reconcile, got '+[string]$bdA.reconciliation.status)
Require ([double]$bdA.reconciliation.tolerance_s -gt 0) 'the reconciliation tolerance must be published and derived'
Require ([int]$bdA.window_count -ge 2) 'the shared boundary set must produce comparison windows'
Require ([double]$bdA.coverage.combined -gt 0.9) ('a fully corresponded pair must publish a high coverage, got '+[string]$bdA.coverage.combined)
foreach($w in @($bdA.windows)){
    Require ($null -ne $w.comparison_window_id) 'every comparison window needs an identity'
    Require ([string]$w.time.direction -eq (NTA-Direction $w.time.delta_s)) 'a window direction must match its own sign'
    Require ([string]$w.time.classification -eq (NTA-Classification $w.time.delta_s)) 'a window classification must match its own sign'
    Require ($null -ne $w.space.subject.distance_m) 'a window must publish the subject distance'
    Require ($null -ne $w.speed.subject.entry_mps) 'a window must publish the subject entry speed'
    Require ($null -ne $w.correspondence.status) 'a window must publish its correspondence status'
}

# Case B: subject window 5.0 s against baseline window 4.0 s -> +1.0 s / slower / loss.
Require (([double]5.0-[double]4.0) -gt 0) 'sanity: the subject is slower'
Require ((NTA-Direction 1.0) -eq 'slower') 'Case B: a positive time delta must read `slower`'
Require ((NTA-Classification 1.0) -eq 'loss') 'Case B: a positive time delta must classify as `loss`'
# Case C: subject window 3.0 s against baseline window 4.0 s -> -1.0 s / faster / gain.
Require ((NTA-Direction -1.0) -eq 'faster') 'Case C: a negative time delta must read `faster`'
Require ((NTA-Classification -1.0) -eq 'gain') 'Case C: a negative time delta must classify as `gain`'

# --- 3. loss and gain are SEPARATED and ranked, and the observations follow the sign ----------
# A subject that is faster, then slower, then faster again: two real gains of DIFFERENT magnitude and
# one real loss, so the ranking itself is pinned (a gain list sorted by magnitude ASCENDING, which a
# single-gain case cannot detect, is a real defect this case was written to catch).
$dMix=New-Object System.Collections.Generic.List[double]
$tMix=New-Object System.Collections.Generic.List[double]
for($d=0;$d-le600;$d++){
    $dMix.Add([double]$d)
    if($d-le200){$tMix.Add($d/12.0)}
    elseif($d-le400){$tMix.Add((200.0/12.0)+(($d-200)/8.0))}
    else{$tMix.Add((200.0/12.0)+25.0+(($d-400)/14.0))}
}
$rowsMix=New-RowsFromCourse ([double[]]$dMix.ToArray()) ([double[]]$tMix.ToArray())
$mixEndT=(200.0/12.0)+25.0+(200.0/14.0)
for($i=0;$i-lt$rowsMix.Count;$i++){
    $dd=[double]$rowsMix[$i].distance
    $rowsMix[$i].speed=$(if($dd-le200){12.0}elseif($dd-le400){8.0}else{14.0})
}
$rowsUniform=New-ConstantSpeedRows -Length 600.0 -LapSeconds 60.0 -Steps 600
$mixT1=200.0/12.0
$mixT2=$mixT1+25.0
$secMix=@(
    [pscustomobject][ordered]@{section_id='L1-S01';lap=1;time=[ordered]@{start_t=0.0;end_t=[Math]::Round($mixT1,4);duration_s=[Math]::Round($mixT1,4)}},
    [pscustomobject][ordered]@{section_id='L1-S02';lap=1;time=[ordered]@{start_t=[Math]::Round($mixT1,4);end_t=[Math]::Round($mixT2,4);duration_s=25.0}},
    [pscustomobject][ordered]@{section_id='L1-S03';lap=1;time=[ordered]@{start_t=[Math]::Round($mixT2,4);end_t=[Math]::Round($mixEndT,4);duration_s=[Math]::Round($mixEndT-$mixT2,4)}}
)
$secUniform=@(
    [pscustomobject][ordered]@{section_id='L2-S01';lap=2;time=[ordered]@{start_t=0.0;end_t=20.0;duration_s=20.0}},
    [pscustomobject][ordered]@{section_id='L2-S02';lap=2;time=[ordered]@{start_t=20.0;end_t=40.0;duration_s=20.0}},
    [pscustomobject][ordered]@{section_id='L2-S03';lap=2;time=[ordered]@{start_t=40.0;end_t=60.0;duration_s=20.0}}
)
$bdMix=NTA-TimeLossBreakdown -SubjectSections $secMix -BaselineSections $secUniform `
    -SubjectRows $rowsMix -BaselineRows $rowsUniform `
    -SubjectLapDurationS ([Math]::Round($mixEndT,4)) -BaselineLapDurationS 60.0 `
    -SubjectLapStart 0 -SubjectLapEnd ($rowsMix.Count-1) -BaselineLapStart 0 -BaselineLapEnd ($rowsUniform.Count-1)
Require (Approx ([double]$bdMix.total_delta_s) ($mixEndT-60.0) 0.01) ('the mixed case total must be the subject minus the baseline, got '+[string]$bdMix.total_delta_s)
Require ([int]$bdMix.window_count -eq 3) ('the mixed case needs three shared windows, got '+[string]$bdMix.window_count)
foreach($w in @($bdMix.windows)){
    if([double]$w.time.delta_s-lt0){
        Require (-not (@($bdMix.top_loss_sections|Where-Object{[string]$_.comparison_window_id -eq [string]$w.comparison_window_id}).Count -gt 0)) 'a GAIN window must never appear in top_loss_sections'
    }
    if([double]$w.time.delta_s-gt0){
        Require (-not (@($bdMix.top_gain_sections|Where-Object{[string]$_.comparison_window_id -eq [string]$w.comparison_window_id}).Count -gt 0)) 'a LOSS window must never appear in top_gain_sections'
    }
}
Require (@($bdMix.top_loss_sections).Count -eq 1) ('exactly one window lost time, got '+[string]@($bdMix.top_loss_sections).Count)
Require (@($bdMix.top_gain_sections).Count -eq 2) ('exactly two windows gained time, got '+[string]@($bdMix.top_gain_sections).Count)
Require ([double]$bdMix.top_loss_sections[0].time.delta_s -gt 0) 'top_loss_sections must only hold real loss'
Require ([double]$bdMix.top_gain_sections[0].time.delta_s -lt 0) 'top_gain_sections must only hold real gain'
Require (Approx ([double]$bdMix.top_loss_sections[0].time.delta_s) 5.0 0.02) ('the loss window must be +5.0 s, got '+[string]$bdMix.top_loss_sections[0].time.delta_s)
# The LARGER gain must come first: this is the ranking assertion.
Require (Approx ([double]$bdMix.top_gain_sections[0].time.delta_s) (-5.7143) 0.02) ('the largest gain must rank first, got '+[string]$bdMix.top_gain_sections[0].time.delta_s)
Require (Approx ([double]$bdMix.top_gain_sections[1].time.delta_s) (-3.3333) 0.02) ('the smaller gain must rank second, got '+[string]$bdMix.top_gain_sections[1].time.delta_s)
Require ([Math]::Abs([double]$bdMix.top_gain_sections[0].time.delta_s) -gt [Math]::Abs([double]$bdMix.top_gain_sections[1].time.delta_s)) 'gains must be ranked by descending magnitude'
$sumMix=[double]$bdMix.reconciliation.matched_delta_s+[double]$bdMix.reconciliation.unmatched_delta_s+[double]$bdMix.reconciliation.non_comparison_delta_s+[double]$bdMix.reconciliation.residual_s
Require (Approx $sumMix ([double]$bdMix.total_delta_s) 0.001) 'the mixed case must reconcile too'

# Case D: natural language must never contradict its own sign.
$obs=@(NTA-BuildObservations -Breakdown $bdMix -SubjectLabel 'L1' -BaselineLabel '基准 L2')
Require ($obs.Count -ge 2) 'a reconciled comparison must produce an observation for both a loss and a gain'
foreach($o in $obs){
    Require ([string]$o.kind -eq 'derived_observation') 'an observation must be labelled derived_observation'
    Require ([string]$o.causation -like 'not asserted*') 'an observation must never assert causation'
    $d=[double]$o.delta_time_s
    $word=$(if($d-gt0){'慢'}else{'快'})
    $other=$(if($d-gt0){'快'}else{'慢'})
    Require ([bool]$o.text.Contains($word)) ('Case D: a '+[string]$o.direction+' window must read '+$word)
    Require (-not $o.text.Contains($other)) ('Case D: an observation must not contain the opposite word '+$other+': '+[string]$o.text)
    if($d-gt0){
        Require ([string]$o.direction -eq 'slower') 'Case D: a positive observation must read slower'
        Require ([string]$o.classification -eq 'loss') 'Case D: a positive observation must classify as loss'
    } else {
        Require ([string]$o.direction -eq 'faster') 'Case D: a negative observation must read faster'
        Require ([string]$o.classification -eq 'gain') 'Case D: a negative observation must classify as gain'
    }
    foreach($banned in @('优秀','差评','技术差','做错了','建议你','评分','得分','因为')){
        Require (-not ([string]$o.text).Contains($banned)) ('an observation must not contain a judgement or a causal claim: '+$banned)
    }
}

# --- 4. swap invariant: compare(A,B) and compare(B,A) must negate ---------------------------
$bdSwap=NTA-TimeLossBreakdown -SubjectSections $secUniform -BaselineSections $secMix `
    -SubjectRows $rowsUniform -BaselineRows $rowsMix `
    -SubjectLapDurationS 60.0 -BaselineLapDurationS ([Math]::Round($mixEndT,4)) `
    -SubjectLapStart 0 -SubjectLapEnd ($rowsUniform.Count-1) -BaselineLapStart 0 -BaselineLapEnd ($rowsMix.Count-1)
Require (Approx ([double]$bdMix.total_delta_s + [double]$bdSwap.total_delta_s) 0.0 0.002) ('the swap invariant must negate the total: '+[string]$bdMix.total_delta_s+' vs '+[string]$bdSwap.total_delta_s)
Require (Approx ([double]$bdMix.reconciliation.matched_delta_s + [double]$bdSwap.reconciliation.matched_delta_s) 0.0 0.01) 'the swap invariant must negate the matched sum'
Require ([int]$bdSwap.window_count -eq [int]$bdMix.window_count) 'swapping must not change the shared window partition'
for($k=0;$k-lt[int]$bdMix.window_count;$k++){
    Require (Approx ([double]$bdMix.windows[$k].time.delta_s + [double]$bdSwap.windows[$k].time.delta_s) 0.0 0.01) ('a stable matched window must negate under swap at index '+[string]$k)
}
Require (@($bdSwap.top_loss_sections).Count -eq 2) 'after the swap the two gains become two losses'
Require (@($bdSwap.top_gain_sections).Count -eq 1) 'after the swap the one loss becomes the one gain'
Require (Approx ([double]$bdSwap.top_loss_sections[0].time.delta_s) (-[double]$bdMix.top_gain_sections[0].time.delta_s) 0.02) 'swap must exchange the largest gain into the largest loss'
Require (Approx ([double]$bdSwap.top_gain_sections[0].time.delta_s) (-[double]$bdMix.top_loss_sections[0].time.delta_s) 0.02) 'swap must exchange the loss into the gain'
Require ([string]$bdSwap.top_loss_sections[0].time.classification -eq 'loss') 'after the swap the previous gain is a loss'

# --- 5. the outer comparison and the decomposition carry the SAME number ---------------------
$trainingSubject=New-TrainingObject 327 's1' (New-LapRecord 's1' 1 60.174 600.0) $secSubject
$trainingBaseline=New-TrainingObject 327 's1' (New-LapRecord 's1' 2 56.801 600.0) $secBaseline
$cmp=Compare-NativeTrainingAnalyses -TrainingA $trainingSubject -TrainingB $trainingBaseline -RowsA $rowsSubject -RowsB $rowsBaseline -LabelA 'SUBJ' -LabelB 'BASE'
Require ([string]$cmp.contract -eq 'native_training_same_map_comparison_v1') 'same-map contract mismatch'
Require ([bool]$cmp.gate.comparable) 'the same authoritative ResourceMapID must be comparable'
Require (Approx ([double]$cmp.overall.total_delta_s) 3.373 0.0006) ('the outer total must be +3.373 s, got '+[string]$cmp.overall.total_delta_s)
Require (Approx ([double]$cmp.overall.total_delta_s) ([double]$cmp.breakdown.total_delta_s) 0.0001) 'the outer total and the decomposition total must be the SAME number'
Require (Approx ([double]$cmp.breakdown.reconciliation.matched_delta_s) 3.373 0.01) 'the decomposition must not be the negated convention'
Require ([string]$cmp.overall.faster -eq 'BASE') 'the faster side must be the baseline here'
Require ([string]$cmp.subject.role -eq 'subject') 'the subject role must be explicit'
Require ([string]$cmp.baseline.role -eq 'baseline') 'the baseline role must be explicit'

$cmpSwap=Compare-NativeTrainingAnalyses -TrainingA $trainingBaseline -TrainingB $trainingSubject -RowsA $rowsBaseline -RowsB $rowsSubject -LabelA 'BASE' -LabelB 'SUBJ'
Require (Approx ([double]$cmp.overall.total_delta_s + [double]$cmpSwap.overall.total_delta_s) 0.0 0.0002) 'the outer total must negate under swap'
Require (Approx ([double]$cmp.breakdown.reconciliation.matched_delta_s + [double]$cmpSwap.breakdown.reconciliation.matched_delta_s) 0.0 0.01) 'the matched sum must negate under swap'
# In the swapped call the roles are exchanged, so the side that used to be the baseline is now the
# SUBJECT. Its total is negative, i.e. this subject is FASTER than its own baseline.
Require ([string]$cmpSwap.overall.faster -eq 'BASE') 'the faster side must follow the swap'
Require (Approx ([double]$cmpSwap.breakdown.total_delta_s) (-3.373) 0.0006) ('the swapped decomposition must be -3.373 s, got '+[string]$cmpSwap.breakdown.total_delta_s)

# --- 6. FAIL CLOSED: different / unresolved resource map identity ---------------------------
$same=NTA-ComparisonGate -MapIdA 327 -MapIdB 327 -AuthorityA 'authoritative' -AuthorityB 'authoritative'
Require ([bool]$same.comparable) 'the same authoritative ResourceMapID must be comparable'
Require ([string]$same.status -eq 'comparable_same_resource_map') 'same-map status mismatch'
$diff=NTA-ComparisonGate -MapIdA 327 -MapIdB 45 -AuthorityA 'authoritative' -AuthorityB 'authoritative'
Require (-not [bool]$diff.comparable) 'PERMANENT REGRESSION: different ResourceMapIDs must never be comparable'
Require ([string]$diff.status -eq 'unavailable_different_resource_map') ('different-map status mismatch: '+[string]$diff.status)
$unresolved=NTA-ComparisonGate -MapIdA $null -MapIdB 327 -AuthorityA 'unresolved' -AuthorityB 'authoritative'
Require (-not [bool]$unresolved.comparable) 'an unresolved map identity must never be comparable'
Require ([string]$unresolved.status -eq 'unavailable_map_identity_not_authoritative') 'unresolved-map status mismatch'
$nonAuth=NTA-ComparisonGate -MapIdA 327 -MapIdB 327 -AuthorityA 'user_confirmed' -AuthorityB 'authoritative'
Require (-not [bool]$nonAuth.comparable) 'a non-authoritative map identity must never be comparable'

$refused=Compare-NativeTrainingAnalyses -TrainingA $trainingSubject -TrainingB (New-TrainingObject 45 's1' (New-LapRecord 's1' 1 40.0 600.0) $secBaseline) -LabelA 'A' -LabelB 'B'
Require ([string]$refused.status -eq 'comparison_unavailable') ('different-map comparison must be unavailable, got '+[string]$refused.status)
Require ($null -eq $refused.breakdown) 'a refused comparison must publish no breakdown'
Require (@($refused.top_loss_sections).Count -eq 0) 'a refused comparison must publish no loss sections'
Require (@($refused.top_gain_sections).Count -eq 0) 'a refused comparison must publish no gain sections'

# --- 7. `unavailable` is null, never 0 ------------------------------------------------------
$noCorr=NTA-TimeLossBreakdown -SubjectSections $secSubject -BaselineSections $secBaseline `
    -SubjectRows $rowsSubject -BaselineRows (New-ConstantSpeedRows -Length 600.0 -LapSeconds 56.801 -Steps 600 -Y 400.0) `
    -SubjectLapDurationS 60.174 -BaselineLapDurationS 56.801 `
    -SubjectLapStart 0 -SubjectLapEnd ($rowsSubject.Count-1) -BaselineLapStart 0 -BaselineLapEnd 599
Require ([string]$noCorr.status -like 'comparison_unavailable*') ('two routes with no correspondence must be unavailable, got '+[string]$noCorr.status)
Require ($null -eq $noCorr.reconciliation.matched_delta_s) 'unavailable must be null, never 0'
Require ($null -eq $noCorr.reconciliation.unmatched_delta_s) 'unavailable must be null, never 0'
Require ($null -eq $noCorr.reconciliation.non_comparison_delta_s) 'unavailable must be null, never 0'
Require ($null -eq $noCorr.reconciliation.residual_s) 'unavailable residual must be null, never 0'
Require (@($noCorr.windows).Count -eq 0) 'an unavailable comparison must publish no windows'

# --- 8. insufficient correspondence degrades instead of inventing a split -------------------
# The baseline follows the subject for the first ~20% of the lap and then leaves the route, so the
# shared comparison covers only a fifth of the lap.
$partList=New-Object System.Collections.Generic.List[object]
for($k=0;$k-lt61;$k++){
    $f=$k/60.0
    $y=$(if($f-gt0.2){300.0}else{0.0})
    $partList.Add((New-Control 0 ($f*600.0) $f ($f*600.0) $y))
}
$partB=NTA-SharedCorrespondence -Subject $straight -Baseline @($partList.ToArray())
Require (@($partB.pairs).Count -ge 2) 'a partial route still has a real corresponded stretch'
Require ([double]$partB.stats.subject_progress_end -lt 0.5) 'the partial correspondence must stop early'

Write-Host ('[OK] Native Training Analysis v1.1 contract passed. delta=subject-baseline caseA=+3.373s closure=matched+unmatched+non_comparison+residual loss_gain=separated swap=negated correspondence=monotonic+order-preserving+heading-gated+bounded+fail-closed components='+[string]$gapCorr.stats.component_count+' fail-closed=different-map/unresolved-map unavailable=null')
exit 0
