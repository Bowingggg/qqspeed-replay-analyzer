param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}
function Put-U32([byte[]]$D,[int]$O,[uint32]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}

. (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeActionEvents.ps1')
. (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeDriftTimeline.ps1')
. (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeSpeedEffects.ps1')
. (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeActionSemantics.ps1')

# ---------------------------------------------------------------------------
# Production native action semantics -- gold regression.
#
# Belongs to the Real Regression gate: it asserts real replay truth against the
# production authority (replay_native_action_event) and the settlement-parity
# accounting (raw / logical / unresolved). The gold replays are pinned by SHA256.
#
# Contract under test:
#   code 8  -> air boost           code 9  -> landing boost
#   code 19 -> WCW                 code 24 -> CW/WCW/CWW common marker
#   code 25 grouped with a code24 (<=500ms, same cluster) -> CW; remaining code24 -> CWW
#   drift raw native intervals -> logical drift actions (short-retrigger coalescing)
#   unknown action codes are preserved verbatim with an evidence-matrix row
# ---------------------------------------------------------------------------

# --- 1. synthetic contracts (no real replay needed) -------------------------
$synthetic=0

function New-EventBytes {
    param([long[]]$Times,[long[]]$Codes,[int]$TrailerBytes=374,[byte[]]$Prefix=@())
    $Count=$Times.Count
    $len=$Prefix.Length+$TrailerBytes+4+12*$Count
    [byte[]]$b=New-Object byte[] $len
    if($Prefix.Length-gt0){[Array]::Copy($Prefix,0,$b,0,$Prefix.Length)}
    $co=$len-$TrailerBytes-4-12*$Count
    Put-U32 $b $co ([uint32]$Count)
    for($i=0;$i -lt $Count;$i++){
        $p=$co+4+12*$i
        Put-U32 $b $p ([uint32]$Times[$i]); Put-U32 $b ($p+4) ([uint32]$Codes[$i]); Put-U32 $b ($p+8) ([uint32]0)
    }
    return ,$b
}

# 1a. windowed decode must be byte-identical to a whole-buffer decode
[byte[]]$prefix=New-Object byte[] 4096
[byte[]]$full=New-EventBytes -Times @(1000,2000,3000,4000,4100,6000,9000) -Codes @(8,9,19,24,25,24,24) -Prefix $prefix
$whole=Get-ReplayNativeActionEventTable -Data $full
Require ([bool]$whole.available) 'window: whole-buffer decode must be available'
$maxRecords=[int](Get-ReplayNativeActionEventMaxRecords)
$trailerBytes=[int](Get-ReplayNativeActionEventTrailerBytes)
$need=[Math]::Max([long]65536,(4L+12L*[long]$maxRecords+[long]$trailerBytes))
$off=[long]$full.Length-$need
if($off-lt0){$off=0}
$win=New-Object byte[] ([int]($full.Length-$off))
[Array]::Copy($full,[int]$off,$win,0,$win.Length)
$w=Get-ReplayNativeActionEventTable -Data $win -BufferOffset $off -FileLength ([long]$full.Length)
Require ([bool]$w.available) 'window: windowed decode must be available'
Require ([int]$w.event_count-eq[int]$whole.event_count) 'window: event count must match a whole-buffer decode'
Require ([long]$w.count_offset-eq[long]$whole.count_offset) 'window: count_offset must stay absolute'
$sigWhole=(@($whole.events|ForEach-Object{[string]$_.record_index+':'+$_.record_offset+':'+$_.time_ms+':'+$_.action_code}) -join '|')
$sigWin=(@($w.events|ForEach-Object{[string]$_.record_index+':'+$_.record_offset+':'+$_.time_ms+':'+$_.action_code}) -join '|')
Require ($sigWhole-eq$sigWin) 'window: every record must be identical to a whole-buffer decode'
$synthetic++

# 1b. fail-closed window contracts
$r=Get-ReplayNativeActionEventTable -Data $win -BufferOffset ([long]($off+1000)) -FileLength ([long]$full.Length)
Require ([string]$r.reason-eq'action_event_window_does_not_reach_container_end') ('window: a window that does not reach the container end must fail closed, got '+[string]$r.reason)
$r2=Get-ReplayNativeActionEventTable -Data $win -BufferOffset 10 -FileLength ([long]$win.Length)
Require ([string]$r2.reason-eq'action_event_window_does_not_reach_container_end') ('window: a window that does not reach the declared container end must fail closed, got '+[string]$r2.reason)
$r3=Get-ReplayNativeActionEventTable -Data (New-Object byte[] 1000) -BufferOffset 1000 -FileLength 2000
Require ([string]$r3.reason-eq'action_event_window_too_small') ('window: a too-small search range must fail closed, got '+[string]$r3.reason)
$synthetic++

# 1c. CW grouping: native adjacency alone is provably insufficient (850ms case must NOT pair)
$t850=Get-ReplayNativeActionEventTable -Data (New-EventBytes -Times @(1000,1850) -Codes @(24,25))
$g850=Get-ReplayNativeActionEventComboGrouping -Table $t850
Require ([int]$g850.cw-eq0) 'combo: a code25 850ms from its code24 must NOT be a CW confirmation'
Require ([int]$g850.cww-eq1) 'combo: the unpaired code24 must stay CWW'
Require ([int]$g850.code25_count-eq1-and@($g850.code25_standalone).Count-eq1) 'combo: the standalone code25 must be preserved'
$t283=Get-ReplayNativeActionEventTable -Data (New-EventBytes -Times @(1000,1283) -Codes @(24,25))
$g283=Get-ReplayNativeActionEventComboGrouping -Table $t283
Require ([int]$g283.cw-eq1) 'combo: a code25 283ms from its code24 must be CW'
Require (@($g283.code25_paired).Count-eq1-and@($g283.code25_paired)[0].delta_ms-eq283) 'combo: CW pair delta evidence must be 283ms'
$synthetic++

# 1d. drift logical grouping rule
function New-DriftIntervals([long[][]]$Pairs){
    $out=New-Object System.Collections.Generic.List[object]
    foreach($p in $Pairs){$out.Add([pscustomobject]@{start_ms=$p[0];end_ms=$p[1];duration_ms=($p[1]-$p[0])})}
    return @($out.ToArray())
}
# the Gold A retrigger run: 7 consecutive intervals (durations 417,17,17,16,17,16,50)
$run=New-DriftIntervals @(@(80667,81084),@(81084,81101),@(81101,81118),@(81118,81134),@(81134,81151),@(81218,81234),@(81234,81284))
$grp=Get-ReplayNativeDriftLogicalGrouping -Intervals $run
Require ([int]$grp.raw_count-eq7) 'drift: raw interval count must be preserved'
Require ([int]$grp.logical_count-eq1) 'drift: the 7-interval retrigger run must coalesce into one logical drift'
Require ([int]$grp.merged_group_count-eq1) 'drift: exactly one merged group expected'
Require ([long]$grp.groups[0].start_ms-eq80667-and[long]$grp.groups[0].end_ms-eq81284) 'drift: merged group must span the whole run'
# intervals that must stay separate: 600ms duration, and a 217ms gap
$sep=New-DriftIntervals @(@(40304,40920),@(41137,42237))
$grpSep=Get-ReplayNativeDriftLogicalGrouping -Intervals $sep
Require ([int]$grpSep.logical_count-eq2) 'drift: a 600ms interval and a 217ms gap must NOT coalesce'
$synthetic++

# 1e. semantic-alignment gate: a replay whose action codes do not align with its code2001 effect
#     intervals is a VARIANT and must fail closed (no game-facing counts, raw evidence kept).
$variantTable=Get-ReplayNativeActionEventTable -Data (New-EventBytes -Times @(1000,2000,3000,4000) -Codes @(8,9,19,24))
Require ([bool]$variantTable.available) 'variant: synthetic event table must decode'
$variantEffects=@(
    [pscustomobject]@{effect_code=2001.0;start_ms=50000;end_ms=50650;duration_ms=650},
    [pscustomobject]@{effect_code=2001.0;start_ms=60000;end_ms=60650;duration_ms=650}
)
$va=Get-ReplayNativeActionSemanticAlignment -Table $variantTable -EffectIntervals $variantEffects
Require ([string]$va.status-eq'variant_mismatch') ('variant: unaligned anchor codes must be a variant mismatch, got '+[string]$va.status)
$vs=Resolve-ReplayNativeActionSemantics -ActionEvents $variantTable -EffectIntervals $variantEffects
Require ([string]$vs.status-eq'production_semantics_variant_unvalidated') ('variant: status must fail closed, got '+[string]$vs.status)
Require ([bool]$vs.available) 'variant: the raw action event table must stay available'
Require (-not[bool]$vs.game_facing_available) 'variant: game-facing counts must be withheld'
Require ($null-eq$vs.air_boost.count-and$null-eq$vs.landing_boost.count) 'variant: air/landing must not be published as game-facing'
Require ($null-eq$vs.combo.cw-and$null-eq$vs.combo.wcw-and$null-eq$vs.combo.cww) 'variant: CW/WCW/CWW must not be published as game-facing'
Require ($null-ne$vs.small_boost.raw_effect_count-and[int]$vs.small_boost.raw_effect_count-eq2) 'variant: the raw code2001 count must still be published'
Require (-not[bool]$vs.game_facing.available) 'variant: the game-facing contract must report unavailability'
$synthetic++

# 1f. semantic-alignment gate: a table without any anchor code is not applicable (not a variant).
$noAnchorTable=Get-ReplayNativeActionEventTable -Data (New-EventBytes -Times @(1000,2000) -Codes @(13,23))
$na=Get-ReplayNativeActionSemanticAlignment -Table $noAnchorTable -EffectIntervals $variantEffects
Require ([string]$na.status-eq'not_applicable_no_anchor_code_events') ('gate: no anchor codes must be not-applicable, got '+[string]$na.status)
Require ([bool]$na.game_facing_allowed) 'gate: a not-applicable alignment must not block game-facing counts'
$nas=Resolve-ReplayNativeActionSemantics -ActionEvents $noAnchorTable -EffectIntervals $variantEffects
Require ([string]$nas.status-eq'production_semantics_ready') ('gate: not-applicable alignment must stay production ready, got '+[string]$nas.status)
Require ([int]$nas.air_boost.count-eq0) 'gate: code8 count must still come from the table histogram'
$synthetic++

# 1g. toggle balance: a raw table whose per-code begin/end records are unbalanced must be reported.
$balRecords=@(
    [pscustomobject]@{time_ms=1000;state=1;effect_code=2001.0},
    [pscustomobject]@{time_ms=1650;state=0;effect_code=2001.0},
    [pscustomobject]@{time_ms=2000;state=1;effect_code=2001.0},
    [pscustomobject]@{time_ms=2000;state=1;effect_code=1.0}
)
$balTable=[pscustomobject]@{
    valid=$true
    records=$balRecords
    intervals=@([pscustomobject]@{effect_code=2001.0;start_ms=1000;end_ms=1650})
    effect_codes=@([pscustomobject]@{effect_code=1.0},[pscustomobject]@{effect_code=2001.0})
}
$balRows=Get-ReplayNativeEffectToggleBalance -Table $balTable
$b2001=@($balRows|Where-Object{[double]$_.effect_code-eq2001.0})[0]
$b1=@($balRows|Where-Object{[double]$_.effect_code-eq1.0})[0]
Require ([int]$b2001.open_record_count-eq2-and[int]$b2001.close_record_count-eq1) 'toggle: begin/end record counts must be reported separately'
Require (-not[bool]$b2001.balanced) 'toggle: an unbalanced code must be reported as unbalanced'
Require ([int]$b1.open_record_count-eq1-and[int]$b1.close_record_count-eq0) 'toggle: the second code must be audited independently'
$synthetic++
Write-Host ('[OK] production native action semantics synthetic contract: '+$synthetic+' case(s)')

# --- 2. gold replays --------------------------------------------------------
$dataDir=Split-Path -Parent $AppDir
$archive=Join-Path $dataDir 'ReplayArchive'
function Find-GoldReplay([string]$Stamp){
    if(-not(Test-Path -LiteralPath $archive -PathType Container)){return $null}
    $m=@(Get-ChildItem -LiteralPath $archive -Recurse -File -Filter ('*'+$Stamp+'*.sav') -ErrorAction SilentlyContinue)
    if($m.Count-eq0){return $null}
    return $m[0]
}
function Assert-Gold {
    param(
        [string]$Tag,[string]$Stamp,[string]$Sha256,
        [int]$Air,[int]$Landing,[int]$Cw,[int]$Wcw,[int]$Cww,
        [int]$DriftRaw,[int]$DriftLogical,
        [int]$SmallRaw,[int]$SmallClassified,[int]$SmallUnresolved,
        [int]$NitroRaw,[int]$Code25Raw,[int]$Code25Paired,
        [long[]]$UnknownCodes
    )
    $f=Find-GoldReplay $Stamp
    if($null-eq$f){ Write-Host ('  ['+$Tag+'] not-present (skipped)'); return $false }
    $sha=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    Require ($sha-eq$Sha256) ($Tag+': replay SHA256 mismatch, refusing to treat this file as the gold replay')

    $table=Get-ReplayNativeActionEventTableFromWindow -ReplayPath $f.FullName
    Require ([bool]$table.available) ($Tag+': action event table unavailable: '+[string]$table.reason)
    $driftResolved=Resolve-ReplayNativeDriftTimeline -Candidates @(Get-ReplayNativeDriftTimelineCandidates -ReplayPath $f.FullName) -Rows @([pscustomobject]@{time_s=0.0;input_bool_candidate_64=$false})
    Require ([bool]$driftResolved.available) ($Tag+': native drift table unavailable: '+[string]$driftResolved.status)
    $effects=Get-ReplayNativeSpeedEffectTableAtOffset -ReplayPath $f.FullName -CountOffset ([long]$driftResolved.candidate.end_exclusive)
    Require ([bool]$effects.valid) ($Tag+': adjacent speed-effect table invalid: '+[string]$effects.status)

    $s=Resolve-ReplayNativeActionSemantics -ActionEvents $table -EffectIntervals @($effects.intervals) -DriftIntervals @($driftResolved.candidate.intervals) -EffectTable $effects

    Require ([string]$s.contract-eq'production_native_action_semantics_v1') ($Tag+': production contract mismatch')
    Require ([string]$s.authority-eq'replay_native_action_event') ($Tag+': production authority must be replay_native_action_event')
    Require ([bool]$s.available) ($Tag+': production semantics must be available')
    Require ([string]$s.status-eq'production_semantics_ready') ($Tag+': production status must be ready')
    # Game-facing gate: a gold replay is semantically aligned, so its action-event-derived counts
    # may be published as game-facing numbers.
    Require ([bool]$s.available) ($Tag+': raw native action evidence must stay available')
    Require ([bool]$s.game_facing_available) ($Tag+': a gold replay must pass the game-facing gate')
    Require ([string]$s.semantic_alignment.status-eq'aligned') ($Tag+': the code2001 semantic alignment gate must be aligned, got '+[string]$s.semantic_alignment.status)
    Require ([double]$s.semantic_alignment.alignment_rate-eq1.0) ($Tag+': every anchor-code occurrence must align in a gold replay')
    Require ([int]$s.semantic_alignment.anchor_event_count-gt0) ($Tag+': the alignment gate must have anchor evidence')
    Require ([bool]$s.game_facing.available) ($Tag+': the game-facing contract must report availability')
    Require (@($s.game_facing.game_facing_fields).Count-gt0) ($Tag+': the game-facing contract must declare its fields')
    Require (@($s.game_facing.raw_only_fields).Count-gt0) ($Tag+': the raw-only contract must declare its fields')
    Require ($null-eq$s.nitro.raw_interval_count-or[int]$s.nitro.raw_interval_count-ge0) ($Tag+': nitro raw must be numeric')

    Require ([int]$s.air_boost.count-eq$Air) ($Tag+': air boost '+[string]$s.air_boost.count+' != '+[string]$Air)
    Require ([string]$s.air_boost.authority-eq'replay_native_action_event') ($Tag+': air boost authority mismatch')
    Require ([int]$s.landing_boost.count-eq$Landing) ($Tag+': landing boost '+[string]$s.landing_boost.count+' != '+[string]$Landing)
    Require ([int]$s.combo.cw-eq$Cw) ($Tag+': CW '+[string]$s.combo.cw+' != '+[string]$Cw)
    Require ([int]$s.combo.wcw-eq$Wcw) ($Tag+': WCW '+[string]$s.combo.wcw+' != '+[string]$Wcw)
    Require ([int]$s.combo.cww-eq$Cww) ($Tag+': CWW '+[string]$s.combo.cww+' != '+[string]$Cww)
    Require ([int]$s.combo.code25_count-eq$Code25Raw) ($Tag+': raw code25 count '+[string]$s.combo.code25_count+' != '+[string]$Code25Raw)
    Require ([int]$s.combo.code25_paired_count-eq$Code25Paired) ($Tag+': paired code25 '+[string]$s.combo.code25_paired_count+' != '+[string]$Code25Paired)
    Require ([int]$s.combo.code25_standalone_count-eq($Code25Raw-$Code25Paired)) ($Tag+': standalone code25 must be raw minus paired')
    Require ([bool]$s.combo.marker_accounting_consistent) ($Tag+': CW+WCW+CWW must account for every code24 marker')
    Require ([bool]$s.combo.wcw_adjacency_valid) ($Tag+': every code19 must be record-adjacent to a code24')

    Require ([int]$s.drift.raw_intervals-eq$DriftRaw) ($Tag+': drift raw intervals '+[string]$s.drift.raw_intervals+' != '+[string]$DriftRaw)
    Require ([int]$s.drift.logical_count-eq$DriftLogical) ($Tag+': drift logical count '+[string]$s.drift.logical_count+' != '+[string]$DriftLogical)
    Require ([string]$s.drift.authority-eq'replay_native_action_object_drift_table') ($Tag+': drift authority mismatch')

    Require ([int]$s.small_boost.raw_effect_count-eq$SmallRaw) ($Tag+': raw code2001 '+[string]$s.small_boost.raw_effect_count+' != '+[string]$SmallRaw)
    Require ([int]$s.small_boost.classified_count-eq$SmallClassified) ($Tag+': classified code2001 '+[string]$s.small_boost.classified_count+' != '+[string]$SmallClassified)
    Require ([int]$s.small_boost.unresolved_count-eq$SmallUnresolved) ($Tag+': unresolved code2001 '+[string]$s.small_boost.unresolved_count+' != '+[string]$SmallUnresolved)
    Require ([int]$s.small_boost.air_anchored_count-eq$Air) ($Tag+': code2001 air anchors must equal the code8 count')
    Require ([int]$s.small_boost.landing_anchored_count-eq$Landing) ($Tag+': code2001 landing anchors must equal the code9 count')
    Require ([int]$s.small_boost.combo_anchored_count-eq([int]$s.combo.code24_count)) ($Tag+': every code24 must anchor a code2001 interval start')
    Require ([string]$s.small_boost.game_facing_parity-eq'unresolved') ($Tag+': small-boost game-facing parity must stay explicitly unresolved')
    Require ([string]$s.small_boost.game_facing_count_status-eq'unavailable_parity_unresolved') ($Tag+': the small-boost game-facing count must be reported as unavailable')
    Require ([string]$s.small_boost.raw_evidence_status-eq'native_fact') ($Tag+': the raw code2001 count must be published as a native fact')
    Require (@($s.small_boost.rejected_hypotheses).Count-gt0) ($Tag+': the rejected 2001 parity hypotheses must stay recorded')
    Require (@($s.small_boost.unpromoted_correlations).Count-gt0) ($Tag+': a fitted correlation must stay explicitly unpromoted')
    $bal=@($s.small_boost.raw_toggle_balance)
    Require ($bal.Count-eq1) ($Tag+': the code2001 toggle balance must be published')
    Require ([bool]$bal[0].balanced) ($Tag+': every code2001 begin record must have a matching end record')
    Require ([bool]$bal[0].interval_count_matches_open_records) ($Tag+': the code2001 interval count must equal its begin-record count')
    Require ([int]$bal[0].interval_count-eq[int]$s.small_boost.raw_effect_count) ($Tag+': the toggle balance must agree with the published raw count')
    Require ([string]$s.nitro.use_vs_effect_interval-eq'unresolved') ($Tag+': the nitro use-vs-effect-interval distinction must stay unresolved')
    Require ([string]$s.nitro.game_facing_count_status-eq'unavailable_parity_unresolved') ($Tag+': the nitro game-facing count must be reported as unavailable')
    Require ($null-eq$s.nitro.game_facing_count) ($Tag+': no game-facing nitro count may be invented')
    Require ($null-eq$s.small_boost.game_facing_normal_count) ($Tag+': no game-facing normal small-boost number may be invented')

    Require ([int]$s.nitro.raw_interval_count-eq$NitroRaw) ($Tag+': nitro raw intervals '+[string]$s.nitro.raw_interval_count+' != '+[string]$NitroRaw)
    Require ([int]$s.nitro.logical_count-eq$NitroRaw) ($Tag+': nitro logical count must equal the raw native count')
    Require ([string]$s.nitro.game_facing_parity-eq'unresolved') ($Tag+': nitro game-facing parity must stay explicitly unresolved')
    Require ([string]$s.nitro.authority-eq'replay_native_action_object_speed_effect_table_v2') ($Tag+': nitro authority mismatch')

    Require (-not[bool]$s.legacy_combo_candidate.authoritative) ($Tag+': the legacy combo detector must not be authoritative')
    Require ([bool]$s.disagreement.combo.production_values_unaffected) ($Tag+': a legacy disagreement must not affect production values')
    Require ([string]$s.disagreement.combo.authority-eq'replay_native_action_event') ($Tag+': disagreement must be reported against the production authority')

    $unknown=@($s.unknown_action_codes|ForEach-Object{[long]$_.action_code})
    foreach($c in @($UnknownCodes)){ Require ($unknown -contains [long]$c) ($Tag+': unknown action code '+[string]$c+' must be preserved') }
    Require (@($s.evidence_matrix).Count-gt0) ($Tag+': the action code evidence matrix must be populated')

    # window equivalence on the real replay
    [byte[]]$all=[IO.File]::ReadAllBytes($f.FullName)
    $winLen=196608
    if($all.Length-lt$winLen){$winLen=$all.Length}
    [byte[]]$win=New-Object byte[] $winLen
    $winOff=[long]$all.Length-[long]$winLen
    [Array]::Copy($all,[int]$winOff,$win,0,([int]$winLen))
    $w2=Get-ReplayNativeActionEventTable -Data $win -BufferOffset $winOff -FileLength ([long]$all.Length)
    Require ([int]$w2.event_count-eq[int]$table.event_count) ($Tag+': windowed decode must match the whole-file decode (event count)')
    Require ([long]$w2.count_offset-eq[long]$table.count_offset) ($Tag+': windowed decode must match the whole-file decode (count offset)')

    Write-Host ('  ['+$Tag+'] authority='+[string]$s.authority+' air='+[string]$s.air_boost.count+' landing='+[string]$s.landing_boost.count+' CW/WCW/CWW='+[string]$s.combo.cw+'/'+[string]$s.combo.wcw+'/'+[string]$s.combo.cww+' drift='+[string]$s.drift.raw_intervals+'/'+[string]$s.drift.logical_count+' code2001='+[string]$s.small_boost.raw_effect_count+'/'+[string]$s.small_boost.classified_count+'/'+[string]$s.small_boost.unresolved_count+' nitro='+[string]$s.nitro.raw_interval_count+' unknown='+((@($unknown)) -join ',')+' window='+[string]$table.window_source)
    return $true
}

# Gold A -- Old Street Pipeline: air 5, landing 4, CW/WCW/CWW 3/3/4, drift 28 raw -> 22 logical.
$goldA=Assert-Gold -Tag 'goldA' -Stamp '20260930-234714' `
    -Sha256 '50436400DE8FF37EA45363470EE8B06112628DABB2F33C22C3AA577FBA641253' `
    -Air 5 -Landing 4 -Cw 3 -Wcw 3 -Cww 4 -DriftRaw 28 -DriftLogical 22 `
    -SmallRaw 27 -SmallClassified 16 -SmallUnresolved 11 -NitroRaw 11 -Code25Raw 3 -Code25Paired 3 `
    -UnknownCodes @(13,22,23)

# Gold B -- City Torch: air 3, landing 1, CW/WCW/CWW 5/6/8, drift 34 raw -> 34 logical.
$goldB=Assert-Gold -Tag 'goldB' -Stamp '20260930-225857' `
    -Sha256 '3164A4F8AFA71A832B30E55A7228C6FA08A9DFCE683689BA33CE8A18CF6A3623' `
    -Air 3 -Landing 1 -Cw 5 -Wcw 6 -Cww 8 -DriftRaw 34 -DriftLogical 34 `
    -SmallRaw 46 -SmallClassified 23 -SmallUnresolved 23 -NitroRaw 21 -Code25Raw 10 -Code25Paired 5 `
    -UnknownCodes @(2,13,20,21,22,23,43,44)

$manifest=Get-Content -LiteralPath (Join-Path $AppDir 'app_manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
$status='goldA='+$(if($goldA){'verified'}else{'not-present'})+' goldB='+$(if($goldB){'verified'}else{'not-present'})
Write-Host ('[OK] Production native action semantics regression passed. app='+[string]$manifest.app_version+' contract=production_native_action_semantics_v1 synthetic='+[string]$synthetic+' authority=replay_native_action_event drift=native-retrigger-coalescing legacy_combo=diagnostic-only '+$status)
exit 0
