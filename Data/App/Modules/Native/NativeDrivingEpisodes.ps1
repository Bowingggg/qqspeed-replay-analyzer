# Native Driving Episodes v1  (Driving Analysis v2)
#
# DERIVED, NON-AUTHORITATIVE analysis. It answers "why was this corner slow for me" by building one
# episode per **logical native Drift action** and attaching the native action timeline to it.
#
# Authority rule (docs/ARCHITECTURE.md):
#   * Native actions define the driving-event FACTS (drift grouping, boost/combo markers).
#   * Geometry / XY is used ONLY for position, distance, route difference and section measurement.
#   * Geometry must never define Drift, Boost, Combo or an action type.
#
# Map independence: episodes, lap metrics and native-action association only need the production
# telemetry + the replay-native action tables. Spatial sections need an authoritative map identity,
# so `spatial_driving` and `native_episode_analysis` are published as SEPARATE statuses - a replay
# without an official map identity keeps full native training value.
#
# Definition-only module. Helpers are reused from NativeDrivingAnalysis.ps1 (NDA-*), which the
# entry scripts load alongside this module.

function NDE-ReadJson([string]$Path) {
    try { if(Test-Path -LiteralPath $Path -PathType Leaf){return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json} } catch {}
    return $null
}
function NDE-RelPath([string]$Root,[string]$Full) {
    try {
        $r=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
        $f=[IO.Path]::GetFullPath($Full)
        if($f.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)){return $f.Substring($r.Length)}
    } catch {}
    return $Full
}
function NDE-Round([object]$V,[int]$Digits) {
    $d=NDA-ToDouble $V
    if([double]::IsNaN($d)-or[double]::IsInfinity($d)){return $null}
    return [Math]::Round($d,$Digits)
}
function NDE-Stats([object[]]$Values,[int]$Digits) {
    $a=@($Values|Where-Object{$null-ne$_}|ForEach-Object{[double]$_}|Where-Object{-not[double]::IsNaN($_)-and-not[double]::IsInfinity($_)}|Sort-Object)
    if($a.Count-eq0){return [ordered]@{count=0;sum=$null;min=$null;max=$null;median=$null;mean=$null}}
    $sum=0.0;foreach($v in $a){$sum+=$v}
    return [ordered]@{
        count=$a.Count
        sum=[Math]::Round($sum,$Digits)
        min=[Math]::Round([double]$a[0],$Digits)
        max=[Math]::Round([double]$a[$a.Count-1],$Digits)
        median=[Math]::Round((NDA-Percentile ([double[]]$a) 0.5),$Digits)
        mean=[Math]::Round($sum/$a.Count,$Digits)
    }
}
function NDE-NearestIndex([object[]]$Rows,[double]$TimeS) {
    if($Rows.Count-eq0){return -1}
    $lo=0;$hi=$Rows.Count-1
    while(($hi-$lo)-gt1){$m=[int](($lo+$hi)/2);if([double]$Rows[$m].t-le$TimeS){$lo=$m}else{$hi=$m}}
    if([Math]::Abs([double]$Rows[$lo].t-$TimeS)-le[Math]::Abs([double]$Rows[$hi].t-$TimeS)){return $lo}
    return $hi
}
function NDE-SpeedWindow([object[]]$Rows,[int]$Start,[int]$End,[bool]$FromStart) {
    $vals=New-Object System.Collections.Generic.List[double]
    if($Start-lt0-or$End-lt0-or$End-lt$Start){return [double]::NaN}
    if($FromStart){$lo=$Start;$hi=[Math]::Min($End,$Start+7)}else{$lo=[Math]::Max($Start,$End-7);$hi=$End}
    for($i=$lo;$i-le$hi;$i++){
        if(-not[bool]$Rows[$i].pose_valid){continue}
        $v=[double]$Rows[$i].speed
        if(-not[double]::IsNaN($v)-and$v-ge0){$vals.Add($v)}
    }
    if($vals.Count-eq0){return [double]::NaN}
    return [double](($vals.ToArray()|Measure-Object -Average).Average)
}

# --- native action timeline accessors ------------------------------------------------------
function NDE-NativeActionTimeline($Stream,[int]$Code) {
    if($null-eq$Stream){return @()}
    $rows=New-Object System.Collections.Generic.List[object]
    foreach($e in @($Stream.native_action_event_timeline)){
        if($null-eq$e){continue}
        if($Code-lt0-or[long]$e.action_code-eq[long]$Code){
            $rows.Add([pscustomobject]@{record_index=[int]$e.record_index;time_ms=[long]$e.time_ms;action_code=[long]$e.action_code})
        }
    }
    return @($rows.ToArray()|Sort-Object time_ms)
}
function NDE-EffectStartTimes($Stream,[string]$Field,[double]$Code) {
    $out=New-Object System.Collections.Generic.List[double]
    if($null-eq$Stream){return @()}
    foreach($s in @($Stream.$Field)){
        if($null-eq$s){continue}
        if(-not[double]::IsNaN($Code)-and[double]$s.effect_code-ne[double]$Code){continue}
        $t=NDA-ToDouble $s.start_t
        if(-not[double]::IsNaN($t)){$out.Add($t)}
    }
    return @($out.ToArray()|Sort-Object)
}
function NDE-FirstAfter([object[]]$TimesS,[double]$FromS) {
    foreach($t in @($TimesS)){ if([double]$t-ge$FromS){return [double]$t} }
    return [double]::NaN
}
function NDE-FirstDelta([object[]]$TimesS,[double]$FromS,[double]$WindowS) {
    $t=NDE-FirstAfter $TimesS $FromS
    if([double]::IsNaN($t)){return $null}
    $d=($t-$FromS)*1000.0
    if($d-gt($WindowS*1000.0)){return $null}
    return [int][Math]::Round($d,0)
}

# --- production combo evidence (authoritative CW / WCW / CWW placements) --------------------
function NDE-ComboEvidence($Stream) {
    $out=[ordered]@{cw=@();wcw=@();cww=@();available=$false}
    if($null-eq$Stream){return [pscustomobject]$out}
    $pa=$Stream.production_actions
    if($null-eq$pa-or-not[bool]$pa.available){return [pscustomobject]$out}
    if($null-eq$pa.combo){return [pscustomobject]$out}
    # Combo placements are the action-event authority's output: they are published only when that
    # authority is semantically validated. This gate is deliberately about combo only; it must never
    # be reused to decide whether episodes (native Drift) exist.
    if($null-ne$pa.game_facing_available-and-not[bool]$pa.game_facing_available){return [pscustomobject]$out}
    $cw=New-Object System.Collections.Generic.List[double]
    foreach($e in @($pa.combo.cw_evidence)){ if($null-ne$e){$cw.Add([double]$e.code24_time_ms/1000.0)} }
    $wcw=New-Object System.Collections.Generic.List[double]
    foreach($e in @($pa.combo.wcw_evidence)){ if($null-ne$e){$wcw.Add([double]$e.time_ms/1000.0)} }
    $cww=New-Object System.Collections.Generic.List[double]
    foreach($e in @($pa.combo.cww_evidence)){ if($null-ne$e){$cww.Add([double]$e.time_ms/1000.0)} }
    return [pscustomobject][ordered]@{
        available=[bool]$pa.game_facing_available
        cw=@($cw.ToArray()|Sort-Object)
        wcw=@($wcw.ToArray()|Sort-Object)
        cww=@($cww.ToArray()|Sort-Object)
    }
}

# --- episode construction ------------------------------------------------------------------
# One episode per logical native Drift action. All native association is by absolute native time
# (native_ms / 1000 == production telemetry time_s), never by geometry.
function NDE-BuildEpisodes {
    param(
        [object[]]$Rows,
        [object]$Stream,
        [object]$Lap,
        [string]$ReplaySha256,
        [double]$BoostSearchWindowS=2.0
    )
    $ls=[Math]::Max(0,[int]$Lap.start_i);$le=[Math]::Min($Rows.Count-1,[int]$Lap.end_i)
    $lapT0=[double]$Rows[$ls].t;$lapT1=[double]$Rows[$le].t
    $pa=$Stream.production_actions
    $groups=@()
    if($null-ne$pa-and$null-ne$pa.drift){$groups=@($pa.drift.groups)}
    $combo=NDE-ComboEvidence $Stream
    $airTimes=NDE-EffectStartTimes $Stream 'air_boost_segments' 2001.0
    $landTimes=NDE-EffectStartTimes $Stream 'landing_boost_segments' 2001.0
    $smallTimes=NDE-EffectStartTimes $Stream 'small_boost_segments' 2001.0
    $nitroTimes=NDE-EffectStartTimes $Stream 'nitro_segments' 1.0
    $markerEvents=NDE-NativeActionTimeline $Stream -1
    $knownCodes=@(8,9,19,24,25)
    $out=New-Object System.Collections.Generic.List[object]
    $index=0
    foreach($g in $groups){
        if($null-eq$g){continue}
        $s=[double]$g.start_ms/1000.0;$e=[double]$g.end_ms/1000.0
        # Exactly one episode per logical Drift action, assigned to exactly one lap. The lap comes
        # from the replay-native lap_index of the drift-start row when present (authoritative), so a
        # group that spans a lap boundary can never be counted twice or dropped.
        $si=NDE-NearestIndex $Rows $s;$ei=NDE-NearestIndex $Rows $e
        if($si-lt0-or$ei-lt0){continue}
        if([bool]$Rows[$si].has_lap_index){ if([int]$Rows[$si].lap_index-ne[int]$Lap.lap){continue} }
        elseif($s-lt$lapT0-or$s-gt$lapT1){continue}
        $index++
        if($ei-lt$si){$tmp=$si;$si=$ei;$ei=$tmp}
        $speeds=New-Object System.Collections.Generic.List[double]
        for($i=$si;$i-le$ei;$i++){
            if(-not[bool]$Rows[$i].pose_valid){continue}
            $v=[double]$Rows[$i].speed
            if(-not[double]::IsNaN($v)-and$v-ge0){$speeds.Add($v)}
        }
        $entry=NDE-SpeedWindow $Rows $si $ei $true
        $exit=NDE-SpeedWindow $Rows $si $ei $false
        $minV=$null;$maxV=$null;$avgV=$null
        if($speeds.Count-gt0){
            $minV=[double](($speeds.ToArray()|Measure-Object -Minimum).Minimum)
            $maxV=[double](($speeds.ToArray()|Measure-Object -Maximum).Maximum)
            $avgV=[double](($speeds.ToArray()|Measure-Object -Average).Average)
        }
        $loss=$null;$recovery=$null
        if($null-ne$minV-and-not[double]::IsNaN($entry)){$loss=$entry-$minV}
        if($null-ne$minV-and-not[double]::IsNaN($exit)){$recovery=$exit-$minV}
        $dist=[double]$Rows[$ei].distance-[double]$Rows[$si].distance

        # native action association, purely by native time
        $evts=@($markerEvents|Where-Object{[double]$_.time_ms/1000.0-ge$s-and[double]$_.time_ms/1000.0-le$e})
        $codes=@($evts|ForEach-Object{[long]$_.action_code}|Sort-Object -Unique)
        $unknown=@($evts|Where-Object{-not($knownCodes -contains [long]$_.action_code)}).Count
        $airIn=@($airTimes|Where-Object{$_-ge$s-and$_-le$e}).Count
        $landIn=@($landTimes|Where-Object{$_-ge$s-and$_-le$e}).Count
        $smallIn=@($smallTimes|Where-Object{$_-ge$s-and$_-le$e}).Count
        $nitroIn=@($nitroTimes|Where-Object{$_-ge$s-and$_-le$e}).Count
        $cwIn=@($combo.cw|Where-Object{$_-ge$s-and$_-le$e}).Count
        $wcwIn=@($combo.wcw|Where-Object{$_-ge$s-and$_-le$e}).Count
        $cwwIn=@($combo.cww|Where-Object{$_-ge$s-and$_-le$e}).Count
        # Exit-window facts: the boosts that follow this drift's end inside the search window.
        $exitSmall=@($smallTimes|Where-Object{$_-ge$e-and$_-le($e+$BoostSearchWindowS)}).Count
        $exitNitro=@($nitroTimes|Where-Object{$_-ge$e-and$_-le($e+$BoostSearchWindowS)}).Count
        $exitCombo=@((@($combo.cw)+@($combo.wcw)+@($combo.cww))|Where-Object{$_-ge$e-and$_-le($e+$BoostSearchWindowS)}).Count

        $out.Add([pscustomobject][ordered]@{
            id=('L'+[string][int]$Lap.lap+'-D'+$index.ToString('D2'))
            replay_sha256=$ReplaySha256
            stream_id=[string]$Stream.id
            lap=[int]$Lap.lap
            logical_drift_index=$index
            identity=[ordered]@{
                authority='replay_native_action_object_drift_table_v3'
                group_id=[int]$g.id
                raw_interval_count=[int]$g.raw_interval_count
                merged=[bool]$g.merged
                grouping_evidence='raw native Drift intervals coalesce when both are <= 500 ms and the gap is <= 100 ms (ADR 0005)'
            }
            time=[ordered]@{
                start_t=[Math]::Round($s,4);end_t=[Math]::Round($e,4);duration_s=[Math]::Round($e-$s,4)
                native_start_ms=[long]$g.start_ms;native_end_ms=[long]$g.end_ms;native_duration_ms=[long]$g.duration_ms
                native_raw_duration_sum_ms=[long]$g.raw_duration_sum_ms
            }
            position=[ordered]@{
                start=[ordered]@{x=(NDE-Round $Rows[$si].x 4);y=(NDE-Round $Rows[$si].y 4);z=(NDE-Round $Rows[$si].z 4);distance=(NDE-Round $Rows[$si].distance 3)}
                end=[ordered]@{x=(NDE-Round $Rows[$ei].x 4);y=(NDE-Round $Rows[$ei].y 4);z=(NDE-Round $Rows[$ei].z 4);distance=(NDE-Round $Rows[$ei].distance 3)}
                distance_traveled_m=[Math]::Round($dist,3)
                source='production_telemetry rows (official world XY when a map identity is available)'
            }
            speed=[ordered]@{
                entry=$(NDE-Round $entry 3);min=$(NDE-Round $minV 3);max=(NDE-Round $maxV 3);avg=(NDE-Round $avgV 3);exit=$(NDE-Round $exit 3)
                speed_loss=$(NDE-Round $loss 3);speed_recovery=$(NDE-Round $recovery 3)
                unit='m/s'
            }
            native_actions=[ordered]@{
                authority='replay_native_action_event + replay_native_action_object_speed_effect_table_v2'
                raw_drift_interval_count=[int]$g.raw_interval_count
                air_boost_count=$airIn
                landing_boost_count=$landIn
                small_boost_native_effect_count=$smallIn
                nitro_native_interval_count=$nitroIn
                combo=[ordered]@{cw=$cwIn;wcw=$wcwIn;cww=$cwwIn;game_facing=[bool]$combo.available}
                marker_event_count=$evts.Count
                unresolved_native_marker_count=$unknown
                marker_codes=@($codes)
                exit_window=[ordered]@{
                    window_ms=[int]($BoostSearchWindowS*1000)
                    small_boost_count=$exitSmall
                    nitro_count=$exitNitro
                    combo_count=$exitCombo
                }
            }
            exit_timing=[ordered]@{
                drift_end_to_first_small_boost_ms=(NDE-FirstDelta $smallTimes $e $BoostSearchWindowS)
                drift_end_to_nitro_ms=(NDE-FirstDelta $nitroTimes $e $BoostSearchWindowS)
                drift_end_to_air_boost_ms=(NDE-FirstDelta $airTimes $e $BoostSearchWindowS)
                drift_end_to_landing_boost_ms=(NDE-FirstDelta $landTimes $e $BoostSearchWindowS)
                drift_end_to_combo_ms=(NDE-FirstDelta (@(@($combo.cw)+@($combo.wcw)+@($combo.cww) | Sort-Object)) $e $BoostSearchWindowS)
                search_window_ms=[int]($BoostSearchWindowS*1000)
                note='Facts only. These latencies are measurements, not a good/bad judgement.'
            }
            derived=$false
        })
    }
    return @($out.ToArray())
}

# --- per-lap metrics ------------------------------------------------------------------------
function NDE-BuildLapMetrics {
    param([object[]]$Rows,[object]$Stream,[object]$Lap,[object[]]$Episodes,[int]$EpisodeBase)
    $ls=[Math]::Max(0,[int]$Lap.start_i);$le=[Math]::Min($Rows.Count-1,[int]$Lap.end_i)
    $lapT0=[double]$Rows[$ls].t;$lapT1=[double]$Rows[$le].t
    $lapTime=[double]$Lap.duration_s
    if($lapTime-le0){$lapTime=$lapT1-$lapT0}
    $dist=[double]$Lap.distance
    $avg=$null
    if($lapTime-gt1e-6){$avg=$dist/$lapTime}
    $mine=@($Episodes|Where-Object{ [int]$_.lap -eq [int]$Lap.lap })
    $active=0.0
    foreach($ep in $mine){$active+=[double]$ep.time.duration_s}
    $nitroRaw=@(NDE-EffectStartTimes $Stream 'nitro_segments' 1.0 | Where-Object{$_-ge$lapT0-and$_-le$lapT1}).Count
    $smallRaw=@(NDE-EffectStartTimes $Stream 'small_boost_segments' 2001.0 | Where-Object{$_-ge$lapT0-and$_-le$lapT1}).Count
    $airRaw=@(NDE-EffectStartTimes $Stream 'air_boost_segments' 2001.0 | Where-Object{$_-ge$lapT0-and$_-le$lapT1}).Count
    $landRaw=@(NDE-EffectStartTimes $Stream 'landing_boost_segments' 2001.0 | Where-Object{$_-ge$lapT0-and$_-le$lapT1}).Count
    $combo=NDE-ComboEvidence $Stream
    $latencies=New-Object System.Collections.Generic.List[double]
    foreach($ep in $mine){ if($null-ne$ep.exit_timing.drift_end_to_first_small_boost_ms){$latencies.Add([double]$ep.exit_timing.drift_end_to_first_small_boost_ms)} }
    # Whole-lap speed statistics. `min` deliberately keeps stops / respawns visible; `moving_min`
    # excludes sub-0.5 m/s samples so a stationary measurement cannot masquerade as a driving fact.
    # Both are published; neither replaces the other.
    $lapSpeeds=New-Object System.Collections.Generic.List[double]
    $lapSpeedsMoving=New-Object System.Collections.Generic.List[double]
    for($li=$ls;$li-le$le;$li++){
        if(-not[bool]$Rows[$li].pose_valid){continue}
        $lv=[double]$Rows[$li].speed
        if([double]::IsNaN($lv)-or$lv-lt0){continue}
        $lapSpeeds.Add($lv)
        if($lv-ge0.5){$lapSpeedsMoving.Add($lv)}
    }
    $lapMax=$null;$lapMedian=$null;$lapMin=$null;$lapMovingMin=$null
    if($lapSpeeds.Count-gt0){
        $lapArr=[double[]]$lapSpeeds.ToArray()
        $lapMax=[double](($lapArr|Measure-Object -Maximum).Maximum)
        $lapMin=[double](($lapArr|Measure-Object -Minimum).Minimum)
        $lapMedian=NDA-Percentile $lapArr 0.5
    }
    if($lapSpeedsMoving.Count-gt0){$lapMovingMin=[double]((([double[]]$lapSpeedsMoving.ToArray())|Measure-Object -Minimum).Minimum)}
    $driftDurations=[double[]]@($mine|ForEach-Object{[double]$_.time.duration_s})
    $rawDriftIntervals=0
    foreach($ep in $mine){ $rawDriftIntervals+=[int]$ep.native_actions.raw_drift_interval_count }
    $gameFacing=[bool]$combo.available
    # Lap-analysis contract (Training Analysis v1): identity, time, distance, speed, native
    # aggregates and the episode aggregate statistics, each with its own authority. Every field is a
    # measurement this function already produced; nothing new is inferred here.
    return [pscustomobject][ordered]@{
        lap=[int]$Lap.lap
        lap_time_s=[Math]::Round($lapTime,4)
        lap_start_s=[Math]::Round($lapT0,4)
        lap_end_s=[Math]::Round($lapT1,4)
        distance_m=[Math]::Round($dist,3)
        average_speed_mps=$(if($null-eq$avg){$null}else{[Math]::Round($avg,3)})
        max_speed_mps=$(if($null-eq$lapMax){$null}else{[Math]::Round([double]$lapMax,3)})
        median_speed_mps=$(if($null-eq$lapMedian){$null}else{[Math]::Round([double]$lapMedian,3)})
        min_speed_mps=$(if($null-eq$lapMin){$null}else{[Math]::Round([double]$lapMin,3)})
        moving_min_speed_mps=$(if($null-eq$lapMovingMin){$null}else{[Math]::Round([double]$lapMovingMin,3)})
        drift_available=$true
        raw_drift_interval_count=$rawDriftIntervals
        action_event_available=$gameFacing
        logical_drift_count=$mine.Count
        total_drift_active_s=[Math]::Round($active,4)
        median_drift_duration_s=$(if($driftDurations.Count-gt0){[Math]::Round((NDA-Percentile $driftDurations 0.5),4)}else{$null})
        drift_duration_s=(NDE-Stats @($mine|ForEach-Object{[double]$_.time.duration_s}) 4)
        entry_speed=(NDE-Stats @($mine|ForEach-Object{$_.speed.entry}) 3)
        min_speed=(NDE-Stats @($mine|ForEach-Object{$_.speed.min}) 3)
        exit_speed=(NDE-Stats @($mine|ForEach-Object{$_.speed.exit}) 3)
        speed_loss=(NDE-Stats @($mine|ForEach-Object{$_.speed.speed_loss}) 3)
        drift_end_to_first_small_boost_ms=(NDE-Stats @($latencies.ToArray()) 0)
        native=[ordered]@{
            authority='replay_native_action_event + replay_native_action_object_speed_effect_table_v2'
            cw=$(if($gameFacing){@($combo.cw|Where-Object{$_-ge$lapT0-and$_-le$lapT1}).Count}else{$null})
            wcw=$(if($gameFacing){@($combo.wcw|Where-Object{$_-ge$lapT0-and$_-le$lapT1}).Count}else{$null})
            cww=$(if($gameFacing){@($combo.cww|Where-Object{$_-ge$lapT0-and$_-le$lapT1}).Count}else{$null})
            combo_game_facing=$gameFacing
            air_boost=$(if($gameFacing){[int](@($mine|ForEach-Object{[int]$_.native_actions.air_boost_count})|Measure-Object -Sum).Sum}else{$null})
            landing_boost=$(if($gameFacing){[int](@($mine|ForEach-Object{[int]$_.native_actions.landing_boost_count})|Measure-Object -Sum).Sum}else{$null})
            air_boost_timeline_count=$airRaw
            landing_boost_timeline_count=$landRaw
            nitro_native_interval_count=$nitroRaw
            nitro_game_facing_status='unresolved'
            small_boost_native_effect_count=$smallRaw
            small_boost_game_facing_status='unresolved'
        }
        episode_index_base=$EpisodeBase
        episode_count=$mine.Count
    }
}

# --- spatial section v2 aggregation ---------------------------------------------------------
# The existing geometry sections stay the spatial containers; this only attaches native-action
# measurements computed from the authoritative timelines, and never changes section boundaries.
function NDE-BuildSectionNativeMetrics {
    param([object]$Section,[object]$Stream,[object[]]$Episodes)
    $startT=[double]$Section.start_t;$endT=[double]$Section.end_t
    $mine=@($Episodes|Where-Object{[double]$_.time.start_t-lt$endT-and[double]$_.time.end_t-gt$startT})
    $dur=0.0
    foreach($ep in $mine){
        $a=[Math]::Max($startT,[double]$ep.time.start_t);$b=[Math]::Min($endT,[double]$ep.time.end_t)
        if($b-gt$a){$dur+=($b-$a)}
    }
    $combo=NDE-ComboEvidence $Stream
    $lat=New-Object System.Collections.Generic.List[double]
    foreach($ep in $mine){ if($null-ne$ep.exit_timing.drift_end_to_first_small_boost_ms){$lat.Add([double]$ep.exit_timing.drift_end_to_first_small_boost_ms)} }
    $cw=0;$wcw=0;$cww=0;$air=0;$land=0
    foreach($ep in $mine){
        $cw+=[int]$ep.native_actions.combo.cw;$wcw+=[int]$ep.native_actions.combo.wcw;$cww+=[int]$ep.native_actions.combo.cww
        $air+=[int]$ep.native_actions.air_boost_count;$land+=[int]$ep.native_actions.landing_boost_count
    }
    return [pscustomobject][ordered]@{
        contract='native_driving_section_metrics_v2'
        authority='replay_native_action_event + replay_native_action_object_drift_table_v3'
        geometry_role='section boundaries and speeds are spatial measurements; native actions are read-only annotations'
        section_time_s=[Math]::Round(($endT-$startT),4)
        section_distance_m=[double]$Section.path_length
        entry_speed_mps=$Section.speed.entry
        min_speed_mps=$Section.speed.min
        exit_speed_mps=$Section.speed.exit
        logical_drift_count=$mine.Count
        total_drift_duration_s=[Math]::Round($dur,4)
        native_actions=[ordered]@{cw=$cw;wcw=$wcw;cww=$cww;total=$cw+$wcw+$cww;air_boost=$air;landing_boost=$land}
        boost_latency_ms=(NDE-Stats @($lat.ToArray()) 0)
        episode_ids=@($mine|ForEach-Object{[string]$_.id})
    }
}

# --- stream assembly ------------------------------------------------------------------------
function NDE-BuildStream {
    param([object]$Stream,[object[]]$Rows,[string]$CsvRel,[string]$ReplaySha256,[double]$BoostSearchWindowS=2.0)
    $laps=@($Stream.laps)
    if($Rows.Count-lt20){
        return [ordered]@{id=[string]$Stream.id;role=[string]$Stream.role;status='unavailable_insufficient_rows';source_csv=$CsvRel;lap_count=0;episode_count=0;laps=@();spatial=[ordered]@{status='unavailable_prerequisite';reason='insufficient telemetry rows'}}
    }
    $pa=$Stream.production_actions
    if($null-eq$pa-or$null-eq$pa.drift-or@($pa.drift.groups).Count-eq0){
        return [ordered]@{id=[string]$Stream.id;role=[string]$Stream.role;status='unavailable_no_native_drift_authority';source_csv=$CsvRel;lap_count=0;episode_count=0;laps=@();spatial=[ordered]@{status='unavailable_prerequisite';reason='no authoritative native Drift timeline'}}
    }
    $allEpisodes=New-Object System.Collections.Generic.List[object]
    $lapMetrics=New-Object System.Collections.Generic.List[object]
    foreach($lap in $laps){
        $base=$allEpisodes.Count
        $eps=@(NDE-BuildEpisodes -Rows $Rows -Stream $Stream -Lap $lap -ReplaySha256 $ReplaySha256 -BoostSearchWindowS $BoostSearchWindowS)
        foreach($ep in $eps){$allEpisodes.Add($ep)}
        $lapMetrics.Add((NDE-BuildLapMetrics -Rows $Rows -Stream $Stream -Lap $lap -Episodes $eps -EpisodeBase $base))
    }
    $episodesOut=@($allEpisodes.ToArray())
    $lapsOut=New-Object System.Collections.Generic.List[object]
    for($i=0;$i-lt$lapMetrics.Count;$i++){
        $lm=[pscustomobject]$lapMetrics[$i]
        $lid=[int]$lm.lap
        $mine=@($episodesOut|Where-Object{[int]$_.lap -eq $lid})
        $lapsOut.Add([pscustomobject][ordered]@{
            lap=$lm.lap
            lap_time_s=$lm.lap_time_s
            lap_start_s=$lm.lap_start_s
            lap_end_s=$lm.lap_end_s
            distance_m=$lm.distance_m
            average_speed_mps=$lm.average_speed_mps
            max_speed_mps=$lm.max_speed_mps
            median_speed_mps=$lm.median_speed_mps
            min_speed_mps=$lm.min_speed_mps
            moving_min_speed_mps=$lm.moving_min_speed_mps
            drift_available=$lm.drift_available
            raw_drift_interval_count=$lm.raw_drift_interval_count
            action_event_available=$lm.action_event_available
            median_drift_duration_s=$lm.median_drift_duration_s
            logical_drift_count=$lm.logical_drift_count
            total_drift_active_s=$lm.total_drift_active_s
            drift_duration_s=$lm.drift_duration_s
            entry_speed=$lm.entry_speed
            min_speed=$lm.min_speed
            exit_speed=$lm.exit_speed
            speed_loss=$lm.speed_loss
            drift_end_to_first_small_boost_ms=$lm.drift_end_to_first_small_boost_ms
            native=$lm.native
            episodes=@($mine)
        })
    }
    $groupCount=@($pa.drift.groups).Count
    $monotonic=$true
    $prevEnd=-1.0
    foreach($ep in $episodesOut){
        if([double]$ep.time.end_t-lt$prevEnd){$monotonic=$false}
        $prevEnd=[double]$ep.time.end_t
    }
    return [ordered]@{
        id=[string]$Stream.id
        role=[string]$Stream.role
        status=$(if($episodesOut.Count-gt0){'ready'}else{'ready_no_logical_drift'})
        source_csv=$CsvRel
        lap_count=$laps.Count
        episode_count=$episodesOut.Count
        logical_drift_group_count=$groupCount
        episode_time_monotonic=$monotonic
        exit_timing_window_ms=[int]($BoostSearchWindowS*1000)
        laps=@($lapsOut.ToArray())
        spatial=[ordered]@{
            status='unavailable_prerequisite'
            reason='spatial sections require an authoritative map identity'
            section_metrics=@()
        }
    }
}

function New-NativeDrivingEpisodes {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$TelemetrySummaryPath,
        [string]$MapMetadataPath='',
        [object]$DrivingSections=$null,
        $RowsCache=$null,
        [double]$BoostSearchWindowS=2.0
    )
    $telemetry=NDE-ReadJson $TelemetrySummaryPath
    if($null-eq$telemetry){
        return [ordered]@{
            schema_version=1;contract='native_driving_episodes_v1';architecture='native_first_v1'
            status='unavailable_telemetry';native_episode_analysis='unavailable'
            spatial_driving='unavailable_prerequisite';spatial_driving_reason='telemetry summary unavailable'
            streams=@()
        }
    }
    $mapReady=$false
    if(-not[string]::IsNullOrWhiteSpace($MapMetadataPath)){
        $map=NDE-ReadJson $MapMetadataPath
        $mapReady=($null-ne$map-and[string]$map.contract-eq'native_map_v1'-and[bool]$map.official_source)
    }
    $teleDir=Split-Path -Parent $TelemetrySummaryPath
    $out=New-Object System.Collections.Generic.List[object]
    foreach($s in @($telemetry.streams)){
        if($null-eq$s-or[string]::IsNullOrWhiteSpace([string]$s.csv)){continue}
        $csv=Join-Path $teleDir ([string]$s.csv)
        if(-not(Test-Path -LiteralPath $csv -PathType Leaf)){
            $out.Add([ordered]@{id=[string]$s.id;role=[string]$s.role;status='unavailable_csv_missing';source_csv=[string]$s.csv;lap_count=0;episode_count=0;laps=@();spatial=[ordered]@{status='unavailable_prerequisite';reason='telemetry csv missing';section_metrics=@()}})
            continue
        }
        try {
            $rows=@(NDA-LoadRowsCached $RowsCache $csv)
            $built=NDE-BuildStream -Stream $s -Rows $rows -CsvRel (NDE-RelPath $ProjectRoot $csv) -ReplaySha256 ([string]$telemetry.source_sha256) -BoostSearchWindowS $BoostSearchWindowS
            # spatial section v2: annotate the geometry sections with native-action measurements.
            if($mapReady-and$null-ne$DrivingSections){
                $ds=@($DrivingSections.streams|Where-Object{[string]$_.id-eq[string]$s.id})
                # Geometry sections are nested per lap; collect every lap's sections so a section
                # metric is produced for each of them (the representative lap is only a preview).
                $sections=New-Object System.Collections.Generic.List[object]
                if($ds.Count-gt0){
                    foreach($dl in @($ds[0].laps)){foreach($sec in @($dl.sections)){$sections.Add($sec)}}
                    if($sections.Count-eq0){foreach($sec in @($ds[0].representative_sections)){$sections.Add($sec)}}
                }
                if($sections.Count-gt0){
                    $allEps=New-Object System.Collections.Generic.List[object]
                    foreach($lm in @($built.laps)){foreach($ep in @($lm.episodes)){$allEps.Add($ep)}}
                    $metrics=New-Object System.Collections.Generic.List[object]
                    foreach($sec in @($sections.ToArray())){
                        $m=NDE-BuildSectionNativeMetrics -Section $sec -Stream $s -Episodes @($allEps.ToArray())
                        $metrics.Add([pscustomobject][ordered]@{section_id=[string]$sec.id;lap=[int]$sec.lap;metrics=$m})
                    }
                    $built.spatial=[ordered]@{status='ready';reason='authoritative map identity available';section_metrics=@($metrics.ToArray())}
                } else {
                    $built.spatial=[ordered]@{status='unavailable_prerequisite';reason='map identity available but no derived sections were built';section_metrics=@()}
                }
            }
            $out.Add($built)
        } catch {
            $out.Add([ordered]@{id=[string]$s.id;role=[string]$s.role;status='failed_derived_analysis';source_csv=(NDE-RelPath $ProjectRoot $csv);error=$_.Exception.Message;lap_count=0;episode_count=0;laps=@();spatial=[ordered]@{status='unavailable_prerequisite';reason=$_.Exception.Message;section_metrics=@()}})
        }
    }
    $streams=@($out.ToArray())
    $ready=@($streams|Where-Object{[string]$_.status -like 'ready*'}).Count
    $episodes=0;foreach($s in $streams){$episodes+=[int]$s.episode_count}
    $spatialReady=@($streams|Where-Object{[string]$_.spatial.status-eq'ready'}).Count
    $overall=if($ready-gt0){'ready'}else{'unavailable'}
    return [ordered]@{
        schema_version=1
        contract='native_driving_episodes_v1'
        architecture='native_first_v1'
        authority='replay_native_action_object_drift_table_v3 + replay_native_action_event'
        geometry_role='position, distance and section measurement only; geometry never defines Drift, Boost, Combo or an action type'
        status=$overall
        native_episode_analysis=$(if($ready-gt0){'ready'}else{'unavailable'})
        native_episode_analysis_requires='production telemetry with an authoritative native Drift timeline; no map identity required'
        spatial_driving=$(if($spatialReady-gt0){'ready'}else{'unavailable_prerequisite'})
        spatial_driving_reason=$(if($spatialReady-gt0){'authoritative map identity available'}else{'spatial sections require an authoritative map identity; native episodes and lap metrics are unaffected'})
        map_independent=$true
        boost_search_window_ms=[int]($BoostSearchWindowS*1000)
        episode_count=$episodes
        streams=$streams
    }
}
