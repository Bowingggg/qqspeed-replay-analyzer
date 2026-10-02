# Production native action semantics.
#
# Promotes the replay-native Action Event Table from research evidence to the PRODUCTION
# authority for air boost / landing boost / CW / WCW / CWW, and demotes the timing-based
# legacy combo detector (ReplayNativeComboActions.ps1) to a diagnostic/disagreement layer.
#
# This module owns three things and nothing else:
#   1. window sourcing for the action event table (cached raw tail first, SAV tail second),
#   2. the production semantic rules (each threshold carries its gold evidence),
#   3. the raw / logical / unresolved accounting the analysis and the frontend consume.
#
# Definition-only module: no runtime actions at import scope.
#
# ---------------------------------------------------------------------------
# Authority rules and their gold evidence (Gold A = Old Street Pipeline, Gold B = City Torch)
# ---------------------------------------------------------------------------
#   code 8                 -> air boost (空喷)       Gold A 5/5, Gold B 3/3 vs game truth
#   code 9                 -> landing boost (落地喷) Gold A 4/4, Gold B 1/1 vs game truth
#   code 19                -> WCW marker             Gold A 3/3, Gold B 6/6 human CW/WCW/CWW
#   code 24                -> CW / WCW / CWW common native combo marker
#   code 25 grouped with a code 24 -> CW             Gold A 3/3, Gold B 5/5 human
#   code 24 with a grouped code 19 -> WCW
#   remaining code 24      -> CWW                    Gold A 10-3-3=4, Gold B 19-5-6=8 human
#
# The code25/code24 grouping is NOT a raw count: code25 also occurs standalone (Gold B: 10 raw
# code25, 5 paired, 5 standalone). Native record adjacency alone is provably insufficient -
# in Gold B, code24 #70 (t=121620) and code25 #71 (t=122470) are consecutive records yet the
# human count requires them NOT to pair (850 ms). So the rule needs exactly one small,
# evidence-bounded tolerance:
#   * largest gap inside an accepted pair      : 283 ms (Gold A code25 t=46801 / code24 t=47084)
#   * smallest gap of a rejected standalone    : 850 ms (Gold B code24 t=121620 / code25 t=122470)
#   -> 500 ms sits inside the observed gap. The pairing additionally requires native cluster
#      order: no code24/code19 record may lie strictly between the two events.
#
# Drift logical grouping (raw native Drift interval -> logical Drift action):
#   * Gold A has one run of 7 consecutive short retrigger intervals; 28 - 7 + 1 = 22 = game drift.
#   * merged pairs: duration <= 500 ms on BOTH sides AND gap <= 100 ms.
#     evidence: the longest interval inside the merged run is 417 ms while the shortest interval
#     that must stay separate is 600 ms (Gold B) -> 500 sits between them; the largest gap inside
#     the merged run is 67 ms while the smallest gap between intervals that must stay separate is
#     217 ms (Gold B) -> 100 sits between them. Gold B has no qualifying pair, so it stays 34/34.
#   Only the native Drift timeline is used: no XY, no route shape, no curvature, no map geometry.
#
# ---------------------------------------------------------------------------
# Settlement parity (raw evidence vs game-facing count) - what is closed and what is not
# ---------------------------------------------------------------------------
#   * air / landing            : closed (code8 / code9 counts equal the game truth).
#   * combo CW/WCW/CWW         : closed (both gold replays equal the human count).
#   * Drift                    : closed (logical count equals the game count in both gold replays).
#   * small boost (code 2001)  : NOT closed. Gold A: 27 raw = 18 normal + 5 air + 4 landing, exactly
#     the game numbers. Gold B: 46 raw vs 35 normal + 3 air + 1 landing = 39 -> 7 intervals are
#     unexplained. The pipeline therefore publishes raw_effect_count / anchored / unresolved and
#     does NOT invent a game-facing normal-small-boost number.
#   * Nitro (code 1)           : NOT closed. Game nitro exceeds the native code1 interval count by
#     exactly one in BOTH gold replays (12 vs 11, 22 vs 21). No native evidence for the missing
#     activation was found, so the raw count is published with parity_delta/parity_status unresolved
#     instead of a "+1" fudge.

$script:RNASContract='production_native_action_semantics_v1'
$script:RNASCwPairToleranceMs=500
$script:RNASCwPairToleranceEvidence='paired max gap 283ms (Gold A 46801/47084); standalone min gap 850ms (Gold B 121620/122470)'
$script:RNASDriftRetriggerMaxMs=500
$script:RNASDriftRetriggerGapMs=100
$script:RNASDriftGroupingEvidence='merged run: 7 intervals, durations 417..16ms, gaps 0..67ms; must-stay-separate: shortest interval 600ms, smallest gap 217ms (Gold B)'
$script:RNASAnchorToleranceMs=2
$script:RNASAnchorToleranceEvidence='code8/code9/code19/code24 all land exactly on a code2001 interval start (delta 0..1ms) in both gold replays'

# ---------------------------------------------------------------------------
# Semantic alignment gate (replay variant detection)
# ---------------------------------------------------------------------------
# The archive-wide cross-replay consistency test for the action event table is the code2001
# interval start: codes 2/8/9/18/19/20/24 land on (or 1 ms before) a code2001 interval start.
# The relation is all-or-nothing per replay. Two archived replays fail it completely
# (0/40 `雪境裂渊-20260924-223202`, 0/45 `风林火山-20260924-224701`), and both come from the
# same 2026-09-24 recording session; a constant time-base offset does not recover the relation
# for either (best fit 4/45 at +985 ms and 3/40 at -1150 ms), so it is a variant, not a shift.
# Those replays must therefore NOT publish game-facing action counts derived from this table:
# the raw evidence stays, the semantics fail closed (see `variant_unvalidated`).
$script:RNASAlignmentMinRate=0.5
$script:RNASAlignmentEvidence='aligned archived replays 1.000 (9/9, 22/22, 32/32, 36/36, 37/37); variant replays 0.000 (0/40 雪境裂渊-20260924-223202, 0/45 风林火山-20260924-224701); a constant time-base offset does not recover it (best 4/45 @ +985ms, 3/40 @ -1150ms)'

function Get-ReplayNativeActionSemanticsContract { return $script:RNASContract }
function Get-ReplayNativeActionSemanticAlignmentAnchorCodes { return @(2,8,9,18,19,20,24) }
function Get-ReplayNativeActionCwPairToleranceMs { return [int]$script:RNASCwPairToleranceMs }
function Get-ReplayNativeActionDriftRetriggerMaxMs { return [int]$script:RNASDriftRetriggerMaxMs }
function Get-ReplayNativeActionDriftRetriggerGapMs { return [int]$script:RNASDriftRetriggerGapMs }

# ---------------------------------------------------------------------------
# window sourcing: the decoder may run on a window instead of the whole file
# ---------------------------------------------------------------------------

# Reads at most NeedBytes from the END of a file and reports the absolute offset of byte 0.
function Read-ReplayNativeActionTailWindow {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][long]$NeedBytes,
        [long]$KnownFileLength=-1
    )
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    $fs=$null
    try {
        # FileShare::ReadWrite|Delete: reading a tail must never block another process.
        $fs=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $len=[long]$fs.Length
        if($KnownFileLength-ge0-and$KnownFileLength-ne$len){return $null}
        $start=[Math]::Max([long]0,$len-$NeedBytes)
        $count=[int]($len-$start)
        [byte[]]$buf=New-Object byte[] $count
        [void]$fs.Seek($start,[IO.SeekOrigin]::Begin)
        $read=0
        while($read-lt$count){
            $n=$fs.Read($buf,$read,$count-$read)
            if($n-le0){break}
            $read+=$n
        }
        if($read-ne$count){return $null}
        return [pscustomobject]@{bytes=$buf;buffer_offset=$start;file_length=$len}
    } catch {
        return $null
    } finally {
        if($null-ne$fs){try{$fs.Dispose()}catch{}}
    }
}

# Decodes the production action event table without reading the whole replay:
# the native-action cache tail window is used first (zero SAV access on a warm run); otherwise
# only the container tail needed to make the structural locator exact is read from the SAV.
function Get-ReplayNativeActionEventTableFromWindow {
    param(
        [Parameter(Mandatory=$true)][string]$ReplayPath,
        [long]$FileLength=-1,
        [string]$CachedTailPath='',
        [long]$CachedTailStartOffset=-1,
        [int]$MaxRecords=0,
        [int]$TrailerBytes=0
    )
    if($MaxRecords-le0){$MaxRecords=[int](Get-ReplayNativeActionEventMaxRecords)}
    if($TrailerBytes-le0){$TrailerBytes=[int](Get-ReplayNativeActionEventTrailerBytes)}
    # Minimum window that keeps the fixed-point locator equivalent to a whole-file read.
    $need=[Math]::Max([long]65536,(4L+12L*[long]$MaxRecords+[long]$TrailerBytes))

    if(-not[string]::IsNullOrWhiteSpace($CachedTailPath)-and$CachedTailStartOffset-ge0){
        $window=Read-ReplayNativeActionTailWindow -Path $CachedTailPath -NeedBytes $need
        if($null-ne$window){
            # The cached tail must be the tail of THIS container.
            $expectedStart=[long]$window.file_length-[long]$window.bytes.Length
            if($expectedStart-eq[long]$CachedTailStartOffset-and($FileLength-lt0-or[long]$window.file_length-eq$FileLength)){
                $t=Get-ReplayNativeActionEventTable -Data $window.bytes -MaxRecords $MaxRecords -TrailerBytes $TrailerBytes -BufferOffset ([long]$window.buffer_offset) -FileLength ([long]$window.file_length)
                if([bool]$t.available){
                    $t|Add-Member -NotePropertyName window_source -NotePropertyValue 'native_action_cache_tail' -Force
                    return $t
                }
            }
        }
    }
    $window=Read-ReplayNativeActionTailWindow -Path $ReplayPath -NeedBytes $need -KnownFileLength $FileLength
    if($null-eq$window){
        $t=Get-ReplayNativeActionEventTable -ReplayPath $ReplayPath -MaxRecords $MaxRecords -TrailerBytes $TrailerBytes
        $t|Add-Member -NotePropertyName window_source -NotePropertyValue 'whole_file_read' -Force
        return $t
    }
    $t=Get-ReplayNativeActionEventTable -Data $window.bytes -MaxRecords $MaxRecords -TrailerBytes $TrailerBytes -BufferOffset ([long]$window.buffer_offset) -FileLength ([long]$window.file_length)
    $t|Add-Member -NotePropertyName window_source -NotePropertyValue 'replay_sav_tail' -Force
    return $t
}

# ---------------------------------------------------------------------------
# production semantic rules
# ---------------------------------------------------------------------------

# Replay-variant gate. Returns the code2001-alignment status that decides whether the action
# event table of THIS replay may publish game-facing action counts.
function Get-ReplayNativeActionSemanticAlignment {
    param(
        [object]$Table=$null,
        [AllowEmptyCollection()][object[]]$EffectIntervals=@()
    )
    $starts=New-Object System.Collections.Generic.List[long]
    foreach($iv in @($EffectIntervals)){
        if($null-eq$iv){continue}
        if([double]$iv.effect_code-eq2001.0){$starts.Add([long]$iv.start_ms)}
    }
    $anchorCodes=@(2,8,9,18,19,20,24)
    $anchorEvents=New-Object System.Collections.Generic.List[long]
    if($null-ne$Table-and[bool]$Table.available){
        foreach($e in @($Table.events)){
            $c=[long]$e.action_code
            if($anchorCodes -contains $c){$anchorEvents.Add([long]$e.time_ms)}
        }
    }
    $tol=[long]$script:RNASAnchorToleranceMs
    $aligned=0
    foreach($t in @($anchorEvents.ToArray())){
        foreach($s in @($starts.ToArray())){ if([Math]::Abs($t-$s)-le$tol){$aligned++;break} }
    }
    $anchorCount=$anchorEvents.Count
    $startCount=$starts.Count
    $rate=$null
    if($anchorCount-gt0){$rate=[Math]::Round($aligned/[double]$anchorCount,6)}
    $status='aligned'
    if($anchorCount-eq0){$status='not_applicable_no_anchor_code_events'}
    elseif($startCount-eq0){$status='not_applicable_no_code2001_effect_intervals'}
    elseif($rate-lt[double]$script:RNASAlignmentMinRate){$status='variant_mismatch'}
    return [pscustomobject][ordered]@{
        contract='native_action_semantic_alignment_v1'
        criterion='an anchor-code occurrence lands within '+[string]$tol+' ms of a code2001 interval start'
        anchor_codes=@($anchorCodes)
        anchor_event_count=$anchorCount
        aligned_anchor_event_count=$aligned
        alignment_rate=$rate
        code2001_interval_count=$startCount
        min_rate=[double]$script:RNASAlignmentMinRate
        status=$status
        game_facing_allowed=($status-eq'aligned'-or$status-like'not_applicable*')
        evidence=$script:RNASAlignmentEvidence
    }
}

# Raw toggle-stream audit: an effect-table interval count is only trustworthy as a *native fact*
# when every `state=1` record of that code is matched by a `state=0` record. This is what proves
# the published raw code2001 / code1 counts are the table's own content and not a pairing artifact.
function Get-ReplayNativeEffectToggleBalance {
    param([object]$Table=$null)
    $out=New-Object System.Collections.Generic.List[object]
    if($null-eq$Table-or-not[bool]$Table.valid){return @()}
    $recs=@($Table.records)
    foreach($code in @($Table.effect_codes|ForEach-Object{[double]$_.effect_code}|Sort-Object -Unique)){
        $sel=@($recs|Where-Object{[double]$_.effect_code-eq[double]$code}|Sort-Object time_ms)
        $opens=@($sel|Where-Object{[int]$_.state-eq1}).Count
        $closes=@($sel|Where-Object{[int]$_.state-eq0}).Count
        $ivCount=@($Table.intervals|Where-Object{[double]$_.effect_code-eq[double]$code}).Count
        $out.Add([pscustomobject][ordered]@{
            effect_code=[double]$code
            open_record_count=$opens
            close_record_count=$closes
            interval_count=$ivCount
            balanced=($opens-eq$closes)
            interval_count_matches_open_records=($ivCount-eq$opens)
        })
    }
    return @($out.ToArray())
}

# CW grouping: pair each code25 with the nearest unused code24 that is (a) inside the
# evidence-bounded tolerance and (b) in the same native action cluster (no code24/code19 record
# strictly between the two events). Deterministic: nearest first, then lowest record index.
function Get-ReplayNativeActionEventComboGrouping {
    param(
        [Parameter(Mandatory=$true)][object]$Table,
        [int]$PairToleranceMs=$script:RNASCwPairToleranceMs
    )
    $unavailable=[ordered]@{
        contract='production_native_action_combo_v1';available=$false
        cw=0;wcw=0;cww=0;code24_count=0;code19_count=0;code25_count=0
        code25_paired=@();code25_standalone=@();code24_unassigned=@()
        marker_accounting_consistent=$false;pair_tolerance_ms=$PairToleranceMs
        pair_tolerance_evidence=$script:RNASCwPairToleranceEvidence
    }
    if($null-eq$Table-or-not[bool]$Table.available){return [pscustomobject]$unavailable}
    $events=@($Table.events)
    $markers=@($events|Where-Object{[long]$_.action_code-eq24})
    $wcwEvents=@($events|Where-Object{[long]$_.action_code-eq19})
    $cwEvents=@($events|Where-Object{[long]$_.action_code-eq25})

    $used=New-Object 'System.Collections.Generic.HashSet[int]'
    foreach($m in $markers){[void]$used.Add(-1)}   # no-op guard; markers are addressed by record_index below
    $usedMarkers=New-Object 'System.Collections.Generic.HashSet[int]'
    $paired=New-Object System.Collections.Generic.List[object]
    $standalone=New-Object System.Collections.Generic.List[object]

    # Nearest code24 first: sort the code25 candidates by their best achievable delta so the
    # greedy assignment cannot be order-dependent.
    $candidates=New-Object System.Collections.Generic.List[object]
    foreach($c in $cwEvents){
        $best=$null;$bestDelta=[long]::MaxValue
        foreach($m in $markers){
            $delta=[Math]::Abs([long]$c.time_ms-[long]$m.time_ms)
            if($delta-lt$bestDelta){$bestDelta=$delta;$best=$m}
        }
        $candidates.Add([pscustomobject]@{event=$c;best_marker=$best;best_delta=$bestDelta})
    }
    foreach($cand in @($candidates.ToArray()|Sort-Object best_delta,@{Expression={[int]$_.event.record_index}})){
        $c=$cand.event
        $chosen=$null;$chosenDelta=[long]::MaxValue
        foreach($m in $markers){
            $idx=[int]$m.record_index
            if($usedMarkers.Contains($idx)){continue}
            $delta=[Math]::Abs([long]$c.time_ms-[long]$m.time_ms)
            if($delta-gt[long]$PairToleranceMs){continue}
            # Same native action cluster: no code24/code19 record strictly between the pair.
            $blocked=$false
            $lo=[Math]::Min([int]$c.record_index,$idx);$hi=[Math]::Max([int]$c.record_index,$idx)
            foreach($e in $events){
                $ri=[int]$e.record_index
                if($ri-le$lo-or$ri-ge$hi){continue}
                if([long]$e.action_code-eq24-or[long]$e.action_code-eq19){$blocked=$true;break}
            }
            if($blocked){continue}
            if($delta-lt$chosenDelta){$chosenDelta=$delta;$chosen=$m}
        }
        if($null-ne$chosen){
            [void]$usedMarkers.Add([int]$chosen.record_index)
            $paired.Add([pscustomobject][ordered]@{
                code25_record_index=[int]$c.record_index;code25_time_ms=[long]$c.time_ms
                code24_record_index=[int]$chosen.record_index;code24_time_ms=[long]$chosen.time_ms;delta_ms=$chosenDelta
            })
        } else {
            $standalone.Add([pscustomobject][ordered]@{
                code25_record_index=[int]$c.record_index;code25_time_ms=[long]$c.time_ms
                nearest_code24_delta_ms=$(if($null-ne$cand.best_marker){[long]$cand.best_delta}else{$null})
            })
        }
    }

    # WCW markers. A code19 IS the WCW marker; the gold evidence adds a structural requirement
    # that each code19 is record-ADJACENT to a code24 (no tolerance needed), which also documents
    # the one native pattern where two code19 events bracket a single code24 (Gold B #43/#44/#45:
    # t=78403 / 81153 / 81153). A shared marker is therefore counted for both WCW events, and the
    # marker accounting below consumes WCW by count instead of by unique assignment.
    $wcwAdjacent=0
    foreach($w in $wcwEvents){
        $ri=[int]$w.record_index
        $ok=$false
        foreach($m in $markers){
            if([Math]::Abs([int]$m.record_index-$ri)-eq1){$ok=$true;break}
        }
        if($ok){$wcwAdjacent++}
    }
    $wcw=$wcwEvents.Count
    $cw=$paired.Count
    $consumedForWcw=[Math]::Min($wcw,[Math]::Max(0,$markers.Count-$cw))
    $cww=$markers.Count-$cw-$consumedForWcw
    $unassigned=New-Object System.Collections.Generic.List[object]
    $remaining=$markers.Count-$cw-$consumedForWcw
    $skip=$cw+$consumedForWcw
    for($i=0;$i -lt$markers.Count;$i++){
        if($i-lt$skip){continue}
        $unassigned.Add([pscustomobject][ordered]@{record_index=[int]$markers[$i].record_index;time_ms=[long]$markers[$i].time_ms})
    }
    return [pscustomobject][ordered]@{
        contract='production_native_action_combo_v1';available=$true
        cw=$cw;wcw=$wcw;cww=$cww
        code24_count=$markers.Count;code19_count=$wcwEvents.Count;code25_count=$cwEvents.Count
        code19_record_adjacent_to_code24=$wcwAdjacent
        wcw_adjacency_valid=($wcwAdjacent-eq$wcwEvents.Count)
        code25_paired=@($paired.ToArray());code25_standalone=@($standalone.ToArray());code24_unassigned=@($unassigned.ToArray())
        marker_accounting_consistent=(($cw+$wcw+$cww)-eq$markers.Count)
        pair_tolerance_ms=$PairToleranceMs
        pair_tolerance_evidence=$script:RNASCwPairToleranceEvidence
    }
}

# Logical drift grouping from the native Drift intervals only (see the header evidence).
function Get-ReplayNativeDriftLogicalGrouping {
    param(
        [AllowEmptyCollection()][object[]]$Intervals=@(),
        [int]$RetriggerMaxMs=$script:RNASDriftRetriggerMaxMs,
        [int]$RetriggerGapMs=$script:RNASDriftRetriggerGapMs
    )
    $rows=@($Intervals)
    $groups=New-Object System.Collections.Generic.List[object]
    if($rows.Count-eq0){
        return [pscustomobject][ordered]@{raw_count=0;logical_count=0;merged_group_count=0;groups=@();retrigger_max_ms=$RetriggerMaxMs;retrigger_gap_ms=$RetriggerGapMs;evidence=$script:RNASDriftGroupingEvidence}
    }
    $current=New-Object System.Collections.Generic.List[object]
    $current.Add($rows[0])
    for($i=1;$i -lt$rows.Count;$i++){
        $prev=$rows[$i-1];$cur=$rows[$i]
        $gap=[long]$cur.start_ms-[long]$prev.end_ms
        $bothShort=([long]$prev.duration_ms-le[long]$RetriggerMaxMs-and[long]$cur.duration_ms-le[long]$RetriggerMaxMs)
        if($bothShort-and$gap-le[long]$RetriggerGapMs-and$gap-ge-60000L){
            $current.Add($cur)
        } else {
            $groups.Add([pscustomobject]@{items=@($current.ToArray())})
            $current=New-Object System.Collections.Generic.List[object]
            $current.Add($cur)
        }
    }
    $groups.Add([pscustomobject]@{items=@($current.ToArray())})
    $out=New-Object System.Collections.Generic.List[object]
    $id=1
    foreach($g in @($groups.ToArray())){
        $items=@($g.items)
        $startMs=[long]::MaxValue;$endMs=0L;$durSum=0L
        foreach($it in $items){
            if([long]$it.start_ms-lt$startMs){$startMs=[long]$it.start_ms}
            if([long]$it.end_ms-gt$endMs){$endMs=[long]$it.end_ms}
            $durSum+=[long]$it.duration_ms
        }
        $out.Add([pscustomobject][ordered]@{
            id=$id;raw_interval_count=$items.Count;merged=($items.Count-gt1)
            start_ms=$startMs;end_ms=$endMs;duration_ms=($endMs-$startMs);raw_duration_sum_ms=$durSum
        })
        $id++
    }
    $mergedCount=@($out.ToArray()|Where-Object{[bool]$_.merged}).Count
    return [pscustomobject][ordered]@{
        raw_count=$rows.Count;logical_count=$out.Count;merged_group_count=$mergedCount;groups=@($out.ToArray())
        retrigger_max_ms=$RetriggerMaxMs;retrigger_gap_ms=$RetriggerGapMs;evidence=$script:RNASDriftGroupingEvidence
    }
}

# Evidence matrix for the action codes that carry no production semantics.
# Facts only: per-code counts plus how each occurrence relates to the native anchors.
function Get-NativeActionCodeEvidenceMatrix {
    param(
        [Parameter(Mandatory=$true)][object]$Table,
        [AllowEmptyCollection()][object[]]$EffectIntervals=@(),
        [AllowEmptyCollection()][object[]]$DriftIntervals=@()
    )
    if($null-eq$Table-or-not[bool]$Table.available){return @()}
    $events=@($Table.events)
    $code1=@($EffectIntervals|Where-Object{[double]$_.effect_code-eq1.0})
    $code2001=@($EffectIntervals|Where-Object{[double]$_.effect_code-eq2001.0})
    $markers=@($events|Where-Object{[long]$_.action_code-eq24})
    $c8=@($events|Where-Object{[long]$_.action_code-eq8})
    $c9=@($events|Where-Object{[long]$_.action_code-eq9})
    $rows=New-Object System.Collections.Generic.List[object]
    foreach($code in @($Table.action_codes)){
        $set=@($events|Where-Object{[long]$_.action_code-eq[long]$code})
        $on2001=0;$onCode1=0;$onDriftStart=0;$onDriftEnd=0;$onMarker=0;$onAir=0;$onLanding=0
        foreach($e in $set){
            $t=[long]$e.time_ms
            foreach($iv in $code2001){if([Math]::Abs($t-[long]$iv.start_ms)-le[long]$script:RNASAnchorToleranceMs){$on2001++;break}}
            foreach($iv in $code1){if([Math]::Abs($t-[long]$iv.start_ms)-le[long]$script:RNASAnchorToleranceMs){$onCode1++;break}}
            foreach($iv in $DriftIntervals){
                if([Math]::Abs($t-[long]$iv.start_ms)-le[long]$script:RNASAnchorToleranceMs){$onDriftStart++;break}
            }
            foreach($iv in $DriftIntervals){
                if([Math]::Abs($t-[long]$iv.end_ms)-le[long]$script:RNASAnchorToleranceMs){$onDriftEnd++;break}
            }
            foreach($m in $markers){if([Math]::Abs($t-[long]$m.time_ms)-le[long]$script:RNASAnchorToleranceMs){$onMarker++;break}}
            foreach($m in $c8){if([Math]::Abs($t-[long]$m.time_ms)-le[long]$script:RNASAnchorToleranceMs){$onAir++;break}}
            foreach($m in $c9){if([Math]::Abs($t-[long]$m.time_ms)-le[long]$script:RNASAnchorToleranceMs){$onLanding++;break}}
        }
        $rows.Add([pscustomobject][ordered]@{
            action_code=[long]$code;count=$set.Count
            on_code2001_start=$on2001;on_code1_start=$onCode1
            on_drift_start=$onDriftStart;on_drift_end=$onDriftEnd
            on_code24=$onMarker;on_code8=$onAir;on_code9=$onLanding
            semantic='unknown'
        })
    }
    return @($rows.ToArray())
}

# ---------------------------------------------------------------------------
# production assembly
# ---------------------------------------------------------------------------

# Assembles the production action contract from native evidence only.
#
# Fail-closed on two levels:
#   1. when the native action event table is unavailable every action count stays $null and the
#      authority is reported as unavailable. The legacy timing detector is NEVER used as a
#      fallback - it is published beside the production values as a diagnostic candidate.
#   2. when the table decodes but fails the code2001 semantic-alignment gate (a replay variant),
#      the game-facing counts are withheld (`status=production_semantics_variant_unvalidated`,
#      `game_facing_available=false`) while every raw native count stays published.
function Resolve-ReplayNativeActionSemantics {
    param(
        [object]$ActionEvents=$null,
        [AllowEmptyCollection()][object[]]$EffectIntervals=@(),
        [AllowEmptyCollection()][object[]]$DriftIntervals=@(),
        [object]$EffectTable=$null,
        [object]$LegacyCombos=$null,
        # Availability of the two native action-object tables. A table that was never decoded is NOT
        # the same as a validated empty table: an unavailable table must publish $null, never 0
        # ("unavailable is not zero"). Callers pass the decoder's own availability flag.
        [bool]$DriftTableAvailable=$true,
        [bool]$EffectTableAvailable=$true,
        [int]$ContactAirBoostCount=-1,
        [int]$ContactLandingBoostCount=-1,
        [int]$NitroCtrlRiseCount=-1,
        [int]$NitroCtrlMatchCount=-1,
        [int]$NitroCtrlMatchFraction=-1
    )
    $eventsAvailable=($null-ne$ActionEvents-and[bool]$ActionEvents.available)
    $alignment=Get-ReplayNativeActionSemanticAlignment -Table $ActionEvents -EffectIntervals $EffectIntervals
    $gameFacing=([bool]$alignment.game_facing_allowed-and$eventsAvailable)
    $combo=Get-ReplayNativeActionEventComboGrouping -Table $ActionEvents
    $drift=Get-ReplayNativeDriftLogicalGrouping -Intervals $DriftIntervals
    $toggleBalance=Get-ReplayNativeEffectToggleBalance -Table $EffectTable
    $driftTableAvailable=[bool]$DriftTableAvailable
    $effectTableAvailable=[bool]$EffectTableAvailable

    $air=$(if($gameFacing){[int]$ActionEvents.histogram['8']}else{$null})
    $landing=$(if($gameFacing){[int]$ActionEvents.histogram['9']}else{$null})

    # --- small-boost class (code 2001) -------------------------------------
    $raw2001=0;$code2001Starts=New-Object System.Collections.Generic.List[long]
    foreach($iv in @($EffectIntervals)){
        if($null-eq$iv){continue}
        if([double]$iv.effect_code-eq2001.0){$raw2001++;$code2001Starts.Add([long]$iv.start_ms)}
    }
    $anchorTol=[long]$script:RNASAnchorToleranceMs
    $airAnchors=New-Object System.Collections.Generic.List[long]
    $landingAnchors=New-Object System.Collections.Generic.List[long]
    $comboAnchors=New-Object System.Collections.Generic.List[long]
    if($eventsAvailable){
        foreach($e in @($ActionEvents.events)){
            $c=[long]$e.action_code
            if($c-eq8){$airAnchors.Add([long]$e.time_ms)}
            elseif($c-eq9){$landingAnchors.Add([long]$e.time_ms)}
            elseif($c-eq24){$comboAnchors.Add([long]$e.time_ms)}
        }
    }
    $anchoredAir=0;$anchoredLanding=0;$anchoredCombo=0;$anchoredTotal=0
    foreach($s in @($code2001Starts.ToArray())){
        # Buckets are counted independently (one 2001 interval can be anchored by BOTH a code8 and
        # a code9 event - Gold A has three air/landing pairs on the same timestamp), while the
        # classified total is the UNION of the anchored intervals.
        $isAir=$false
        foreach($a in @($airAnchors.ToArray())){if([Math]::Abs($s-$a)-le$anchorTol){$isAir=$true;break}}
        $isLanding=$false
        foreach($a in @($landingAnchors.ToArray())){if([Math]::Abs($s-$a)-le$anchorTol){$isLanding=$true;break}}
        $isCombo=$false
        foreach($a in @($comboAnchors.ToArray())){if([Math]::Abs($s-$a)-le$anchorTol){$isCombo=$true;break}}
        if($isAir){$anchoredAir++}
        if($isLanding){$anchoredLanding++}
        if($isCombo){$anchoredCombo++}
        if($isAir-or$isLanding-or$isCombo){$anchoredTotal++}
    }
    $smallBoost=[ordered]@{
        authority='replay_native_action_object_speed_effect_table_v2'
        anchor_authority='replay_native_action_event'
        anchor_tolerance_ms=[int]$anchorTol
        anchor_tolerance_evidence=$script:RNASAnchorToleranceEvidence
        raw_effect_count=$(if($effectTableAvailable){$raw2001}else{$null})
        air_anchored_count=$(if($effectTableAvailable){$anchoredAir}else{$null})
        landing_anchored_count=$(if($effectTableAvailable){$anchoredLanding}else{$null})
        combo_anchored_count=$(if($effectTableAvailable){$anchoredCombo}else{$null})
        classified_count=$(if($effectTableAvailable){$anchoredTotal}else{$null})
        unresolved_count=$(if($effectTableAvailable){($raw2001-$anchoredTotal)}else{$null})
        # The raw count is a native fact (the effect table's own toggle content), not a pairing
        # artifact - proven by the toggle balance below.
        raw_evidence_status=$(if($effectTableAvailable){'native_fact'}else{'unavailable_no_native_effect_table'})
        raw_toggle_balance=@($toggleBalance|Where-Object{[double]$_.effect_code-eq2001.0})
        game_facing_normal_count=$null
        game_facing_count_status='unavailable_parity_unresolved'
        game_facing_parity='unresolved'
        game_facing_parity_evidence='Gold A closes (27 raw = 18 normal + 5 air + 4 landing) but Gold B does not (46 raw vs 35 normal + 3 air + 1 landing = 39 -> 7 intervals unexplained). No game-facing normal-small-boost number is published.'
        rejected_hypotheses=@(
            'overlapping-interval collapse: every overlapping 2001 pair counted once would give Gold A 22 (game 27) -> rejected'
            'nitro containment: 2001 starts strictly inside a code1 interval are 14/27 Gold A and 31/46 Gold B -> not the 7'
            'combo-marker collapse: 2001 intervals anchored exactly on a code24 are 10 Gold A and 19 Gold B -> not the 7'
            'short-duration intervals alone: duration <= 640 ms is 1 (Gold A) and 11 (Gold B) -> not the 7'
        )
        unpromoted_correlations=@(
            'duration <= 640 ms AND not exactly anchored on a code24 is 7 in Gold B and 0 in Gold A. This reproduces the gap but has no identified native mechanism, so per ADR 0005 it is recorded as an unpromoted correlation and NOT used as a rule.'
        )
    }

    # --- nitro (code 1) ----------------------------------------------------
    $rawNitro=0
    foreach($iv in @($EffectIntervals)){
        if($null-eq$iv){continue}
        if([double]$iv.effect_code-eq1.0){$rawNitro++}
    }
    $nitro=[ordered]@{
        authority='replay_native_action_object_speed_effect_table_v2'
        native_code=1
        raw_interval_count=$(if($effectTableAvailable){$rawNitro}else{$null})
        logical_count=$(if($effectTableAvailable){$rawNitro}else{$null})
        unresolved_count=$(if($effectTableAvailable){0}else{$null})
        raw_evidence_status=$(if($effectTableAvailable){'native_fact'}else{'unavailable_no_native_effect_table'})
        raw_toggle_balance=@($toggleBalance|Where-Object{[double]$_.effect_code-eq1.0})
        game_facing_count=$null
        game_facing_count_status='unavailable_parity_unresolved'
        game_facing_parity='unresolved'
        game_facing_parity_evidence='Both gold replays: game nitro = native code1 interval count + 1 (12 vs 11; 22 vs 21). No native evidence for the extra activation was found, so the raw count is published unmodified instead of adding one.'
        observed_game_minus_native='+1 in both gold replays; published as an observation only, never as a computed game-facing count.'
        use_vs_effect_interval='unresolved'
        use_vs_effect_interval_evidence='The code1 toggle stream is strictly alternating and balanced in both gold replays (11 opens / 11 closes, 21/21), no interval reaches twice the nominal ~3283-3300 ms duration, and no action event code lands on a code1 interval start (0 of 724 archive-wide). A "one game use never opened its own effect interval" model is therefore the only surviving candidate, but no independent native use marker was found. Ctrl input-rise is 11 = interval count in Gold A (29 vs 21 in Gold B), so it is not a use count.'
        ctrl_rise_count=$(if($NitroCtrlRiseCount-ge0){$NitroCtrlRiseCount}else{$null})
        ctrl_match_count=$(if($NitroCtrlMatchCount-ge0){$NitroCtrlMatchCount}else{$null})
        ctrl_match_fraction=$(if($NitroCtrlMatchFraction-ge0){$NitroCtrlMatchFraction}else{$null})
    }

    # --- legacy combo diagnostic + disagreement ----------------------------
    $legacyAvailable=($null-ne$LegacyCombos-and[bool]$LegacyCombos.available)
    $legacy=[ordered]@{
        authoritative=$false
        status=$(if($legacyAvailable){[string]$LegacyCombos.status}else{'unavailable'})
        source=$(if($legacyAvailable){[string]$LegacyCombos.source}else{'none'})
        cw=$(if($legacyAvailable){[int]$LegacyCombos.cw_count}else{$null})
        wcw=$(if($legacyAvailable){[int]$LegacyCombos.wcw_count}else{$null})
        cww=$(if($legacyAvailable){[int]$LegacyCombos.cww_count}else{$null})
        note='Timing-based sequence detector. Diagnostic only: production CW/WCW/CWW authority is replay_native_action_event. It is never used as a fallback.'
    }
    $comboDisagreement=[ordered]@{
        authority='replay_native_action_event'
        legacy_authoritative=$false
        comparable=$eventsAvailable
        native=[ordered]@{cw=[int]$combo.cw;wcw=[int]$combo.wcw;cww=[int]$combo.cww}
        legacy=[ordered]@{cw=$legacy.cw;wcw=$legacy.wcw;cww=$legacy.cww}
        cw_delta=$(if($legacyAvailable){[int]$combo.cw-[int]$legacy.cw}else{$null})
        wcw_delta=$(if($legacyAvailable){[int]$combo.wcw-[int]$legacy.wcw}else{$null})
        cww_delta=$(if($legacyAvailable){[int]$combo.cww-[int]$legacy.cww}else{$null})
        matches=$(if($legacyAvailable){([int]$combo.cw-eq[int]$legacy.cw)-and([int]$combo.wcw-eq[int]$legacy.wcw)-and([int]$combo.cww-eq[int]$legacy.cww)}else{$null})
        production_values_unaffected=$true
    }
    $airContactDisagreement=[ordered]@{
        authority='replay_native_action_event'
        native_air_boost=$air
        contact_state_air_boost=$(if($ContactAirBoostCount-ge0){$ContactAirBoostCount}else{$null})
        delta=$(if($air-ne$null-and$ContactAirBoostCount-ge0){[int]$air-$ContactAirBoostCount}else{$null})
        production_values_unaffected=$true
    }
    $landingContactDisagreement=[ordered]@{
        authority='replay_native_action_event'
        native_landing_boost=$landing
        contact_state_landing_boost=$(if($ContactLandingBoostCount-ge0){$ContactLandingBoostCount}else{$null})
        delta=$(if($landing-ne$null-and$ContactLandingBoostCount-ge0){[int]$landing-$ContactLandingBoostCount}else{$null})
        production_values_unaffected=$true
    }

    # --- unknown action codes ---------------------------------------------
    $known=@{}
    foreach($k in @(8,9,19,24,25)){$known[[long]$k]=$true}
    $unknownCodes=New-Object System.Collections.Generic.List[object]
    if($eventsAvailable){
        foreach($k in @($ActionEvents.action_codes)){
            if($known.ContainsKey([long]$k)){continue}
            $unknownCodes.Add([pscustomobject]@{action_code=[long]$k;count=[int]$ActionEvents.histogram[[string][long]$k]})
        }
    }

    return [pscustomobject][ordered]@{
        contract=$script:RNASContract
        architecture='native_first_v1'
        available=$eventsAvailable
        game_facing_available=$gameFacing
        status=$(if(-not$eventsAvailable){'native_action_event_table_unavailable'}elseif(-not$gameFacing){'production_semantics_variant_unvalidated'}else{'production_semantics_ready'})
        authority='replay_native_action_event'
        action_event_contract=$(if($null-ne$ActionEvents){[string]$ActionEvents.contract}else{'native_action_event_table_v1'})
        action_event_status=$(if($null-ne$ActionEvents){[string]$ActionEvents.status}else{'unavailable'})
        action_event_reason=$(if($null-ne$ActionEvents-and-not$eventsAvailable){[string]$ActionEvents.reason}else{''})
        action_event_count=$(if($eventsAvailable){[int]$ActionEvents.event_count}else{$null})
        action_event_histogram=$(if($eventsAvailable){$ActionEvents.histogram}else{@{}})
        semantic_alignment=$alignment
        # Game-facing contract: which published fields are settlement-equivalent and which are raw
        # native evidence. Consumers must label raw fields as raw; they may not present them as a
        # game-facing action count.
        game_facing=[ordered]@{
            contract='native_action_game_facing_v1'
            available=$gameFacing
            reason=$(if($gameFacing){'native action event table is semantically aligned with the code2001 effect table'}elseif(-not$eventsAvailable){'native action event table unavailable'}else{'native action event table fails the code2001 semantic-alignment gate (replay variant); game-facing counts are withheld'})
            game_facing_fields=@('air_boost.count','landing_boost.count','combo.cw','combo.wcw','combo.cww')
            raw_only_fields=@('small_boost.raw_effect_count','small_boost.classified_count','small_boost.unresolved_count','nitro.raw_interval_count','drift.raw_intervals','action_event_histogram','unknown_action_codes')
            unresolved_fields=@('small_boost.game_facing_normal_count','nitro.game_facing_count')
        }
        air_boost=[ordered]@{authority='replay_native_action_event';native_code=8;count=$air;game_facing=$gameFacing}
        landing_boost=[ordered]@{authority='replay_native_action_event';native_code=9;count=$landing;game_facing=$gameFacing}
        combo=[ordered]@{
            authority='replay_native_action_event'
            game_facing=$gameFacing
            cw=$(if($gameFacing){[int]$combo.cw}else{$null})
            wcw=$(if($gameFacing){[int]$combo.wcw}else{$null})
            cww=$(if($gameFacing){[int]$combo.cww}else{$null})
            code24_count=$(if($eventsAvailable){[int]$combo.code24_count}else{$null})
            code19_count=$(if($eventsAvailable){[int]$combo.code19_count}else{$null})
            code25_count=$(if($eventsAvailable){[int]$combo.code25_count}else{$null})
            code25_paired_count=@($combo.code25_paired).Count
            code25_standalone_count=@($combo.code25_standalone).Count
            code19_record_adjacent_to_code24=[int]$combo.code19_record_adjacent_to_code24
            wcw_adjacency_valid=[bool]$combo.wcw_adjacency_valid
            marker_accounting_consistent=[bool]$combo.marker_accounting_consistent
            pair_tolerance_ms=[int]$combo.pair_tolerance_ms
            pair_tolerance_evidence=$combo.pair_tolerance_evidence
            cw_evidence=@($combo.code25_paired)
            wcw_evidence=@(@($ActionEvents.events)|Where-Object{[long]$_.action_code-eq19})
            cww_evidence=@($combo.code24_unassigned)
        }
        drift=[ordered]@{
            authority='replay_native_action_object_drift_table'
            available=$driftTableAvailable
            status=$(if($driftTableAvailable){'replay_native_drift_table_validated'}else{'native_action_object_drift_table_unavailable'})
            game_facing=($driftTableAvailable-and$drift.raw_count-gt0)
            game_facing_basis='native Drift table present and structurally validated; grouping thresholds are evidence-bounded (ADR 0005)'
            raw_intervals=$(if($driftTableAvailable){$drift.raw_count}else{$null})
            logical_count=$(if($driftTableAvailable){$drift.logical_count}else{$null})
            merged_group_count=$(if($driftTableAvailable){$drift.merged_group_count}else{$null})
            retrigger_max_ms=$(if($driftTableAvailable){$drift.retrigger_max_ms}else{$null})
            retrigger_gap_ms=$(if($driftTableAvailable){$drift.retrigger_gap_ms}else{$null})
            grouping_evidence=$(if($driftTableAvailable){$drift.evidence}else{$null})
            groups=$(if($driftTableAvailable){@($drift.groups)}else{@()})
        }
        small_boost=$smallBoost
        nitro=$nitro
        legacy_combo_candidate=$legacy
        disagreement=[ordered]@{combo=$comboDisagreement;air_contact_state=$airContactDisagreement;landing_contact_state=$landingContactDisagreement}
        unknown_action_codes=@($unknownCodes.ToArray())
        evidence_matrix=Get-NativeActionCodeEvidenceMatrix -Table $ActionEvents -EffectIntervals $EffectIntervals -DriftIntervals $DriftIntervals
    }
}
