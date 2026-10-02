# TRAINING_ANALYSIS_CORPUS enumeration.
#
# Definition-only helper (functions only, no import-scope work). Dot-source this from the training
# acceptance tooling and from the training regression gate so that both enumerate the SAME corpus.
#
# Contract:
#   * CANDIDATE SET = <PROJECT_ROOT>\replay\*.sav
#                     + Data\ReplayArchive\<sha16>\*.sav
#     Those are exactly the two places a supported replay can live in this workspace. No hand-written
#     file list is ever used.
#   * The 2026-09 recording month selects the archive extension set, the same selector the
#     Current-2026 closure and the September readiness gate use. Replays recorded outside that month
#     are long-retired formats: they are excluded by NAME-DERIVED MONTH, never by parsing their bytes,
#     and every exclusion is reported (a silently dropped file is never acceptable).
#   * A file that does not carry the `<map>-<yyyyMMdd>-<HHmmss>-<player>.sav` convention cannot be
#     month-classified. It is kept as `out_of_scope` so the reason is visible, and it never enters a
#     capability count. The convention itself is display/external metadata: no parser, decoder or
#     structural decision may depend on it (see AGENTS.md / ARCHITECTURE.md authority rules).
#   * Entries are de-duplicated by SHA256. The `replay\` copy wins over the archive copy.
#   * Test ids are `T01`, `T02`, ... assigned by sorted SHA16, so they are stable across machines and
#     never derived from a player name or a file name.
#   * `has_local_shadow` / `has_network_shadow` are derived from the telemetry summary when it is
#     available (pass -TelemetryLookup). They are metadata for corpus selection, never a gate.
#
# PRIVACY: a QQSpeed replay file name carries the player nickname. `Get-TrainingCorpusPublishable`
# is the only shape allowed into a document, a handoff or the review ZIP: it exposes the anonymous
# test id and the hashes, never the file name, the nickname or an absolute path.

function Get-TrainingCorpusTestId {
    param([Parameter(Mandatory=$true)][int]$Index)
    return ('T{0:D2}' -f $Index)
}

# A TF1/TF2 (and the 2021/2000 archive leftovers) replay is not part of the 2026-09 supported set.
# The decision is made from the file-name month only, so it is reproducible and never a byte parse.
function Get-TrainingCorpusScopeReason {
    param(
        [Parameter(Mandatory=$true)][AllowNull()][AllowEmptyString()][string]$RecordedMonth,
        [string]$YearMonth='2026-09'
    )
    if([string]::IsNullOrWhiteSpace($RecordedMonth)){ return 'undated_file_name' }
    if($RecordedMonth -ne $YearMonth){ return ('recording_month_'+$RecordedMonth) }
    return 'in_scope'
}

function Get-TrainingAnalysisCorpus {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [string]$UserCorpusDir='',
        [string]$ArchiveDir='',
        [string]$YearMonth='2026-09',
        # Optional hashtable sha256 -> telemetry summary object. Used ONLY to record which replays
        # carry a local + network shadow; it never gates corpus membership.
        $TelemetryLookup=$null
    )
    if([string]::IsNullOrWhiteSpace($UserCorpusDir)){ $UserCorpusDir=Join-Path $ProjectRoot 'replay' }
    if([string]::IsNullOrWhiteSpace($ArchiveDir)){ $ArchiveDir=Join-Path $ProjectRoot 'Data\ReplayArchive' }

    $candidates=New-Object System.Collections.Generic.List[object]
    if(Test-Path -LiteralPath $UserCorpusDir -PathType Container){
        foreach($f in @(Get-ChildItem -LiteralPath $UserCorpusDir -File -Filter '*.sav' -ErrorAction SilentlyContinue)){
            $candidates.Add([pscustomobject]@{path=$f.FullName;origin='replay_dir';bytes=[long]$f.Length})
        }
    }
    if(Test-Path -LiteralPath $ArchiveDir -PathType Container){
        foreach($f in @(Get-ChildItem -LiteralPath $ArchiveDir -Recurse -File -Filter '*.sav' -ErrorAction SilentlyContinue)){
            $candidates.Add([pscustomobject]@{path=$f.FullName;origin='replay_archive';bytes=[long]$f.Length})
        }
    }

    # The `replay\` copy is the user's own current verification corpus and always wins.
    $bySha=@{}
    $order=New-Object System.Collections.Generic.List[string]
    foreach($c in @($candidates.ToArray() | Sort-Object @{Expression={if($_.origin -eq 'replay_dir'){0}else{1}}},@{Expression='path'})){
        $t=$null
        try { $t=Get-SeptemberRecordedTimeFromName $c.path } catch { $t=$null }
        $ym=$(if($null -ne $t){ $t.ToString('yyyy-MM') }else{ $null })

        $sha=Get-ReplayFileSha256Hex $c.path
        if($bySha.ContainsKey($sha)){ continue }
        $order.Add($sha)
        $bySha[$sha]=[pscustomobject][ordered]@{
            sha256=$sha
            sha16=$sha.Substring(0,16)
            size_bytes=[long]$c.bytes
            recorded_at=$(if($null -ne $t){ $t.ToString('s') }else{ $null })
            recorded_month=$ym
            recorded_at_source=$(if($null -ne $t){'replay_filename_convention'}else{'unavailable'})
            scope_reason=Get-TrainingCorpusScopeReason -RecordedMonth $ym -YearMonth $YearMonth
            origin=$c.origin
            source_path=$c.path
        }
    }

    $rows=New-Object System.Collections.Generic.List[object]
    $i=0
    foreach($sha in @($order.ToArray() | Sort-Object)){
        $i++
        $e=$bySha[$sha]
        $inScope=([string]$e.scope_reason -eq 'in_scope')
        $localShadow='unavailable';$networkShadow='unavailable';$logicalStreams=$null;$physicalStreams=$null
        if($null -ne $TelemetryLookup -and $TelemetryLookup.ContainsKey($sha)){
            $tel=$TelemetryLookup[$sha]
            if($null -ne $tel){
                $streams=@($tel.streams)
                $logicalStreams=$streams.Count
                $localShadow=[bool](@($streams | Where-Object { [string]$_.role -eq 'local_high_frequency' }).Count -gt 0)
                $networkShadow=[bool](@($streams | Where-Object { [string]$_.role -like 'network*' }).Count -gt 0)
                if($null -ne $tel.physical_stream_count){ $physicalStreams=[int]$tel.physical_stream_count }
            }
        }
        $rows.Add([pscustomobject][ordered]@{
            test_id=Get-TrainingCorpusTestId $i
            sha256=$e.sha256
            sha16=$e.sha16
            size_bytes=$e.size_bytes
            recorded_at=$e.recorded_at
            recorded_month=$e.recorded_month
            recorded_at_source=$e.recorded_at_source
            scope_reason=$e.scope_reason
            in_scope=$inScope
            origin=$e.origin
            has_local_shadow=$localShadow
            has_network_shadow=$networkShadow
            logical_stream_count=$logicalStreams
            physical_stream_count=$physicalStreams
            source_path=$e.source_path
        })
    }
    return @($rows.ToArray())
}

# Same-map groups: entries that share an authoritative ResourceMapID can be compared A/B, entries
# that do not cannot. Grouping is by the resolved resource id only; an unresolved identity is its own
# `unresolved` bucket and is never merged with another replay "because the names look similar".
function Group-TrainingCorpusByMap {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Corpus)
    $groups=@{}
    foreach($e in @($Corpus)){
        if($null -eq $e){ continue }
        $key=$(if($null -eq $e.resource_map_id){'unresolved'}else{('resource_'+[string][int]$e.resource_map_id)})
        if(-not $groups.ContainsKey($key)){ $groups[$key]=New-Object System.Collections.Generic.List[object] }
        $groups[$key].Add($e)
    }
    $out=New-Object System.Collections.Generic.List[object]
    foreach($k in @($groups.Keys | Sort-Object)){
        $m=@($groups[$k].ToArray())
        $out.Add([pscustomobject][ordered]@{
            group_key=$k
            resource_map_id=$(if($k -eq 'unresolved'){$null}else{[int]($k -replace '^resource_','')})
            replay_count=$m.Count
            test_ids=@($m | ForEach-Object { [string]$_.test_id })
            ab_comparable=($k -ne 'unresolved' -and $m.Count -ge 2)
        })
    }
    return @($out.ToArray())
}

# Publishable view: no absolute paths and no file names (a QQSpeed file name carries the player
# nickname). This is the only shape allowed into documents, handoffs or the review ZIP.
function Get-TrainingCorpusPublishable {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Corpus)
    $out=New-Object System.Collections.Generic.List[object]
    foreach($e in @($Corpus)){
        if($null -eq $e){ continue }
        $out.Add([pscustomobject][ordered]@{
            test_id=[string]$e.test_id
            sha16=[string]$e.sha16
            size_bytes=[long]$e.size_bytes
            recorded_at=$e.recorded_at
            recorded_at_source=[string]$e.recorded_at_source
            scope_reason=[string]$e.scope_reason
            in_scope=[bool]$e.in_scope
            origin=[string]$e.origin
            has_local_shadow=$e.has_local_shadow
            has_network_shadow=$e.has_network_shadow
            logical_stream_count=$e.logical_stream_count
            physical_stream_count=$e.physical_stream_count
        })
    }
    return @($out.ToArray())
}
