# Replay-native speed-effect timeline decoder and contextual subtype classifier.
# Definition-only module: no runtime actions at import scope.

function RNSE-ReadU32([byte[]]$Data,[int]$Offset){ return [BitConverter]::ToUInt32($Data,$Offset) }
function RNSE-ReadI32([byte[]]$Data,[int]$Offset){ return [BitConverter]::ToInt32($Data,$Offset) }
function RNSE-ReadF32([byte[]]$Data,[int]$Offset){ return [BitConverter]::ToSingle($Data,$Offset) }
function RNSE-AsBool($Value){
    if($null-eq$Value){return $false}
    if($Value-is[bool]){return [bool]$Value}
    $s=[string]$Value
    return ($s-eq'True'-or$s-eq'true'-or$s-eq'1')
}
function RNSE-CodeNear([double]$Code,[double]$Target,[double]$Tolerance=0.001){ return ([Math]::Abs($Code-$Target)-le$Tolerance) }

function Get-ReplayNativeSpeedEffectTableAtOffset {
    param(
        [string]$ReplayPath='',
        [Parameter(Mandatory=$true)][long]$CountOffset,
        [int]$MaxRecords=5000,
        # Preloaded replay bytes. Supplying them avoids a second full ReadAllBytes per logical
        # shadow when the caller already holds the file (native action scan / cache rebuild).
        # Table grammar is byte-identical either way: this parameter only changes the source buffer.
        [byte[]]$Data=$null
    )
    if($null-eq$Data){
        if([string]::IsNullOrWhiteSpace($ReplayPath)){throw 'Native speed-effect table reader requires -ReplayPath or -Data.'}
        if(-not(Test-Path -LiteralPath $ReplayPath -PathType Leaf)){throw ('Replay not found: '+$ReplayPath)}
        [byte[]]$data=[IO.File]::ReadAllBytes($ReplayPath)
    } else {[byte[]]$data=$Data}
    if($CountOffset-lt0-or($CountOffset+4)-gt$data.Length){return [pscustomobject][ordered]@{valid=$false;status='count_offset_out_of_range';count_offset=$CountOffset}}
    [uint32]$countU32=RNSE-ReadU32 $data ([int]$CountOffset)
    if($countU32-gt[uint32]$MaxRecords){return [pscustomobject][ordered]@{valid=$false;status='record_count_out_of_range';count_offset=$CountOffset;record_count_u32=[uint64]$countU32}}
    $count=[int]$countU32
    [long]$end=$CountOffset+4L+9L*$count
    if($end-gt$data.Length){return [pscustomobject][ordered]@{valid=$false;status='table_exceeds_file';count_offset=$CountOffset;record_count=$count;end_exclusive=$end}}
    $records=New-Object System.Collections.Generic.List[object]
    $intervals=New-Object System.Collections.Generic.List[object]
    $open=@{}
    $prev=-1L
    $codes=@{}
    for($i=0;$i-lt$count;$i++){
        $p=[int]($CountOffset+4L+9L*$i)
        $t=[long](RNSE-ReadU32 $data $p)
        $state=[int]$data[$p+4]
        $codeBits=[int](RNSE-ReadI32 $data ($p+5))
        $code=[double](RNSE-ReadF32 $data ($p+5))
        if($state-ne0-and$state-ne1){return [pscustomobject][ordered]@{valid=$false;status='invalid_state_value';count_offset=$CountOffset;record_index=$i;state=$state}}
        if($t-lt$prev-or$t-gt600000){return [pscustomobject][ordered]@{valid=$false;status='invalid_or_nonmonotonic_time';count_offset=$CountOffset;record_index=$i;time_ms=$t;previous_time_ms=$prev}}
        if([double]::IsNaN($code)-or[double]::IsInfinity($code)-or[Math]::Abs($code)-gt10000000){return [pscustomobject][ordered]@{valid=$false;status='invalid_effect_code';count_offset=$CountOffset;record_index=$i;effect_code=$code}}
        $key=[string]$codeBits
        if(-not$codes.ContainsKey($key)){$codes[$key]=$code}
        if(-not$open.ContainsKey($key)){$open[$key]=New-Object System.Collections.Queue}
        $q=$open[$key]
        if($state-eq1){
            $q.Enqueue($t)
        }else{
            if($q.Count-eq0){return [pscustomobject][ordered]@{valid=$false;status='effect_end_without_start';count_offset=$CountOffset;record_index=$i;time_ms=$t;effect_code=$code}}
            $st=[long]$q.Dequeue()
            if($t-lt$st){return [pscustomobject][ordered]@{valid=$false;status='negative_effect_duration';count_offset=$CountOffset;record_index=$i;effect_code=$code}}
            $intervals.Add([pscustomobject][ordered]@{effect_code=$code;effect_code_bits=$codeBits;start_ms=$st;end_ms=$t;duration_ms=($t-$st)})
        }
        $records.Add([pscustomobject][ordered]@{time_ms=$t;state=$state;effect_code=$code;effect_code_bits=$codeBits})
        $prev=$t
    }
    foreach($k in @($open.Keys)){if($open[$k].Count-ne0){return [pscustomobject][ordered]@{valid=$false;status='unclosed_effect_start';count_offset=$CountOffset;effect_code=[double]$codes[$k];open_count=[int]$open[$k].Count}}}
    $codeSummary=New-Object System.Collections.Generic.List[object]
    foreach($k in @($codes.Keys|Sort-Object {[double]$codes[$_]})){
        $c=[double]$codes[$k]
        $ci=@($intervals.ToArray()|Where-Object{[int]$_.effect_code_bits-eq[int]$k})
        $dur=@($ci|ForEach-Object{[double]$_.duration_ms})
        $med=$null
        if($dur.Count-gt0){$s=@($dur|Sort-Object);$n=$s.Count;$med=$(if(($n%2)-eq1){[double]$s[[int][Math]::Floor($n/2)]}else{([double]$s[$n/2-1]+[double]$s[$n/2])/2.0})}
        $codeSummary.Add([pscustomobject][ordered]@{effect_code=$c;effect_code_bits=[int]$k;interval_count=$ci.Count;duration_median_ms=$med})
    }
    return [pscustomobject][ordered]@{
        valid=$true;status=$(if($count-eq0){'adjacent_speed_effect_table_empty_validated'}else{'adjacent_speed_effect_table_validated'})
        source='replay_native_action_object_speed_effect_table_v2';count_offset=$CountOffset;end_exclusive=$end;record_count=$count;interval_count=$intervals.Count
        records=$records.ToArray();intervals=$intervals.ToArray();effect_codes=$codeSummary.ToArray()
    }
}

function RNSE-GetCtrlRiseTimes {
    param([Parameter(Mandatory=$true)][object[]]$Rows)
    $out=New-Object System.Collections.Generic.List[double]
    $prev=$false
    foreach($r in @($Rows)){
        $cur=RNSE-AsBool $r.input_bool_candidate_65
        if($cur-and-not$prev){$out.Add([double]$r.time_s)}
        $prev=$cur
    }
    return @($out.ToArray())
}
function RNSE-NearestAbsDeltaMs([double]$TimeS,[double[]]$TimesS){
    if($TimesS.Count-eq0){return $null}
    $best=[double]::PositiveInfinity
    foreach($t in $TimesS){$d=[Math]::Abs(($t-$TimeS)*1000.0);if($d-lt$best){$best=$d}}
    if([double]::IsInfinity($best)){return $null}
    return $best
}

function Resolve-ReplayNativeSpeedEffectTimeline {
    param(
        [string]$ReplayPath='',
        [Parameter(Mandatory=$true)][object]$NativeDriftResolved,
        [Parameter(Mandatory=$true)][object[]]$Rows,
        [double]$CtrlToleranceMs=40.0,
        # NativeActionCache replay path: the raw adjacent table payload recorded at scan time.
        # When supplied, the resolver performs no replay file access at all. The payload has
        # exactly the shape produced by Get-ReplayNativeSpeedEffectTableAtOffset, so the
        # semantic layer cannot distinguish a cache replay from a fresh raw read.
        [object]$EffectTablePayload=$null
    )
    if($null-eq$NativeDriftResolved-or-not[bool]$NativeDriftResolved.available){
        return [pscustomobject][ordered]@{available=$false;status='native_action_object_anchor_unavailable';source='replay_native_action_object_speed_effect_table_v2';nitro_semantic_valid=$false}
    }
    $countOffset=[long]$NativeDriftResolved.candidate.end_exclusive
    if($null-ne$EffectTablePayload){
        $table=$EffectTablePayload
    } else {
        if([string]::IsNullOrWhiteSpace($ReplayPath)){
            return [pscustomobject][ordered]@{available=$false;status='native_action_effect_table_source_missing';source='replay_native_action_object_speed_effect_table_v2';count_offset=$countOffset;nitro_semantic_valid=$false}
        }
        $table=Get-ReplayNativeSpeedEffectTableAtOffset -ReplayPath $ReplayPath -CountOffset $countOffset
    }
    if(-not[bool]$table.valid){return [pscustomobject][ordered]@{available=$false;status=('adjacent_table_invalid_'+[string]$table.status);source='replay_native_action_object_speed_effect_table_v2';count_offset=$countOffset;table=$table;nitro_semantic_valid=$false}}
    $ctrl=@(RNSE-GetCtrlRiseTimes -Rows $Rows)
    $code1=@($table.intervals|Where-Object{RNSE-CodeNear ([double]$_.effect_code) 1.0})
    $match=0;$deltas=New-Object System.Collections.Generic.List[double]
    foreach($iv in $code1){
        $d=RNSE-NearestAbsDeltaMs ([double]$iv.start_ms/1000.0) ([double[]]$ctrl)
        if($null-ne$d){$deltas.Add([double]$d);if([double]$d-le$CtrlToleranceMs){$match++}}
    }
    $frac=$(if($code1.Count-gt0){$match/[double]$code1.Count}else{1.0})
    $nitroValid=($code1.Count-eq0-or$frac-ge0.80)
    return [pscustomobject][ordered]@{
        available=$true;status=[string]$table.status;source='replay_native_action_object_speed_effect_table_v2';table=$table
        native_drift_count_offset=[long]$NativeDriftResolved.candidate.count_offset;count_offset=$countOffset
        ctrl_rise_count=$ctrl.Count;nitro_code_interval_count=$code1.Count;nitro_ctrl_match_count=$match;nitro_ctrl_match_fraction=[Math]::Round($frac,6);nitro_ctrl_tolerance_ms=$CtrlToleranceMs;nitro_semantic_valid=$nitroValid
        semantic_contract='code1=standard_nitro; code2001=small_boost_class_context_subtyped; code2003=map_propulsion_effect (dedicated map-scene propulsion recordings + position/speed validation); all_other_codes=unknown'
    }
}

function RNSE-BuildContactContext {
    param([Parameter(Mandatory=$true)][object[]]$Rows)
    $air=New-Object System.Collections.Generic.List[object]
    $landings=New-Object System.Collections.Generic.List[object]
    $inAir=$false;$startS=0.0
    for($i=0;$i-lt$Rows.Count;$i++){
        $hasContact=($null-ne$Rows[$i].contact_state)
        $curAir=($hasContact-and[int]$Rows[$i].contact_state-eq0)
        if($curAir-and-not$inAir){$inAir=$true;$startS=[double]$Rows[$i].time_s}
        if(-not$curAir-and$inAir){
            $landS=[double]$Rows[$i].time_s;$durMs=($landS-$startS)*1000.0
            $air.Add([pscustomobject][ordered]@{start_s=$startS;end_s=$landS;landing_s=$landS;duration_ms=$durMs;validated_air=($durMs-ge100.0)})
            $landings.Add([pscustomobject][ordered]@{time_s=$landS;preceding_air_duration_ms=$durMs})
            $inAir=$false
        }
    }
    if($inAir-and$Rows.Count-gt0){
        $endS=[double]$Rows[$Rows.Count-1].time_s;$durMs=($endS-$startS)*1000.0
        $air.Add([pscustomobject][ordered]@{start_s=$startS;end_s=$endS;landing_s=$null;duration_ms=$durMs;validated_air=($durMs-ge100.0)})
    }
    return [pscustomobject][ordered]@{air_intervals=$air.ToArray();landing_edges=$landings.ToArray()}
}

function RNSE-ClassifySmallBoostStart {
    param(
        [Parameter(Mandatory=$true)][double]$StartS,
        [Parameter(Mandatory=$true)][object]$ContactContext,
        [object]$NativeDriftResolved
    )
    foreach($a in @($ContactContext.air_intervals)){
        if([bool]$a.validated_air-and$StartS-ge[double]$a.start_s-and$StartS-lt[double]$a.end_s){
            return [pscustomobject][ordered]@{subtype='air_boost';context='inside_validated_air_interval';air_duration_ms=[Math]::Round([double]$a.duration_ms,3);landing_delta_ms=$null;drift_id=$null;drift_relation=$null;drift_boundary_delta_ms=$null}
        }
    }
    $bestLanding=$null;$bestLandingDelta=[double]::PositiveInfinity
    foreach($l in @($ContactContext.landing_edges)){
        $d=($StartS-[double]$l.time_s)*1000.0
        if($d-ge0-and$d-le200.0-and$d-lt$bestLandingDelta){$bestLanding=$l;$bestLandingDelta=$d}
    }
    if($null-ne$bestLanding){
        return [pscustomobject][ordered]@{subtype='landing_boost';context='within_200ms_after_raw_landing_edge';air_duration_ms=[Math]::Round([double]$bestLanding.preceding_air_duration_ms,3);landing_delta_ms=[Math]::Round($bestLandingDelta,3);drift_id=$null;drift_relation=$null;drift_boundary_delta_ms=$null}
    }
    if($null-ne$NativeDriftResolved-and[bool]$NativeDriftResolved.available){
        $id=1;$best=$null;$bestAbs=[double]::PositiveInfinity
        foreach($iv in @($NativeDriftResolved.candidate.intervals)){
            $s=[double]$iv.start_ms/1000.0;$e=[double]$iv.end_ms/1000.0
            if($StartS-ge$s-and$StartS-le$e){
                return [pscustomobject][ordered]@{subtype='drift_small_boost';context='inside_replay_native_drift_interval';air_duration_ms=$null;landing_delta_ms=$null;drift_id=$id;drift_relation='during';drift_boundary_delta_ms=[Math]::Round(($StartS-$e)*1000.0,3)}
            }
            $d=($StartS-$e)*1000.0
            if($d-ge0-and$d-le350.0-and$d-lt$bestAbs){$best=[pscustomobject]@{id=$id;d=$d};$bestAbs=$d}
            $id++
        }
        if($null-ne$best){
            return [pscustomobject][ordered]@{subtype='drift_small_boost';context='within_350ms_after_replay_native_drift_end';air_duration_ms=$null;landing_delta_ms=$null;drift_id=[int]$best.id;drift_relation='post_drift';drift_boundary_delta_ms=[Math]::Round([double]$best.d,3)}
        }
    }
    return [pscustomobject][ordered]@{subtype='other_small_boost';context='native_code2001_unclassified_context';air_duration_ms=$null;landing_delta_ms=$null;drift_id=$null;drift_relation=$null;drift_boundary_delta_ms=$null}
}

function RNSE-EnsureRowFlags {
    param([Parameter(Mandatory=$true)][object[]]$Rows)
    if($null-eq$Rows -or $Rows.Count-eq0){return}
    # qpf_v1 typed rows already carry these fields. Avoid 7 Add-Member calls per telemetry row.
    $names=@($Rows[0].PSObject.Properties.Name)
    if($names -contains 'nitro_active' -and $names -contains 'small_boost_class_active' -and $names -contains 'speed_effect_state_source'){return}
    foreach($r in @($Rows)){
        $r|Add-Member -NotePropertyName nitro_active -NotePropertyValue $false -Force
        $r|Add-Member -NotePropertyName small_boost_active -NotePropertyValue $false -Force
        $r|Add-Member -NotePropertyName air_boost_active -NotePropertyValue $false -Force
        $r|Add-Member -NotePropertyName landing_boost_active -NotePropertyValue $false -Force
        $r|Add-Member -NotePropertyName map_propulsion_active -NotePropertyValue $false -Force
        $r|Add-Member -NotePropertyName small_boost_class_active -NotePropertyValue $false -Force
        $r|Add-Member -NotePropertyName speed_effect_state_source -NotePropertyValue 'replay_native_action_object_speed_effect_table_v2' -Force
    }
}
function RNSE-LowerBoundTime([object[]]$Rows,[double]$TimeS) {
    $lo=0;$hi=$Rows.Count
    # Termination contract: the midpoint must be computed with an integer-safe form.
    # PowerShell's [int] cast rounds half-to-even, so [int](($lo+$hi)/2) can evaluate to
    # exactly $hi (e.g. lo=549,hi=550 -> 550) and the no-progress branch $hi=$m then spins
    # forever. Floor is used here for the same reason RNDT-NearestRowIndex uses it.
    while($lo-lt$hi){$m=[int][Math]::Floor(($lo+$hi)/2.0);if([double]$Rows[$m].time_s-lt$TimeS){$lo=$m+1}else{$hi=$m}}
    return $lo
}
function RNSE-MarkRows {
    param([Parameter(Mandatory=$true)][object[]]$Rows,[double]$StartS,[double]$EndS,[Parameter(Mandatory=$true)][string]$Property)
    if($null-eq$Rows -or $Rows.Count-eq0 -or $EndS-le$StartS){return}
    # Rows are chronological. Mark only the interval instead of rescanning the full replay for every effect.
    $lo=RNSE-LowerBoundTime -Rows $Rows -TimeS $StartS
    $hi=RNSE-LowerBoundTime -Rows $Rows -TimeS $EndS
    for($i=$lo;$i-lt$hi-and$i-lt$Rows.Count;$i++){$Rows[$i].$Property=$true}
}

function Convert-ReplayNativeSpeedEffectsToSegments {
    param(
        [Parameter(Mandatory=$true)][object]$Resolved,
        [Parameter(Mandatory=$true)][object[]]$Rows,
        [object]$NativeDriftResolved
    )
    RNSE-EnsureRowFlags -Rows $Rows
    $nitro=New-Object System.Collections.Generic.List[object]
    $small=New-Object System.Collections.Generic.List[object]
    $air=New-Object System.Collections.Generic.List[object]
    $landing=New-Object System.Collections.Generic.List[object]
    $other=New-Object System.Collections.Generic.List[object]
    $mapPropulsion=New-Object System.Collections.Generic.List[object]
    $unknown=New-Object System.Collections.Generic.List[object]
    $all=New-Object System.Collections.Generic.List[object]
    if($null-eq$Resolved-or-not[bool]$Resolved.available){
        return [pscustomobject][ordered]@{available=$false;status=$(if($null-eq$Resolved){'unresolved'}else{[string]$Resolved.status});nitro_segments=@();small_boost_segments=@();air_boost_segments=@();landing_boost_segments=@();other_small_boost_segments=@();map_propulsion_effect_segments=@();unknown_speed_effect_segments=@();native_speed_effect_segments=@()}
    }
    $ctx=RNSE-BuildContactContext -Rows $Rows
    $id=1
    foreach($iv in @($Resolved.table.intervals)){
        $code=[double]$iv.effect_code;$startS=[double]$iv.start_ms/1000.0;$endS=[double]$iv.end_ms/1000.0;$dur=[double]$iv.duration_ms
        $semantic='unknown_speed_effect';$context='unmapped_native_effect_code';$classification=$null
        if((RNSE-CodeNear $code 1.0)-and[bool]$Resolved.nitro_semantic_valid){$semantic='nitro';$context='native_code1_cross_replay_inventory_consume_and_ctrl_validated'}
        elseif(RNSE-CodeNear $code 2001.0){
            if($dur-ge100.0-and$dur-le1000.0){$classification=RNSE-ClassifySmallBoostStart -StartS $startS -ContactContext $ctx -NativeDriftResolved $NativeDriftResolved;$semantic=[string]$classification.subtype;$context=[string]$classification.context}
            else{$context='native_code2001_duration_outside_validated_small_boost_window'}
        }elseif(RNSE-CodeNear $code 2003.0){
            # Dedicated labeled map-scene recordings show code 2003 without Shift/Ctrl, at repeatable world positions,
            # with immediate positive native-speed gain.  Promote the propulsion effect itself; the exact scene geometry/driver stays separate.
            $semantic='map_propulsion_effect';$context='native_code2003_map_propulsion_labeled_position_locked_and_speed_gain_validated'
        }elseif(RNSE-CodeNear $code 1.0){$context='native_code1_local_ctrl_semantic_gate_failed'}
        $seg=[ordered]@{
            id=$id;effect_code=$code;effect_code_bits=[int]$iv.effect_code_bits;start_t=[Math]::Round($startS,4);end_t=[Math]::Round($endS,4);duration_s=[Math]::Round(($endS-$startS),4);duration_ms=[Math]::Round($dur,3)
            semantic_type=$semantic;context=$context;source='replay_native_action_object_speed_effect_table_v2';authoritative=($semantic-ne'unknown_speed_effect');native_start_ms=[long]$iv.start_ms;native_end_ms=[long]$iv.end_ms;native_table_count_offset=[long]$Resolved.count_offset
            drift_id=$(if($null-ne$classification){$classification.drift_id}else{$null});drift_relation=$(if($null-ne$classification){$classification.drift_relation}else{$null});drift_boundary_delta_ms=$(if($null-ne$classification){$classification.drift_boundary_delta_ms}else{$null});air_duration_ms=$(if($null-ne$classification){$classification.air_duration_ms}else{$null});landing_delta_ms=$(if($null-ne$classification){$classification.landing_delta_ms}else{$null})
        }
        $all.Add($seg)
        switch($semantic){
            'nitro' {$nitro.Add($seg);RNSE-MarkRows -Rows $Rows -StartS $startS -EndS $endS -Property 'nitro_active'}
            'drift_small_boost' {$small.Add($seg);RNSE-MarkRows -Rows $Rows -StartS $startS -EndS $endS -Property 'small_boost_active';RNSE-MarkRows -Rows $Rows -StartS $startS -EndS $endS -Property 'small_boost_class_active'}
            'air_boost' {$air.Add($seg);RNSE-MarkRows -Rows $Rows -StartS $startS -EndS $endS -Property 'air_boost_active';RNSE-MarkRows -Rows $Rows -StartS $startS -EndS $endS -Property 'small_boost_class_active'}
            'landing_boost' {$landing.Add($seg);RNSE-MarkRows -Rows $Rows -StartS $startS -EndS $endS -Property 'landing_boost_active';RNSE-MarkRows -Rows $Rows -StartS $startS -EndS $endS -Property 'small_boost_class_active'}
            'other_small_boost' {$other.Add($seg);RNSE-MarkRows -Rows $Rows -StartS $startS -EndS $endS -Property 'small_boost_class_active'}
            'map_propulsion_effect' {$mapPropulsion.Add($seg);RNSE-MarkRows -Rows $Rows -StartS $startS -EndS $endS -Property 'map_propulsion_active'}
            default {$unknown.Add($seg)}
        }
        $id++
    }
    return [pscustomobject][ordered]@{
        available=$true;status=[string]$Resolved.status;source='replay_native_action_object_speed_effect_table_v2'
        nitro_segments=$nitro.ToArray();small_boost_segments=$small.ToArray();air_boost_segments=$air.ToArray();landing_boost_segments=$landing.ToArray();other_small_boost_segments=$other.ToArray();map_propulsion_effect_segments=$mapPropulsion.ToArray();unknown_speed_effect_segments=$unknown.ToArray();native_speed_effect_segments=$all.ToArray()
        native_effect_interval_count=$all.Count;nitro_count=$nitro.Count;small_boost_count=$small.Count;air_boost_count=$air.Count;landing_boost_count=$landing.Count;other_small_boost_count=$other.Count;map_propulsion_effect_count=$mapPropulsion.Count;unknown_speed_effect_count=$unknown.Count
        contact_context=[pscustomobject][ordered]@{validated_air_interval_count=@($ctx.air_intervals|Where-Object{[bool]$_.validated_air}).Count;raw_landing_edge_count=@($ctx.landing_edges).Count}
    }
}
