param()
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
$appDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $appDir 'Modules\Native\NativeAnalysisSegments.ps1')
. (Join-Path $appDir 'Modules\Native\NativeAnalysis.ps1')
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}
function Approx([double]$A,[double]$B,[double]$Tol){return ([Math]::Abs($A-$B)-le$Tol)}

# =============================================================================================
# Smoke-AnalysisSegments - the Drift-start -> recovery-end segmentation contract.
#
# SYNTHETIC CONTRACT: every input below is hand-built, so this gate runs without a real replay and
# without the game install. It pins the durable rules; the real-replay evidence lives in
# Tests/Smoke-AnalysisClosureReal.ps1.
# =============================================================================================

function New-Episode([int]$Lap,[int]$Index,[double]$StartT,[double]$EndT){
    return [pscustomobject][ordered]@{
        id=('L'+[string]$Lap+'-D'+$Index.ToString('D2'))
        lap=$Lap
        logical_drift_index=$Index
        time=[pscustomobject][ordered]@{start_t=$StartT;end_t=$EndT;duration_s=($EndT-$StartT)}
    }
}
function New-Effect([double]$StartT,[double]$EndT,[string]$Semantic,[double]$Code=2001){
    return [pscustomobject][ordered]@{
        id=1
        effect_code=$Code
        semantic_type=$Semantic
        start_t=$StartT
        end_t=$EndT
        duration_s=($EndT-$StartT)
        native_end_ms=[long][math]::Round($EndT*1000.0)
    }
}

# ---- 1. single Drift, no recovery effect -----------------------------------------------------
$segs=@(NAS-DriftSegments -Episodes @((New-Episode 1 1 10.0 11.5)))
Require ($segs.Count-eq1) 'single logical Drift must produce exactly one segment'
Require ([int]$segs[0].drift_count-eq1) 'single segment must report drift_count = 1'
Require (-not[bool]$segs[0].merged) 'a single Drift must not be marked merged'
Require ([int]$segs[0].lap_owner-eq1) 'segment ownership must be the lap of its first logical Drift'
$rec=NAS-RecoveryForSegment -Segment $segs[0] -EffectIntervals @() -NextDriftStartT $null
Require (-not[bool]$rec.available) 'a segment with no native effect must publish recovery_available = false'
Require ([string]$rec.end_reason-eq'no_native_recovery_effect') 'a segment with no native effect must name the reason'
Require (Approx ([double]$rec.recovery_end_t) 11.5 1e-6) 'a segment with no recovery tail ends at its own Drift end'

# ---- 2. adjacent logical Drifts: gap < 0.150 s merges ---------------------------------------
$mergePair=@((New-Episode 1 1 10.0 11.0),(New-Episode 1 2 11.10 12.0))
$merged=@(NAS-DriftSegments -Episodes $mergePair)
Require ($merged.Count-eq1) 'two logical Drifts with a 0.10 s gap must merge into one segment'
Require ([int]$merged[0].drift_count-eq2) 'a merged segment must count both logical Drifts'
Require ([bool]$merged[0].merged) 'a merged segment must be flagged merged'
Require (Approx ([double]$merged[0].smallest_merge_gap_s) 0.10 1e-6) 'a merged segment must publish the measured merge gap'
Require (Approx ([double]$merged[0].drift_end_t) 12.0 1e-6) 'a merged segment ends at its last logical Drift end'
Require (@($merged[0].logical_drift_indices).Count-eq2) 'a merged segment must keep both logical Drift indices'
Require (@($merged[0].drift_intervals).Count-eq2) 'a merged segment must keep both native Drift intervals'

# ---- 3. gap exactly at the boundary stays separate (the rule is gap < 0.150 s) --------------
$boundary=@(NAS-DriftSegments -Episodes @((New-Episode 1 1 10.0 11.0),(New-Episode 1 2 11.15 12.0)))
Require ($boundary.Count-eq2) 'logical Drifts separated by exactly 0.150 s must stay separate'
$justUnder=@(NAS-DriftSegments -Episodes @((New-Episode 1 1 10.0 11.0),(New-Episode 1 2 11.149 12.0)))
Require ($justUnder.Count-eq1) 'logical Drifts separated by 0.149 s must merge'
Require (Approx ([double]$script:NasDriftMergeGapS) 0.15 1e-9) 'the durable merge gap must stay 0.15 s'

# ---- 4. a Drift that crosses the lap boundary is neither truncated nor re-owned --------------
$crossEps=@((New-Episode 1 5 50.0 51.0),(New-Episode 2 1 51.05 52.0))
$cross=@(NAS-DriftSegments -Episodes $crossEps)
Require ($cross.Count-eq1) 'a 0.05 s gap across the lap boundary must still merge'
Require ([int]$cross[0].lap_owner-eq1) 'a segment that starts in lap 1 must be owned by lap 1'
Require ([bool]$cross[0].crosses_lap_boundary) 'a segment spanning two laps must be flagged'
Require (Approx ([double]$cross[0].start_t) 50.0 1e-6) 'the lap boundary must not move a Drift start'
Require (Approx ([double]$cross[0].drift_end_t) 52.0 1e-6) 'the lap boundary must not truncate a Drift'
$lapTable=@([pscustomobject]@{lap=1;start_t=20.0;end_t=51.0},[pscustomobject]@{lap=2;start_t=51.0;end_t=80.0})
$contract=NAS-BuildContract -Episodes $crossEps -EffectIntervals @() -Laps $lapTable
$lap1=@($contract.laps | Where-Object { $_.lap -eq 1 })[0]
$lap2=@($contract.laps | Where-Object { $_.lap -eq 2 })[0]
Require ([int]$lap1.segment_count-eq1) 'the cross-lap segment must be listed under its owning lap'
Require ([int]$lap2.segment_count-eq0) 'the cross-lap segment must NOT be duplicated into the next lap'
Require ([int]$lap1.crosses_lap_boundary_count-eq1) 'the owning lap must report the cross-boundary segment'

# ---- 5. next-Drift hard cut -----------------------------------------------------------------
$cutEps=@((New-Episode 1 1 10.0 11.0),(New-Episode 1 2 11.5 12.5))
$cutSegs=@(NAS-DriftSegments -Episodes $cutEps)
$longBoost=@(New-Effect 11.05 13.0 'drift_small_boost')
$cutRec=NAS-RecoveryForSegment -Segment $cutSegs[0] -EffectIntervals $longBoost -NextDriftStartT 11.5
Require ([bool]$cutRec.available) 'a native boost before the next Drift must still be found'
Require ([string]$cutRec.end_reason-eq'next_drift_hard_cut') 'a recovery end beyond the next Drift start must be hard cut'
Require (Approx ([double]$cutRec.recovery_end_t) 11.5 1e-6) 'the hard cut must land exactly on the next independent Drift start'
Require ([bool]$cutRec.hard_cut_applied) 'the hard cut must be reported'
# an effect that starts after the next independent Drift start belongs to that next corner
$lateBoost=@(New-Effect 11.6 12.2 'drift_small_boost')
$lateRec=NAS-RecoveryForSegment -Segment $cutSegs[0] -EffectIntervals $lateBoost -NextDriftStartT 11.5
Require (-not[bool]$lateRec.available) 'an effect that starts after the next Drift start must not end this recovery'

# ---- 6. single-boost and double-boost recovery ----------------------------------------------
$oneBoost=@(New-Effect 11.55 11.95 'drift_small_boost')
$oneRec=NAS-RecoveryForSegment -Segment $segs[0] -EffectIntervals $oneBoost -NextDriftStartT $null
Require ([bool]$oneRec.available) 'a single native small boost must end the recovery'
Require ([string]$oneRec.end_reason-eq'native_small_boost_end') 'a small-boost recovery must name its native reason'
Require (Approx ([double]$oneRec.recovery_end_t) 11.95 1e-6) 'the recovery end must be the native effect end'
$twoBoost=@((New-Effect 11.55 11.95 'drift_small_boost'),(New-Effect 12.10 12.50 'drift_small_boost'))
$twoRec=NAS-RecoveryForSegment -Segment $segs[0] -EffectIntervals $twoBoost -NextDriftStartT $null
Require (Approx ([double]$twoRec.recovery_end_t) 12.50 1e-6) 'a double boost must end the recovery at the LAST native effect end'
Require ([int]$twoRec.evidence.driver_relevant_count-eq2) 'both boosts must appear as recovery evidence'

# ---- 7. effects that may never end a recovery ------------------------------------------------
$notRecovery=@((New-Effect 11.55 12.5 'unknown_speed_effect' 777),(New-Effect 11.60 12.9 'map_propulsion_effect' 2003))
$nrRec=NAS-RecoveryForSegment -Segment $segs[0] -EffectIntervals $notRecovery -NextDriftStartT $null
Require (-not[bool]$nrRec.available) 'unknown and scene-driven effects must never end a recovery'
Require ([int]$nrRec.evidence.candidate_count-eq2) 'non-driver effects must still be published as evidence'
Require ([int]$nrRec.evidence.driver_relevant_count-eq0) 'non-driver effects must not count as driver-relevant'

# ---- 8. Nitro is evidence-only for recovery ownership ----------------------------------------
$overlap=@((New-Effect 11.55 12.00 'drift_small_boost'),(New-Effect 11.70 14.00 'nitro' 1))
$ovRec=NAS-RecoveryForSegment -Segment $segs[0] -EffectIntervals $overlap -NextDriftStartT $null
Require ([string]$ovRec.end_reason-eq'native_small_boost_end') 'the small-boost family must own the recovery end when both classes overlap'
Require (Approx ([double]$ovRec.recovery_end_t) 12.00 1e-6) 'an overlapping nitro must not extend the small-boost recovery'
Require ([int]$ovRec.evidence.nitro_candidate_count-eq1) 'an overlapping nitro must still be published as evidence'
Require ([string]$ovRec.evidence.anchor_class-eq'small_boost') 'the evidence must name the anchor class that closed the recovery'
$ovCut=NAS-RecoveryForSegment -Segment $segs[0] -EffectIntervals $overlap -NextDriftStartT 11.8
Require ([string]$ovCut.end_reason-eq'next_drift_hard_cut') 'a small-boost recovery is still hard cut by the next Drift'
Require (Approx ([double]$ovCut.recovery_end_t) 11.8 1e-6) 'the hard cut must win over the native effect end'
$nitroOnly=@(New-Effect 11.60 14.50 'nitro' 1)
$nitroRec=NAS-RecoveryForSegment -Segment $segs[0] -EffectIntervals $nitroOnly -NextDriftStartT $null
Require (-not[bool]$nitroRec.available) 'a Nitro-only post-Drift interval must NOT create a recovery tail'
Require ([string]$nitroRec.end_reason-eq'no_native_recovery_effect') 'Nitro-only recovery ownership must fail closed'
Require (Approx ([double]$nitroRec.recovery_end_t) 11.5 1e-6) 'without a code2001 recovery effect the segment must end at native Drift end'
Require ([int]$nitroRec.evidence.nitro_candidate_count-eq1) 'the excluded Nitro must remain visible as native evidence'
Require ($null-eq$nitroRec.evidence.anchor_class) 'an excluded Nitro must never be published as the recovery anchor'
Require ([string]$nitroRec.evidence.nitro_recovery_policy-eq'evidence_only_never_extends_segment') 'the Nitro ownership policy must be explicit'
$nitroBeforeNext=NAS-RecoveryForSegment -Segment $segs[0] -EffectIntervals $nitroOnly -NextDriftStartT 11.8
Require (-not[bool]$nitroBeforeNext.available) 'a next-Drift hard cut must not turn a Nitro-only interval into recovery'
Require (Approx ([double]$nitroBeforeNext.recovery_end_t) 11.5 1e-6) 'Nitro-only must still end at Drift end even when a later next-Drift boundary exists'
Require (-not[bool]$nitroBeforeNext.hard_cut_applied) 'no hard cut is applied when there is no eligible recovery tail'


# ---- 9. sustained airborne state hard-cuts an owned recovery tail ----------------------------
$airRows=@(
    [pscustomobject]@{time_s=11.50;contact_state=5},
    [pscustomobject]@{time_s=11.70;contact_state=5},
    [pscustomobject]@{time_s=11.90;contact_state=0},
    [pscustomobject]@{time_s=12.05;contact_state=0},
    [pscustomobject]@{time_s=12.20;contact_state=5}
)
$airIntervals=@(NAS-ValidatedAirIntervalsFromRows -Rows $airRows)
Require ($airIntervals.Count-eq1) 'a sustained contact_state=0 run must publish one validated airborne interval'
Require (Approx ([double]$airIntervals[0].start_t) 11.90 1e-6) 'the air hard cut must start at the first in-air sample'
$airBoost=@((New-Effect 11.60 12.40 'drift_small_boost'),(New-Effect 12.21 12.70 'landing_boost'))
$airRec=NAS-RecoveryForSegment -Segment $segs[0] -EffectIntervals $airBoost -AirborneIntervals $airIntervals -NextDriftStartT $null
Require ([bool]$airRec.available) 'a pre-takeoff small boost still owns a recovery tail'
Require ([string]$airRec.end_reason-eq'airborne_hard_cut') 'take-off must hard-cut automatic Drift recovery'
Require (Approx ([double]$airRec.recovery_end_t) 11.90 1e-6) 'automatic recovery must stop at sustained airborne onset'
Require (Approx ([double]$airRec.airborne_hard_cut_t) 11.90 1e-6) 'the airborne cut must be published'
$shortAir=@([pscustomobject]@{time_s=20.00;contact_state=5},[pscustomobject]@{time_s=20.10;contact_state=0},[pscustomobject]@{time_s=20.15;contact_state=5})
Require (@(NAS-ValidatedAirIntervalsFromRows -Rows $shortAir).Count-eq0) 'a sub-100ms contact blip must not cut a Drift segment'

# ---- 10. the recovery window is bounded ------------------------------------------------------
$farBoost=@(New-Effect 14.0 14.4 'drift_small_boost')
$farRec=NAS-RecoveryForSegment -Segment $segs[0] -EffectIntervals $farBoost -NextDriftStartT $null -WindowS 2.0
Require (-not[bool]$farRec.available) 'an effect outside the recovery window must not end the recovery'

# ---- 11. contract-level counts and rules ----------------------------------------------------
$allEps=@(
    (New-Episode 1 1 10.0 11.0),
    (New-Episode 1 2 11.05 12.0),
    (New-Episode 1 3 13.0 14.0),
    (New-Episode 2 1 60.0 61.0)
)
$allEffects=@((New-Effect 12.05 12.40 'drift_small_boost'),(New-Effect 14.05 14.30 'drift_small_boost'))
$full=NAS-BuildContract -Episodes $allEps -EffectIntervals $allEffects -Laps $lapTable
Require ([string]$full.contract-eq'native_analysis_segments_v1') 'the segmentation contract name must be stable'
Require ([int]$full.schema_version-eq3) 'the airborne hard-cut contract must publish segment schema 3'
Require ([string]$full.nitro_recovery_policy-eq'evidence_only_never_extends_segment') 'the contract must publish the Nitro ownership policy'
Require ([int]$full.segment_count-eq3) 'the synthetic stream must produce three segments'
Require ([int]$full.recovery_available_count-eq2) 'two of the three segments must have a native recovery end'
Require ([int]$full.recovery_unavailable_count-eq1) 'the third segment must publish an unavailable recovery'
Require (Approx ([double]$full.drift_merge_gap_s) 0.15 1e-9) 'the contract must publish the merge gap'
Require (([string]$full.ownership_rule).Length-gt0) 'the contract must publish the ownership rule'
$s1=@($full.segments | Where-Object { $_.segment_index -eq 1 })[0]
Require (Approx ([double]$s1.next_drift_start_t) 13.0 1e-6) 'each segment must publish the next independent Drift start'
$s3=@($full.segments | Where-Object { $_.segment_index -eq 3 })[0]
Require ($null-eq$s3.next_drift_start_t) 'the last segment has no next Drift start'
foreach($s in @($full.segments)){
    Require ([double]$s.recovery_end_t-ge[double]$s.drift_end_t-1e-9) ('recovery end must never precede the Drift end (segment '+[string]$s.segment_index+')')
    Require ([double]$s.total_duration_s-ge[double]$s.drift_duration_s-1e-9) ('total duration must cover the drift duration (segment '+[string]$s.segment_index+')')
}

# ---- 12. determinism ------------------------------------------------------------------------
$again=NAS-BuildContract -Episodes $allEps -EffectIntervals $allEffects -Laps $lapTable
Require ((($again.segments | ConvertTo-Json -Depth 12 -Compress)) -eq (($full.segments | ConvertTo-Json -Depth 12 -Compress))) 'segmentation must be deterministic for identical input'
$shuffled=@($allEps[3],$allEps[2],$allEps[0],$allEps[1])
$resorted=NAS-BuildContract -Episodes $shuffled -EffectIntervals $allEffects -Laps $lapTable
Require ((($resorted.segments | ConvertTo-Json -Depth 12 -Compress)) -eq (($full.segments | ConvertTo-Json -Depth 12 -Compress))) 'segmentation must not depend on the input order'

# ---- 13. stream ownership: exact identity first, unique-role fallback, ambiguity fails closed --
# A replay may hold several network_low_frequency shadows. Attaching another car's Drift table to a
# shadow because its role matched "the first candidate" is not allowed.
function New-OwnerTelemetry([string[]]$Ids,[string[]]$Roles){
    $out=@()
    for($i=0;$i-lt$Ids.Count;$i++){ $out+=[pscustomobject]@{id=$Ids[$i];role=$Roles[$i];native_speed_effect_segments=@();laps=@([pscustomobject]@{lap=1;start_t=0;end_t=10})} }
    return [pscustomobject]@{streams=$out}
}
function New-OwnerEpisodes([string[]]$Ids,[string[]]$Roles){
    $out=@()
    for($i=0;$i-lt$Ids.Count;$i++){ $out+=[pscustomobject]@{id=$Ids[$i];role=$Roles[$i];laps=@([pscustomobject]@{lap=1;episodes=@((New-Episode 1 1 5.0 6.0))})} }
    return [pscustomobject]@{streams=$out}
}
$ownerTel=New-OwnerTelemetry -Ids @('shadow_local','shadow_network_01') -Roles @('local_high_frequency','network_low_frequency')
$exactEps=New-OwnerEpisodes -Ids @('shadow_local','shadow_network_01') -Roles @('local_high_frequency','network_low_frequency')
$exact=NF-SegmentAnalysis $ownerTel $exactEps
Require ([string]@($exact.streams|Where-Object{$_.id-eq'shadow_network_01'})[0].status-eq'ready') 'exact stream identity must resolve the owner'
$uniqueEps=New-OwnerEpisodes -Ids @('shadow_local','net_a') -Roles @('local_high_frequency','network_low_frequency')
$unique=NF-SegmentAnalysis $ownerTel $uniqueEps
Require ([string]@($unique.streams|Where-Object{$_.id-eq'shadow_network_01'})[0].status-eq'ready') 'a unique same-role candidate may be used as the fallback'
Require ([int]@($unique.streams|Where-Object{$_.id-eq'shadow_network_01'})[0].segment_count-eq1) 'the unique-role fallback must actually attach the episodes'
$ambiguousEps=New-OwnerEpisodes -Ids @('shadow_local','net_a','net_b') -Roles @('local_high_frequency','network_low_frequency','network_low_frequency')
$ambiguous=NF-SegmentAnalysis $ownerTel $ambiguousEps
$ambStream=@($ambiguous.streams|Where-Object{$_.id-eq'shadow_network_01'})[0]
Require ([string]$ambStream.status-eq'unavailable_native_drift_owner_ambiguous') 'an ambiguous same-role owner must fail closed'
Require ([int]$ambStream.segment_count-eq0) 'an ambiguous owner must publish no segment'
Require ([string]@($ambiguous.streams|Where-Object{$_.id-eq'shadow_local'})[0].status-eq'ready') 'the unambiguous local stream must still resolve'

Write-Host '[OK] Analysis segmentation contract passed. cases=single/merge-0.10/separate-0.150/merge-0.149/cross-lap-ownership/no-truncation/next-drift-hard-cut/late-effect-excluded/single-boost/double-boost/no-native-boost/unknown-and-scene-effect-rejected/nitro-overlap/nitro-evidence-only/airborne-hard-cut/short-air-blip-ignored/window-bound/contract-counts/determinism/stream-owner-exact/stream-owner-unique-role/stream-owner-ambiguous-fail-closed merge_gap=0.15s native-recovery-end=code2001-only air-cut=contact0>=100ms'
exit 0
