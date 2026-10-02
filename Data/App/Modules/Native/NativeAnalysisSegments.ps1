# Native analysis segmentation v1 / schema 3  (Drift start -> conservative recovery end)
#
# DERIVED, NON-AUTHORITATIVE segmentation contract. It turns the replay-native Drift timeline and
# the replay-native speed-effect table into the product's automatic analysis units:
#
#     segment = [ first native Drift start , recovery end ]
#
# Authority rules (docs/ARCHITECTURE.md) this module obeys:
#   * The Drift authority is the replay-native Drift action-object table (NDE logical episodes).
#     No speed peak, no curvature, no XY geometry and no map reference line may create, extend or
#     trim a segment start.
#   * The recovery end may be extended only by a post-Drift code2001 small-boost-class native
#     effect from the replay-native speed-effect table (`replay_native_action_object_speed_effect_table_v2`).
#     Standard Nitro/code1 is independent propulsion evidence: it is preserved diagnostically but
#     NEVER extends a Drift segment. A recovery end is never invented from kinematics here; when no
#     eligible native small-boost effect exists the segment ends at Drift end and says so.
#   * Automatic Drift analysis is deliberately conservative after take-off. A sustained replay-native
#     `contact_state == 0` interval (>= 100 ms, the same native contact contract used by the speed-effect
#     classifier) hard-cuts an already-owned recovery tail at the first airborne onset. Airborne/Nitro
#     continuation belongs to Custom Path, not to the default Drift segment.
#   * A recovery end never crosses the next independent native Drift start. That is also a hard cut.
#   * A segment that starts in lap N owns lap N for its whole life, even when its tail crosses the
#     lap boundary. The lap boundary never truncates a Drift.
#
# Everything in this module is PURE: published objects in, published objects out. It reads no file,
# no cache and no telemetry CSV, so the whole grouping / recovery contract is durably testable
# from synthetic input (Tests/Smoke-AnalysisSegments.ps1).
#
# Definition-only module. Loaded by the analyzer entry script and by the tests.
#
# ---------------------------------------------------------------------------------------------
# Two grouping levels, deliberately separate
# ---------------------------------------------------------------------------------------------
# 1. LOGICAL NATIVE DRIFT (authority: Modules/Native/NativeDrivingEpisodes.ps1, ADR 0005).
#    Raw native Drift intervals coalesce when both are <= 500 ms and the gap is <= 100 ms.
#    One logical Drift action == one published episode == one native Drift event.
# 2. ANALYSIS SEGMENT (this module). Consecutive logical Drift actions still belong to the same
#    corner when the gap between them is shorter than a driver's release-then-re-drift turnaround,
#    so neighbouring logical Drifts with `next.start - current.end < 0.15 s` are published as ONE
#    segment. The 0.15 s value is a durable regression constant, not a per-replay tuning: it is
#    the measured turnaround of a double-tap corner, and no file name, SHA or offset is consulted.
$script:NasDriftMergeGapS = 0.15

# Driver-relevant effects that are retained as recovery evidence. Only the code2001 small-boost
# family may OWN a recovery end. Standard Nitro/code1 is kept in the evidence so a bad ownership
# regression is observable, but it never extends a Drift segment. `map_propulsion_effect` and
# `unknown_speed_effect` are not recovery evidence.
function NAS-RecoveryEffectTypes {
    return @('drift_small_boost','air_boost','landing_boost','other_small_boost','nitro')
}

# Read one property from a published object without assuming the property exists. Published
# contracts are the input here, and a missing property must read as "unavailable", never as 0.
function NAS-Prop {
    param($Object,[string]$Name)
    if($null-eq$Object){ return $null }
    # Published contracts are PSCustomObjects, but caller-supplied option bags are usually
    # hashtables, and a hashtable's own PSObject properties are Count/Keys/Values - never its keys.
    if($Object -is [System.Collections.IDictionary]){
        if($Object.Contains($Name)){ return $Object[$Name] }
        return $null
    }
    if(@($Object.PSObject.Properties.Name) -notcontains $Name){ return $null }
    return $Object.$Name
}
function NAS-Num {
    param($Value)
    if($null-eq$Value){ return $null }
    $d=0.0
    if(-not[double]::TryParse([string]$Value,[ref]$d)){ return $null }
    if([double]::IsNaN($d)-or[double]::IsInfinity($d)){ return $null }
    return $d
}
function NAS-Round {
    param($Value,[int]$Digits=4)
    $d=NAS-Num $Value
    if($null-eq$d){ return $null }
    return [math]::Round($d,$Digits)
}
function NAS-IntOrNull {
    param($Value)
    if($null-eq$Value){ return $null }
    $i=0
    if(-not[int]::TryParse([string]$Value,[ref]$i)){ return $null }
    return $i
}

# ---------------------------------------------------------------------------------------------
# 1. Logical-drift episodes -> analysis segments (the 0.15 s grouping)
# ---------------------------------------------------------------------------------------------

# One ordered list of logical native Drift episodes -> merged analysis segments.
#
# Input episode shape (published by NativeDrivingEpisodes.ps1): `lap`, `logical_drift_index`,
# `time.start_t`, `time.end_t`, `id`. Anything else is carried through untouched.
#
# The input does NOT have to be one lap: segmentation is a property of the whole stream, so a
# segment may legitimately contain a Drift that starts in lap N and one that starts in lap N+1.
# Segment ownership is the lap of its FIRST logical Drift (`lap_owner`), and
# `crosses_lap_boundary` records that the segment's Drift content spans more than one lap.
function NAS-DriftSegments {
    param(
        [AllowEmptyCollection()][object[]]$Episodes=@(),
        [double]$MergeGapS=$script:NasDriftMergeGapS
    )
    $eps=New-Object System.Collections.Generic.List[object]
    foreach($e in @($Episodes)){
        if($null-eq$e){ continue }
        $t=NAS-Prop $e 'time'
        $st=NAS-Num (NAS-Prop $t 'start_t')
        $et=NAS-Num (NAS-Prop $t 'end_t')
        if($null-eq$st-or$null-eq$et-or$et-le$st){ continue }
        $eps.Add([pscustomobject]@{
            id=[string](NAS-Prop $e 'id')
            lap=NAS-IntOrNull (NAS-Prop $e 'lap')
            logical_drift_index=NAS-IntOrNull (NAS-Prop $e 'logical_drift_index')
            start_t=$st
            end_t=$et
            episode=$e
        })
    }
    $sorted=@($eps.ToArray() | Sort-Object start_t,end_t,id)
    $out=New-Object System.Collections.Generic.List[object]
    foreach($e in $sorted){
        if($out.Count-eq0){
            $out.Add([pscustomobject]@{
                start_t=$e.start_t
                drift_end_t=$e.end_t
                lap_owner=$e.lap
                laps=@($e.lap)
                logical_drift_indices=@($e.logical_drift_index)
                episode_ids=@($e.id)
                drift_intervals=@([pscustomobject]@{start_t=$e.start_t;end_t=$e.end_t})
                merged=$false
                merge_gap_s=$null
            })
            continue
        }
        $cur=$out[$out.Count-1]
        $gap=$e.start_t-[double]$cur.drift_end_t
        if($gap-lt$MergeGapS){
            $cur.drift_end_t=[math]::Max([double]$cur.drift_end_t,$e.end_t)
            $cur.logical_drift_indices=@($cur.logical_drift_indices)+@($e.logical_drift_index)
            $cur.episode_ids=@($cur.episode_ids)+@($e.id)
            $cur.drift_intervals=@($cur.drift_intervals)+@([pscustomobject]@{start_t=$e.start_t;end_t=$e.end_t})
            if($null -ne $e.lap -and @($cur.laps) -notcontains $e.lap){ $cur.laps=@($cur.laps)+@($e.lap) }
            $cur.merged=$true
            if($null-eq$cur.merge_gap_s-or$gap-lt[double]$cur.merge_gap_s){ $cur.merge_gap_s=$gap }
            continue
        }
        $out.Add([pscustomobject]@{
            start_t=$e.start_t
            drift_end_t=$e.end_t
            lap_owner=$e.lap
            laps=@($e.lap)
            logical_drift_indices=@($e.logical_drift_index)
            episode_ids=@($e.id)
            drift_intervals=@([pscustomobject]@{start_t=$e.start_t;end_t=$e.end_t})
            merged=$false
            merge_gap_s=$null
        })
    }
    $segments=New-Object System.Collections.Generic.List[object]
    $index=0
    foreach($s in @($out.ToArray())){
        $index++
        $laps=@($s.laps | Where-Object { $null-ne$_ })
        $segments.Add([pscustomobject][ordered]@{
            segment_index=$index
            lap_owner=$s.lap_owner
            laps_touched=$laps
            drift_count=@($s.logical_drift_indices).Count
            logical_drift_indices=@($s.logical_drift_indices)
            episode_ids=@($s.episode_ids)
            drift_intervals=@($s.drift_intervals)
            start_t=[math]::Round([double]$s.start_t,4)
            drift_end_t=[math]::Round([double]$s.drift_end_t,4)
            drift_duration_s=[math]::Round(([double]$s.drift_end_t-[double]$s.start_t),4)
            merged=$s.merged
            smallest_merge_gap_s=NAS-Round $s.merge_gap_s 4
            crosses_lap_boundary=($laps.Count-gt1)
        })
    }
    return @($segments.ToArray())
}

# The segments that a lap view owns: ownership is the lap of the first logical Drift, so a segment
# whose tail crosses into the next lap is still returned for the lap it started in.
function NAS-SegmentsForLap {
    param(
        [AllowEmptyCollection()][object[]]$Segments=@(),
        [object]$Lap
    )
    $lapNo=NAS-IntOrNull $Lap
    if($null-eq$lapNo){ return @() }
    return @(@($Segments) | Where-Object { $null-ne$_ -and (NAS-IntOrNull (NAS-Prop $_ 'lap_owner')) -eq $lapNo })
}

# Build sustained native-air intervals from production telemetry rows.  Contact state 0 is the
# historical TencentCar `ECS_INAIR` value promoted by the 2026 record contract. States 1..5 are
# intentionally NOT inferred as air/ground booleans. A run must last >= 100 ms; this is the same
# validation bound already used by ReplayNativeSpeedEffects for contact-context diagnostics.
function NAS-ValidatedAirIntervalsFromRows {
    param(
        [AllowEmptyCollection()][object[]]$Rows=@(),
        [double]$MinimumDurationS=0.100
    )
    $out=New-Object System.Collections.Generic.List[object]
    if($null-eq$Rows-or$Rows.Count-eq0){return @()}
    $inAir=$false;$start=$null
    for($i=0;$i-lt$Rows.Count;$i++){
        $r=$Rows[$i]
        $t=NAS-Num (NAS-Prop $r 'time_s')
        if($null-eq$t){$t=NAS-Num (NAS-Prop $r 'time')}
        $cs=NAS-IntOrNull (NAS-Prop $r 'contact_state')
        $air=($null-ne$cs-and$cs-eq0)
        if($air-and-not$inAir){$inAir=$true;$start=$t}
        if(-not$air-and$inAir){
            $stop=$t
            if($null-ne$start-and$null-ne$stop-and($stop-$start)-ge($MinimumDurationS-1e-6)){
                $out.Add([pscustomobject][ordered]@{start_t=[math]::Round([double]$start,4);end_t=[math]::Round([double]$stop,4);duration_s=[math]::Round(([double]$stop-[double]$start),4);source='replay_native_contact_state_0';validated=$true})
            }
            $inAir=$false;$start=$null
        }
    }
    if($inAir-and$null-ne$start){
        $last=$Rows[$Rows.Count-1]
        $stop=NAS-Num (NAS-Prop $last 'time_s');if($null-eq$stop){$stop=NAS-Num (NAS-Prop $last 'time')}
        if($null-ne$stop-and($stop-$start)-ge($MinimumDurationS-1e-6)){
            $out.Add([pscustomobject][ordered]@{start_t=[math]::Round([double]$start,4);end_t=[math]::Round([double]$stop,4);duration_s=[math]::Round(([double]$stop-[double]$start),4);source='replay_native_contact_state_0';validated=$true})
        }
    }
    return @($out.ToArray())
}

# ---------------------------------------------------------------------------------------------
# 2. Recovery end (native effect end, hard-cut by air/next Drift)
# ---------------------------------------------------------------------------------------------

# Recovery evidence for ONE segment.
#
# `NextDriftStartT` is the next independent native Drift start STRICTLY AFTER this segment's own
# Drift content (i.e. the start of the next segment). It is the hard cut: no recovery end may
# cross it, whatever the effect table says.
#
# `EffectIntervals` is the published native speed-effect list of the same stream. Only intervals
# whose semantics are assigned and driver-relevant can end a recovery (see
# $script:NasRecoveryEffectTypes); an unknown effect code is never a recovery.
#
# The 2.0 s window bounds the eligible code2001 effect ONSET search: a small-boost-class effect must
# START within 2.0 s after the Drift end to belong to this corner. Its END is not limited to 2.0 s -
# a legal small-boost effect may end later, and the next independent Drift start is still the hard cut.
# Nitro may also start in this window, but is evidence-only and cannot own/extend the recovery tail.
function NAS-RecoveryForSegment {
    param(
        [Parameter(Mandatory=$true)][object]$Segment,
        [AllowEmptyCollection()][object[]]$EffectIntervals=@(),
        [AllowEmptyCollection()][object[]]$AirborneIntervals=@(),
        [object]$NextDriftStartT=$null,
        [double]$WindowS=2.0
    )
    $driftEnd=NAS-Num (NAS-Prop $Segment 'drift_end_t')
    if($null-eq$driftEnd){ throw 'NAS-RecoveryForSegment requires a segment with drift_end_t.' }
    $next=NAS-Num $NextDriftStartT
    $hardCut=$null
    if($null-ne$next-and$next-gt$driftEnd+1e-6){ $hardCut=$next }
    # First sustained native-air interval touching/after Drift end.  It does not create recovery by
    # itself; it only prevents an otherwise-owned code2001 recovery tail from leaking into flight.
    $airCut=$null;$airEvidence=$null
    foreach($a in @($AirborneIntervals)){
        if($null-eq$a){continue}
        $ast=NAS-Num (NAS-Prop $a 'start_t');$aet=NAS-Num (NAS-Prop $a 'end_t')
        if($null-eq$ast-or$null-eq$aet-or$aet-le$driftEnd+1e-6){continue}
        $candidate=$(if($ast-le$driftEnd+1e-6){$driftEnd}else{$ast})
        if($null-eq$airCut-or$candidate-lt$airCut){$airCut=$candidate;$airEvidence=$a}
    }
    $windowEnd=$driftEnd+$WindowS
    $limit=$windowEnd
    if($null-ne$hardCut-and$hardCut-lt$limit){ $limit=$hardCut }
    if($null-ne$airCut-and$airCut-lt$limit){ $limit=$airCut }
    $candidates=New-Object System.Collections.Generic.List[object]
    foreach($iv in @($EffectIntervals)){
        if($null-eq$iv){ continue }
        $st=NAS-Num (NAS-Prop $iv 'start_t')
        $et=NAS-Num (NAS-Prop $iv 'end_t')
        if($null-eq$st-or$null-eq$et-or$et-le$st){ continue }
        if($st-lt$driftEnd-1e-6){ continue }
        if($st-gt$limit+1e-6){ continue }
        $semantic=[string](NAS-Prop $iv 'semantic_type')
        $driverRelevant=($null-ne$semantic-and(@(NAS-RecoveryEffectTypes)-contains$semantic))
        $candidates.Add([pscustomobject][ordered]@{
            effect_code=NAS-Num (NAS-Prop $iv 'effect_code')
            semantic_type=$semantic
            start_t=[math]::Round($st,4)
            end_t=[math]::Round($et,4)
            duration_s=[math]::Round(($et-$st),4)
            native_end_ms=NAS-IntOrNull (NAS-Prop $iv 'native_end_ms')
            driver_relevant=$driverRelevant
        })
    }
    $relevant=@($candidates.ToArray() | Where-Object { [bool]$_.driver_relevant })
    $smallPool=@($relevant | Where-Object { [string]$_.semantic_type -ne 'nitro' })
    $nitroPool=@($relevant | Where-Object { [string]$_.semantic_type -eq 'nitro' })
    # Recovery OWNERSHIP is deliberately narrower than speed-effect semantics. A code1 Nitro is a
    # real native effect, but field validation showed that treating "Nitro-only after Drift" as a
    # recovery tail absorbs ordinary/system Nitro straights into the corner. Therefore only the
    # post-Drift code2001 small-boost family may close recovery; Nitro remains evidence-only.
    $anchorClass='small_boost'
    $pool=$smallPool
    $evidence=[pscustomobject][ordered]@{
        rule='recovery end = end of the LAST code2001 small-boost-class native speed effect whose START lies within 2.0 s after Drift end and before hard cuts. Standard Nitro/code1 never extends a Drift. A sustained native contact_state=0 interval hard-cuts an owned recovery at take-off; detailed airborne continuation belongs to Custom Path. If no eligible small-boost effect exists, recovery ends at native Drift end.'
        window_s=$WindowS
        hard_cut_t=NAS-Round $hardCut 4
        airborne_hard_cut_t=NAS-Round $airCut 4
        airborne_hard_cut_source=$(if($null-ne$airEvidence){'replay_native_contact_state_0_sustained'}else{$null})
        candidate_count=$candidates.Count
        driver_relevant_count=$relevant.Count
        small_boost_candidate_count=$smallPool.Count
        nitro_candidate_count=$nitroPool.Count
        anchor_class=$(if($pool.Count-gt0){$anchorClass}else{$null})
        nitro_recovery_policy='evidence_only_never_extends_segment'
        candidates=@($candidates.ToArray())
    }
    if($pool.Count-eq0){
        return [pscustomobject][ordered]@{
            available=$false
            recovery_end_t=[math]::Round($driftEnd,4)
            end_reason='no_native_recovery_effect'
            hard_cut_t=NAS-Round $hardCut 4
            airborne_hard_cut_t=NAS-Round $airCut 4
            hard_cut_applied=$false
            chosen=$null
            evidence=$evidence
        }
    }
    $winner=$null
    foreach($c in $pool){
        if($null-eq$winner-or[double]$c.end_t-gt[double]$winner.end_t-or([double]$c.end_t-eq[double]$winner.end_t-and[double]$c.start_t-gt[double]$winner.start_t)){
            $winner=$c
        }
    }
    $cut=$false;$airCutApplied=$false;$nextCutApplied=$false
    $end=[double]$winner.end_t
    if($null-ne$hardCut-and$end-gt$hardCut+1e-6){ $end=$hardCut;$cut=$true;$nextCutApplied=$true }
    if($null-ne$airCut-and$end-gt$airCut+1e-6){ $end=$airCut;$cut=$true;$airCutApplied=$true;$nextCutApplied=$false }
    $reason='native_small_boost_end'
    if($nextCutApplied){$reason='next_drift_hard_cut'}
    if($airCutApplied){$reason='airborne_hard_cut'}
    return [pscustomobject][ordered]@{
        available=$true
        recovery_end_t=[math]::Round($end,4)
        end_reason=$reason
        hard_cut_t=NAS-Round $hardCut 4
        airborne_hard_cut_t=NAS-Round $airCut 4
        hard_cut_applied=$cut
        chosen=$winner
        evidence=$evidence
    }
}

# ---------------------------------------------------------------------------------------------
# 3. The published contract
# ---------------------------------------------------------------------------------------------

# Build the whole stream contract: segments (with recovery) grouped by owning lap.
#
# `Episodes` is the LOGICAL native Drift episode list of ONE stream (all laps, time ordered).
# `EffectIntervals` is that stream's native speed-effect list. `Laps` is optional and is used only
# to report the lap whose boundary a segment's tail crosses; it never truncates anything.
function NAS-BuildContract {
    param(
        [AllowEmptyCollection()][object[]]$Episodes=@(),
        [AllowEmptyCollection()][object[]]$EffectIntervals=@(),
        [AllowEmptyCollection()][object[]]$AirborneIntervals=@(),
        [AllowEmptyCollection()][object[]]$Laps=@(),
        [double]$MergeGapS=$script:NasDriftMergeGapS,
        [double]$RecoveryWindowS=2.0
    )
    $segs=@(NAS-DriftSegments -Episodes $Episodes -MergeGapS $MergeGapS)
    # Lap end times are used ONLY to REPORT that a segment's Drift content runs past its owning lap
    # boundary. They never move, truncate or re-own anything.
    $lapEndByLap=@{}
    foreach($lap in @($Laps)){
        if($null-eq$lap){ continue }
        $ln=NAS-IntOrNull (NAS-Prop $lap 'lap')
        $le=NAS-Num (NAS-Prop $lap 'end_t')
        if($null-ne$ln-and$null-ne$le){ $lapEndByLap[[string]$ln]=$le }
    }
    $built=New-Object System.Collections.Generic.List[object]
    for($k=0;$k-lt$segs.Count;$k++){
        $seg=$segs[$k]
        $nextStart=$null
        if(($k+1)-lt$segs.Count){ $nextStart=$segs[$k+1].start_t }
        $rec=NAS-RecoveryForSegment -Segment $seg -EffectIntervals $EffectIntervals -AirborneIntervals $AirborneIntervals -NextDriftStartT $nextStart -WindowS $RecoveryWindowS
        $crosses=[bool]$seg.crosses_lap_boundary
        $ownerEnd=$null
        if($null-ne$seg.lap_owner-and$lapEndByLap.ContainsKey([string](NAS-IntOrNull $seg.lap_owner))){
            $ownerEnd=[double]$lapEndByLap[[string](NAS-IntOrNull $seg.lap_owner)]
            if([double]$seg.drift_end_t-gt$ownerEnd+1e-6){ $crosses=$true }
        }
        $built.Add([pscustomobject][ordered]@{
            segment_index=[int]$seg.segment_index
            lap_owner=$seg.lap_owner
            laps_touched=@($seg.laps_touched)
            drift_count=[int]$seg.drift_count
            logical_drift_indices=@($seg.logical_drift_indices)
            episode_ids=@($seg.episode_ids)
            drift_intervals=@($seg.drift_intervals)
            start_t=$seg.start_t
            drift_end_t=$seg.drift_end_t
            drift_duration_s=$seg.drift_duration_s
            recovery_available=[bool]$rec.available
            recovery_end_t=$rec.recovery_end_t
            recovery_stop_reason=[string]$rec.end_reason
            next_drift_start_t=NAS-Round $nextStart 4
            airborne_hard_cut_t=$rec.airborne_hard_cut_t
            total_duration_s=[math]::Round(([double]$rec.recovery_end_t-[double]$seg.start_t),4)
            recovery_duration_s=[math]::Round(([double]$rec.recovery_end_t-[double]$seg.drift_end_t),4)
            merged=[bool]$seg.merged
            smallest_merge_gap_s=$seg.smallest_merge_gap_s
            crosses_lap_boundary=$crosses
            owning_lap_end_t=NAS-Round $ownerEnd 4
            recovery=[pscustomobject][ordered]@{
                chosen=$rec.chosen
                evidence=$rec.evidence
            }
            derived=$true
        })
    }
    $lapsOut=New-Object System.Collections.Generic.List[object]
    foreach($lap in @($Laps)){
        if($null-eq$lap){ continue }
        $lapNo=NAS-IntOrNull (NAS-Prop $lap 'lap')
        $mine=@($built.ToArray() | Where-Object { (NAS-IntOrNull $_.lap_owner) -eq $lapNo })
        $lapsOut.Add([pscustomobject][ordered]@{
            lap=$lapNo
            lap_start_t=NAS-Round (NAS-Prop $lap 'start_t') 4
            lap_end_t=NAS-Round (NAS-Prop $lap 'end_t') 4
            segment_count=$mine.Count
            segment_indices=@($mine | ForEach-Object { [int]$_.segment_index })
            crosses_lap_boundary_count=@($mine | Where-Object { [bool]$_.crosses_lap_boundary }).Count
            segments=@($mine)
        })
    }
    if($lapsOut.Count-eq0){
        # No lap table: publish a single ownership bucket per distinct lap_owner so a consumer can
        # still find a segment by lap.
        foreach($lapNo in @($built.ToArray() | ForEach-Object { $_.lap_owner } | Sort-Object -Unique)){
            $mine=@($built.ToArray() | Where-Object { (NAS-IntOrNull $_.lap_owner) -eq (NAS-IntOrNull $lapNo) })
            $lapsOut.Add([pscustomobject][ordered]@{
                lap=NAS-IntOrNull $lapNo
                lap_start_t=$null
                lap_end_t=$null
                segment_count=$mine.Count
                segment_indices=@($mine | ForEach-Object { [int]$_.segment_index })
                crosses_lap_boundary_count=@($mine | Where-Object { [bool]$_.crosses_lap_boundary }).Count
                segments=@($mine)
            })
        }
    }
    $recoveryCount=@($built.ToArray() | Where-Object { [bool]$_.recovery_available }).Count
    $hardCutCount=@($built.ToArray() | Where-Object { [string]$_.recovery_stop_reason -eq 'next_drift_hard_cut' }).Count
    $airCutCount=@($built.ToArray() | Where-Object { [string]$_.recovery_stop_reason -eq 'airborne_hard_cut' }).Count
    return [pscustomobject][ordered]@{
        schema_version=3
        contract='native_analysis_segments_v1'
        architecture='native_first_v1'
        authority='replay_native_action_object_drift_table_v3 + replay_native_action_object_speed_effect_table_v2 + replay_native_contact_state_offset_52_hard_cut'
        derived=$true
        geometry_role='measurement_only'
        drift_merge_gap_s=$MergeGapS
        recovery_window_s=$RecoveryWindowS
        ownership_rule='a segment belongs to the lap of its first logical native Drift; a lap boundary never truncates a Drift'
        recovery_rule='recovery end = end of the last post-Drift code2001 small-boost-class native effect whose START is inside the 2.0 s onset window; an owned recovery is hard-cut at sustained native airborne onset or the next independent Drift start; Nitro/code1 never extends a Drift segment; airborne continuation is left to Custom Path'
        nitro_recovery_policy='evidence_only_never_extends_segment'
        segment_count=$built.Count
        recovery_available_count=$recoveryCount
        recovery_unavailable_count=($built.Count-$recoveryCount)
        next_drift_hard_cut_count=$hardCutCount
        airborne_hard_cut_count=$airCutCount
        lap_count=$lapsOut.Count
        laps=@($lapsOut.ToArray())
        segments=@($built.ToArray())
    }
}
