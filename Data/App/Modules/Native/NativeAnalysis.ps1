function NF-ReadJson([string]$Path) {
    try { if(Test-Path -LiteralPath $Path -PathType Leaf){return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json} } catch {}
    return $null
}
function NF-RelPath([string]$Root,[string]$Full) {
    $r=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $f=[IO.Path]::GetFullPath($Full)
    if($f.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)){return $f.Substring($r.Length)}
    return $Full
}
function NF-LocalStream($Telemetry) {
    if($null-eq$Telemetry){return $null}
    $s=@($Telemetry.streams|Where-Object{[string]$_.role -eq 'local_high_frequency'}|Select-Object -First 1)
    if($s.Count-gt0){return $s[0]}
    $a=@($Telemetry.streams);if($a.Count-gt0){return $a[0]}
    return $null
}
function NF-NativeActionSummary($Telemetry) {
    $s=NF-LocalStream $Telemetry
    if($null-eq$s){return [ordered]@{status='unavailable';source='none'}}
    $driftReady=[bool]$s.system_drift_state_available
    $effectReady=[bool]$s.speed_effect_state_available
    $prod=$s.production_actions
    $prodProps=$(if($null-eq$prod){@()}else{@($prod.PSObject.Properties.Name)})
    # Every capability is gated by the availability of ITS OWN native authority, never by another.
    # Raw native integrity is published per authority below; do not read `$prod.available` as a proxy
    # for it. 320冒险岛 is the regression: its action event table is undecodable as v1 while its Drift
    # and effect tables are intact, and the product must still show the real logical drift count
    # while only the action-event fields go N/A.
    $eventsAvailable=($null-ne$prod-and$prodProps-contains'available'-and[bool]$prod.available)
    # Per-authority raw-evidence availability. `available` (action event table) MUST NOT be used to
    # gate Drift or effect evidence; the two native action-object tables have their own flags.
    $rawDriftReady=($null-ne$prod-and$prodProps-contains'drift'-and[bool]$prod.drift.available)
    $rawEffectReady=($null-ne$prod-and$prodProps-contains'small_boost'-and$prodProps-contains'nitro')
    # Game-facing gate (product statistics contract, ADR 0005): a count may only be presented as a
    # game-facing number when the native evidence actually supports it. Raw native evidence stays
    # published beside it and is never renamed into a game-facing label.
    # A telemetry summary written by an older semantics contract has no `game_facing_available`
    # field at all; that must fail closed too (never silently treated as validated).
    $gameFacingDeclared=($null-ne$prod-and$prodProps-contains'game_facing_available')
    $gameFacing=($gameFacingDeclared-and[bool]$prod.game_facing_available)
    $actions=[ordered]@{
        authority=$(if($eventsAvailable){'replay_native_action_event'}else{'unavailable'})
        status=$(if($gameFacing){'production_semantics_ready'}elseif($eventsAvailable-and-not$gameFacingDeclared){'production_semantics_contract_stale'}elseif($eventsAvailable){'production_semantics_variant_unvalidated'}else{'native_action_event_table_unavailable'})
        drift=[ordered]@{raw_intervals=$(if($rawDriftReady){$prod.drift.raw_intervals}else{$null});logical_count=$(if($rawDriftReady){$prod.drift.logical_count}else{$null});game_facing=$(if($rawDriftReady){[bool]$prod.drift.game_facing}else{$false});authority='replay_native_action_object_drift_table'}
        air_boost=[ordered]@{count=$(if($gameFacing){$prod.air_boost.count}else{$null});game_facing=$gameFacing;native_code=8;authority='replay_native_action_event'}
        landing_boost=[ordered]@{count=$(if($gameFacing){$prod.landing_boost.count}else{$null});game_facing=$gameFacing;native_code=9;authority='replay_native_action_event'}
        combo=[ordered]@{cw=$(if($gameFacing){$prod.combo.cw}else{$null});wcw=$(if($gameFacing){$prod.combo.wcw}else{$null});cww=$(if($gameFacing){$prod.combo.cww}else{$null});game_facing=$gameFacing;authority='replay_native_action_event'}
        small_boost=[ordered]@{raw_effect_count=$(if($rawEffectReady){$prod.small_boost.raw_effect_count}else{$null});classified_count=$(if($rawEffectReady){$prod.small_boost.classified_count}else{$null});unresolved_count=$(if($rawEffectReady){$prod.small_boost.unresolved_count}else{$null});game_facing_normal_count=$null;game_facing=$false;game_facing_parity=$(if($rawEffectReady){[string]$prod.small_boost.game_facing_parity}else{'unavailable'});authority='replay_native_action_object_speed_effect_table_v2'}
        nitro=[ordered]@{raw_interval_count=$(if($rawEffectReady){$prod.nitro.raw_interval_count}else{$null});logical_count=$(if($rawEffectReady){$prod.nitro.logical_count}else{$null});unresolved_count=$(if($rawEffectReady){$prod.nitro.unresolved_count}else{$null});game_facing_count=$null;game_facing=$false;game_facing_parity=$(if($rawEffectReady){[string]$prod.nitro.game_facing_parity}else{'unavailable'});native_code=1;authority='replay_native_action_object_speed_effect_table_v2'}
    }
    # Product-facing statistics contract: the single place that declares which number the user may
    # read as a game-facing action count and which one is only raw native evidence.
    $statistics=[ordered]@{
        contract='product_statistics_contract_v1'
        rule='A primary (game-facing) number is only published where the native evidence closes against the gold replays. Everything else is published as raw native evidence with an explicit unresolved status; raw evidence is never renamed into a game-facing label.'
        primary=[ordered]@{
            drift=$(if($driftReady){[ordered]@{label='漂移';value=$(if($rawDriftReady){[int]$prod.drift.logical_count}else{$null});unit='次';basis='logical drift actions (native retrigger coalescing)';authority='replay_native_action_object_drift_table'}}else{$null})
            air_boost=$(if($gameFacing){[ordered]@{label='空喷';value=[int]$prod.air_boost.count;unit='次';basis='native action code 8';authority='replay_native_action_event'}}else{$null})
            landing_boost=$(if($gameFacing){[ordered]@{label='落地喷';value=[int]$prod.landing_boost.count;unit='次';basis='native action code 9';authority='replay_native_action_event'}}else{$null})
            cw=$(if($gameFacing){[ordered]@{label='CW';value=[int]$prod.combo.cw;unit='次';basis='native code25 grouped with a code24';authority='replay_native_action_event'}}else{$null})
            wcw=$(if($gameFacing){[ordered]@{label='WCW';value=[int]$prod.combo.wcw;unit='次';basis='native action code 19 marker';authority='replay_native_action_event'}}else{$null})
            cww=$(if($gameFacing){[ordered]@{label='CWW';value=[int]$prod.combo.cww;unit='次';basis='remaining native code 24 markers';authority='replay_native_action_event'}}else{$null})
        }
        raw_only=[ordered]@{
            small_boost_native_effects=$(if($rawEffectReady){[ordered]@{label='小喷类原生效果（结算口径未闭合）';value=[int]$prod.small_boost.raw_effect_count;unit='个原生区间';basis='native speed-effect code 2001 intervals';authority='replay_native_action_object_speed_effect_table_v2';parity='unresolved'}}else{$null})
            nitro_native_intervals=$(if($rawEffectReady){[ordered]@{label='氮气原生区间（结算口径未闭合）';value=[int]$prod.nitro.raw_interval_count;unit='个原生区间';basis='native speed-effect code 1 intervals';authority='replay_native_action_object_speed_effect_table_v2';parity='unresolved'}}else{$null})
            drift_raw_intervals=$(if($rawDriftReady){[ordered]@{label='原生漂移区间';value=[int]$prod.drift.raw_intervals;unit='个原生区间';basis='native Drift intervals before retrigger coalescing';authority='replay_native_action_object_drift_table'}}else{$null})
            system_drift_segments=$(if($driftReady){[ordered]@{label='原生 Drift timeline 段';value=[int]$s.system_drift_segment_count;unit='段';basis='system_drift_state timeline';authority='replay_native_action_object_drift_table'}}else{$null})
            unknown_action_codes=$(if($eventsAvailable){[ordered]@{label='未知原生 code';value=@($prod.unknown_action_codes);basis='preserved verbatim';authority='replay_native_action_event'}}else{$null})
        }
        unavailable=[ordered]@{
            small_boost_game_facing=[ordered]@{label='普通小喷（结算口径）';value=$null;reason='code2001 raw vs game settlement does not close (Gold B 46 raw vs 39 reported actions); no game-facing normal-small-boost number is invented'}
            nitro_game_facing=[ordered]@{label='氮气次数（结算口径）';value=$null;reason='game nitro = native code1 interval count + 1 in both gold replays; no native activation evidence found'}
        }
        mislabeled_terms_removed=@('漂移小喷 (raw code2001 presented as a normal small-boost count)')
    }
    return [ordered]@{
        schema_version=3
        status=$(if($gameFacing){'native_actions_ready'}elseif($eventsAvailable-and-not$gameFacingDeclared){'native_actions_contract_stale'}elseif($eventsAvailable){'native_actions_variant_unvalidated'}elseif($driftReady -or $effectReady){'native_actions_partial'}else{'native_actions_unavailable'})
        source='replay_native_action_event + replay_native_action_object_tables'
        authoritative_only=$true
        game_facing_available=$gameFacing
        action_event_table_available=$eventsAvailable
        drift_table_available=$rawDriftReady
        effect_table_available=$rawEffectReady
        semantic_alignment=$(if($null-ne$prod){$prod.semantic_alignment}else{$null})
        production_action_contract=$(if($null-ne$prod){[string]$prod.contract}else{'production_native_action_semantics_v1'})
        production_action_authority='replay_native_action_event'
        production_action_available=$eventsAvailable
        statistics_contract=$statistics
        actions=$actions
        production_actions=$prod
        drift=[ordered]@{available=$driftReady;game_facing=$(if($rawDriftReady){[bool]$prod.drift.game_facing}else{$false});raw_intervals=$(if($rawDriftReady){$prod.drift.raw_intervals}else{$null});logical_count=$(if($rawDriftReady){$prod.drift.logical_count}else{$null});count=$(if($driftReady){[int]$s.system_drift_segment_count}else{$null});source=$(if($driftReady){[string]$s.system_drift_state_source}else{$null})}
        nitro=[ordered]@{available=$effectReady;count=$(if($effectReady){[int]$s.nitro_segment_count}else{$null});raw_interval_count=$(if($rawEffectReady){$prod.nitro.raw_interval_count}else{$null});logical_count=$(if($rawEffectReady){$prod.nitro.logical_count}else{$null});game_facing=$false;game_facing_parity=$(if($rawEffectReady){[string]$prod.nitro.game_facing_parity}else{'unavailable'});source=$(if($effectReady){[string]$s.speed_effect_state_source}else{$null})}
        drift_small_boost=[ordered]@{available=$effectReady;count=$(if($effectReady){[int]$s.small_boost_segment_count}else{$null});role='diagnostic_only';note='raw native code2001 buckets; the primary view must not present this as a game-facing normal small-boost count'}
        air_boost=[ordered]@{available=$gameFacing;count=$(if($gameFacing){$prod.air_boost.count}else{$null});game_facing=$gameFacing;authority='replay_native_action_event';native_code=8;contact_state_diagnostic_count=$(if($null-ne$prod){$prod.disagreement.air_contact_state.contact_state_air_boost}else{$null})}
        landing_boost=[ordered]@{available=$gameFacing;count=$(if($gameFacing){$prod.landing_boost.count}else{$null});game_facing=$gameFacing;authority='replay_native_action_event';native_code=9;contact_state_diagnostic_count=$(if($null-ne$prod){$prod.disagreement.landing_contact_state.contact_state_landing_boost}else{$null})}
        other_small_boost=[ordered]@{available=$effectReady;count=$(if($effectReady){[int]$s.other_small_boost_segment_count}else{$null});role='diagnostic_only'}
        map_propulsion_effect=[ordered]@{available=$effectReady;count=$(if($effectReady){[int]$s.map_propulsion_effect_segment_count}else{$null});native_code=2003;authority='dedicated_labeled_map_scene_propulsion';scene_geometry_driver='unresolved'}
        unknown_speed_effect=[ordered]@{available=$effectReady;count=$(if($effectReady){[int]$s.unknown_speed_effect_segment_count}else{$null});preserved=$true}
        unknown_action_codes=$(if($eventsAvailable){@($prod.unknown_action_codes)}else{@()})
        combo_actions=[ordered]@{status=$(if($gameFacing){'production'}elseif($eventsAvailable){'variant_unvalidated'}else{'unavailable'});source='replay_native_action_event';authority='replay_native_action_event';supported=@('CW','WCW','CWW');CW=$(if($gameFacing){$prod.combo.cw}else{$null});WCW=$(if($gameFacing){$prod.combo.wcw}else{$null});CWW=$(if($gameFacing){$prod.combo.cww}else{$null});total=$(if($gameFacing){[int]$prod.combo.cw+[int]$prod.combo.wcw+[int]$prod.combo.cww}else{$null});legacy_combo_candidate=$(if($null-ne$prod){$prod.legacy_combo_candidate}else{$null});legacy_fallback='none';legacy_authoritative=$false}
        rule='Native state/effect/action tables are facts. Derived analysis may explain them but may not redefine them, and unavailable evidence stays unavailable.'
    }
}
function NF-StreamMeta($Telemetry) {
    $rows=New-Object System.Collections.Generic.List[object]
    if($null-eq$Telemetry){return @()}
    foreach($s in @($Telemetry.streams)){
        if($null-eq$s){continue}
        $rows.Add([ordered]@{
            id=[string]$s.id;role=[string]$s.role;role_label=[string]$s.role_label;sample_hz=$s.sample_hz;records=$s.records;duration_s=$s.duration_s;distance=$s.distance;avg_speed=$s.avg_speed;speed_source=[string]$s.speed_source
            lap_count=$s.lap_count;system_drift_state_available=[bool]$s.system_drift_state_available;system_drift_segment_count=$s.system_drift_segment_count;speed_effect_state_available=[bool]$s.speed_effect_state_available;native_speed_effect_segment_count=$s.native_speed_effect_segment_count;map_propulsion_effect_segment_count=$s.map_propulsion_effect_segment_count;combo_action_count=$s.combo_action_count;cw_count=$s.cw_count;wcw_count=$s.wcw_count;cww_count=$s.cww_count
        })
    }
    return $rows.ToArray()
}
# Conservative automatic-Drift air cut.  The telemetry summary intentionally stays compact; the
# logical per-stream CSV is the full production row source already emitted beside it.  Read only the
# native time/contact columns needed to build sustained ECS_INAIR intervals.  Failure is fail-open for
# this optional hard cut (the existing native effect/next-Drift rules still apply); it never invents air.
function NF-ValidatedAirIntervalsForStream($TelemetrySummaryPath,$Stream) {
    if([string]::IsNullOrWhiteSpace([string]$TelemetrySummaryPath)-or$null-eq$Stream){return @()}
    $csv=[string]$Stream.csv
    if([string]::IsNullOrWhiteSpace($csv)){return @()}
    $dir=Split-Path -Parent $TelemetrySummaryPath
    $path=Join-Path $dir $csv
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return @()}
    try {
        $rows=@(Import-Csv -LiteralPath $path -Encoding UTF8)
        return @(NAS-ValidatedAirIntervalsFromRows -Rows $rows)
    } catch { return @() }
}

# Analysis Closure v1: the product segmentation contract (native Drift start -> native recovery end).
# NATIVE-ONLY by construction: the logical native Drift episodes decide the segment starts and only
# a post-Drift code2001 small-boost-class native effect may extend the recovery end. Standard Nitro
# is evidence-only for this ownership decision. No speed peak, no curvature and no map geometry
# participates, and a network shadow without its own native action ownership simply
# publishes `unavailable_no_native_drift_authority`.
function NF-SegmentAnalysis($Telemetry,$DrivingEpisodes,[string]$TelemetrySummaryPath='') {
    $streams=New-Object System.Collections.Generic.List[object]
    if($null-eq$Telemetry){
        return [ordered]@{
            schema_version=3;contract='native_analysis_segments_v1';status='unavailable_prerequisite'
            reason='production telemetry unavailable';nitro_recovery_policy='evidence_only_never_extends_segment';streams=@();segment_count=0
        }
    }
    $episodeStreams=@()
    if($null-ne$DrivingEpisodes){$episodeStreams=@($DrivingEpisodes.streams)}
    foreach($s in @($Telemetry.streams)){
        if($null-eq$s){continue}
        $match=$null
        foreach($es in $episodeStreams){if([string]$es.id-eq[string]$s.id){$match=$es;break}}
        $ownerAmbiguous=$false
        if($null-eq$match){
            # Exact identity first. A role may only be used as a fallback when exactly ONE candidate
            # carries it: a replay can hold several network_low_frequency shadows, and choosing "the
            # first same-role stream" would attach another car's Drift table to this one.
            $cand=@($episodeStreams|Where-Object{$null-ne$_-and[string]$_.role-eq[string]$s.role})
            if($cand.Count-eq1){$match=$cand[0]}elseif($cand.Count-gt1){$ownerAmbiguous=$true}
        }
        $eps=New-Object System.Collections.Generic.List[object]
        if($null-ne$match){foreach($lap in @($match.laps)){foreach($ep in @($lap.episodes)){if($null-ne$ep){$eps.Add($ep)}}}}
        $airIntervals=@(NF-ValidatedAirIntervalsForStream -TelemetrySummaryPath $TelemetrySummaryPath -Stream $s)
        $contract=NAS-BuildContract -Episodes @($eps.ToArray()) -EffectIntervals @($s.native_speed_effect_segments) -AirborneIntervals $airIntervals -Laps @($s.laps)
        $streams.Add([ordered]@{
            id=[string]$s.id
            role=[string]$s.role
            status=$(if($ownerAmbiguous){'unavailable_native_drift_owner_ambiguous'}elseif(@($eps.ToArray()).Count-gt0){'ready'}else{'unavailable_no_native_drift_authority'})
            drift_merge_gap_s=$contract.drift_merge_gap_s
            recovery_window_s=$contract.recovery_window_s
            segment_count=$contract.segment_count
            recovery_available_count=$contract.recovery_available_count
            recovery_unavailable_count=$contract.recovery_unavailable_count
            next_drift_hard_cut_count=$contract.next_drift_hard_cut_count
            airborne_hard_cut_count=$contract.airborne_hard_cut_count
            lap_count=$contract.lap_count
            laps=@($contract.laps)
            segments=@($contract.segments)
        })
    }
    $total=0
    foreach($x in @($streams.ToArray())){$total+=[int]$x.segment_count}
    return [ordered]@{
        schema_version=3
        contract='native_analysis_segments_v1'
        architecture='native_first_v1'
        status=$(if($total-gt0){'ready'}else{'unavailable_no_native_drift_authority'})
        reason=$(if($total-gt0){''}else{'no logical native Drift episode is available in any stream'})
        authority='replay_native_action_object_drift_table_v3 + replay_native_action_object_speed_effect_table_v2 + replay_native_contact_state_offset_52_hard_cut'
        derived=$true
        geometry_role='measurement_only'
        ownership_rule='a segment belongs to the lap of its first logical native Drift; a lap boundary never truncates a Drift'
        recovery_rule='recovery end = end of the last post-Drift code2001 small-boost-class native effect whose START is inside the 2.0 s onset window; an owned tail is hard-cut at sustained native airborne onset or the next independent Drift; Nitro/code1 never extends a Drift; detailed airborne continuation belongs to Custom Path'
        nitro_recovery_policy='evidence_only_never_extends_segment'
        stream_count=$streams.Count
        segment_count=$total
        streams=@($streams.ToArray())
    }
}
function New-NativeFirstAnalysis {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$ReplayPath,
        [Parameter(Mandatory=$true)][string]$ReplaySha256,
        $MapIdentity,
        $Resolution,
        [string]$TelemetrySummaryPath,
        [string]$NativeMapMetadataPath='',
        $DrivingAnalysis=$null,
        $DrivingEpisodes=$null,
        $TrainingAnalysis=$null
    )
    $telemetry=NF-ReadJson $TelemetrySummaryPath
    $mapMeta=if([string]::IsNullOrWhiteSpace($NativeMapMetadataPath)){$null}else{NF-ReadJson $NativeMapMetadataPath}
    $telemetryReady=($null-ne$telemetry)
    $basicStream=NF-LocalStream $telemetry
    $mapResolved=($null-ne$MapIdentity -and [bool]$MapIdentity.authoritative -and $null-ne$MapIdentity.resource_map_id)
    $mapReady=($mapResolved -and $null-ne$mapMeta -and [string]$mapMeta.contract -eq 'native_map_v1')
    $status=if(-not$telemetryReady){'telemetry_failed'}elseif(-not$mapResolved){'telemetry_ready_map_unresolved'}elseif(-not$mapReady){'telemetry_ready_native_map_missing'}else{'native_ready'}
    $mapId=if($mapResolved){[int]$MapIdentity.resource_map_id}else{$null}
    $mapName=if($null-ne$MapIdentity -and -not[string]::IsNullOrWhiteSpace([string]$MapIdentity.canonical_name)){[string]$MapIdentity.canonical_name}elseif($null-ne$MapIdentity -and -not[string]::IsNullOrWhiteSpace([string]$MapIdentity.display_name)){[string]$MapIdentity.display_name}else{''}
    return [ordered]@{
        schema_version=29
        contract='native_first_analysis_v1'
        architecture='native_first_v1'
        compatibility_mode='none'
        replay_file=[IO.Path]::GetFileName($ReplayPath)
        replay_sha256=$ReplaySha256
        status=$status
        map_hint=$(if($null-ne$Resolution){[string]$Resolution.map_hint}else{$null})
        map_name=$mapName
        map_id=$mapId
        resource_map_id=$mapId
        game_map_id=$(if($null-ne$MapIdentity){$MapIdentity.game_map_id}else{$null})
        course_key=$(if($null-ne$MapIdentity){[string]$MapIdentity.course_key}else{''})
        identity_key=$(if($null-ne$MapIdentity){[string]$MapIdentity.course_key}else{''})
        map_identity=$MapIdentity
        map_resolution=[ordered]@{method=$(if($null-ne$Resolution){[string]$Resolution.resolution_method}else{'none'});confidence=$(if($null-ne$Resolution){[string]$Resolution.confidence}else{'unresolved'});native_first_accepted=$mapResolved}
        telemetry_status=$(if($telemetryReady){'ready'}else{'failed'})
        telemetry_summary=$(if($telemetryReady){NF-RelPath $ProjectRoot $TelemetrySummaryPath}else{$null})
        detected_profile=$(if($telemetryReady){[string]$telemetry.detected_profile}else{$null})
        stream_count=$(if($telemetryReady){@($telemetry.streams).Count}else{0})
        streams=$(NF-StreamMeta $telemetry)
        native_actions=$(NF-NativeActionSummary $telemetry)
        native_map=[ordered]@{
            status=$(if($mapReady){'ready'}elseif($mapResolved){'missing'}else{'unresolved'})
            authoritative=$mapReady
            resource_map_id=$mapId
            metadata=$(if($mapReady){NF-RelPath $ProjectRoot $NativeMapMetadataPath}else{$null})
            vector_minimap=$(if($mapReady){NF-RelPath $ProjectRoot (Join-Path (Split-Path -Parent $NativeMapMetadataPath) 'official_map.svg')}else{$null})
            model=$(if($mapReady){NF-RelPath $ProjectRoot (Join-Path (Split-Path -Parent $NativeMapMetadataPath) 'official_map.nif')}else{$null})
            source='Map\Common Map\MapNN\map.nif'
            coordinate_rule='direct world XY; no fit/rotation/scale/translation'
            dynamic_scene_status='native_code2003_map_propulsion_effect_validated_scene_geometry_driver_unresolved'
        }
        driving_analysis=$(if($null-ne$DrivingAnalysis){$DrivingAnalysis}else{[ordered]@{schema_version=1;contract='native_driving_sections_v1';detector_revision=3;status=$(if($mapReady-and$telemetryReady){'unavailable_not_built'}else{'unavailable_prerequisite'});authoritative=$false;streams=@()}})
        # Driving v2: native episodes + lap metrics are map-independent; only `spatial_driving`
        # needs an authoritative map identity. This keeps an unresolved-identity replay useful.
        driving_episodes=$(if($null-ne$DrivingEpisodes){$DrivingEpisodes}else{[ordered]@{
            schema_version=1;contract='native_driving_episodes_v1';status='unavailable'
            native_episode_analysis='unavailable'
            spatial_driving='unavailable_prerequisite'
            spatial_driving_reason=$(if(-not$telemetryReady){'production telemetry unavailable'}else{'derived episode analysis was not built'})
            map_independent=$true
            # An episode count that was never produced is unavailable, not zero.
            episode_count=$(if($telemetryReady){$null}else{$null})
            streams=@()
        }})
        # Level 1 of the product capability ladder. Basic Driving is a production-telemetry fact
        # (duration / distance / average speed / max speed / sample rate / frame count / lap count)
        # and needs neither an official map identity nor a native action table. It must be ready
        # whenever Physical telemetry is ready, and any quantity telemetry does not carry stays
        # $null (N/A) - never 0. 0 means "successfully resolved and measured as zero".
        basic_driving=[ordered]@{
            status=$(if($null-ne$basicStream){'ready'}elseif($telemetryReady){'unavailable_no_local_stream'}else{'unavailable_prerequisite'})
            authoritative=$false
            source='production_telemetry'
            stream_id=$(if($null-ne$basicStream){[string]$basicStream.id}else{$null})
            duration_s=$(if($null-ne$basicStream){$basicStream.duration_s}else{$null})
            distance_m=$(if($null-ne$basicStream){$basicStream.distance}else{$null})
            average_speed=$(if($null-ne$basicStream){$basicStream.avg_speed}else{$null})
            max_speed=$(if($null-ne$basicStream){$basicStream.max_speed}else{$null})
            sample_rate_hz=$(if($null-ne$basicStream){$basicStream.sample_hz}else{$null})
            frame_count=$(if($null-ne$basicStream){$basicStream.records}else{$null})
            lap_count=$(if($null-ne$basicStream){$basicStream.lap_count}else{$null})
            lap_count_status=$(if($null-ne$basicStream){[string]$basicStream.lap_status}else{'unavailable'})
            rule='Basic Driving is Level 1: ready whenever Physical telemetry is ready, independent of map identity and native action tables. Unavailable quantities stay null; only a resolved measurement may be 0.'
        }
        # Analysis Closure v1: the automatic product segmentation (Drift start -> recovery end).
        # It is derived from native authority only and is published per stream and per lap, so the
        # product surface never has to re-derive it and can never disagree with the analyzer.
        segment_analysis=$(NF-SegmentAnalysis $telemetry $DrivingEpisodes $TelemetrySummaryPath)
        driving_status=[ordered]@{
            basic_driving=$(if($null-ne$basicStream){'ready'}elseif($telemetryReady){'unavailable_no_local_stream'}else{'unavailable_prerequisite'})
            native_action_analysis=$(if($null-ne$DrivingEpisodes-and[string]$DrivingEpisodes.native_episode_analysis-eq'ready'){'ready'}elseif($telemetryReady){'unavailable'}else{'unavailable_prerequisite'})
            lap_metrics=$(if($null-ne$DrivingEpisodes-and[string]$DrivingEpisodes.native_episode_analysis-eq'ready'){'ready'}elseif($telemetryReady){'unavailable'}else{'unavailable_prerequisite'})
            native_driving_episodes=$(if($null-ne$DrivingEpisodes-and[string]$DrivingEpisodes.native_episode_analysis-eq'ready'){'ready'}else{'unavailable'})
            spatial_driving=$(if($null-ne$DrivingEpisodes){[string]$DrivingEpisodes.spatial_driving}else{'unavailable_prerequisite'})
            spatial_driving_reason=$(if($null-ne$DrivingEpisodes){[string]$DrivingEpisodes.spatial_driving_reason}else{'official map identity required for spatial sections'})
            official_map=$(if($mapReady){'ready'}elseif($mapResolved){'missing'}else{'unresolved'})
            rule='Native episode / lap analysis is independent of map identity. Only official map / spatial section / same-map A/B require a resolved identity.'
        }
        # Training Analysis v1. Level 1 (lap) and level 2 (native episode) are map-independent; only
        # level 3 (spatial section / same-map A/B) needs an authoritative map identity. An unresolved
        # identity therefore never makes the training analysis unavailable - it only removes the
        # spatial layer. No score, no grade, no coaching is produced anywhere below.
        training_analysis=$(if($null-ne$TrainingAnalysis){$TrainingAnalysis}else{[ordered]@{
            schema_version=1;contract='native_training_analysis_v1'
            status=$(if(-not$telemetryReady){'unavailable_prerequisite'}else{'unavailable_not_built'})
            reason=$(if(-not$telemetryReady){'production telemetry unavailable'}else{'the training analysis was not built'})
            map_independent=$true
            laps=@();episodes=@();sections=@();comparisons=@();time_loss=@();observations=@()
        }})
        training_status=[ordered]@{
            lap_analysis=$(if($null-ne$TrainingAnalysis){[string]$TrainingAnalysis.capabilities.lap_analysis}else{'unavailable'})
            episode_analysis=$(if($null-ne$TrainingAnalysis){[string]$TrainingAnalysis.capabilities.episode_analysis}else{'unavailable'})
            spatial_section=$(if($null-ne$TrainingAnalysis){[string]$TrainingAnalysis.capabilities.spatial_section}else{'unavailable_prerequisite'})
            intra_replay_comparison=$(if($null-ne$TrainingAnalysis){[string]$TrainingAnalysis.comparisons.intra_replay.status}else{'unavailable_prerequisite'})
            time_loss_sections=$(if($null-ne$TrainingAnalysis){@($TrainingAnalysis.time_loss).Count}else{0})
            rule='Training Analysis degrades independently per level. Same-map A/B additionally needs two replays with the same authoritative ResourceMapID.'
        }
        production_policy=[ordered]@{semantic_fallback='none';map_guessing='none';trajectory_basemap=$false;official_map_source='map.nif';derived_analysis_may_redefine_native_facts=$false;driving_sections='derived_observed_path_only';driving_episodes='native_actions_define_events_geometry_measures_only';canonical_track_authority=$false;training_analysis='measurement_only_no_score_no_grade_no_coaching'}
    }
}
