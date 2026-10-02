# Replay-native action cache.
#
# Purpose: persist the raw native action-object scan evidence (Drift candidate tables + the
# adjacent native speed-effect tables) together with the exact replay tail window it was read
# from, so later Analyze / -ForceTelemetry runs can re-interpret native action semantics from
# PhysicalTelemetryCache + NativeActionCache without scanning the original .sav again.
#
# Contract boundaries (v1):
# - This cache is raw evidence first, performance cache second. It never stores semantic labels
#   (nitro / drift-small-boost / combo / unknown classification / per-row flags / drift ids).
#   Every semantic field is re-derived from the telemetry rows by the unchanged semantic layer.
# - Validity binds source replay identity (SHA256 + size) and the native-action scanner contract
#   only. It deliberately does NOT bind the physical qpf cache hash: the two caches have
#   independent lifecycles (-ForceRaw rebuilds qpf only, -ForceNativeActions rebuilds this only).
#   Physical cache facts are recorded as audit metadata, never as an invalidation input.
# - Any mismatch fails closed: the caller re-scans from the stored raw tail when possible and
#   otherwise re-reads the .sav. No path may silently produce different native action facts.
#
# Definition-only module: no runtime actions at import scope.

$script:RACCacheContract='native_action_cache_v1'
# v2: the Drift record-pair ordering rule changed. Raw record times are no longer required to be
# globally non-decreasing; the contract is the interval sequence (each consecutive record pair is
# one interval, boundaries normalised to min/max, intervals never overlap). A cache written by v1
# re-derives its intervals under the old rule, so it must be rescanned rather than reused.
$script:RACScannerContract='replay_native_action_suffix_scan_v2'
$script:RACDefaultTailBytes=196608

function Get-NativeActionCacheContract { return $script:RACCacheContract }
function Get-NativeActionScannerContract { return $script:RACScannerContract }
function Get-NativeActionDefaultTailBytes { return $script:RACDefaultTailBytes }

# ---------------------------------------------------------------------------
# primitives
# ---------------------------------------------------------------------------

function RAC-Prop($Object,[string]$Name) {
    if($null-eq$Object){return $null}
    if($Object -is [System.Collections.IDictionary]){
        if($Object.Contains($Name)){return $Object[$Name]}
        return $null
    }
    $p=$Object.PSObject.Properties[$Name]
    if($null-eq$p){return $null}
    return $p.Value
}
function RAC-CodeFromBits([int]$Bits) {
    $b=[BitConverter]::GetBytes([int]$Bits)
    return [double][BitConverter]::ToSingle($b,0)
}
function RAC-BitsFromCode([double]$Code) {
    $b=[BitConverter]::GetBytes([single]$Code)
    return [int][BitConverter]::ToInt32($b,0)
}
function RAC-Sha256Bytes([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash=$sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    return ([BitConverter]::ToString($hash)).Replace('-','').ToUpperInvariant()
}
function RAC-WriteJson([string]$Path,[object]$Value,[int]$Depth=12) {
    $enc=New-Object System.Text.UTF8Encoding -ArgumentList $true
    [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth $Depth),$enc)
}
function RAC-MoveIntoPlace([string]$TempPath,[string]$FinalPath) {
    if(Test-Path -LiteralPath $FinalPath){Remove-Item -LiteralPath $FinalPath -Force}
    Move-Item -LiteralPath $TempPath -Destination $FinalPath -Force
}
function RAC-NullableLong($Value) {
    if($null-eq$Value){return $null}
    return [long]$Value
}
function RAC-AsBool($Value) {
    if($null-eq$Value){return $false}
    if($Value-is[bool]){return [bool]$Value}
    $s=[string]$Value
    return ($s-eq'True'-or$s-eq'true'-or$s-eq'1')
}
function RAC-AddProblem([object]$Problems,[string]$Message) { [void]$Problems.Add($Message) }

# ---------------------------------------------------------------------------
# canonical evidence document
# ---------------------------------------------------------------------------

function RAC-CanonicalCandidate([object]$Candidate) {
    $records=New-Object System.Collections.Generic.List[object]
    foreach($r in @($Candidate.records)){
        if($null-eq$r){continue}
        $records.Add([ordered]@{time_ms=[long]$r.time_ms;state=[int]$r.state})
    }
    $intervals=New-Object System.Collections.Generic.List[object]
    foreach($iv in @($Candidate.intervals)){
        if($null-eq$iv){continue}
        $intervals.Add([ordered]@{start_ms=[long]$iv.start_ms;end_ms=[long]$iv.end_ms;duration_ms=[long]$iv.duration_ms})
    }
    return [ordered]@{
        count_offset=[long]$Candidate.count_offset;end_exclusive=[long]$Candidate.end_exclusive
        record_count=[int]$Candidate.record_count;interval_count=[int]$Candidate.interval_count
        native_object_marker_valid=[bool]$Candidate.native_object_marker_valid;object_marker_hex=[string]$Candidate.object_marker_hex
        structural_table_valid=[bool]$Candidate.structural_table_valid;empty_table=[bool]$Candidate.empty_table
        legacy_unmarked_action_pair=[bool]$Candidate.legacy_unmarked_action_pair
        inverted_pair_count=[int](RAC-Prop $Candidate 'inverted_pair_count')
        adjacent_effect_table_valid=[bool]$Candidate.adjacent_effect_table_valid
        adjacent_effect_record_count=[int]$Candidate.adjacent_effect_record_count
        adjacent_effect_interval_count=[int]$Candidate.adjacent_effect_interval_count
        adjacent_effect_end_exclusive=[long]$Candidate.adjacent_effect_end_exclusive
        start_time_ms=$(if($null-ne$Candidate.start_time_ms){[long]$Candidate.start_time_ms}else{$null})
        end_time_ms=$(if($null-ne$Candidate.end_time_ms){[long]$Candidate.end_time_ms}else{$null})
        records=$records.ToArray();intervals=$intervals.ToArray()
        source=[string]$Candidate.source
    }
}
function RAC-CanonicalTable([object]$Table) {
    $records=New-Object System.Collections.Generic.List[object]
    foreach($r in @($Table.records)){
        if($null-eq$r){continue}
        $records.Add([ordered]@{time_ms=[long]$r.time_ms;state=[int]$r.state;effect_code_bits=[int]$r.effect_code_bits;effect_code=[double]$r.effect_code})
    }
    $intervals=New-Object System.Collections.Generic.List[object]
    foreach($iv in @($Table.intervals)){
        if($null-eq$iv){continue}
        $intervals.Add([ordered]@{effect_code=[double]$iv.effect_code;effect_code_bits=[int]$iv.effect_code_bits;start_ms=[long]$iv.start_ms;end_ms=[long]$iv.end_ms;duration_ms=[long]$iv.duration_ms})
    }
    $codes=New-Object System.Collections.Generic.List[object]
    foreach($c in @($Table.effect_codes)){
        if($null-eq$c){continue}
        $codes.Add([ordered]@{effect_code=[double]$c.effect_code;effect_code_bits=[int]$c.effect_code_bits;interval_count=[int]$c.interval_count;duration_median_ms=$(if($null-ne$c.duration_median_ms){[double]$c.duration_median_ms}else{$null})})
    }
    # Invalid tables carry a small failure detail; preserve it verbatim for audit.
    $detail=[ordered]@{
        record_count_u32=$(if($null-ne$Table.record_count_u32){[long]$Table.record_count_u32}else{$null})
        record_index=$(if($null-ne$Table.record_index){[int]$Table.record_index}else{$null})
        state=$(if($null-ne$Table.state){[int]$Table.state}else{$null})
        time_ms=$(if($null-ne$Table.time_ms){[long]$Table.time_ms}else{$null})
        previous_time_ms=$(if($null-ne$Table.previous_time_ms){[long]$Table.previous_time_ms}else{$null})
        effect_code=$(if($null-ne$Table.effect_code){[double]$Table.effect_code}else{$null})
        open_count=$(if($null-ne$Table.open_count){[int]$Table.open_count}else{$null})
    }
    return [ordered]@{
        valid=[bool]$Table.valid;status=[string]$Table.status
        source=$(if([string]::IsNullOrWhiteSpace([string]$Table.source)){'replay_native_action_object_speed_effect_table_v2'}else{[string]$Table.source})
        count_offset=[long]$Table.count_offset
        end_exclusive=$(if($null-ne$Table.end_exclusive){[long]$Table.end_exclusive}else{[long]$Table.count_offset})
        record_count=$(if($null-ne$Table.record_count){[int]$Table.record_count}else{0})
        interval_count=$(if($null-ne$Table.interval_count){[int]$Table.interval_count}else{0})
        records=$records.ToArray();intervals=$intervals.ToArray();effect_codes=$codes.ToArray()
        detail=$detail
    }
}
function RAC-BuildDocument {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Candidates,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$EffectTables,
        [Parameter(Mandatory=$true)][object]$Source,
        [Parameter(Mandatory=$true)][object]$ScanWindow,
        [string]$ScannerContract=$script:RACScannerContract
    )
    $candOut=New-Object System.Collections.Generic.List[object]
    foreach($c in @($Candidates)){if($null-eq$c){continue};$candOut.Add((RAC-CanonicalCandidate $c))}
    $tableOut=New-Object System.Collections.Generic.List[object]
    foreach($t in @($EffectTables)){if($null-eq$t){continue};$tableOut.Add((RAC-CanonicalTable $t))}
    return [ordered]@{
        schema_version=1;contract=$script:RACCacheContract;scanner_contract=[string]$ScannerContract
        source=[ordered]@{
            sha256=[string](RAC-Prop $Source 'sha256');size_bytes=[long](RAC-Prop $Source 'size_bytes')
            last_write_utc=[string](RAC-Prop $Source 'last_write_utc');file_name=[string](RAC-Prop $Source 'file_name')
        }
        scan_window=[ordered]@{
            file_length=[long](RAC-Prop $ScanWindow 'file_length');tail_bytes=[int](RAC-Prop $ScanWindow 'tail_bytes')
            scan_start_offset=[long](RAC-Prop $ScanWindow 'scan_start_offset');scan_end_offset=[long](RAC-Prop $ScanWindow 'scan_end_offset')
        }
        drift_candidate_count=$candOut.Count;effect_table_count=$tableOut.Count
        drift_candidates=$candOut.ToArray();effect_tables=$tableOut.ToArray()
    }
}

# ---------------------------------------------------------------------------
# independent re-derivation (raw records must reproduce the recorded intervals)
# ---------------------------------------------------------------------------

function RAC-DriftIntervalsFromRecords([object[]]$Records) {
    $out=New-Object System.Collections.Generic.List[object]
    $rows=@($Records)
    if(($rows.Count%2)-ne0){return [pscustomobject]@{ok=$false;reason='drift_record_count_not_paired';intervals=@();inverted_pair_count=0}}
    for($i=0;$i-lt$rows.Count;$i++){
        if($null-eq$rows[$i]){return [pscustomobject]@{ok=$false;reason='drift_record_missing';intervals=@();inverted_pair_count=0}}
        $t=[long](RAC-Prop $rows[$i] 'time_ms');$st=[int](RAC-Prop $rows[$i] 'state')
        $expected=$(if(($i%2)-eq0){1}else{0})
        if($st-ne$expected){return [pscustomobject]@{ok=$false;reason='drift_state_not_alternating';intervals=@();inverted_pair_count=0}}
        if($t-gt600000){return [pscustomobject]@{ok=$false;reason='drift_time_out_of_range';intervals=@();inverted_pair_count=0}}
    }
    # Interval sequence contract: each consecutive record pair is one Drift interval, the two
    # timestamps are its boundaries in either write order, and interval starts never move
    # backwards. This mirrors RNDT-TryParseToggleTable exactly; a raw record order check would
    # reject the current 2026-09 tables (see that function for the measured evidence).
    $prevStart=-1L;$inverted=0;$positive=0
    for($i=0;$i-lt$rows.Count;$i+=2){
        $a=[long](RAC-Prop $rows[$i] 'time_ms');$b=[long](RAC-Prop $rows[$i+1] 'time_ms')
        $st=[Math]::Min($a,$b);$en=[Math]::Max($a,$b)
        if($a-gt$b){$inverted++}
        if($st-lt$prevStart){return [pscustomobject]@{ok=$false;reason='drift_interval_start_regression';intervals=@();inverted_pair_count=$inverted}}
        if($en-gt$st){$positive++}
        $prevStart=$st
        $out.Add([pscustomobject]@{start_ms=$st;end_ms=$en;duration_ms=($en-$st)})
    }
    return [pscustomobject]@{ok=$true;reason='';intervals=$out.ToArray();inverted_pair_count=$inverted;positive_interval_count=$positive}
}
function RAC-EffectIntervalsFromRecords([object[]]$Records) {
    $open=@{}
    $out=New-Object System.Collections.Generic.List[object]
    foreach($r in @($Records)){
        if($null-eq$r){return [pscustomobject]@{ok=$false;reason='effect_record_missing';intervals=@()}}
        $bits=[int](RAC-Prop $r 'effect_code_bits');$state=[int](RAC-Prop $r 'state');$t=[long](RAC-Prop $r 'time_ms')
        $key=[string]$bits
        if(-not$open.ContainsKey($key)){$open[$key]=New-Object System.Collections.Queue}
        $q=$open[$key]
        if($state-eq1){$q.Enqueue($t)}
        else{
            if($q.Count-eq0){return [pscustomobject]@{ok=$false;reason='effect_end_without_start';intervals=@()}}
            $st=[long]$q.Dequeue()
            if($t-lt$st){return [pscustomobject]@{ok=$false;reason='negative_effect_duration';intervals=@()}}
            $out.Add([pscustomobject]@{effect_code=(RAC-CodeFromBits $bits);effect_code_bits=$bits;start_ms=$st;end_ms=$t;duration_ms=($t-$st)})
        }
    }
    foreach($k in @($open.Keys)){if($open[$k].Count-ne0){return [pscustomobject]@{ok=$false;reason='unclosed_effect_start';intervals=@()}}}
    return [pscustomobject]@{ok=$true;reason='';intervals=$out.ToArray()}
}
function RAC-EffectCodesFromIntervals([object[]]$Intervals) {
    $byBits=@{}
    foreach($iv in @($Intervals)){
        if($null-eq$iv){continue}
        $key=[string][int]$iv.effect_code_bits
        if(-not$byBits.ContainsKey($key)){$byBits[$key]=New-Object System.Collections.Generic.List[double]}
        $byBits[$key].Add([double]$iv.duration_ms)
    }
    $out=New-Object System.Collections.Generic.List[object]
    foreach($key in @($byBits.Keys|Sort-Object {[int]$_})){
        $durations=@($byBits[$key].ToArray()|Sort-Object)
        $n=$durations.Count;$med=$null
        if($n-gt0){$med=$(if(($n%2)-eq1){[double]$durations[[int][Math]::Floor($n/2)]}else{([double]$durations[$n/2-1]+[double]$durations[$n/2])/2.0})}
        $bits=[int]$key
        $out.Add([pscustomobject]@{effect_code=(RAC-CodeFromBits $bits);effect_code_bits=$bits;interval_count=$n;duration_median_ms=$med})
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------
# strict document rebuild (shared by writer self-check and reader validation)
# ---------------------------------------------------------------------------

function RAC-RebuildDocument {
    param([Parameter(Mandatory=$true)][object]$Document)
    $problems=New-Object System.Collections.Generic.List[string]

    $source=RAC-Prop $Document 'source'
    $scanWindow=RAC-Prop $Document 'scan_window'
    if($null-eq$source){RAC-AddProblem $problems 'source block missing'}
    if($null-eq$scanWindow){RAC-AddProblem $problems 'scan_window block missing'}

    $candidates=New-Object System.Collections.Generic.List[object]
    foreach($c in @(RAC-Prop $Document 'drift_candidates')){
        if($null-eq$c){RAC-AddProblem $problems 'null drift candidate entry';continue}
        $countOffset=RAC-Prop $c 'count_offset'
        if($null-eq$countOffset){RAC-AddProblem $problems 'drift candidate without count_offset';continue}
        $records=New-Object System.Collections.Generic.List[object]
        foreach($r in @(RAC-Prop $c 'records')){
            if($null-eq$r){continue}
            $records.Add([pscustomobject][ordered]@{time_ms=[long](RAC-Prop $r 'time_ms');state=[int](RAC-Prop $r 'state')})
        }
        $intervals=New-Object System.Collections.Generic.List[object]
        foreach($iv in @(RAC-Prop $c 'intervals')){
            if($null-eq$iv){continue}
            $st=[long](RAC-Prop $iv 'start_ms');$en=[long](RAC-Prop $iv 'end_ms');$du=[long](RAC-Prop $iv 'duration_ms')
            if($du-ne($en-$st)){RAC-AddProblem $problems ('drift interval duration mismatch at offset '+[string]$countOffset)}
            $intervals.Add([pscustomobject][ordered]@{start_ms=$st;end_ms=$en;duration_ms=$du})
        }
        $recordCount=[int](RAC-Prop $c 'record_count');$intervalCount=[int](RAC-Prop $c 'interval_count')
        if($recordCount-ne$records.Count){RAC-AddProblem $problems ('drift record_count mismatch at offset '+[string]$countOffset)}
        if($intervalCount-ne$intervals.Count){RAC-AddProblem $problems ('drift interval_count mismatch at offset '+[string]$countOffset)}
        # Raw evidence must reproduce the recorded interval list exactly.
        $derived=RAC-DriftIntervalsFromRecords -Records $records.ToArray()
        if(-not[bool]$derived.ok){RAC-AddProblem $problems ('drift records invalid at offset '+[string]$countOffset+': '+[string]$derived.reason)}
        elseif(@($derived.intervals).Count-ne$intervals.Count){RAC-AddProblem $problems ('drift intervals not reproducible from records at offset '+[string]$countOffset)}
        else{
            for($i=0;$i-lt$intervals.Count;$i++){
                if([long]$derived.intervals[$i].start_ms-ne[long]$intervals[$i].start_ms-or[long]$derived.intervals[$i].end_ms-ne[long]$intervals[$i].end_ms){RAC-AddProblem $problems ('drift interval value drift at offset '+[string]$countOffset);break}
            }
        }
        # The declared inverted-boundary count is raw evidence; it must be reproducible from the
        # records, never trusted as a free-form label.
        if([int](RAC-Prop $c 'inverted_pair_count')-ne[int]$derived.inverted_pair_count){RAC-AddProblem $problems ('drift inverted_pair_count not reproducible at offset '+[string]$countOffset)}
        $candidates.Add([pscustomobject][ordered]@{
            count_offset=[long]$countOffset;end_exclusive=[long](RAC-Prop $c 'end_exclusive')
            record_count=$recordCount;interval_count=$intervalCount
            native_object_marker_valid=(RAC-AsBool (RAC-Prop $c 'native_object_marker_valid'));object_marker_hex=[string](RAC-Prop $c 'object_marker_hex')
            structural_table_valid=(RAC-AsBool (RAC-Prop $c 'structural_table_valid'));empty_table=(RAC-AsBool (RAC-Prop $c 'empty_table'))
            legacy_unmarked_action_pair=(RAC-AsBool (RAC-Prop $c 'legacy_unmarked_action_pair'))
            inverted_pair_count=[int]$derived.inverted_pair_count
            adjacent_effect_table_valid=(RAC-AsBool (RAC-Prop $c 'adjacent_effect_table_valid'))
            adjacent_effect_record_count=[int](RAC-Prop $c 'adjacent_effect_record_count')
            adjacent_effect_interval_count=[int](RAC-Prop $c 'adjacent_effect_interval_count')
            adjacent_effect_end_exclusive=[long](RAC-Prop $c 'adjacent_effect_end_exclusive')
            start_time_ms=$(if($null-ne(RAC-Prop $c 'start_time_ms')){[long](RAC-Prop $c 'start_time_ms')}else{$null})
            end_time_ms=$(if($null-ne(RAC-Prop $c 'end_time_ms')){[long](RAC-Prop $c 'end_time_ms')}else{$null})
            records=$records.ToArray();intervals=$intervals.ToArray()
            source=[string](RAC-Prop $c 'source')
        })
    }

    $tables=New-Object System.Collections.Generic.List[object]
    $tableOffsets=New-Object 'System.Collections.Generic.HashSet[long]'
    foreach($t in @(RAC-Prop $Document 'effect_tables')){
        if($null-eq$t){RAC-AddProblem $problems 'null effect table entry';continue}
        $countOffset=RAC-Prop $t 'count_offset'
        if($null-eq$countOffset){RAC-AddProblem $problems 'effect table without count_offset';continue}
        $valid=RAC-AsBool (RAC-Prop $t 'valid')
        $status=[string](RAC-Prop $t 'status')
        if([string]::IsNullOrWhiteSpace($status)){RAC-AddProblem $problems ('effect table without status at offset '+[string]$countOffset)}
        $records=New-Object System.Collections.Generic.List[object]
        foreach($r in @(RAC-Prop $t 'records')){
            if($null-eq$r){continue}
            $bits=[int](RAC-Prop $r 'effect_code_bits');$code=[double](RAC-Prop $r 'effect_code')
            if((RAC-CodeFromBits $bits)-ne$code){RAC-AddProblem $problems ('effect record code/bits mismatch at offset '+[string]$countOffset)}
            $records.Add([pscustomobject][ordered]@{time_ms=[long](RAC-Prop $r 'time_ms');state=[int](RAC-Prop $r 'state');effect_code=$code;effect_code_bits=$bits})
        }
        $intervals=New-Object System.Collections.Generic.List[object]
        foreach($iv in @(RAC-Prop $t 'intervals')){
            if($null-eq$iv){continue}
            $bits=[int](RAC-Prop $iv 'effect_code_bits');$code=[double](RAC-Prop $iv 'effect_code')
            if((RAC-CodeFromBits $bits)-ne$code){RAC-AddProblem $problems ('effect interval code/bits mismatch at offset '+[string]$countOffset)}
            $st=[long](RAC-Prop $iv 'start_ms');$en=[long](RAC-Prop $iv 'end_ms');$du=[long](RAC-Prop $iv 'duration_ms')
            if($du-ne($en-$st)){RAC-AddProblem $problems ('effect interval duration mismatch at offset '+[string]$countOffset)}
            $intervals.Add([pscustomobject][ordered]@{effect_code=$code;effect_code_bits=$bits;start_ms=$st;end_ms=$en;duration_ms=$du})
        }
        $recordCount=[int](RAC-Prop $t 'record_count');$intervalCount=[int](RAC-Prop $t 'interval_count')
        if($valid){
            if($recordCount-ne$records.Count){RAC-AddProblem $problems ('effect record_count mismatch at offset '+[string]$countOffset)}
            if($intervalCount-ne$intervals.Count){RAC-AddProblem $problems ('effect interval_count mismatch at offset '+[string]$countOffset)}
            $derived=RAC-EffectIntervalsFromRecords -Records $records.ToArray()
            if(-not[bool]$derived.ok){RAC-AddProblem $problems ('effect records invalid at offset '+[string]$countOffset+': '+[string]$derived.reason)}
            elseif(@($derived.intervals).Count-ne$intervals.Count){RAC-AddProblem $problems ('effect intervals not reproducible from records at offset '+[string]$countOffset)}
            else{
                for($i=0;$i-lt$intervals.Count;$i++){
                    $a=$derived.intervals[$i];$b=$intervals[$i]
                    if([int]$a.effect_code_bits-ne[int]$b.effect_code_bits-or[long]$a.start_ms-ne[long]$b.start_ms-or[long]$a.end_ms-ne[long]$b.end_ms){RAC-AddProblem $problems ('effect interval value drift at offset '+[string]$countOffset);break}
                }
            }
            # The recorded effect-code summary must be reproducible from the recorded intervals.
            $codesDerived=RAC-EffectCodesFromIntervals -Intervals $intervals.ToArray()
            $storedCodes=@{}
            foreach($sc in @(RAC-Prop $t 'effect_codes')){
                if($null-eq$sc){continue}
                $storedCodes[[string][int](RAC-Prop $sc 'effect_code_bits')]=$sc
            }
            if($storedCodes.Count-ne@($codesDerived).Count){RAC-AddProblem $problems ('effect code summary count mismatch at offset '+[string]$countOffset)}
            foreach($dc in @($codesDerived)){
                $key=[string][int]$dc.effect_code_bits
                if(-not$storedCodes.ContainsKey($key)){RAC-AddProblem $problems ('effect code summary missing code '+$key+' at offset '+[string]$countOffset);continue}
                $sc=$storedCodes[$key]
                if([int](RAC-Prop $sc 'interval_count')-ne[int]$dc.interval_count){RAC-AddProblem $problems ('effect code summary count mismatch for code '+$key+' at offset '+[string]$countOffset)}
                $storedMed=RAC-Prop $sc 'duration_median_ms'
                if($null-eq$storedMed-and$null-ne$dc.duration_median_ms){RAC-AddProblem $problems ('effect code median missing for code '+$key+' at offset '+[string]$countOffset)}
                elseif($null-ne$storedMed-and[double]$storedMed-ne[double]$dc.duration_median_ms){RAC-AddProblem $problems ('effect code median mismatch for code '+$key+' at offset '+[string]$countOffset)}
            }
        } else {
            if($records.Count-ne0-or$intervals.Count-ne0){RAC-AddProblem $problems ('invalid effect table carries decoded payload at offset '+[string]$countOffset)}
        }
        $detail=RAC-Prop $t 'detail'
        $tableOffsets.Add([long]$countOffset)|Out-Null
        $tables.Add([pscustomobject][ordered]@{
            valid=$valid;status=$status;source=[string](RAC-Prop $t 'source')
            count_offset=[long]$countOffset
            end_exclusive=$(if($null-ne(RAC-Prop $t 'end_exclusive')){[long](RAC-Prop $t 'end_exclusive')}else{[long]$countOffset})
            record_count=$recordCount;interval_count=$intervalCount
            records=$records.ToArray();intervals=$intervals.ToArray()
            effect_codes=$(if($valid){$codesDerived}else{@()})
            record_count_u32=$(if($null-ne(RAC-Prop $detail 'record_count_u32')){[long](RAC-Prop $detail 'record_count_u32')}else{$null})
            record_index=$(if($null-ne(RAC-Prop $detail 'record_index')){[int](RAC-Prop $detail 'record_index')}else{$null})
            state=$(if($null-ne(RAC-Prop $detail 'state')){[int](RAC-Prop $detail 'state')}else{$null})
            time_ms=$(if($null-ne(RAC-Prop $detail 'time_ms')){[long](RAC-Prop $detail 'time_ms')}else{$null})
            previous_time_ms=$(if($null-ne(RAC-Prop $detail 'previous_time_ms')){[long](RAC-Prop $detail 'previous_time_ms')}else{$null})
            effect_code=$(if($null-ne(RAC-Prop $detail 'effect_code')){[double](RAC-Prop $detail 'effect_code')}else{$null})
            open_count=$(if($null-ne(RAC-Prop $detail 'open_count')){[int](RAC-Prop $detail 'open_count')}else{$null})
        })
    }

    # Lossless replay requirement: every candidate must ship the table payload its end_exclusive
    # points at, valid or invalid. Otherwise a cache hit could resolve differently than a scan.
    foreach($c in $candidates.ToArray()){
        if(-not$tableOffsets.Contains([long]$c.end_exclusive)){RAC-AddProblem $problems ('effect table payload missing for candidate end_exclusive '+[string]$c.end_exclusive)}
    }
    return [pscustomobject]@{
        candidates=$candidates.ToArray();effect_tables=$tables.ToArray()
        candidate_count=$candidates.Count;effect_table_count=$tables.Count
        problems=$problems.ToArray()
    }
}

# ---------------------------------------------------------------------------
# scan
# ---------------------------------------------------------------------------

function New-NativeActionScan {
    param(
        [string]$ReplayPath='',
        [byte[]]$Data=$null,
        [int]$TailBytes=$script:RACDefaultTailBytes
    )
    if($null-eq$Data){
        if([string]::IsNullOrWhiteSpace($ReplayPath)){throw 'Native action scan requires -ReplayPath or -Data.'}
        if(-not(Test-Path -LiteralPath $ReplayPath -PathType Leaf)){throw ('Replay not found: '+$ReplayPath)}
        [byte[]]$data=[IO.File]::ReadAllBytes($ReplayPath)
    } else {[byte[]]$data=$Data}

    # Collect through a List so a 0/1/N candidate scan always yields an array (never a bare object).
    $candidates=New-Object System.Collections.Generic.List[object]
    foreach($c in @(Get-ReplayNativeDriftTimelineCandidates -ReplayPath $ReplayPath -Data $data -TailBytes $TailBytes)){if($null-ne$c){$candidates.Add($c)}}
    # The production reader is invoked for every candidate anchor, valid or not, so a cache hit
    # cannot resolve differently from a raw scan.
    $tables=New-Object System.Collections.Generic.List[object]
    $seen=New-Object 'System.Collections.Generic.HashSet[long]'
    foreach($c in $candidates.ToArray()){
        $offset=[long]$c.end_exclusive
        if($seen.Contains($offset)){continue}
        [void]$seen.Add($offset)
        $tables.Add((Get-ReplayNativeSpeedEffectTableAtOffset -ReplayPath $ReplayPath -Data $data -CountOffset $offset))
    }

    $tailStart=[Math]::Max(0,$data.Length-[Math]::Max(32768,$TailBytes))
    $tailLength=$data.Length-$tailStart
    [byte[]]$tail=New-Object byte[] $tailLength
    if($tailLength-gt0){[Array]::Copy($data,$tailStart,$tail,0,$tailLength)}
    return [pscustomobject]@{
        candidates=$candidates.ToArray();effect_tables=$tables.ToArray()
        file_length=[long]$data.Length;tail_bytes=$TailBytes
        scan_start_offset=[long]$tailStart;scan_end_offset=[long]($data.Length-1)
        tail=$tail
    }
}

function New-NativeActionDataFromTail {
    param(
        [Parameter(Mandatory=$true)][byte[]]$Tail,
        [Parameter(Mandatory=$true)][long]$ScanStartOffset,
        [Parameter(Mandatory=$true)][long]$FileLength
    )
    if($FileLength-lt1-or$FileLength-gt([long][int]::MaxValue)){throw ('Cached native action tail declares an unsupported file length: '+[string]$FileLength)}
    if($ScanStartOffset-lt0-or(($ScanStartOffset+[long]$Tail.Length)-ne$FileLength)){throw 'Cached native action tail does not match its recorded scan window.'}
    [byte[]]$buffer=New-Object byte[] ([int]$FileLength)
    if($Tail.Length-gt0){[Array]::Copy($Tail,0,$buffer,[int]$ScanStartOffset,$Tail.Length)}
    return $buffer
}

function New-NativeActionScanFromTail {
    param(
        [Parameter(Mandatory=$true)][string]$TailPath,
        [Parameter(Mandatory=$true)][long]$ScanStartOffset,
        [Parameter(Mandatory=$true)][long]$FileLength,
        [int]$TailBytes=$script:RACDefaultTailBytes
    )
    if(-not(Test-Path -LiteralPath $TailPath -PathType Leaf)){throw ('Cached native action tail missing: '+$TailPath)}
    [byte[]]$tail=[IO.File]::ReadAllBytes($TailPath)
    $data=New-NativeActionDataFromTail -Tail $tail -ScanStartOffset $ScanStartOffset -FileLength $FileLength
    return New-NativeActionScan -Data $data -TailBytes $TailBytes
}

# ---------------------------------------------------------------------------
# cache directory read/write
# ---------------------------------------------------------------------------

function Get-NativeActionCacheDir([string]$CacheRoot,[string]$ReplaySha256) {
    if([string]::IsNullOrWhiteSpace($CacheRoot)){return $null}
    if([string]::IsNullOrWhiteSpace($ReplaySha256)-or$ReplaySha256.Length-lt16){return $null}
    return (Join-Path $CacheRoot $ReplaySha256.Substring(0,16).ToUpperInvariant())
}
function New-NativeActionCacheReadResult {
    param([bool]$Ok,[string]$Status,[string]$Reason='',[object]$Cache=$null,[object]$Manifest=$null)
    return [pscustomobject]@{ok=$Ok;status=$Status;reason=$Reason;cache=$Cache;manifest=$Manifest}
}

function Read-NativeActionCache {
    param(
        [Parameter(Mandatory=$true)][string]$CacheRoot,
        [Parameter(Mandatory=$true)][string]$ReplaySha256,
        [Parameter(Mandatory=$true)][long]$SourceSizeBytes,
        [string]$ScannerContract=$script:RACScannerContract,
        [switch]$RequireTail
    )
    try{
        $dir=Get-NativeActionCacheDir -CacheRoot $CacheRoot -ReplaySha256 $ReplaySha256
        if($null-eq$dir){return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_cache_root_unspecified' -Reason 'cache root or replay sha is empty'}
        $manifestPath=Join-Path $dir 'manifest.json'
        $actionsPath=Join-Path $dir 'native_actions.json'
        $tailPath=Join-Path $dir 'native_action_tail.bin'
        if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_cache_missing' -Reason ('manifest not found: '+$manifestPath)}
        if(-not(Test-Path -LiteralPath $actionsPath -PathType Leaf)){return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_cache_missing' -Reason ('document not found: '+$actionsPath)}
        $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
        if([string](RAC-Prop $manifest 'contract')-ne$script:RACCacheContract){return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_cache_contract_mismatch' -Reason ('cached='+[string](RAC-Prop $manifest 'contract')+' expected='+$script:RACCacheContract) -Manifest $manifest}
        if([string](RAC-Prop $manifest 'scanner_contract')-ne$ScannerContract){return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_scanner_contract_mismatch' -Reason ('cached='+[string](RAC-Prop $manifest 'scanner_contract')+' expected='+[string]$ScannerContract) -Manifest $manifest}
        $manifestSource=RAC-Prop $manifest 'source'
        $cachedSha=[string](RAC-Prop $manifestSource 'sha256')
        if(-not[string]::Equals($cachedSha,$ReplaySha256,[StringComparison]::OrdinalIgnoreCase)){return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_cache_source_sha_mismatch' -Reason ('cached='+$cachedSha+' expected='+$ReplaySha256) -Manifest $manifest}
        $cachedSize=$(if($null-ne(RAC-Prop $manifestSource 'size_bytes')){[long](RAC-Prop $manifestSource 'size_bytes')}else{-1})
        if($cachedSize-ne$SourceSizeBytes){return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_cache_source_size_mismatch' -Reason ('cached='+[string]$cachedSize+' expected='+[string]$SourceSizeBytes) -Manifest $manifest}
        $window=RAC-Prop $manifest 'scan_window'
        $cachedFileLength=$(if($null-ne(RAC-Prop $window 'file_length')){[long](RAC-Prop $window 'file_length')}else{-1})
        if($cachedFileLength-ne$SourceSizeBytes){return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_cache_scan_window_mismatch' -Reason ('window file_length='+[string]$cachedFileLength+' expected='+[string]$SourceSizeBytes) -Manifest $manifest}

        $document=Get-Content -LiteralPath $actionsPath -Raw -Encoding UTF8|ConvertFrom-Json
        if([string](RAC-Prop $document 'contract')-ne$script:RACCacheContract){return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_cache_contract_mismatch' -Reason 'document contract mismatch' -Manifest $manifest}
        if([string](RAC-Prop $document 'scanner_contract')-ne$ScannerContract){return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_scanner_contract_mismatch' -Reason 'document scanner contract mismatch' -Manifest $manifest}
        $rebuilt=RAC-RebuildDocument -Document $document
        if(@($rebuilt.problems).Count-gt0){return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_cache_document_invalid' -Reason (@($rebuilt.problems)-join '; ') -Manifest $manifest}
        $declaredCandidates=$(if($null-ne(RAC-Prop $document 'drift_candidate_count')){[int](RAC-Prop $document 'drift_candidate_count')}else{-1})
        if($declaredCandidates-ne[int]$rebuilt.candidate_count){return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_cache_document_invalid' -Reason ('declared candidate count '+[string]$declaredCandidates+' != '+[string]$rebuilt.candidate_count) -Manifest $manifest}

        # The stored tail is raw evidence used when the scanner contract changes. A missing or
        # mismatched tail never changes semantics (the tables are self-contained), so it is
        # reported as an audit status instead of invalidating an otherwise usable cache.
        $tailStatus='unavailable'
        $tailSha=[string](RAC-Prop (RAC-Prop $manifest 'artifacts') 'tail_sha256')
        if(Test-Path -LiteralPath $tailPath -PathType Leaf){
            [byte[]]$tailBytes=Read-NativeActionTailBytes $tailPath
            # Recorded window is authoritative: scan_start_offset + actual tail length == file length.
            $expectedTail=[int]($SourceSizeBytes-[long](RAC-Prop $window 'scan_start_offset'))
            if($tailBytes.Length-ne$expectedTail){$tailStatus='length_mismatch'}
            elseif(-not[string]::IsNullOrWhiteSpace($tailSha)-and(RAC-Sha256Bytes $tailBytes)-ne$tailSha){$tailStatus='hash_mismatch'}
            else{$tailStatus='verified'}
        }
        if($RequireTail-and$tailStatus-ne'verified'){return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_cache_tail_invalid' -Reason $tailStatus -Manifest $manifest}

        $tableIndex=@{}
        foreach($t in @($rebuilt.effect_tables)){$tableIndex[[string]([long]$t.count_offset)]=$t}
        $cache=[pscustomobject]@{
            dir=$dir;manifest=$manifest;manifest_path=$manifestPath;actions_path=$actionsPath;tail_path=$tailPath
            contract=$script:RACCacheContract;scanner_contract=$ScannerContract
            source=[pscustomobject]@{sha256=$cachedSha;size_bytes=$cachedSize;last_write_utc=[string](RAC-Prop $manifestSource 'last_write_utc');file_name=[string](RAC-Prop $manifestSource 'file_name')}
            scan_window=[pscustomobject]@{file_length=$cachedFileLength;tail_bytes=[int](RAC-Prop $window 'tail_bytes');scan_start_offset=[long](RAC-Prop $window 'scan_start_offset');scan_end_offset=[long](RAC-Prop $window 'scan_end_offset')}
            candidates=$rebuilt.candidates;effect_tables=$rebuilt.effect_tables;table_index=$tableIndex
            candidate_count=[int]$rebuilt.candidate_count;effect_table_count=[int]$rebuilt.effect_table_count
            tail_path_status=$tailStatus;tail_sha256=$tailSha
        }
        return New-NativeActionCacheReadResult -Ok $true -Status 'native_action_cache_validated' -Cache $cache -Manifest $manifest
    } catch {
        return New-NativeActionCacheReadResult -Ok $false -Status 'native_action_cache_unreadable' -Reason $_.Exception.Message
    }
}
function Read-NativeActionTailBytes([string]$Path) {
    # Windows PowerShell 5.1 has no -AsByteStream; raw byte transport is explicit here.
    return [IO.File]::ReadAllBytes($Path)
}

function Write-NativeActionCache {
    param(
        [Parameter(Mandatory=$true)][string]$CacheRoot,
        [Parameter(Mandatory=$true)][string]$ReplaySha256,
        [Parameter(Mandatory=$true)][object]$Source,
        [Parameter(Mandatory=$true)][object]$Scan,
        [string]$CacheScope='persistent_project',
        [string]$ToolVersion='',
        [object]$PhysicalAudit=$null,
        [string]$ScannerContract=$script:RACScannerContract
    )
    $dir=Get-NativeActionCacheDir -CacheRoot $CacheRoot -ReplaySha256 $ReplaySha256
    if($null-eq$dir){throw 'Native action cache root or replay sha is empty.'}
    New-Item -ItemType Directory -Force -Path $dir|Out-Null

    $scanWindow=[ordered]@{
        file_length=[long]$Scan.file_length;tail_bytes=[int]$Scan.tail_bytes
        scan_start_offset=[long]$Scan.scan_start_offset;scan_end_offset=[long]$Scan.scan_end_offset
    }
    $document=RAC-BuildDocument -Candidates $Scan.candidates -EffectTables $Scan.effect_tables -Source $Source -ScanWindow $scanWindow -ScannerContract $ScannerContract
    $check=RAC-RebuildDocument -Document $document
    if(@($check.problems).Count-gt0){throw ('Native action cache document failed self-validation: '+(@($check.problems)-join '; '))}

    [byte[]]$tail=$Scan.tail
    if($null-eq$tail){$tail=New-Object byte[] 0}
    $tailPath=Join-Path $dir 'native_action_tail.bin'
    $tailTemp=$tailPath+'.tmp'
    [IO.File]::WriteAllBytes($tailTemp,$tail)
    RAC-MoveIntoPlace -TempPath $tailTemp -FinalPath $tailPath

    $actionsPath=Join-Path $dir 'native_actions.json'
    $actionsTemp=$actionsPath+'.tmp'
    RAC-WriteJson -Path $actionsTemp -Value $document -Depth 12
    RAC-MoveIntoPlace -TempPath $actionsTemp -FinalPath $actionsPath

    $driftIntervalCount=0
    foreach($c in @($check.candidates)){$driftIntervalCount+=[int]$c.interval_count}
    $effectRecordCount=0;$validEffectTableCount=0
    foreach($t in @($check.effect_tables)){$effectRecordCount+=[int]$t.record_count;if([bool]$t.valid){$validEffectTableCount++}}
    $manifest=[ordered]@{
        schema_version=1;contract=$script:RACCacheContract;scanner_contract=[string]$ScannerContract
        tool_version=[string]$ToolVersion;cache_scope=[string]$CacheScope
        created_at_utc=(Get-Date).ToUniversalTime().ToString('o')
        source=[ordered]@{
            sha256=[string](RAC-Prop $Source 'sha256');size_bytes=[long](RAC-Prop $Source 'size_bytes')
            last_write_utc=[string](RAC-Prop $Source 'last_write_utc');file_name=[string](RAC-Prop $Source 'file_name')
        }
        scan_window=$scanWindow
        counts=[ordered]@{
            drift_candidate_count=[int]$document.drift_candidate_count;effect_table_count=[int]$document.effect_table_count
            drift_interval_count=$driftIntervalCount;effect_record_count=$effectRecordCount;valid_effect_table_count=$validEffectTableCount
        }
        artifacts=[ordered]@{
            document='native_actions.json';tail='native_action_tail.bin'
            tail_bytes=$tail.Length;tail_sha256=(RAC-Sha256Bytes $tail)
        }
        # Audit metadata only: physical cache facts never gate native action cache validity.
        physical_audit=$(if($null-ne$PhysicalAudit){$PhysicalAudit}else{$null})
        evidence_rule='Raw replay-native action-object tables plus the exact scan tail window. No semantic labels are stored; all action semantics are re-derived from telemetry rows.'
    }
    $manifestPath=Join-Path $dir 'manifest.json'
    $manifestTemp=$manifestPath+'.tmp'
    RAC-WriteJson -Path $manifestTemp -Value $manifest -Depth 12
    # manifest last: a partially written cache directory is never considered valid.
    RAC-MoveIntoPlace -TempPath $manifestTemp -FinalPath $manifestPath

    # Verify the persisted raw evidence artifact by reading the manifest back and checking the
    # on-disk tail against it, so a rebuild run reports the same tail status a reuse run would.
    $tailStatus='verified'
    try{
        $manifestRead=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
        $artifacts=RAC-Prop $manifestRead 'artifacts'
        $declaredBytes=[int](RAC-Prop $artifacts 'tail_bytes')
        $declaredSha=[string](RAC-Prop $artifacts 'tail_sha256')
        if(-not(Test-Path -LiteralPath $tailPath -PathType Leaf)){$tailStatus='tail_missing_after_write'}
        else{
            [byte[]]$onDisk=[IO.File]::ReadAllBytes($tailPath)
            if($onDisk.Length-ne$declaredBytes){$tailStatus='tail_length_mismatch_after_write'}
            elseif((RAC-Sha256Bytes $onDisk)-ne$declaredSha){$tailStatus='tail_hash_mismatch_after_write'}
        }
    }catch{$tailStatus=('tail_verification_failed: '+$_.Exception.Message)}

    return [pscustomobject]@{
        dir=$dir;manifest_path=$manifestPath;actions_path=$actionsPath;tail_path=$tailPath
        tail_bytes=$tail.Length;tail_sha256=(RAC-Sha256Bytes $tail);tail_status=$tailStatus
    }
}

function Get-NativeActionTailForRescan {
    param(
        [Parameter(Mandatory=$true)][string]$CacheRoot,
        [Parameter(Mandatory=$true)][string]$ReplaySha256,
        [Parameter(Mandatory=$true)][long]$SourceSizeBytes,
        [int]$RequiredTailBytes=$script:RACDefaultTailBytes
    )
    $dir=Get-NativeActionCacheDir -CacheRoot $CacheRoot -ReplaySha256 $ReplaySha256
    if($null-eq$dir){return [pscustomobject]@{ok=$false;status='native_action_cache_root_unspecified';reason='';tail_path=$null;scan_start_offset=0;file_length=0;tail_bytes=0}}
    $manifestPath=Join-Path $dir 'manifest.json'
    $tailPath=Join-Path $dir 'native_action_tail.bin'
    if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return [pscustomobject]@{ok=$false;status='native_action_cache_missing';reason='';tail_path=$tailPath;scan_start_offset=0;file_length=0;tail_bytes=0}}
    try{$manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{return [pscustomobject]@{ok=$false;status='native_action_cache_unreadable';reason=$_.Exception.Message;tail_path=$tailPath;scan_start_offset=0;file_length=0;tail_bytes=0}}
    if([string](RAC-Prop $manifest 'contract')-ne$script:RACCacheContract){return [pscustomobject]@{ok=$false;status='native_action_cache_contract_mismatch';reason='';tail_path=$tailPath;scan_start_offset=0;file_length=0;tail_bytes=0}}
    $manifestSource=RAC-Prop $manifest 'source'
    if(-not[string]::Equals([string](RAC-Prop $manifestSource 'sha256'),$ReplaySha256,[StringComparison]::OrdinalIgnoreCase)){return [pscustomobject]@{ok=$false;status='native_action_cache_source_sha_mismatch';reason='';tail_path=$tailPath;scan_start_offset=0;file_length=0;tail_bytes=0}}
    if([long](RAC-Prop $manifestSource 'size_bytes')-ne$SourceSizeBytes){return [pscustomobject]@{ok=$false;status='native_action_cache_source_size_mismatch';reason='';tail_path=$tailPath;scan_start_offset=0;file_length=0;tail_bytes=0}}
    if(-not(Test-Path -LiteralPath $tailPath -PathType Leaf)){return [pscustomobject]@{ok=$false;status='native_action_cache_tail_missing';reason='';tail_path=$tailPath;scan_start_offset=0;file_length=0;tail_bytes=0}}
    $window=RAC-Prop $manifest 'scan_window'
    $fileLength=[long](RAC-Prop $window 'file_length')
    $scanStart=[long](RAC-Prop $window 'scan_start_offset')
    $tailBytes=[int](RAC-Prop $window 'tail_bytes')
    $actualLength=[long](Get-Item -LiteralPath $tailPath).Length
    if(($scanStart+$actualLength)-ne$fileLength){return [pscustomobject]@{ok=$false;status='native_action_cache_tail_window_mismatch';reason='';tail_path=$tailPath;scan_start_offset=$scanStart;file_length=$fileLength;tail_bytes=$actualLength}}
    if($fileLength-ne$SourceSizeBytes){return [pscustomobject]@{ok=$false;status='native_action_cache_scan_window_mismatch';reason='';tail_path=$tailPath;scan_start_offset=$scanStart;file_length=$fileLength;tail_bytes=$actualLength}}
    # A changed scanner contract may need a wider window than the stored tail covers.
    $requiredStart=[Math]::Max(0,$fileLength-[Math]::Max(32768,$RequiredTailBytes))
    if($scanStart-gt$requiredStart){return [pscustomobject]@{ok=$false;status='native_action_cache_tail_window_too_small';reason=('cached_start='+[string]$scanStart+' required_start='+[string]$requiredStart);tail_path=$tailPath;scan_start_offset=$scanStart;file_length=$fileLength;tail_bytes=$actualLength}}
    return [pscustomobject]@{ok=$true;status='native_action_cache_tail_usable';reason='';tail_path=$tailPath;scan_start_offset=$scanStart;file_length=$fileLength;tail_bytes=[int]$actualLength;declared_tail_bytes=$tailBytes}
}

function Get-NativeActionEffectTable {
    param([Parameter(Mandatory=$true)][object]$Scan,[Parameter(Mandatory=$true)][long]$CountOffset)
    if($null-eq$Scan){return $null}
    if($null-eq$Scan.table_index){return $null}
    $key=[string]$CountOffset
    if(-not$Scan.table_index.ContainsKey($key)){return $null}
    return $Scan.table_index[$key]
}

# ---------------------------------------------------------------------------
# orchestration used by the telemetry pipeline
# ---------------------------------------------------------------------------

function Resolve-NativeActionCacheScan {
    param(
        [Parameter(Mandatory=$true)][string]$ReplayPath,
        [Parameter(Mandatory=$true)][string]$CacheRoot,
        [Parameter(Mandatory=$true)][string]$ReplaySha256,
        [Parameter(Mandatory=$true)][long]$SourceSizeBytes,
        [string]$CacheScope='persistent_project',
        [string]$ToolVersion='',
        [object]$PhysicalAudit=$null,
        [switch]$Force,
        [int]$TailBytes=$script:RACDefaultTailBytes,
        [object]$Source=$null
    )
    $scannerContract=$script:RACScannerContract
    if($null-eq$Source){
        $Source=[ordered]@{sha256=$ReplaySha256;size_bytes=$SourceSizeBytes;last_write_utc='';file_name=[IO.Path]::GetFileName($ReplayPath)}
    }
    $lookupWatch=[Diagnostics.Stopwatch]::StartNew()
    $mode='';$readStatus='';$readReason='';$forced=[bool]$Force
    $scan=$null;$scanMs=0;$writeMs=0;$writeStatus=''
    $sourceRead=$false;$tailRescan=$false;$tailStatus='unavailable'
    if($Force){
        $mode='rebuilt';$readStatus='native_action_cache_bypassed_force_native_actions';$readReason='ForceNativeActions'
    } else {
        $read=Read-NativeActionCache -CacheRoot $CacheRoot -ReplaySha256 $ReplaySha256 -SourceSizeBytes $SourceSizeBytes -ScannerContract $scannerContract
        $readStatus=[string]$read.status;$readReason=[string]$read.reason
        if([bool]$read.ok){
            $mode='reuse';$tailStatus=[string]$read.cache.tail_path_status
            $scan=[pscustomobject]@{candidates=@($read.cache.candidates);effect_tables=@($read.cache.effect_tables);table_index=$read.cache.table_index;file_length=$read.cache.scan_window.file_length;tail_bytes=$read.cache.scan_window.tail_bytes;scan_start_offset=$read.cache.scan_window.scan_start_offset;scan_end_offset=$read.cache.scan_window.scan_end_offset;tail=$null}
        } elseif($read.status-eq'native_action_scanner_contract_mismatch'){
            # Scanner rule changes must re-parse the persisted raw tail instead of re-reading the replay.
            $tail=Get-NativeActionTailForRescan -CacheRoot $CacheRoot -ReplaySha256 $ReplaySha256 -SourceSizeBytes $SourceSizeBytes -RequiredTailBytes $TailBytes
            if([bool]$tail.ok){
                $scanWatch=[Diagnostics.Stopwatch]::StartNew()
                $scan=New-NativeActionScanFromTail -TailPath $tail.tail_path -ScanStartOffset $tail.scan_start_offset -FileLength $tail.file_length -TailBytes $TailBytes
                $scanMs=[long]$scanWatch.ElapsedMilliseconds
                $mode='rebuilt_from_tail';$tailRescan=$true;$tailStatus='reused_for_rescan'
            } else {
                $tailStatus=[string]$tail.status
            }
        }
    }
    $lookupMs=[long]$lookupWatch.ElapsedMilliseconds

    if($null-eq$scan){
        if($mode-eq''){$mode='rebuilt'}
        $scanWatch=[Diagnostics.Stopwatch]::StartNew()
        $scan=New-NativeActionScan -ReplayPath $ReplayPath -TailBytes $TailBytes
        $scanMs=[long]$scanWatch.ElapsedMilliseconds
        $sourceRead=$true
    }

    if($mode-ne'reuse'){
        $writeWatch=[Diagnostics.Stopwatch]::StartNew()
        try{
            $written=Write-NativeActionCache -CacheRoot $CacheRoot -ReplaySha256 $ReplaySha256 -Source $Source -Scan $scan -CacheScope $CacheScope -ToolVersion $ToolVersion -PhysicalAudit $PhysicalAudit -ScannerContract $scannerContract
            $writeStatus='written'
            $tailStatus=[string]$written.tail_status
        }catch{
            $writeStatus=('failed: '+$_.Exception.Message)
            Write-Warning ('Native action cache write failed (analysis continues with in-memory scan): '+$_.Exception.Message)
        }
        $writeMs=[long]$writeWatch.ElapsedMilliseconds
    }

    if($null-eq$scan.table_index){
        $index=@{}
        foreach($t in @($scan.effect_tables)){$index[[string]([long]$t.count_offset)]=$t}
        $scan|Add-Member -NotePropertyName table_index -NotePropertyValue $index -Force
    }
    return [pscustomobject]@{
        mode=$mode;forced=$forced;status=$readStatus;reason=$readReason
        cache_dir=(Get-NativeActionCacheDir -CacheRoot $CacheRoot -ReplaySha256 $ReplaySha256)
        scope=[string]$CacheScope;contract=$script:RACCacheContract;scanner_contract=$scannerContract
        lookup_ms=$lookupMs;scan_ms=$scanMs;write_ms=$writeMs;write_status=$writeStatus
        source_read=$sourceRead;tail_rescan=$tailRescan;tail_status=$tailStatus
        candidates=@($scan.candidates);effect_tables=@($scan.effect_tables);table_index=$scan.table_index
        candidate_count=@($scan.candidates).Count;effect_table_count=@($scan.effect_tables).Count
        scan_window=[pscustomobject]@{file_length=[long]$scan.file_length;tail_bytes=[int]$scan.tail_bytes;scan_start_offset=[long]$scan.scan_start_offset;scan_end_offset=[long]$scan.scan_end_offset}
    }
}

# ---------------------------------------------------------------------------
# audit
# ---------------------------------------------------------------------------

function Test-NativeActionCacheAgainstSource {
    param(
        [Parameter(Mandatory=$true)][string]$CacheRoot,
        [Parameter(Mandatory=$true)][string]$ReplaySha256,
        [Parameter(Mandatory=$true)][string]$ReplayPath,
        [string]$ScannerContract=$script:RACScannerContract,
        [int]$TailBytes=$script:RACDefaultTailBytes
    )
    $problems=New-Object System.Collections.Generic.List[string]
    if(-not(Test-Path -LiteralPath $ReplayPath -PathType Leaf)){return [pscustomobject]@{ok=$false;problems=@('replay not found: '+$ReplayPath)}}
    $size=[long](Get-Item -LiteralPath $ReplayPath).Length
    $read=Read-NativeActionCache -CacheRoot $CacheRoot -ReplaySha256 $ReplaySha256 -SourceSizeBytes $size -ScannerContract $ScannerContract -RequireTail
    if(-not[bool]$read.ok){return [pscustomobject]@{ok=$false;problems=@('cache unavailable: '+[string]$read.status+' '+[string]$read.reason)}}
    $fresh=New-NativeActionScan -ReplayPath $ReplayPath -TailBytes $TailBytes
    # Compare candidates/tables/window only: the cached source block is reused for both documents so
    # the audit never depends on volatile metadata such as the last-write timestamp.
    $cachedDoc=RAC-BuildDocument -Candidates $read.cache.candidates -EffectTables $read.cache.effect_tables -Source $read.cache.source -ScanWindow $read.cache.scan_window -ScannerContract $ScannerContract
    $freshWindow=[ordered]@{file_length=[long]$fresh.file_length;tail_bytes=[int]$fresh.tail_bytes;scan_start_offset=[long]$fresh.scan_start_offset;scan_end_offset=[long]$fresh.scan_end_offset}
    $freshDoc=RAC-BuildDocument -Candidates $fresh.candidates -EffectTables $fresh.effect_tables -Source $read.cache.source -ScanWindow $freshWindow -ScannerContract $ScannerContract
    $cachedJson=($cachedDoc|ConvertTo-Json -Depth 12)
    $freshJson=($freshDoc|ConvertTo-Json -Depth 12)
    if($cachedJson-ne$freshJson){$problems.Add('cached candidate/table document differs from a fresh scan of the source replay')}
    [byte[]]$freshTail=$fresh.tail
    [byte[]]$cachedTail=[IO.File]::ReadAllBytes((Join-Path $read.cache.dir 'native_action_tail.bin'))
    if($freshTail.Length-ne$cachedTail.Length){$problems.Add('cached raw tail length differs from the fresh scan window')}
    else{
        for($i=0;$i-lt$freshTail.Length;$i++){if($freshTail[$i]-ne$cachedTail[$i]){$problems.Add('cached raw tail bytes differ from the source tail window');break}}
    }
    return [pscustomobject]@{ok=(@($problems).Count-eq0);problems=$problems.ToArray()}
}
