param()
$ErrorActionPreference='Stop'
$appDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $appDir 'Modules\Native\NativeDrivingAnalysis.ps1')
. (Join-Path $appDir 'Modules\Native\NativeDrivingEpisodes.ps1')
function Require([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message}}
function Write-Utf8BomLocal([string]$Path,[string]$Text){$enc=New-Object System.Text.UTF8Encoding -ArgumentList $true;[IO.File]::WriteAllText($Path,$Text,$enc)}

# ---------------------------------------------------------------------------
# Driving Analysis v2 -- native driving episodes / lap metrics / section v2.
#
# Synthetic, map-independent by design: the same synthetic telemetry is analysed twice, once
# without an official map identity (native episodes must still be READY) and once with it
# (spatial section metrics become READY). Authority rule under test: native actions define the
# driving-event facts; geometry only measures position / distance / section.
# ---------------------------------------------------------------------------
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_DrivingEpisodes_'+[Guid]::NewGuid().ToString('N'))
try {
    $root=Join-Path $tmp 'Project'
    $teleDir=Join-Path $root 'Data\Telemetry\synthetic'
    $mapDir=Join-Path $root 'Data\NativeMaps\Map999'
    New-Item -ItemType Directory -Force -Path $teleDir,$mapDir | Out-Null

    # --- synthetic production telemetry: 2 laps, one logical drift each --------------------
    $rows=New-Object System.Collections.Generic.List[object]
    $laps=New-Object System.Collections.Generic.List[object]
    $cum=0.0;$time=0.0;$globalIndex=0
    for($lap=1;$lap-le2;$lap++){
        $lapStart=$globalIndex;$lapStartD=$cum;$lapStartT=$time
        $n=200
        for($k=0;$k-lt$n;$k++){
            $x=[double]$k*0.5;$y=0.0
            if($k-ge50-and$k-le70){$y=[double]($k-50)*0.4}
            if($k-gt0){$dx=0.5;$dy=0.0;if($k-ge51-and$k-le70){$dy=0.4};$cum+=[Math]::Sqrt($dx*$dx+$dy*$dy)}
            $speed=200.0
            if($k-ge40-and$k-le80){$speed=150.0}
            $rows.Add([pscustomobject]@{time_s=[Math]::Round($time,4);x=[Math]::Round($x,5);y=[Math]::Round($y,5);z=0.0;speed=$speed;distance=[Math]::Round($cum,5);lap_index=$lap;pose_valid=$true;pose_break_before=$false})
            $time+=0.1;$globalIndex++
        }
        $lapEnd=$globalIndex-1
        $laps.Add([ordered]@{lap=$lap;start_i=$lapStart;end_i=$lapEnd;start_t=[Math]::Round($lapStartT,4);end_t=[Math]::Round($time-0.1,4);duration_s=[Math]::Round(($time-0.1)-$lapStartT,4);start_distance=[Math]::Round($lapStartD,4);end_distance=[Math]::Round($cum,4);distance=[Math]::Round($cum-$lapStartD,4);source='replay_native_lap_index'})
        $time+=0.5
    }
    $csv=Join-Path $teleDir 'logical_01.csv';$rows.ToArray()|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

    # Native tables. Lap 1 occupies 0.0..19.9 s, lap 2 occupies 20.4..40.3 s.
    $driftGroups=@(
        [ordered]@{id=1;raw_interval_count=3;merged=$true;start_ms=5000;end_ms=7000;duration_ms=2000;raw_duration_sum_ms=1900},
        [ordered]@{id=2;raw_interval_count=1;merged=$false;start_ms=25400;end_ms=27400;duration_ms=2000;raw_duration_sum_ms=2000}
    )
    function New-Effect([double]$StartT,[double]$Code,[string]$Semantic){
        return [ordered]@{effect_code=$Code;start_t=$StartT;end_t=($StartT+0.65);semantic_type=$Semantic;authoritative=$true}
    }
    $small=@((New-Effect 7.2 2001.0 'drift_small_boost'),(New-Effect 27.6 2001.0 'drift_small_boost'))
    $air=@((New-Effect 5.5 2001.0 'air_boost'))
    $landing=@((New-Effect 6.5 2001.0 'landing_boost'))
    $nitro=@((New-Effect 9.0 1.0 'nitro'),(New-Effect 29.4 1.0 'nitro'))
    $timeline=@(
        [ordered]@{record_index=0;time_ms=5500;action_code=8},
        [ordered]@{record_index=1;time_ms=6000;action_code=13},
        [ordered]@{record_index=2;time_ms=6500;action_code=9},
        [ordered]@{record_index=6;time_ms=6800;action_code=19},
        [ordered]@{record_index=3;time_ms=7200;action_code=24},
        [ordered]@{record_index=4;time_ms=7283;action_code=25},
        [ordered]@{record_index=5;time_ms=27600;action_code=24}
    )
    $pa=[ordered]@{
        contract='production_native_action_semantics_v1'
        available=$true
        game_facing_available=$true
        status='production_semantics_ready'
        authority='replay_native_action_event'
        air_boost=[ordered]@{count=1}
        landing_boost=[ordered]@{count=1}
        drift=[ordered]@{raw_intervals=4;logical_count=2;groups=$driftGroups}
        combo=[ordered]@{
            cw=1;wcw=1;cww=0
            cw_evidence=@([ordered]@{code25_record_index=4;code25_time_ms=7283;code24_record_index=3;code24_time_ms=7200;delta_ms=83})
            wcw_evidence=@([ordered]@{record_index=6;time_ms=6800;action_code=19})
            cww_evidence=@([ordered]@{record_index=5;time_ms=27600})
        }
    }
    $stream=[ordered]@{
        id='shadow_local';role='local_high_frequency';csv='logical_01.csv';lap_count=2;laps=$laps.ToArray()
        production_actions=$pa
        native_action_event_timeline=$timeline
        system_drift_segments=@([ordered]@{start_t=5.0;end_t=7.0},[ordered]@{start_t=25.4;end_t=27.4})
        nitro_segments=$nitro
        small_boost_segments=$small
        air_boost_segments=$air
        landing_boost_segments=$landing
        map_propulsion_effect_segments=@()
        native_combo_segments=@()
    }
    $tele=[ordered]@{schema_version=17;architecture='native_first_v1';source_sha256='SYNTHETIC';streams=@($stream)}
    $telePath=Join-Path $teleDir 'telemetry_summary.json';Write-Utf8BomLocal $telePath ($tele|ConvertTo-Json -Depth 14)

    # --- 1. map unresolved: native episodes must still be READY ---------------------------
    $noMap=New-NativeDrivingEpisodes -ProjectRoot $root -TelemetrySummaryPath $telePath
    Require ([string]$noMap.contract -eq 'native_driving_episodes_v1') 'episodes contract mismatch'
    Require ([string]$noMap.native_episode_analysis -eq 'ready') ('native episodes must be ready without a map identity, got '+[string]$noMap.native_episode_analysis)
    Require ([string]$noMap.spatial_driving -eq 'unavailable_prerequisite') 'spatial driving must be unavailable without a map identity'
    Require ([bool]$noMap.map_independent) 'the episodes contract must declare map independence'
    $ns=@($noMap.streams)[0]
    Require ([string]$ns.status -eq 'ready') ('stream episode status not ready: '+[string]$ns.status)
    Require ([int]$ns.episode_count -eq 2) ('episode count must equal the logical drift group count, got '+[string]$ns.episode_count)
    $lapSum=0;foreach($lm0 in @($ns.laps)){$lapSum+=[int]$lm0.logical_drift_count}
    Require ($lapSum -eq [int]$ns.episode_count) ('every episode must be assigned to exactly one lap: lap-sum='+[string]$lapSum+' vs episodes='+[string]$ns.episode_count)
    Require ([int]$ns.logical_drift_group_count -eq 2) 'logical drift group count mismatch'
    Require ([bool]$ns.episode_time_monotonic) 'episode times must be monotonic'
    $eps=New-Object System.Collections.Generic.List[object]
    foreach($lm in @($ns.laps)){foreach($e in @($lm.episodes)){$eps.Add($e)}}
    Require ($eps.Count -eq 2) ('total episode count mismatch: '+[string]$eps.Count)
    Require ([string]$eps[0].id -eq 'L1-D01') ('episode identity mismatch: '+[string]$eps[0].id)
    Require ([string]$eps[1].id -eq 'L2-D01') ('episode identity mismatch: '+[string]$eps[1].id)
    foreach($e in $eps){
        Require ([double]$e.time.duration_s -gt 0) 'episode duration must be positive'
        Require ([int]$e.identity.raw_interval_count -ge 1) 'episode must carry its raw native interval count'
        foreach($v in @($e.speed.entry,$e.speed.min,$e.speed.exit,$e.speed.avg,$e.speed.max)){
            Require ($null -ne $v) 'episode speed values must be present'
            Require (-not[double]::IsNaN([double]$v) -and -not[double]::IsInfinity([double]$v)) 'episode speed values must be finite'
        }
        Require ([double]$e.speed.speed_loss -ge 0) 'speed loss must be non-negative for this synthetic case'
        Require ([int]$e.time.native_start_ms -gt 0) 'episode must carry native start ms'
        Require ([double]$e.position.distance_traveled_m -gt 0) 'episode must carry a distance measurement'
        Require (-not[bool]$e.derived) 'episode facts must not be flagged derived'
    }
    # native action association is by native time, never by geometry
    $e1=$eps[0]
    Require ([int]$e1.native_actions.air_boost_count -eq 1) ('air boost association failed: '+[string]$e1.native_actions.air_boost_count)
    Require ([int]$e1.native_actions.landing_boost_count -eq 1) 'landing boost association failed'
    Require ([int]$e1.native_actions.small_boost_native_effect_count -eq 0) 'the in-drift small-boost window count must stay 0 for this synthetic case'
    Require ([int]$e1.native_actions.exit_window.small_boost_count -eq 1) 'the exit-window small-boost fact must be recorded'
    Require ([int]$e1.native_actions.exit_window.combo_count -eq 1) 'the exit-window combo fact must be recorded'
    Require ([int]$e1.native_actions.nitro_native_interval_count -eq 0) 'nitro must not be associated outside its own window'
    Require ([int]$e1.native_actions.combo.cw -eq 0) 'a combo marker after the drift end must not count as in-drift'
    Require ([int]$e1.native_actions.combo.wcw -eq 1) 'WCW association failed'
    Require ([int]$e1.native_actions.exit_window.combo_count -eq 1) 'the CW marker after the drift end must appear in the exit window'
    Require ([int]$e1.native_actions.unresolved_native_marker_count -eq 1) ('unknown native marker accounting failed: '+[string]$e1.native_actions.unresolved_native_marker_count)
    # exit timing facts (drift end 7.0s, first small boost 7.2s -> 200 ms)
    Require ([int]$e1.exit_timing.drift_end_to_first_small_boost_ms -eq 200) ('boost latency fact wrong: '+[string]$e1.exit_timing.drift_end_to_first_small_boost_ms)
    # --- 2. per-lap metrics ---------------------------------------------------------------
    foreach($lm in @($ns.laps)){
        Require ([int]$lm.logical_drift_count -eq 1) 'lap logical drift count must match its episodes'
        Require ([double]$lm.lap_time_s -gt 0) 'lap time must be positive'
        Require ([int]$lm.drift_duration_s.count -eq 1) 'lap drift-duration statistics missing'
        Require ([double]$lm.total_drift_active_s -gt 0) 'lap drift active time must be positive'
        Require ([int]$lm.drift_end_to_first_small_boost_ms.count -ge 1) 'lap boost-latency statistics missing'
        Require ([bool]$lm.native.combo_game_facing) 'lap must publish the combo game-facing flag'
        Require ([int]$lm.native.small_boost_game_facing_status.Length -gt 0) 'lap must publish the small-boost parity status'
    }
    $lap1=@($ns.laps)[0]
    Require ([int]$lap1.native.cw -eq 1) 'lap CW count must come from the authoritative combo evidence'
    Require ([int]$lap1.native.air_boost -eq 1) 'lap air-boost count must come from episode association'

    # --- 3. map resolved: section v2 metrics on the geometry sections ---------------------
    $svg=Join-Path $mapDir 'official_map.svg'
    $svgText='<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width="1200" height="1200" viewBox="0 0 1200 1200"><polygon points="50,1150 1150,1150 1150,50"/><polygon points="50,1150 1150,50 50,50"/></svg>'
    [IO.File]::WriteAllText($svg,$svgText,(New-Object System.Text.UTF8Encoding -ArgumentList $false))
    $meta=[ordered]@{schema_version=1;contract='native_map_v1';official_source=$true;resource_map_id=999;vector_minimap='official_map.svg';render_transform=[ordered]@{canvas_width=1200;canvas_height=1200;world_min_x=0;world_min_y=0;world_max_x=100;world_max_y=100;scale=11.0;offset_x=50.0;offset_y=50.0;y_inverted=$true}}
    $metaPath=Join-Path $mapDir 'metadata.json';Write-Utf8BomLocal $metaPath ($meta|ConvertTo-Json -Depth 8)

    $sections=New-NativeDrivingAnalysis -ProjectRoot $root -TelemetrySummaryPath $telePath -MapMetadataPath $metaPath
    $withMap=New-NativeDrivingEpisodes -ProjectRoot $root -TelemetrySummaryPath $telePath -MapMetadataPath $metaPath -DrivingSections $sections
    Require ([string]$withMap.native_episode_analysis -eq 'ready') 'native episodes must stay ready with a map identity'
    Require ([string]$withMap.spatial_driving -eq 'ready') ('spatial driving should be ready with a map, got '+[string]$withMap.spatial_driving)
    $ws=@($withMap.streams)[0]
    Require ([string]$ws.spatial.status -eq 'ready') 'spatial section metrics must be ready'
    $metrics=@($ws.spatial.section_metrics)
    Require ($metrics.Count -gt 0) 'section v2 metrics must be produced for the geometry sections'
    $m=@($metrics|Where-Object{[int]$_.metrics.logical_drift_count -gt 0})
    Require ($m.Count -ge 1) 'at least one section must carry a logical drift measurement'
    $m0=$m[0].metrics
    Require ([string]$m0.contract -eq 'native_driving_section_metrics_v2') 'section metrics contract mismatch'
    Require ([double]$m0.section_time_s -gt 0) 'section time missing'
    Require ($null -ne $m0.entry_speed_mps -and $null -ne $m0.min_speed_mps -and $null -ne $m0.exit_speed_mps) 'section speed measurements missing'
    Require ([int]$m0.logical_drift_count -ge 1) 'section logical drift count missing'
    Require ([double]$m0.total_drift_duration_s -gt 0) 'section total drift duration missing'
    Require ($null -ne $m0.native_actions.cw) 'section must aggregate native combo counts'
    Require ([int]$m0.boost_latency_ms.count -ge 1) 'section boost-latency statistics missing'
    Require (@($m0.episode_ids).Count -ge 1) 'section must reference its episodes'
    # geometry must not have redefined any native fact
    Require ([int]$ws.episode_count -eq 2) 'episode count must not change when the map is available'

    Write-Host ('[OK] Native Driving Episodes v2 smoke passed. episodes='+[string]$ws.episode_count+' laps='+[string]$ns.lap_count+' boost-latency='+[string]$e1.exit_timing.drift_end_to_first_small_boost_ms+'ms section-metrics='+[string]$metrics.Count+' map-unresolved=native-episodes-ready/spatial-unavailable map-resolved=spatial-ready authority=native-actions-define-events geometry=measurement-only')
    exit 0
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
