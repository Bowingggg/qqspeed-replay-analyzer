# Native Training Analysis v1 — the production contract.
#
# DERIVED, NON-AUTHORITATIVE. Three capability levels degrade independently:
#
#   Level 1  Lap Analysis                       needs only production telemetry; works without a map.
#   Level 2  Native Driving Episode v2          needs the replay-native Drift table; works without a map.
#   Level 3  Spatial Section / Same-Map A/B     needs an AUTHORITATIVE official map identity, and
#                                               same-map A/B additionally needs TWO replays with the
#                                               SAME official ResourceMapID.
#
# Nothing here is all-or-nothing. A replay with no map identity still gets Level 1 + Level 2, and a
# replay whose action event table could not be decoded still gets its Drift and speed measurements
# with the action fields published as null + status (availability never propagates across levels).
#
# No score, no grade, no coaching. Every derived statement is labelled `derived_observation`.

function NTA-PrimaryStream([object]$Episodes) {
    if($null-eq$Episodes){return $null}
    $s=@($Episodes.streams)
    if($s.Count-eq0){return $null}
    $local=@($s|Where-Object{[string]$_.role -eq 'local_high_frequency'})
    if($local.Count-gt0){return $local[0]}
    return $s[0]
}

function NTA-PrimaryStreamFromSections($DrivingSections) {
    if($null-eq$DrivingSections){return $null}
    $s=@($DrivingSections.streams)
    if($s.Count-eq0){return $null}
    $local=@($s|Where-Object{[string]$_.role -eq 'local_high_frequency'})
    if($local.Count-gt0){return $local[0]}
    return $s[0]
}

# The drive section for one lap of the driving-sections stream, or @() when the lap has none.
function NTA-SectionsForLap($DriveStream,[int]$Lap) {
    if($null-eq$DriveStream){return @()}
    $out=New-Object System.Collections.Generic.List[object]
    foreach($dl in @($DriveStream.laps)){
        if($null-eq$dl){continue}
        if([int]$dl.lap-ne$Lap){continue}
        foreach($sec in @($dl.sections)){ if($null-ne$sec){$out.Add($sec)} }
    }
    if($out.Count-eq0-and[int]$DriveStream.representative_lap-eq$Lap){
        foreach($sec in @($DriveStream.representative_sections)){ if($null-ne$sec){$out.Add($sec)} }
    }
    return @($out.ToArray())
}

# One lap record per lap: identity, time, distance, speed, native aggregates, episode aggregates and
# the compact spatial section list.
# Compact section descriptor published in the analysis JSON (no trajectory points; the full section
# contract with its observed trajectory lives in the `<replay>_training.json` artifact).
function NTA-CompactSection([object]$Section) {
    if($null-eq$Section){return $null}
    return [ordered]@{
        section_id=[string]$Section.section_id
        lap=[int]$Section.lap
        ordinal=[int]$Section.ordinal
        kind=[string]$Section.kind
        direction=[string]$Section.direction
        duration_s=$Section.time.duration_s
        start_t=$Section.time.start_t
        end_t=$Section.time.end_t
        path_length_m=$Section.space.path_length_m
        entry_speed_mps=$Section.speed.entry_mps
        min_speed_mps=$Section.speed.min_mps
        exit_speed_mps=$Section.speed.exit_mps
        logical_drift_count=$Section.native_actions.logical_drift_count
        total_drift_duration_s=$Section.native_actions.total_drift_duration_s
        boost_latency_median_ms=$Section.latency.boost_latency.median_ms
        boost_latency_p90_ms=$Section.latency.boost_latency.p90_ms
        cw=$Section.native_actions.cw
        wcw=$Section.native_actions.wcw
        cww=$Section.native_actions.cww
        air_boost=$Section.native_actions.air_boost
        landing_boost=$Section.native_actions.landing_boost
        episode_ids=@($Section.episode_ids)
    }
}

function NTA-BuildLapRecord {
    param(
        [object]$Lap,
        [string]$StreamId,
        [object[]]$SectionContracts=@()
    )
    $eps=@($Lap.episodes)
    $durations=[double[]]@($eps|ForEach-Object{[double]$_.time.duration_s})
    $entries=[double[]]@($eps|Where-Object{$null-ne$_.speed.entry}|ForEach-Object{[double]$_.speed.entry})
    $mins=[double[]]@($eps|Where-Object{$null-ne$_.speed.min}|ForEach-Object{[double]$_.speed.min})
    $exits=[double[]]@($eps|Where-Object{$null-ne$_.speed.exit}|ForEach-Object{[double]$_.speed.exit})
    $lat=[double[]]@($eps|Where-Object{$null-ne$_.exit_timing.drift_end_to_first_small_boost_ms}|ForEach-Object{[double]$_.exit_timing.drift_end_to_first_small_boost_ms})
    $active=0.0;foreach($e in $eps){$active+=[double]$e.time.duration_s}
    $compact=New-Object System.Collections.Generic.List[object]
    foreach($s in @($SectionContracts)){ if($null-ne$s){$compact.Add((NTA-CompactSection $s))} }
    $recovery=$null
    if($exits.Count-gt0-and$mins.Count-gt0){$recovery=[Math]::Round((NDA-Percentile $exits 0.5)-(NDA-Percentile $mins 0.5),3)}
    return [ordered]@{
        lap=[int]$Lap.lap
        stream_id=$StreamId
        time=[ordered]@{
            lap_start_s=$(if($null-ne$Lap.lap_start_s){[double]$Lap.lap_start_s}else{$null})
            lap_end_s=$(if($null-ne$Lap.lap_end_s){[double]$Lap.lap_end_s}else{$null})
            lap_time_s=$(if($null-ne$Lap.lap_time_s){[double]$Lap.lap_time_s}else{$null})
        }
        distance=[ordered]@{total_distance_m=$(if($null-ne$Lap.distance_m){[double]$Lap.distance_m}else{$null})}
        speed=[ordered]@{
            available=($null-ne$Lap.average_speed_mps)
            average_mps=$(if($null-ne$Lap.average_speed_mps){[double]$Lap.average_speed_mps}else{$null})
            max_mps=$(if($null-ne$Lap.max_speed_mps){[double]$Lap.max_speed_mps}else{$null})
            median_mps=$(if($null-ne$Lap.median_speed_mps){[double]$Lap.median_speed_mps}else{$null})
            min_mps=$(if($null-ne$Lap.min_speed_mps){[double]$Lap.min_speed_mps}else{$null})
            moving_min_mps=$(if($null-ne$Lap.moving_min_speed_mps){[double]$Lap.moving_min_speed_mps}else{$null})
            unit='m/s'
            note='min keeps stops / respawns visible; moving_min excludes sub-0.5 m/s samples'
        }
        native=[ordered]@{
            available=[bool]$Lap.drift_available
            authority='replay_native_action_object_drift_table_v3'
            logical_drift_count=$(if($null-ne$Lap.logical_drift_count){[int]$Lap.logical_drift_count}else{$null})
            raw_drift_interval_count=$(if($null-ne$Lap.raw_drift_interval_count){[int]$Lap.raw_drift_interval_count}else{$null})
            total_drift_active_s=[Math]::Round($active,4)
            median_drift_duration_s=$(if($null-ne$Lap.median_drift_duration_s){[double]$Lap.median_drift_duration_s}else{$null})
        }
        actions=[ordered]@{
            available=[bool]$Lap.action_event_available
            authority='replay_native_action_event'
            game_facing_available=[bool]$Lap.native.combo_game_facing
            cw=$Lap.native.cw
            wcw=$Lap.native.wcw
            cww=$Lap.native.cww
            air_boost=$Lap.native.air_boost
            landing_boost=$Lap.native.landing_boost
            small_boost_native_effect_count=$Lap.native.small_boost_native_effect_count
            small_boost_parity_status=[string]$Lap.native.small_boost_game_facing_status
            nitro_native_interval_count=$Lap.native.nitro_native_interval_count
            nitro_parity_status=[string]$Lap.native.nitro_game_facing_status
        }
        episode_aggregates=[ordered]@{
            episode_count=$eps.Count
            median_entry_speed_mps=$(if($entries.Count-gt0){[Math]::Round((NDA-Percentile $entries 0.5),3)}else{$null})
            median_min_speed_mps=$(if($mins.Count-gt0){[Math]::Round((NDA-Percentile $mins 0.5),3)}else{$null})
            median_exit_speed_mps=$(if($exits.Count-gt0){[Math]::Round((NDA-Percentile $exits 0.5),3)}else{$null})
            median_speed_loss_mps=$(if($null-ne$Lap.speed_loss.median){[double]$Lap.speed_loss.median}else{$null})
            median_recovery_mps=$recovery
            median_boost_latency_ms=$(if($lat.Count-gt0){[int][Math]::Round((NDA-Percentile $lat 0.5),0)}else{$null})
        }
        spatial=[ordered]@{
            available=($compact.Count-gt0)
            section_count=$compact.Count
            sections=@($compact.ToArray())
        }
        # The FULL section contracts (space/time/native/latency/trajectory), kept in memory for the
        # analysis JSON's sibling artifact. They are deliberately NOT serialised into this object:
        # ConvertTo-Json collapses a one-element array to a scalar, so a per-lap copy would come back
        # as a single object and silently hide the rest. The artifact publishes them once from the
        # live contract list instead.
        section_contracts=$SectionContracts
        derived=$true
    }
}

# Intra-replay comparison: every other lap against the fastest valid lap of the same stream.
#
# ROLES ARE EXPLICIT: the subject is the lap under examination, the baseline is the fastest valid lap
# of the same recording, and every published delta is `subject - baseline`. A positive lap total is
# therefore time LOST by the subject. Both laps are compared through ONE shared spatial
# correspondence, so the two sides never section their own course independently.
function NTA-BuildIntraReplayComparison {
    param(
        [object]$EpisodesStream,
        [object[]]$Rows,
        [hashtable]$SectionsByLap,
        $Opts,
        # Lap number -> the FULL section contracts for that lap. Preferred over $SectionsByLap, which
        # only exists for callers that still build it themselves.
        [hashtable]$FullSectionsByLap=$null
    )
    function __secs([int]$n){
        if($null-ne$FullSectionsByLap-and$FullSectionsByLap.ContainsKey($n)){return @($FullSectionsByLap[$n])}
        return @($SectionsByLap[$n])
    }
    $laps=@($EpisodesStream.laps)
    if($laps.Count-lt2){
        return [pscustomobject][ordered]@{status='unavailable_single_lap';reason='intra-replay lap comparison needs at least two laps';fastest_lap=$null;comparisons=@()}
    }
    $valid=@($laps|Where-Object{$null-ne$_.lap_time_s-and[double]$_.lap_time_s-gt0})
    if($valid.Count-lt2){
        return [pscustomobject][ordered]@{status='unavailable_insufficient_valid_laps';reason='fewer than two laps carry a positive measured lap time';fastest_lap=$null;comparisons=@()}
    }
    $fastest=@($valid|Sort-Object @{Expression={[double]$_.lap_time_s}},@{Expression={[int]$_.lap}})[0]
    $fLap=[int]$fastest.lap
    $secB=@(__secs $fLap)
    $nRows=@($Rows).Count
    $lbStart=NTA-RowIndexAtTime $Rows 0 ($nRows-1) ([double]$fastest.lap_start_s)
    $lbEnd=NTA-RowIndexAtTime $Rows 0 ($nRows-1) ([double]$fastest.lap_end_s)
    $out=New-Object System.Collections.Generic.List[object]
    foreach($lap in @($valid|Sort-Object {[int]$_.lap})){
        if([int]$lap.lap-eq$fLap){continue}
        $secA=@(__secs ([int]$lap.lap))
        $total=[Math]::Round(([double]$lap.lap_time_s-[double]$fastest.lap_time_s),4)
        if($secA.Count-eq0-or$secB.Count-eq0){
            $out.Add([pscustomobject][ordered]@{
                status='comparison_unavailable_no_sections'
                lap=[int]$lap.lap;compared_against_lap=$fLap;total_delta_s=$total
                subject=[ordered]@{label=('L'+[string][int]$lap.lap);lap=[int]$lap.lap;lap_time_s=[double]$lap.lap_time_s}
                baseline=[ordered]@{label=('L'+[string]$fLap);lap=$fLap;lap_time_s=[double]$fastest.lap_time_s}
                reason='one of the two laps has no derived spatial section, so no shared comparison window can be built'
                breakdown=$null;observations=@()
            })
            continue
        }
        $laStart=NTA-RowIndexAtTime $Rows 0 ($nRows-1) ([double]$lap.lap_start_s)
        $laEnd=NTA-RowIndexAtTime $Rows 0 ($nRows-1) ([double]$lap.lap_end_s)
        $bd=NTA-TimeLossBreakdown -SubjectSections $secA -BaselineSections $secB -SubjectRows $Rows -BaselineRows $Rows `
            -SubjectEpisodes @($lap.episodes) -BaselineEpisodes @($fastest.episodes) `
            -SubjectLapDurationS ([double]$lap.lap_time_s) -BaselineLapDurationS ([double]$fastest.lap_time_s) `
            -SubjectLapStart $laStart -SubjectLapEnd $laEnd -BaselineLapStart $lbStart -BaselineLapEnd $lbEnd `
            -SubjectDriftAvailable ([bool]$lap.drift_available) -SubjectComboAvailable ([bool]$lap.native.combo_game_facing) `
            -BaselineDriftAvailable ([bool]$fastest.drift_available) -BaselineComboAvailable ([bool]$fastest.native.combo_game_facing) `
            -TopN $Opts.TopLossSections -MaxSeparationM $Opts.MaxSeparationM -MatchedSeparationM $Opts.MatchedSeparationM `
            -MaxHeadingDeltaDeg $Opts.MaxHeadingDeltaDeg -BandProgress $Opts.BandProgress -MaxGapProgress $Opts.MaxGapProgress `
            -MinWindowSeparationM $Opts.MinWindowSeparationM -MinCoverage $Opts.MinCoverage -MaxControlPoints $Opts.MaxControlPoints
        $out.Add([pscustomobject][ordered]@{
            status=[string]$bd.status
            lap=[int]$lap.lap
            compared_against_lap=$fLap
            subject=[ordered]@{label=('L'+[string][int]$lap.lap);lap=[int]$lap.lap;lap_time_s=[double]$lap.lap_time_s}
            baseline=[ordered]@{label=('L'+[string]$fLap);lap=$fLap;lap_time_s=[double]$fastest.lap_time_s}
            total_delta_s=$total
            breakdown=$bd
            observations=@(NTA-BuildObservations -Breakdown $bd -SubjectLabel ('L'+[string][int]$lap.lap) -BaselineLabel ('最快圈 L'+[string]$fLap) -MaxObservations $Opts.MaxObservations)
        })
    }
    return [pscustomobject][ordered]@{
        status=$(if($out.Count-gt0){'ready'}else{'unavailable'})
        fastest_lap=$fLap
        fastest_lap_time_s=[double]$fastest.lap_time_s
        fastest_lap_selection_rule='lowest measured lap time among laps carrying a positive lap time; ties resolve to the lower lap index'
        comparisons=@($out.ToArray())
    }
}

# Main entry point for one analyzed replay.
# Main entry point for one analyzed replay.
#
# The section contracts are built ONCE per lap here and kept in a lap-indexed table that is handed
# straight to the comparison, so nothing downstream ever has to re-derive them from another stream.
function New-NativeTrainingAnalysis {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [string]$TelemetrySummaryPath='',
        [string]$ReplaySha256='',
        $DrivingSections=$null,
        $DrivingEpisodes=$null,
        $RowsCache=$null,
        $MapInfo=$null,
        [int]$TopLossSections=5,
        [int]$MaxObservations=8,
        [double]$MaxSeparationM=30.0,
        [double]$MatchedSeparationM=15.0,
        [double]$MaxHeadingDeltaDeg=80.0,
        [double]$BandProgress=0.06,
        [double]$MaxGapProgress=0.03,
        [double]$MinWindowSeparationM=8.0,
        [int]$MaxControlPoints=180,
        [double]$MinCoverage=0.34
    )
    $opts=[pscustomobject]@{
        TopLossSections=$TopLossSections;MaxObservations=$MaxObservations
        MaxSeparationM=$MaxSeparationM;MatchedSeparationM=$MatchedSeparationM;MaxHeadingDeltaDeg=$MaxHeadingDeltaDeg
        BandProgress=$BandProgress;MaxGapProgress=$MaxGapProgress;MinWindowSeparationM=$MinWindowSeparationM
        MaxControlPoints=$MaxControlPoints;MinCoverage=$MinCoverage
    }
    $empty=[ordered]@{
        schema_version=1;contract='native_training_analysis_v1';architecture='native_first_v1'
        status='unavailable';laps=@();episodes=@();sections=@();comparisons=@();time_loss=@();observations=@()
        section_count=0;lap_count=0;episode_count=0
    }
    $telemetry=$(if([string]::IsNullOrWhiteSpace($TelemetrySummaryPath)){$null}else{NDE-ReadJson $TelemetrySummaryPath})
    if($null-eq$telemetry){
        $r=$empty.Clone();$r.status='unavailable_telemetry';$r.reason='production telemetry summary unavailable';$r.map_independent=$true
        return $r
    }
    if($null-eq$DrivingEpisodes){
        $r=$empty.Clone();$r.status='unavailable_native_drift_episodes';$r.reason='native driving episodes were not built';$r.map_independent=$true
        return $r
    }
    $teleDir=Split-Path -Parent $TelemetrySummaryPath
    $primaryEpisodes=NTA-PrimaryStream $DrivingEpisodes
    $primaryStreamId=$(if($null-ne$primaryEpisodes){[string]$primaryEpisodes.id}else{''})
    if([string]::IsNullOrWhiteSpace($primaryStreamId)-and@($telemetry.streams).Count-gt0){$primaryStreamId=[string]@($telemetry.streams)[0].id}

    $mapResolved=($null-ne$MapInfo-and[bool]$MapInfo.authoritative-and$null-ne$MapInfo.resource_map_id)
    $resourceMapId=$(if($mapResolved){[int]$MapInfo.resource_map_id}else{$null})
    $mapAuthority=$(if($mapResolved){'authoritative'}else{'unresolved'})

    $teleByStream=@{}
    foreach($ts in @($telemetry.streams)){ if($null-ne$ts){$teleByStream[[string]$ts.id]=$ts} }
    $driveByStream=@{}
    if($null-ne$DrivingSections){ foreach($x in @($DrivingSections.streams)){ if($null-ne$x){$driveByStream[[string]$x.id]=$x} } }

    $lapRecords=New-Object System.Collections.Generic.List[object]
    $sectionRecords=New-Object System.Collections.Generic.List[object]
    $streamsOut=New-Object System.Collections.Generic.List[object]
    $episodeStreamsOut=New-Object System.Collections.Generic.List[object]
    $intra=$null
    $primaryEpisodeCount=0

    foreach($es in @($DrivingEpisodes.streams)){
        if($null-eq$es){continue}
        $sid=[string]$es.id
        $ds=$(if($driveByStream.ContainsKey($sid)){$driveByStream[$sid]}elseif($driveByStream.Count-gt0){@($driveByStream.Values)[0]}else{$null})
        $rows=@()
        $telStream=$(if($teleByStream.ContainsKey($sid)){$teleByStream[$sid]}else{$null})
        if($null-ne$telStream-and-not[string]::IsNullOrWhiteSpace([string]$telStream.csv)){
            $csvPath=Join-Path $teleDir ([string]$telStream.csv)
            if(Test-Path -LiteralPath $csvPath -PathType Leaf){
                try { $rows=@(NDA-LoadRowsCached $RowsCache $csvPath) } catch { $rows=@() }
            }
        }
        # Collect this stream's episodes for the artifact.
        $streamEpisodes=New-Object System.Collections.Generic.List[object]
        foreach($lm in @($es.laps)){ foreach($ep in @($lm.episodes)){ $streamEpisodes.Add($ep) } }
        if($sid-eq$primaryStreamId){ $primaryEpisodeCount=$streamEpisodes.Count }
        $episodeStreamsOut.Add([ordered]@{
            id=$sid;role=[string]$es.role;status=[string]$es.status
            lap_count=[int]$es.lap_count;episode_count=[int]$es.episode_count
            logical_drift_group_count=$(if($null-ne$es.logical_drift_group_count){[int]$es.logical_drift_group_count}else{$null})
            episode_time_monotonic=[bool]$es.episode_time_monotonic
            episodes=@($streamEpisodes.ToArray())
        })

        $spatialReady=($rows.Count-ge20-and$null-ne$ds-and[string]$ds.status-eq'ready')
        if(-not $spatialReady){
            $streamsOut.Add([ordered]@{
                id=$sid;role=[string]$es.role;lap_count=@($es.laps).Count
                spatial_status=$(if($null-eq$ds){'unavailable_prerequisite'}else{[string]$ds.status})
                sections_available=$false;section_count=0
            })
            # Levels 1 and 2 still work: the lap metrics are published with an empty spatial block.
            foreach($lap in @($es.laps)){
                $lapRecords.Add((NTA-BuildLapRecord -Lap $lap -StreamId $sid -SectionContracts @()))
            }
            continue
        }

        $contractsByLap=@{}
        foreach($lap in @($es.laps)){
            $lapNo=[int]$lap.lap
            $raw=@(NTA-SectionsForLap $ds $lapNo)
            $full=New-Object System.Collections.Generic.List[object]
            foreach($sec in $raw){
                $c=NTA-BuildSectionContract -Rows $rows -Section $sec -Lap $lap -StreamId $sid -ResourceMapId $resourceMapId `
                    -Episodes @($lap.episodes) -ComboAvailable ([bool]$lap.native.combo_game_facing) `
                    -ActionEventAvailable ([bool]$lap.action_event_available) -DriftAvailable ([bool]$lap.drift_available) `
                    -EffectAvailable $true
                if($null-ne$c){ $full.Add($c); $sectionRecords.Add($c) }
            }
            $list=@($full.ToArray())
            $contractsByLap[$lapNo]=$list
            # The full contracts are kept as a list ON the lap record so the comparison never depends
            # on a hashtable lookup surviving anything.
            $lapRecords.Add((NTA-BuildLapRecord -Lap $lap -StreamId $sid -SectionContracts $list))
        }
        $streamSectionCount=0
        foreach($k in @($contractsByLap.Keys)){ $streamSectionCount+=@($contractsByLap[$k]).Count }
        $streamsOut.Add([ordered]@{
            id=$sid;role=[string]$es.role;lap_count=@($es.laps).Count
            spatial_status='ready';sections_available=$true
            section_count=$streamSectionCount
        })
        if($sid-eq$primaryStreamId){
            $intra=NTA-BuildIntraReplayComparison -EpisodesStream $es -Rows $rows -SectionsByLap $contractsByLap -Opts $opts
        }
    }

    $timeLoss=New-Object System.Collections.Generic.List[object]
    $observations=New-Object System.Collections.Generic.List[object]
    $intraStatus='unavailable_prerequisite'
    if($null-ne$intra){
        $intraStatus=[string]$intra.status
        foreach($c in @($intra.comparisons)){
            if($null-eq$c.breakdown){continue}
            $timeLoss.Add([pscustomobject][ordered]@{
                kind='intra_replay_lap_vs_fastest'
                lap=[int]$c.lap
                compared_against_lap=[int]$c.compared_against_lap
                total_delta_s=$c.total_delta_s
                status=[string]$c.status
                breakdown=$c.breakdown
            })
            foreach($o in @($c.observations)){$observations.Add($o)}
        }
    }

    $spatialReadyCount=@($streamsOut.ToArray()|Where-Object{[bool]$_.sections_available}).Count
    $episodesReady=([bool]($null-ne$primaryEpisodes-and[string]$primaryEpisodes.status-like'ready*'))
    $status=$(if($spatialReadyCount-gt0){'ready'}elseif($episodesReady){'ready_without_spatial_sections'}else{'unavailable'})
    $sectionArray=@($sectionRecords.ToArray())
    return [ordered]@{
        schema_version=1
        contract='native_training_analysis_v1'
        architecture='native_first_v1'
        authority='replay_native_action_object_drift_table_v3 + replay_native_action_event + replay_native_action_object_speed_effect_table_v2 + official map world XY'
        geometry_role='spatial measurement and section correspondence only; geometry never defines Drift, Boost, Combo, an action type, a score or a grade'
        status=$status
        replay_sha256=$ReplaySha256
        primary_stream_id=$primaryStreamId
        resource_map_id=$resourceMapId
        map_authority=$mapAuthority
        capabilities=[ordered]@{
            lap_analysis=$(if($lapRecords.Count-gt0){'ready'}else{'unavailable'})
            lap_analysis_requires='production telemetry only; map-independent'
            episode_analysis=$(if($episodesReady){'ready'}else{'unavailable'})
            episode_analysis_requires='replay-native Drift table; map-independent'
            spatial_section=$(if($spatialReadyCount-gt0){'ready'}else{'unavailable_prerequisite'})
            spatial_section_requires='an authoritative official map identity'
            same_map_ab='requires a second replay with the SAME authoritative ResourceMapID'
        }
        streams=@($streamsOut.ToArray())
        lap_count=$lapRecords.Count
        laps=@($lapRecords.ToArray())
        episode_streams=@($episodeStreamsOut.ToArray())
        episodes=[ordered]@{
            authority='logical native Drift actions'
            count=$primaryEpisodeCount
            contract='native_driving_episodes_v1 (episode facts are published by driving_episodes)'
            detail_source='Output/<replay>_training.json'
        }
        episode_count=$primaryEpisodeCount
        lived_sections=$sectionArray
        sections=[ordered]@{
            authority='derived spatial containers with read-only native annotations'
            count=$sectionArray.Count
            contract='native_training_section_v1'
            detail_source='Output/<replay>_training.json'
        }
        section_count=$sectionArray.Count
        comparisons=[ordered]@{
            intra_replay=$(if($null-ne$intra){$intra}else{[ordered]@{status=$intraStatus;fastest_lap=$null;comparisons=@()}})
            same_map=[ordered]@{
                status='not_requested'
                reason='a same-map comparison needs TWO replays of the SAME authoritative ResourceMapID and is produced by Compare-NativeTrainingAnalyses'
                comparison=$null
            }
        }
        time_loss=@($timeLoss.ToArray())
        observations=@($observations.ToArray())
        limits=[ordered]@{
            no_score=$true;no_grade=$true;no_coaching=$true
            delta_rule='delta = subject - baseline; positive means the subject is slower / larger / more'
            unmatched_windows_stay_unmatched=$true
            correspondence_never_forced_to_full_coverage=$true
            time_never_part_of_the_correspondence_cost=$true
            different_resource_map_never_compared=$true
            unavailable_is_not_zero=$true
        }
    }
}
function NTA-FastestLapOf($Training) {
    if($null-eq$Training){return $null}
    $laps=@($Training.laps|Where-Object{$null-ne$_.time.lap_time_s-and[double]$_.time.lap_time_s-gt0})
    if($laps.Count-eq0){return $null}
    return @($laps|Sort-Object @{Expression={[double]$_.time.lap_time_s}},@{Expression={[int]$_.lap}})[0]
}

# The full section contract for one lap of a training analysis.
#
# The published artifact carries the full contracts ONCE at the top level (`sections`, each with its
# own `lap`), while the per-lap block carries the compact descriptor. This helper accepts either
# order: the full list when it was supplied, otherwise whatever the lap record itself holds. Only the
# full shape carries the measured entry/exit positions the correspondence kernel anchors on, so a
# compact-only lap is reported as having no usable anchor rather than being guessed at.
function NTA-SectionsOfLap($Lap,[AllowEmptyCollection()][object[]]$FullSections=@()) {
    if($null-eq$Lap){return @()}
    $lapNo=[int]$Lap.lap
    $full=@($FullSections)
    if($full.Count-gt0){
        $mine=New-Object System.Collections.Generic.List[object]
        foreach($s in $full){ if($null-ne$s-and[int]$s.lap-eq$lapNo){$mine.Add($s)} }
        if($mine.Count-gt0){return @($mine.ToArray())}
    }
    $own=@($Lap.section_contracts)
    if($own.Count-gt0){return $own}
    if($null-eq$Lap.spatial){return @()}
    return @($Lap.spatial.sections)
}

# Compare two analyzed replays of the SAME official map.
#
# The episodes of ONE lap of a training analysis, taken from the stream the comparison is about.
# Episodes keep their native Drift authority: this helper only selects them, it never creates or
# re-labels one.
function NTA-EpisodesOfLap {
    param([object]$Training,[int]$LapNo,[string]$StreamId='')
    if($null-eq$Training){return @()}
    $s=@($Training.episode_streams)
    if($s.Count-eq0){return @()}
    $chosen=$null
    if(-not[string]::IsNullOrWhiteSpace($StreamId)){
        foreach($st in $s){ if($null-ne$st-and[string]$st.id-eq$StreamId){$chosen=$st;break} }
    }
    if($null-eq$chosen){ foreach($st in $s){ if($null-ne$st-and[string]$st.status-like'ready*'){$chosen=$st;break} } }
    if($null-eq$chosen){ $chosen=$s[0] }
    if($null-eq$chosen){return @()}
    $out=New-Object System.Collections.Generic.List[object]
    foreach($ep in @($chosen.episodes)){
        if($null-eq$ep){continue}
        if([int]$ep.lap-eq$LapNo){$out.Add($ep)}
    }
    return @($out.ToArray())
}

# FAIL-CLOSED: unless BOTH sides carry an authoritative and EQUAL ResourceMapID the comparison is
# published as unavailable and NO delta is produced. This is a permanent regression
# (Tests/Smoke-TrainingAnalysis.ps1) because a cross-map "comparison" is not a measurement.
#
# ROLES ARE EXPLICIT: `-TrainingA` is the SUBJECT and `-TrainingB` is the BASELINE. Every signed
# number is `subject - baseline`, so swapping the two arguments negates every signed metric, swaps
# loss and gain, and is pinned by the swap-invariant regression.
function Compare-NativeTrainingAnalyses {
    param(
        [Parameter(Mandatory=$true)]$TrainingA,
        [Parameter(Mandatory=$true)]$TrainingB,
        [object[]]$RowsA=@(),
        [object[]]$RowsB=@(),
        [string]$LabelA='A',
        [string]$LabelB='B',
        [int]$TopLossSections=5,
        [int]$MaxObservations=8,
        [double]$MaxSeparationM=30.0,
        [double]$MatchedSeparationM=15.0,
        [double]$MaxHeadingDeltaDeg=80.0,
        [double]$BandProgress=0.06,
        [double]$MaxGapProgress=0.03,
        [double]$MinWindowSeparationM=8.0,
        [int]$MaxControlPoints=180,
        [double]$MinCoverage=0.34
    )
    $idA=$(if($null-ne$TrainingA){$TrainingA.resource_map_id}else{$null})
    $idB=$(if($null-ne$TrainingB){$TrainingB.resource_map_id}else{$null})
    $authA=$(if($null-ne$TrainingA){[string]$TrainingA.map_authority}else{'unresolved'})
    $authB=$(if($null-ne$TrainingB){[string]$TrainingB.map_authority}else{'unresolved'})
    $gate=NTA-ComparisonGate -MapIdA $idA -MapIdB $idB -AuthorityA $authA -AuthorityB $authB
    $bestA=$(NTA-FastestLapOf $TrainingA)
    $bestB=$(NTA-FastestLapOf $TrainingB)
    $bestATime=$(if($null-ne$bestA){[double]$bestA.time.lap_time_s}else{$null})
    $bestBTime=$(if($null-ne$bestB){[double]$bestB.time.lap_time_s}else{$null})
    # delta = subject - baseline, so a POSITIVE total means the subject lost time to the baseline.
    $overallDelta=$(if($null-ne$bestATime-and$null-ne$bestBTime){[Math]::Round(($bestATime-$bestBTime),4)}else{$null})
    $overall=[ordered]@{
        fastest_lap_a=$(if($null-ne$bestA){[int]$bestA.lap}else{$null})
        fastest_lap_b=$(if($null-ne$bestB){[int]$bestB.lap}else{$null})
        fastest_lap_time_a_s=$bestATime
        fastest_lap_time_b_s=$bestBTime
        subject_lap_time_s=$bestATime
        baseline_lap_time_s=$bestBTime
        total_delta_s=$overallDelta
        faster=$(if($null-eq$overallDelta){'unavailable'}elseif([Math]::Abs([double]$overallDelta)-lt0.0005){'equal'}elseif([double]$overallDelta-lt0){$LabelA}else{$LabelB})
        faster_note='the faster side took less time for its fastest valid lap; `total_delta_s` stays subject - baseline'
        basis='fastest valid lap of each replay; no score and no weighted aggregate is produced'
    }
    $subjectBlock=[ordered]@{replay_label=$LabelA;fastest_lap=$overall.fastest_lap_a;fastest_lap_time_s=$bestATime;role='subject'}
    $baselineBlock=[ordered]@{replay_label=$LabelB;fastest_lap=$overall.fastest_lap_b;fastest_lap_time_s=$bestBTime;role='baseline'}
    if(-not[bool]$gate.comparable){
        return [pscustomobject][ordered]@{
            schema_version=1
            contract='native_training_same_map_comparison_v1'
            status='comparison_unavailable'
            reason=[string]$gate.status
            delta_rule='delta = subject - baseline; positive means the subject is slower / larger / more'
            gate=$gate
            subject=$subjectBlock
            baseline=$baselineBlock
            subject_replay=$LabelA
            baseline_replay=$LabelB
            label_a=$LabelA;label_b=$LabelB
            overall=$overall
            breakdown=$null
            top_loss_sections=@()
            top_gain_sections=@()
            observations=@()
            limits=[ordered]@{no_score=$true;no_grade=$true;unmatched_windows_stay_unmatched=$true}
        }
    }
    $secA=@(NTA-SectionsOfLap $bestA @($TrainingA.sections))
    $secB=@(NTA-SectionsOfLap $bestB @($TrainingB.sections))
    if($secA.Count-eq0-or$secB.Count-eq0){
        return [pscustomobject][ordered]@{
            schema_version=1
            contract='native_training_same_map_comparison_v1'
            status='comparison_unavailable'
            reason='one of the two replays has no derived spatial section for its fastest lap'
            delta_rule='delta = subject - baseline; positive means the subject is slower / larger / more'
            gate=$gate
            subject=$subjectBlock
            baseline=$baselineBlock
            subject_replay=$LabelA
            baseline_replay=$LabelB
            label_a=$LabelA;label_b=$LabelB
            overall=$overall
            breakdown=$null
            top_loss_sections=@()
            top_gain_sections=@()
            observations=@()
            limits=[ordered]@{no_score=$true;no_grade=$true;unmatched_windows_stay_unmatched=$true}
        }
    }
    $nA=@($RowsA).Count;$nB=@($RowsB).Count
    $laStart=NTA-RowIndexAtTime $RowsA 0 ($nA-1) ([double]$bestA.time.lap_start_s)
    $laEnd=NTA-RowIndexAtTime $RowsA 0 ($nA-1) ([double]$bestA.time.lap_end_s)
    $lbStart=NTA-RowIndexAtTime $RowsB 0 ($nB-1) ([double]$bestB.time.lap_start_s)
    $lbEnd=NTA-RowIndexAtTime $RowsB 0 ($nB-1) ([double]$bestB.time.lap_end_s)
    $epA=@(NTA-EpisodesOfLap $TrainingA ([int]$bestA.lap) ([string]$TrainingA.primary_stream_id))
    $epB=@(NTA-EpisodesOfLap $TrainingB ([int]$bestB.lap) ([string]$TrainingB.primary_stream_id))
    $bd=NTA-TimeLossBreakdown -SubjectSections $secA -BaselineSections $secB -SubjectRows $RowsA -BaselineRows $RowsB `
        -SubjectEpisodes $epA -BaselineEpisodes $epB `
        -SubjectLapDurationS ([double]$bestA.time.lap_time_s) -BaselineLapDurationS ([double]$bestB.time.lap_time_s) `
        -SubjectLapStart $laStart -SubjectLapEnd $laEnd -BaselineLapStart $lbStart -BaselineLapEnd $lbEnd `
        -SubjectDriftAvailable ([bool]$bestA.native.available) -SubjectComboAvailable ([bool]$bestA.actions.game_facing_available) `
        -BaselineDriftAvailable ([bool]$bestB.native.available) -BaselineComboAvailable ([bool]$bestB.actions.game_facing_available) `
        -TopN $TopLossSections -MaxSeparationM $MaxSeparationM -MatchedSeparationM $MatchedSeparationM `
        -MaxHeadingDeltaDeg $MaxHeadingDeltaDeg -BandProgress $BandProgress -MaxGapProgress $MaxGapProgress `
        -MinWindowSeparationM $MinWindowSeparationM -MinCoverage $MinCoverage -MaxControlPoints $MaxControlPoints
    return [pscustomobject][ordered]@{
        schema_version=1
        contract='native_training_same_map_comparison_v1'
        status=$(if([string]$bd.status-eq'reconciled'){'ready'}else{[string]$bd.status})
        reason='same authoritative ResourceMapID on both sides'
        delta_rule='delta = subject - baseline; positive means the subject is slower / larger / more'
        gate=$gate
        subject=$subjectBlock
        baseline=$baselineBlock
        subject_replay=$LabelA
        baseline_replay=$LabelB
        label_a=$LabelA;label_b=$LabelB
        overall=$overall
        breakdown=$bd
        top_loss_sections=@($bd.top_loss_sections)
        top_gain_sections=@($bd.top_gain_sections)
        observations=@(NTA-BuildObservations -Breakdown $bd -SubjectLabel $LabelA -BaselineLabel $LabelB -MaxObservations $MaxObservations)
        limits=[ordered]@{no_score=$true;no_grade=$true;unmatched_windows_stay_unmatched=$true;different_resource_map_never_compared=$true}
    }
}

# ---------------------------------------------------------------------------------------------
# Human-checkable artifact
# ---------------------------------------------------------------------------------------------

# The full, human-checkable per-replay artifact written to Output/<replay>_training.json: the lap and
# section detail (including the observed trajectory) that the everyday analysis JSON deliberately
# keeps compact. No absolute path, no player nickname, no SAV bytes.
function New-NativeTrainingArtifact {
    param(
        [Parameter(Mandatory=$true)]$Training,
        # The live full section contracts from New-NativeTrainingAnalysis. Passed explicitly because a
        # nested one-element array cannot survive ConvertTo-Json.
        [AllowEmptyCollection()][object[]]$SectionContracts=@()
    )
    $laps=New-Object System.Collections.Generic.List[object]
    foreach($lr in @($Training.laps)){
        $laps.Add([ordered]@{
            lap=[int]$lr.lap
            stream_id=[string]$lr.stream_id
            time=$lr.time
            distance=$lr.distance
            speed=$lr.speed
            native=$lr.native
            actions=$lr.actions
            episode_aggregates=$lr.episode_aggregates
            spatial=[ordered]@{
                available=[bool]$lr.spatial.available
                section_count=[int]$lr.spatial.section_count
                sections=@($lr.spatial.sections)
            }
        })
    }
    # The full section contracts arrive as an explicit array so a single-section replay cannot be
    # collapsed into one scalar on the way here.
    $sections=New-Object System.Collections.Generic.List[object]
    foreach($sc in @($SectionContracts)){ if($null-ne$sc){$sections.Add($sc)} }
    $episodesOut=New-Object System.Collections.Generic.List[object]
    foreach($es in @($Training.episode_streams)){
        foreach($ep in @($es.episodes)){ $episodesOut.Add($ep) }
    }
    return [ordered]@{
        schema_version=1
        contract='native_training_artifact_v1'
        architecture='native_first_v1'
        generated_from='native_training_analysis_v1'
        replay_sha256=$Training.replay_sha256
        status=$Training.status
        primary_stream_id=$Training.primary_stream_id
        resource_map_id=$Training.resource_map_id
        map_authority=$Training.map_authority
        capabilities=$Training.capabilities
        lap_count=[int]$Training.lap_count
        laps=@($laps.ToArray())
        section_count=[int]$sections.Count
        sections=@($sections.ToArray())
        episode_count=[int]$Training.episode_count
        episodes=[ordered]@{
            authority='logical native Drift actions'
            count=[int]$Training.episode_count
            by_stream=@($episodesOut.ToArray())
        }
        time_loss=@($Training.time_loss)
        observations=@($Training.observations)
        intra_replay_comparison=$Training.comparisons.intra_replay
        limits=$Training.limits
    }
}
