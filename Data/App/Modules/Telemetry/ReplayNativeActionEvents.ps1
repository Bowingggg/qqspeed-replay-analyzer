# Replay-native Action Event Table decoder (research/native-evidence layer).
#
# This module decodes a replay-native action event table that was previously not
# read by any production code path. It is deliberately NOT wired into the
# production analysis chain:
#   * it produces native evidence only;
#   * it does not modify ReplayNativeActionCache, Drift, SpeedEffect, Combo or
#     any analysis schema;
#   * its semantic candidate layer is explicitly non-authoritative.
#
# Definition-only module: no runtime actions at import scope.
#
# ---------------------------------------------------------------------------
# Structure established from real replays (12/12 archived replays)
# ---------------------------------------------------------------------------
# Layout, little endian:
#
#   u32 count                       <- count_offset (table start)
#   count * { u32 time_ms; u32 action_code; u32 reserved }
#
# The table is the last table in the file and is followed by a fixed 374 byte
# SAV trailer. Therefore:
#
#   table_end_exclusive = file_length - 374
#
# and the count is recovered by a fixed point: the only c with
#   u32(table_end_exclusive - 4 - 12*c) == c
# In all 12 archived replays that fixed point is unique, which is what makes the
# locator fail-closed without hardcoding any per-replay offset.
#
# Observed action codes across 12 replays (NOT a whitelist; unknown codes are
# preserved verbatim and never reinterpreted):
#   2, 8, 9, 13, 18, 19, 20, 21, 22, 23, 24, 25, 40, 41, 43, 44, 45

$script:RNDEContract='native_action_event_table_v1'
$script:RNDETrailerBytes=374
$script:RNDEMaxRecords=5000
$script:RNDEMaxTimeMs=600000
# v2 structural locator (see Find-ReplayNativeActionEventTableCandidates).
# The container does NOT always end the action event table exactly 374 bytes before EOF: a bounded
# trailing region after the table can carry recording/session metadata. The locator therefore also
# accepts a table that ends anywhere in the last `EofBound` bytes, but ONLY when its declared `u32
# count` equals the maximal reversely-validated record run and that run is read with the documented
# 12-byte stride, reserved == 0, 1..200 codes and non-decreasing bounded times. Ties fail closed.
$script:RNDELocatorContract='replay_native_action_event_locator_v2'
$script:RNDEEofBoundBytes=8192
# Record-validity bounds used by the structural reverse scan. `RNDEMinRunRecords` only exists to keep
# the search from accepting trivially short coincidences; it is never a semantic filter.
$script:RNDECodeMin=1
$script:RNDECodeMax=200
$script:RNDEMinRunRecords=4
$script:RNDEPairToleranceMs=500
$script:RNDEPairToleranceEvidence='paired max=283ms; unpaired min=850ms; 500ms sits in the observed gap'

function Get-ReplayNativeActionEventContract { return $script:RNDEContract }
function Get-ReplayNativeActionEventLocatorContract { return $script:RNDELocatorContract }
function Get-ReplayNativeActionEventTrailerBytes { return [int]$script:RNDETrailerBytes }
function Get-ReplayNativeActionEventMaxRecords { return [int]$script:RNDEMaxRecords }

function RNDE-ReadU32([byte[]]$Data,[int]$Offset) {
    return [long]([BitConverter]::ToUInt32($Data,$Offset))
}

function RNDE-NewUnavailable {
    param(
        [string]$Reason,
        [long]$FileLength=0,
        [int]$TrailerBytes=0,
        [long]$TableEndExclusive=0,
        [int]$CountSolutions=0,
        [object[]]$SolutionOffsets=@(),
        [long]$ElapsedMs=0,
        [object]$Extra=$null
    )
    return [pscustomobject][ordered]@{
        contract=$script:RNDEContract
        authoritative=$false
        source='replay_native'
        available=$false
        status='unavailable'
        reason=$Reason
        file_length=[long]$FileLength
        trailer_bytes=[int]$TrailerBytes
        table_end_exclusive=[long]$TableEndExclusive
        count_offset=$null
        event_count=0
        events=@()
        histogram=@{}
        action_codes=@()
        distinct_code_count=0
        first_time_ms=$null
        last_time_ms=$null
        duration_ms=$null
        count_solutions=[int]$CountSolutions
        solution_offsets=@($SolutionOffsets)
        detail=$Extra
        elapsed_ms=[long]$ElapsedMs
    }
}

# Locate the action event table purely from container structure:
# the table ends where the fixed SAV trailer begins, and the count field must be
# self-consistent with that end. Every self-consistent solution is collected so
# that an ambiguous file fails closed instead of picking one.
# Structural locator used when the fixed 374-byte-trailer fixed point has no solution.
#
# The search is strictly bounded:
#   * candidate table ends are only the last `EofBound` bytes of the container, 4-byte aligned;
#   * the run is validated with direct byte arithmetic (no per-record function calls) and stops at
#     `VisibleStart`, so a windowed read costs the same as a whole-file read;
#   * a candidate is accepted only when the `u32` immediately before the run equals the run length
#     (table shape self-consistency: `u32 count; count * {u32 time_ms; u32 action_code; u32 0}`);
#   * when several candidates accept, the longest wins; a tie fails closed (`ambiguous`).
#
# Time is non-decreasing and `reserved == 0` across the whole run, so a trailing metadata region
# cannot be mistaken for records: its first sample fails the run.
function Get-ReplayNativeActionEventStructuralCandidates {
    param(
        [Parameter(Mandatory=$true)][byte[]]$Data,
        [Parameter(Mandatory=$true)][long]$VisibleStart,
        [Parameter(Mandatory=$true)][long]$FileLength,
        [int]$EofBound=$script:RNDEEofBoundBytes,
        [int]$TrailerBytes=$script:RNDETrailerBytes,
        [int]$MaxRecords=$script:RNDEMaxRecords,
        [int]$MinRunRecords=$script:RNDEMinRunRecords,
        [int]$CodeMin=$script:RNDECodeMin,
        [int]$CodeMax=$script:RNDECodeMax,
        [int]$MaxTimeMs=$script:RNDEMaxTimeMs
    )
    $found=New-Object System.Collections.Generic.List[object]
    if($FileLength-$VisibleStart -lt 16){ return [pscustomobject]@{candidates=@();ambiguous=$false;ambiguity_count=0} }

    # Bounded count-field anchored search.
    #
    # The container does NOT always end the action event table exactly `trailer_bytes` before EOF: a
    # 320冒险岛 recording carries ~659 trailing bytes of recording/session metadata after the table,
    # so the v1 fixed point has no solution there even though the table is intact.
    #
    # The search below is anchored on the `u32 count` field and then validates the claimed span
    # FORWARD, which is what makes it unambiguous:
    #   * candidate count offsets are limited to the region a v1 table could start in
    #     ([searchFloor, FileLength - trailer_bytes - 4]); the trailing region is never scanned
    #     byte-by-byte without that bound;
    #   * `count` is read from the container, never guessed, and the whole `count * 12` span must fit;
    #   * every record must satisfy reserved == 0, 1..CodeMax action codes and non-decreasing times in
    #     1..MaxTimeMs, so a coincidental `u32` inside the metadata region cannot produce a table;
    #   * a candidate is discarded when the record region beyond its claimed span is itself a valid
    #     record (the declared count would not describe the whole region - this is what rejects the
    #     12-byte-phase decoy inside the 320冒险岛 table);
    #   * the remaining trailing length must stay within `EofBound`;
    #   * several surviving candidates of the maximal length fail closed (`ambiguous`).
    [long]$searchFloor=[Math]::Max($VisibleStart,($FileLength-[long]$TrailerBytes-4L-12L*[long]$MaxRecords))
    [long]$maxCountOffset=$FileLength-[long]$TrailerBytes-4L
    for([long]$co=$searchFloor;$co -le $maxCountOffset;$co+=1){
        $declared=[long][BitConverter]::ToUInt32($Data,[int]($co-$VisibleStart))
        if($declared -lt [long]$MinRunRecords -or $declared -gt [long]$MaxRecords){ continue }
        [long]$first=$co+4L
        [long]$span=12L*$declared
        if($first+$span -gt $FileLength){ continue }
        $ok=$true;$prev=-1L;$minT=-1L;$maxT=-1L
        for($i=0;$i -lt $declared;$i++){
            $o=[int]($first+12L*[long]$i-$VisibleStart)
            $t=[long][BitConverter]::ToUInt32($Data,$o)
            $c=[long][BitConverter]::ToUInt32($Data,$o+4)
            $r=[long][BitConverter]::ToUInt32($Data,$o+8)
            if($r -ne 0){ $ok=$false;break }
            if($t -le 0 -or $t -gt [long]$MaxTimeMs){ $ok=$false;break }
            if($c -lt [long]$CodeMin -or $c -gt [long]$CodeMax){ $ok=$false;break }
            if($prev -ge 0 -and $t -lt $prev){ $ok=$false;break }
            if($minT -lt 0 -or $t -lt $minT){ $minT=$t }
            $maxT=$t;$prev=$t
        }
        if(-not $ok){ continue }
        # The declared count must describe the WHOLE record region: if the 12 bytes before the table
        # start are themselves a valid record, this candidate is a shifted view of a longer table.
        if($co-12 -ge $VisibleStart){
            $b=[int]($co-12-$VisibleStart)
            $bt=[long][BitConverter]::ToUInt32($Data,$b)
            $bc=[long][BitConverter]::ToUInt32($Data,$b+4)
            $br=[long][BitConverter]::ToUInt32($Data,$b+8)
            $firstT=[long][BitConverter]::ToUInt32($Data,[int]($first-$VisibleStart))
            if($br -eq 0 -and $bt -gt 0 -and $bt -le [long]$MaxTimeMs -and $bc -ge [long]$CodeMin -and $bc -le [long]$CodeMax -and $bt -le $firstT){ continue }
        }
        $trailer=$FileLength-($first+$span)
        if($trailer -lt 0 -or $trailer -gt [long]$EofBound){ continue }
        $found.Add([pscustomobject]@{
            count_offset=$co
            count=[int]$declared
            min_time_ms=$minT
            max_time_ms=$maxT
            trailer_bytes=$trailer
            search_source='structural_count_anchored_forward_v2'
        })
    }

    if($found.Count -eq 0){ return [pscustomobject]@{candidates=@();ambiguous=$false;ambiguity_count=0} }
    $bestCount=-1
    foreach($f in $found){ if($f.count -gt $bestCount){ $bestCount=$f.count } }
    $best=@($found|Where-Object{$_.count -eq $bestCount})
    if($best.Count -ne 1){
        # Several different tables of the same (maximal) length: refuse to pick one.
        return [pscustomobject]@{candidates=@($best.ToArray());ambiguous=$true;ambiguity_count=$best.Count}
    }
    return [pscustomobject]@{candidates=@($best[0]);ambiguous=$false;ambiguity_count=1}
}
function Find-ReplayNativeActionEventCountOffset {
    param(
        [Parameter(Mandatory=$true)][byte[]]$Data,
        [int]$MaxRecords=$script:RNDEMaxRecords,
        [int]$TrailerBytes=$script:RNDETrailerBytes,
        # Data may be a WINDOW of the container instead of the whole file: BufferOffset is the
        # absolute container offset of Data[0] and FileLength is the real container length.
        [long]$BufferOffset=0,
        [long]$FileLength=-1
    )
    [long]$fileLen=$(if($FileLength-ge0){$FileLength}else{([long]$BufferOffset+[long]$Data.Length)})
    $tableEnd=$fileLen-[long]$TrailerBytes
    $solutions=New-Object System.Collections.Generic.List[object]
    if($tableEnd-lt4){return [pscustomobject]@{table_end_exclusive=$tableEnd;solutions=@()}}
    for($c=1;$c -le $MaxRecords;$c++){
        $co=[long]$tableEnd-4L-12L*[long]$c
        if($co-lt$BufferOffset){break}
        if((RNDE-ReadU32 $Data ([int]($co-$BufferOffset)))-eq[long]$c){
            $solutions.Add([pscustomobject]@{count=[int]$c;count_offset=$co})
        }
    }
    return [pscustomobject]@{table_end_exclusive=$tableEnd;solutions=@($solutions.ToArray())}
}

function Get-ReplayNativeActionEventTable {
    param(
        [string]$ReplayPath='',
        [byte[]]$Data=$null,
        [int]$MaxRecords=$script:RNDEMaxRecords,
        [int]$TrailerBytes=$script:RNDETrailerBytes,
        # Absolute container offset of Data[0]. Every offset this function reports is absolute, so
        # a windowed read and a whole-file read of the same container are byte-identical in result.
        [long]$BufferOffset=0,
        [long]$FileLength=-1
    )
    $sw=[System.Diagnostics.Stopwatch]::StartNew()
    if($null-eq$Data){
        if([string]::IsNullOrWhiteSpace($ReplayPath)){throw 'Native action event decoder requires -ReplayPath or -Data.'}
        if(-not(Test-Path -LiteralPath $ReplayPath -PathType Leaf)){
            $sw.Stop()
            return (RNDE-NewUnavailable -Reason 'replay_not_found' -TrailerBytes $TrailerBytes -ElapsedMs $sw.ElapsedMilliseconds)
        }
        [byte[]]$data=[IO.File]::ReadAllBytes($ReplayPath)
        $BufferOffset=0
        $FileLength=[long]$data.Length
    } else {[byte[]]$data=$Data}
    if($FileLength-lt0){$FileLength=[long]$BufferOffset+[long]$data.Length}

    # A window must reach the container end, otherwise the trailer anchor is meaningless.
    if(($BufferOffset+[long]$data.Length)-ne[long]$FileLength){
        $sw.Stop()
        return (RNDE-NewUnavailable -Reason 'action_event_window_does_not_reach_container_end' -FileLength $FileLength -TrailerBytes $TrailerBytes -ElapsedMs $sw.ElapsedMilliseconds -Extra ([ordered]@{buffer_offset=$BufferOffset;buffer_length=[long]$data.Length}))
    }
    if([long]$FileLength-le([long]$TrailerBytes+4L)){
        $sw.Stop()
        return (RNDE-NewUnavailable -Reason 'file_smaller_than_container_trailer' -FileLength $FileLength -TrailerBytes $TrailerBytes -ElapsedMs $sw.ElapsedMilliseconds)
    }
    # The locator searches every count up to MaxRecords. A window that does not cover that whole
    # search range could miss the unique solution, so it fails closed instead of guessing.
    $searchFloor=[Math]::Max([long]0,($FileLength-[long]$TrailerBytes-4L-12L*[long]$MaxRecords))
    if([long]$BufferOffset-gt$searchFloor){
        $sw.Stop()
        return (RNDE-NewUnavailable -Reason 'action_event_window_too_small' -FileLength $FileLength -TrailerBytes $TrailerBytes -ElapsedMs $sw.ElapsedMilliseconds -Extra ([ordered]@{buffer_offset=$BufferOffset;search_floor=$searchFloor}))
    }

    # Locator contract v2. The v1 fixed point (table ends exactly `trailer_bytes` before EOF) is
    # tried FIRST so nothing that already resolves can change behaviour. Only when it has no solution
    # do we run the bounded structural reverse scan, which accepts a table ending anywhere in the
    # last `EofBound` bytes as long as its `u32 count` equals its validated record run.
    $locate=Find-ReplayNativeActionEventCountOffset -Data $data -MaxRecords $MaxRecords -TrailerBytes $TrailerBytes -BufferOffset $BufferOffset -FileLength $FileLength
    $sols=@($locate.solutions)
    $locatorPath='trailer_fixed_point_v1'
    $tableEndExclusive=[long]$locate.table_end_exclusive
    if($sols.Count-eq0){
        $locatorPath='structural_count_anchored_forward_v2'
        $structural=$null
        try {
            $structural=Get-ReplayNativeActionEventStructuralCandidates -Data $data -VisibleStart ([long]$BufferOffset) -FileLength ([long]$FileLength)
        } catch {
            $structural=$null
        }
        if($null-eq$structural){
            $sw.Stop()
            return (RNDE-NewUnavailable -Reason 'action_event_structural_scan_failed' -FileLength $FileLength -TrailerBytes $TrailerBytes -TableEndExclusive ([long]$locate.table_end_exclusive) -ElapsedMs $sw.ElapsedMilliseconds -Extra ([ordered]@{locator_contract=$script:RNDELocatorContract;locator_path=$locatorPath}))
        }
        if([bool]$structural.ambiguous){
            # Several candidate tables share the maximal length: fail closed instead of picking one.
            $sw.Stop()
            return (RNDE-NewUnavailable -Reason 'action_event_count_ambiguous' -FileLength $FileLength -TrailerBytes $TrailerBytes -TableEndExclusive ([long]$locate.table_end_exclusive) -CountSolutions ([int]$structural.ambiguity_count) -SolutionOffsets @(@($structural.candidates)|ForEach-Object{[long]$_.count_offset}) -ElapsedMs $sw.ElapsedMilliseconds -Extra ([ordered]@{locator_contract=$script:RNDELocatorContract;locator_path=$locatorPath}))
        }
        $sols=@(@($structural.candidates)|ForEach-Object{[pscustomobject]@{count=[int]$_.count;count_offset=[long]$_.count_offset;search_source=[string]$_.search_source}})
        if($sols.Count-eq1){ $tableEndExclusive=([long]$sols[0].count_offset)+4L+12L*[long]$sols[0].count }
    }
    if($sols.Count-eq0){
        $sw.Stop()
        return (RNDE-NewUnavailable -Reason 'action_event_count_unresolved' -FileLength $FileLength -TrailerBytes $TrailerBytes -TableEndExclusive $tableEndExclusive -ElapsedMs $sw.ElapsedMilliseconds -Extra ([ordered]@{locator_contract=$script:RNDELocatorContract;locator_path='trailer_fixed_point_v1_then_structural_count_anchored_forward_v2'}))
    }
    if($sols.Count-gt1){
        $sw.Stop()
        return (RNDE-NewUnavailable -Reason 'action_event_count_ambiguous' -FileLength $FileLength -TrailerBytes $TrailerBytes -TableEndExclusive $tableEndExclusive -CountSolutions $sols.Count -SolutionOffsets @($sols|ForEach-Object{[long]$_.count_offset}) -ElapsedMs $sw.ElapsedMilliseconds -Extra ([ordered]@{locator_contract=$script:RNDELocatorContract;locator_path=$locatorPath}))
    }

    $count=[int]$sols[0].count
    [long]$countOffset=[long]$sols[0].count_offset
    [long]$expectedEnd=$countOffset+4L+12L*[long]$count
    if($expectedEnd-ne$tableEndExclusive){
        $sw.Stop()
        return (RNDE-NewUnavailable -Reason 'table_shape_does_not_reach_container_trailer' -FileLength $FileLength -TrailerBytes $TrailerBytes -TableEndExclusive $tableEndExclusive -ElapsedMs $sw.ElapsedMilliseconds -Extra ([ordered]@{locator_contract=$script:RNDELocatorContract;locator_path=$locatorPath}))
    }

    $events=New-Object System.Collections.Generic.List[object]
    $histogram=@{}
    $prev=-1L
    for($i=0;$i -lt $count;$i++){
        [long]$pAbs=$countOffset+4L+12L*[long]$i
        $p=[int]($pAbs-$BufferOffset)
        [long]$t=RNDE-ReadU32 $data $p
        [long]$code=RNDE-ReadU32 $data ($p+4)
        [long]$res=RNDE-ReadU32 $data ($p+8)
        if($t-gt[long]$script:RNDEMaxTimeMs){
            $sw.Stop()
            return (RNDE-NewUnavailable -Reason 'action_event_time_out_of_range' -FileLength $FileLength -TrailerBytes $TrailerBytes -TableEndExclusive $tableEndExclusive -ElapsedMs $sw.ElapsedMilliseconds -Extra ([ordered]@{record_index=$i;time_ms=$t;action_code=$code}))
        }
        if($t-lt$prev){
            $sw.Stop()
            return (RNDE-NewUnavailable -Reason 'action_event_time_not_monotonic' -FileLength $FileLength -TrailerBytes $TrailerBytes -TableEndExclusive $tableEndExclusive -ElapsedMs $sw.ElapsedMilliseconds -Extra ([ordered]@{record_index=$i;time_ms=$t;previous_time_ms=$prev}))
        }
        if($res-ne0){
            $sw.Stop()
            return (RNDE-NewUnavailable -Reason 'action_event_reserved_field_nonzero' -FileLength $FileLength -TrailerBytes $TrailerBytes -TableEndExclusive $tableEndExclusive -ElapsedMs $sw.ElapsedMilliseconds -Extra ([ordered]@{record_index=$i;time_ms=$t;action_code=$code;reserved=$res}))
        }
        $prev=$t
        $key=[string]$code
        if(-not $histogram.ContainsKey($key)){$histogram[$key]=0}
        $histogram[$key]=[int]$histogram[$key]+1
        $events.Add([pscustomobject][ordered]@{
            record_index=$i
            record_offset=[long]$pAbs
            time_ms=$t
            action_code=$code
            reserved=$res
        })
    }

    $sw.Stop()
    $first=$null;$last=$null
    if($events.Count-gt0){$first=[long]$events[0].time_ms;$last=[long]$events[$events.Count-1].time_ms}
    $codes=@($histogram.Keys|ForEach-Object{[long]$_}|Sort-Object)
    return [pscustomobject][ordered]@{
        contract=$script:RNDEContract
        locator_contract=$script:RNDELocatorContract
        locator_path=$locatorPath
        trailer_bytes_at_locator=[long]($FileLength-$tableEndExclusive)
        authoritative=$false
        source='replay_native'
        available=$true
        status='validated'
        reason=''
        file_length=[long]$FileLength
        trailer_bytes=[int]$TrailerBytes
        table_end_exclusive=[long]$tableEndExclusive
        count_offset=$countOffset
        event_count=$count
        events=@($events.ToArray())
        histogram=$histogram
        action_codes=@($codes)
        distinct_code_count=$codes.Count
        first_time_ms=$first
        last_time_ms=$last
        duration_ms=$(if($null-ne$first){[long]($last-$first)}else{$null})
        count_solutions=1
        solution_offsets=@($countOffset)
        detail=$null
        elapsed_ms=[long]$sw.ElapsedMilliseconds
    }
}

# ---------------------------------------------------------------------------
# Research / candidate semantic layer. NOT production authority.
# ---------------------------------------------------------------------------
# Nothing here may be promoted into the production analysis chain without a
# separate GPT-reviewed authority cutover. The existing CW/WCW/CWW detector is
# left untouched and remains the only authority used by the product.
#
# Candidate model under test (native event evidence only; no XY, no curvature,
# no route position, no speed threshold, no legacy combo time window):
#
#   code 24                     -> combo marker common to CW / WCW / CWW
#   code 19                     -> WCW
#   code 25 adjacent to a code24 (within PairToleranceMs, either order)
#                               -> CW
#   code 24 not consumed by CW/WCW -> CWW
#   code 8                      -> air boost candidate
#   code 9                      -> landing boost candidate
#
# code25 total is NOT the CW count: code25 also occurs standalone. The pairing
# tolerance is evidence-derived, not invented.

function Get-ReplayNativeActionEventComboCandidate {
    param(
        [Parameter(Mandatory=$true)][object]$Table,
        [int]$PairToleranceMs=$script:RNDEPairToleranceMs
    )
    $result=[ordered]@{
        contract='native_action_event_combo_candidate_v1'
        authoritative=$false
        available=$false
        status='unavailable'
        reason='action_event_table_unavailable'
        pair_tolerance_ms=$PairToleranceMs
        pair_tolerance_evidence=$script:RNDEPairToleranceEvidence
        combo_marker_count=0
        cw=0
        wcw=0
        cww=0
        air_boost=0
        landing_boost=0
        code19_count=0
        code25_count=0
        code25_paired=@()
        code25_unpaired=@()
        code24_unassigned=@()
        unresolved_codes=@()
    }
    if($null-eq$Table-or-not[bool]$Table.available){return [pscustomobject]$result}
    if([string]$Table.contract-ne$script:RNDEContract){return [pscustomobject]$result}

    $events=@($Table.events)
    $markers=@($events|Where-Object{[long]$_.action_code-eq24})
    $wcwEvents=@($events|Where-Object{[long]$_.action_code-eq19})
    $cwEvents=@($events|Where-Object{[long]$_.action_code-eq25})

    # Pair each code25 with the nearest code24 inside the tolerance window
    # (order-agnostic: the table has code25 both before and after code24).
    $usedMarkers=New-Object 'System.Collections.Generic.HashSet[int]'
    $paired=New-Object System.Collections.Generic.List[object]
    $unpaired=New-Object System.Collections.Generic.List[object]
    foreach($c in $cwEvents){
        $best=$null;$bestDelta=[long]::MaxValue
        foreach($m in $markers){
            $idx=[int]$m.record_index
            if($usedMarkers.Contains($idx)){continue}
            $delta=[Math]::Abs([long]$c.time_ms-[long]$m.time_ms)
            if($delta-lt$bestDelta){$bestDelta=$delta;$best=$m}
        }
        if($null-ne$best-and$bestDelta-le[long]$PairToleranceMs){
            [void]$usedMarkers.Add([int]$best.record_index)
            $paired.Add([pscustomobject][ordered]@{code25_record_index=[int]$c.record_index;code25_time_ms=[long]$c.time_ms;code24_record_index=[int]$best.record_index;code24_time_ms=[long]$best.time_ms;delta_ms=[long]$bestDelta})
        } else {
            $unpaired.Add([pscustomobject][ordered]@{code25_record_index=[int]$c.record_index;code25_time_ms=[long]$c.time_ms;nearest_code24_delta_ms=$(if($null-ne$best){[long]$bestDelta}else{$null})})
        }
    }

    $cw=$paired.Count
    $wcw=$wcwEvents.Count
    $cww=$markers.Count-$cw-$wcw
    $unassigned=New-Object System.Collections.Generic.List[object]
    foreach($m in $markers){
        if(-not $usedMarkers.Contains([int]$m.record_index)){
            $unassigned.Add([pscustomobject][ordered]@{record_index=[int]$m.record_index;time_ms=[long]$m.time_ms})
        }
    }

    $known=@{}
    foreach($k in @(8,9,19,24,25)){$known[[long]$k]=$true}
    $other=@($Table.action_codes|Where-Object{-not$known.ContainsKey([long]$_)})

    return [pscustomobject][ordered]@{
        contract='native_action_event_combo_candidate_v1'
        authoritative=$false
        available=$true
        status='candidate_only'
        reason=''
        pair_tolerance_ms=$PairToleranceMs
        pair_tolerance_evidence=$script:RNDEPairToleranceEvidence
        combo_marker_count=$markers.Count
        cw=$cw
        wcw=$wcw
        cww=$cww
        air_boost=[int]$Table.histogram['8']
        landing_boost=[int]$Table.histogram['9']
        code19_count=$wcwEvents.Count
        code25_count=$cwEvents.Count
        code25_paired=@($paired.ToArray())
        code25_unpaired=@($unpaired.ToArray())
        code24_unassigned=@($unassigned.ToArray())
        unresolved_codes=@($other)
    }
}
