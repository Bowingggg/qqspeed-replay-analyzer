param(
    # Tools\TrainingAnalysis\<this file> -> Data\App
    # Tools\TrainingAnalysis\<this file> -> Data\App. $PSScriptRoot is reliable under -File.
    [string]$AppDir = '',
    [Parameter(Mandatory=$true)][string]$ReportPath,
    [string]$BaselineOut='',
    [string]$FinalOut=''
)
# Tools\TrainingAnalysis\<this file> -> Data\App. Derive the app directory from $PSScriptRoot,
# which is populated when the script is invoked with -File.
if([string]::IsNullOrWhiteSpace($AppDir)){ $AppDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
# Renders the human-readable Training Analysis reports from a measured acceptance report.
#
# PRIVACY: the acceptance report deliberately carries only the anonymous test id, the SHA16, sizes and
# verdicts. It never carries a replay file name (a QQSpeed name contains the player nickname), a
# player name or an absolute path, so neither do the documents this tool writes.
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}

$dataDir=Split-Path -Parent $AppDir
$root=Split-Path -Parent $dataDir
if(-not(Test-Path -LiteralPath $ReportPath -PathType Leaf)){ throw ('training acceptance report not found: '+$ReportPath) }
$R=Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json

function T($v){ if($null-eq$v){return 'null'}; if($v -is [bool]){ if($v){return 'true'}; return 'false' }; return [string]$v }
function S([object]$v,[int]$d){ if($null-eq$v){return 'n/a'}; if([double]::IsNaN([double]$v)){return 'n/a'}; return ([Math]::Round([double]$v,$d)).ToString('F'+[string]$d) }
function Csv($a){ if($null-eq$a){return ''}; $x=@($a); if($x.Count-eq0){return ''}; return ($x -join ', ') }
# Safe property read: a missing key on a PSCustomObject or an ordered hashtable reads as $null.
function Prop($Object,[string]$Name){
    if($null -eq $Object){ return $null }
    if(@($Object.PSObject.Properties.Name) -contains $Name){ return $Object.$Name }
    return $null
}

$entries=@($R.entries)
$inScope=@($entries|Where-Object{[bool]$_.in_scope})
$groups=@($R.map_groups)
$abCases=@($R.same_map_ab_cases)

$lines=New-Object System.Collections.Generic.List[string]
function AddBase([string]$s){ $script:lines.Add($s) }

$timing=$R.timing_summary
$multiLap=@($entries|Where-Object{@($_.training.lap_times_s).Count -ge 2})
$withLoss=@($entries|Where-Object{[int]$_.training.time_loss_entries -gt 0})
$reconciled=0;$degraded=0;$unavailable=0
foreach($e in $entries){
    foreach($tl in @($e.training.time_loss)){
        $st=[string]$tl.status
        if($st -eq 'reconciled'){$reconciled++}
        elseif($st -like 'degraded*'){$degraded++}
        else{$unavailable++}
    }
}

AddBase '# TRAINING ANALYSIS v1.1 — BASELINE'
AddBase ''
AddBase ('Contract: `' + (T $R.contract) + '` · mode: `' + (T $R.mode) + '` · generated: `' + (T $R.generated_at) + '`')
AddBase ''
AddBase 'Measured by driving the real production entry point (`QQReplay.ps1 -Mode Analyze`) once per corpus'
AddBase 'entry. The corpus is enumerated from the working tree, never from a hand-written list; every id is'
AddBase 'assigned by sorted SHA16 so no id can depend on a player name or a file name.'
AddBase ''
AddBase '## 1. Corpus'
AddBase ''
AddBase ('- corpus contract: `' + (T $R.corpus_contract) + '`')
AddBase ('- total entries: **' + $entries.Count + '** · in scope (2026-09): **' + $inScope.Count + '**')
AddBase ('- timing: median **' + (S $timing.median_s 2) + ' s**, P90 **' + (S $timing.p90_s 2) + ' s**, max **' + (S $timing.max_s 2) + ' s** (n=' + (T $timing.count) + ')')
AddBase ''
AddBase '| test id | sha16 | size (bytes) | recorded | origin | local shadow | network shadow | in scope | scope reason |'
AddBase '| --- | --- | --- | --- | --- | --- | --- | --- | --- |'
foreach($e in $entries){
    AddBase ('| ' + (T $e.test_id) + ' | `' + (T $e.sha16) + '` | ' + (T $e.size_bytes) + ' | ' + (T $e.recorded_at) + ' | ' + (T $e.origin) + ' | ' + (T $e.has_local_shadow) + ' | ' + (T $e.has_network_shadow) + ' | ' + (T $e.in_scope) + ' | ' + (T $e.scope_reason) + ' |')
}
AddBase ''
AddBase '## 2. Per-replay capability and lap metrics'
AddBase ''
AddBase '| test id | map (game/resource) | confidence | lap count | lap times (s) | logical drifts | episodes | sections | spatial | training |'
AddBase '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
foreach($e in $entries){
    $m=(T $e.map.game_map_id)+'/'+(T $e.map.resource_map_id)
    AddBase ('| ' + (T $e.test_id) + ' | ' + $m + ' | ' + (T $e.map.confidence) + ' | ' + (T $e.physical.lap_count) + ' | ' + (Csv $e.training.lap_times_s) + ' | ' + (T $e.drift.logical_count) + ' | ' + (T $e.driving.episode_count) + ' | ' + (T $e.training.section_count) + ' | ' + (T $e.training.spatial_section) + ' | ' + (T $e.training.status) + ' |')
}
AddBase ''
AddBase '### Capability degradation'
AddBase ''
AddBase '| capability | ready | unavailable | prerequisite missing |'
AddBase '| --- | --- | --- | --- |'
$lapReady=@($entries|Where-Object{[string]$_.training.lap_analysis -eq 'ready'}).Count
$epReady=@($entries|Where-Object{[string]$_.training.episode_analysis -eq 'ready'}).Count
$spReady=@($entries|Where-Object{[string]$_.training.spatial_section -eq 'ready'}).Count
AddBase ('| Level 1 lap analysis | ' + $lapReady + ' | ' + ($entries.Count-$lapReady) + ' | 0 |')
AddBase ('| Level 2 native episodes | ' + $epReady + ' | ' + ($entries.Count-$epReady) + ' | 0 |')
AddBase ('| Level 3 shared spatial comparison | ' + $spReady + ' | 0 | ' + ($entries.Count-$spReady) + ' |')
AddBase ''
AddBase '## 3. Same-map groups'
AddBase ''
AddBase 'A/B is permitted only between two replays that carry the **same authoritative ResourceMapID**. A'
AddBase 'group that is not `ab_comparable` is never compared.'
AddBase ''
AddBase '| group | resource map id | replays | test ids | A/B comparable | multi-lap replays |'
AddBase '| --- | --- | --- | --- | --- | --- |'
foreach($g in $groups){
    AddBase ('| `' + (T $g.group_key) + '` | ' + (T $g.resource_map_id) + ' | ' + (T $g.replay_count) + ' | ' + (Csv $g.test_ids) + ' | ' + (T $g.ab_comparable) + ' | ' + (Csv $g.multi_lap_replays) + ' |')
}
AddBase ''
AddBase '## 4. Before-baseline summary'
AddBase ''
AddBase '| quantity | value |'
AddBase '| --- | --- |'
AddBase ('| corpus entries | ' + $entries.Count + ' |')
AddBase ('| in-scope entries | ' + $inScope.Count + ' |')
AddBase ('| replays with an authoritative official map | ' + @($entries|Where-Object{[bool]$_.map.authoritative}).Count + ' |')
AddBase ('| replays with native Drift available | ' + @($entries|Where-Object{[bool]$_.drift.available}).Count + ' |')
AddBase ('| replays with >= 2 laps | ' + $multiLap.Count + ' |')
AddBase ('| replays with a time-loss decomposition | ' + $withLoss.Count + ' |')
AddBase ('| time-loss comparisons reconciled | ' + $reconciled + ' |')
AddBase ('| time-loss comparisons degraded | ' + $degraded + ' |')
AddBase ('| time-loss comparisons unavailable | ' + $unavailable + ' |')
AddBase ('| same-map groups | ' + $groups.Count + ' |')
AddBase ('| same-map A/B comparable groups | ' + @($groups|Where-Object{[bool]$_.ab_comparable}).Count + ' |')
AddBase ('| same-map A/B cases produced | ' + $abCases.Count + ' |')
AddBase ''

$baselineText=($lines -join "`r`n")

# ---- final report ---------------------------------------------------------------------------
$flines=New-Object System.Collections.Generic.List[string]
function AddFinal([string]$s){ $script:flines.Add($s) }

AddFinal '# TRAINING ANALYSIS v1.1 — FINAL'
AddFinal ''
AddFinal ('Contract: `' + (T $R.contract) + '` · mode: `' + (T $R.mode) + '` · generated: `' + (T $R.generated_at) + '`')
AddFinal ''
AddFinal 'This document is the AFTER side of the milestone. The BEFORE side is'
AddFinal '`TRAINING_ANALYSIS_BASELINE.md`, produced from the same corpus enumeration.'
AddFinal ''
AddFinal '## 1. What the milestone delivers'
AddFinal ''
AddFinal 'A user can now see WHERE lap time was lost, not only how much. Both sides of a comparison are'
AddFinal 'read through ONE shared spatial correspondence built from the two REAL driven routes, ONE shared'
AddFinal 'boundary set defines the comparison windows, and every comparison publishes its own reconciliation'
AddFinal 'under a single `delta = subject - baseline` rule with loss and gain kept apart, so a decomposition'
AddFinal 'that does not close is visible instead of plausible.'
AddFinal ''
AddFinal '## 2. Capability result'
AddFinal ''
AddFinal '| level | capability | ready | note |'
AddFinal '| --- | --- | --- | --- |'
AddFinal ('| 1 | Lap analysis | ' + $lapReady + '/' + $entries.Count + ' | production telemetry only; map-independent |')
AddFinal ('| 2 | Native driving episodes | ' + $epReady + '/' + $entries.Count + ' | replay-native Drift table; map-independent |')
AddFinal ('| 3 | Shared spatial comparison | ' + $spReady + '/' + $entries.Count + ' | needs an authoritative official map identity |')
AddFinal ('| 4 | Same-map A/B | ' + @($groups|Where-Object{[bool]$_.ab_comparable}).Count + ' groups | needs TWO replays with the SAME ResourceMapID |')
AddFinal ''
AddFinal '## 3. Delta reconciliation'
AddFinal ''
AddFinal 'Every comparison publishes `total_delta = matched_delta + unmatched_delta + non_comparison_delta + residual`,'
AddFinal 'with `delta = subject - baseline` so a positive time delta is always time LOST by the subject, and a'
AddFinal 'tolerance derived from the measured sample interval and the number of non-comparison boundaries.'
AddFinal ''
AddFinal '| verdict | count |'
AddFinal '| --- | --- |'
AddFinal ('| reconciled | ' + $reconciled + ' |')
AddFinal ('| degraded | ' + $degraded + ' |')
AddFinal ('| unavailable | ' + $unavailable + ' |')
AddFinal ''
AddFinal '## 4. Truthful limits'
AddFinal ''
AddFinal '- No score, no grade, no coaching is produced anywhere. Every derived statement is labelled'
AddFinal '  `derived_observation` and states a measured time difference beside the co-occurring measured'
AddFinal '  differences; it never asserts causation.'
AddFinal '- An unavailable quantity stays `null` with a status and is never published as `0`.'
AddFinal '- Different or unresolved ResourceMapIDs are never compared.'
AddFinal '- Section correspondence uses official world XY, observed heading and motion direction only. No'
AddFinal '  canonical line, reference line, TrackTopology or curvature-derived action is involved.'
AddFinal '- A matched pair whose two sections are far larger than their time difference is a boundary-'
AddFinal '  placement fact, not a driving fact; the measured separation is published beside every window.'
AddFinal '- 	op_loss_sections holds only `delta > 0` (largest first) and `top_gain_sections` only'
AddFinal '  `delta < 0` (largest magnitude first); loss and gain are never mixed.'
AddFinal ''
AddFinal '## 5. Measured corpus (after)'
AddFinal ''
AddFinal '| test id | map | fastest lap (s) | laps | sections | time-loss entries | intra status |'
AddFinal '| --- | --- | --- | --- | --- | --- | --- |'
foreach($e in $entries){
    AddFinal ('| ' + (T $e.test_id) + ' | ' + (T $e.map.resource_map_id) + ' | ' + (S $e.training.fastest_lap_s 3) + ' | ' + @($e.training.lap_times_s).Count + ' | ' + (T $e.training.section_count) + ' | ' + (T $e.training.time_loss_entries) + ' | ' + (T $e.training.intra_replay_status) + ' |')
}
AddFinal ''
AddFinal '## 6. Same-map A/B cases'
AddFinal ''
if($abCases.Count -eq 0){
    AddFinal 'No same-map A/B case exists in this corpus: no official ResourceMapID is shared by two in-scope'
    AddFinal 'replays. The comparison path is implemented and fail-closed; it stays `comparison_unavailable`'
    AddFinal 'rather than comparing two different tracks.'
} else {
    AddFinal '| subject | baseline | resource map | status | faster | delta (s) | windows | matched | top loss window | top loss (s) | top gain (s) | residual (s) | tolerance (s) |'
    AddFinal '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
    foreach($c in $abCases){
        $cmp=$c.comparison
        $topWin='';$topDelta=''
        if($null-ne$cmp -and $null-ne$cmp.breakdown -and @($cmp.breakdown.top_loss_sections).Count -gt 0){
            $t0=@($cmp.breakdown.top_loss_sections)[0]
            $topWin=[string]$t0.comparison_window_id;$topDelta=S $t0.time.delta_s 3
        }
        $topGain=''
        if($null-ne$cmp -and $null-ne$cmp.breakdown -and @($cmp.breakdown.top_gain_sections).Count -gt 0){
            $topGain=S (@($cmp.breakdown.top_gain_sections)[0]).time.delta_s 3
        }
        $bd=$(if($null-ne$cmp){$cmp.breakdown}else{$null})
        $res=$(if($null-ne$bd){S $bd.reconciliation.residual_s 3}else{'n/a'})
        $tol=$(if($null-ne$bd){S $bd.reconciliation.tolerance_s 3}else{'n/a'})
        $mt=$(if($null-ne$bd){T $bd.matched_window_count}else{'0'})
        $wc=$(if($null-ne$bd){T $bd.window_count}else{'0'})
        AddFinal ('| ' + (T $c.test_id_a) + ' | ' + (T $c.test_id_b) + ' | ' + (T $c.resource_map_id) + ' | ' + (T $c.status) + ' | ' + (T $c.faster) + ' | ' + (S $c.total_delta_s 3) + ' | ' + $wc + ' | ' + $mt + ' | ' + $topWin + ' | ' + $topDelta + ' | ' + $topGain + ' | ' + $res + ' | ' + $tol + ' |')
    }
}
AddFinal ''
AddFinal '## 7. Per-replay time-loss detail'
AddFinal ''
$any=0
foreach($e in $entries){
    if([int]$e.training.time_loss_entries -le 0){continue}
    $any++
    AddFinal ('### ' + (T $e.test_id) + ' (sha16 `' + (T $e.sha16) + '`, resource map ' + (T $e.map.resource_map_id) + ')')
    AddFinal ''
    foreach($tl in @($e.training.time_loss)){
        $b=$tl.breakdown
        $rec=Prop $b 'reconciliation'
        AddFinal ('- **L' + (T $tl.lap) + ' vs L' + (T $tl.compared_against_lap) + '** · total delta **' + (S $tl.total_delta_s 3) + ' s** (= subject − baseline) · status `' + (T $tl.status) + '`')
        AddFinal ('  - matched windows: ' + (S $rec.matched_delta_s 3) + ' s')
        AddFinal ('  - unmatched windows: ' + (S $rec.unmatched_delta_s 3) + ' s')
        AddFinal ('  - non-comparison stretches: ' + (S $rec.non_comparison_delta_s 3) + ' s')
        AddFinal ('  - residual: ' + (S $rec.residual_s 3) + ' s (derived tolerance ' + (S $rec.tolerance_s 3) + ' s, residual consumes ' + (S $rec.residual_ratio 3) + ' of it)')
        AddFinal ('  - coverage: subject ' + (S (Prop $b 'coverage').subject 3) + ' · baseline ' + (S (Prop $b 'coverage').baseline 3) + ' · combined ' + (S (Prop $b 'coverage').combined 3))
        AddFinal ('  - windows: ' + (T $b.window_count) + ' (matched ' + (T $b.matched_window_count) + ' / unmatched ' + (T $b.unmatched_window_count) + ') · correspondence pairs ' + (T (Prop $b 'correspondence').pair_count) + ' · breaks ' + (T (Prop $b 'correspondence').break_count) + ' · components ' + (T (Prop $b 'correspondence').component_count))
        AddFinal ('  - tolerance basis: ' + (T $rec.tolerance_basis))
        if(@($b.top_loss_sections).Count -gt 0){
            AddFinal ''
            AddFinal '  Time LOSS windows (subject slower, delta > 0):'
            AddFinal ''
            AddFinal '  | window | delta (s) | direction | mean sep (m) | entry d (m/s) | min d (m/s) | exit d (m/s) | drift dur d (s) | drift count d | boost lat d (ms) | route dist d (m) | CW/WCW/CWW d |'
            AddFinal '  | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
            foreach($s0 in @($b.top_loss_sections)){
                AddFinal ('  | ' + (T $s0.comparison_window_id) + ' | ' + (S $s0.time.delta_s 3) + ' | ' + (T $s0.time.direction) + ' | ' + (S (Prop $s0 'correspondence').mean_separation_m 2) + ' | ' + (S (Prop $s0 'speed').delta.entry_mps 2) + ' | ' + (S (Prop $s0 'speed').delta.min_mps 2) + ' | ' + (S (Prop $s0 'speed').delta.exit_mps 2) + ' | ' + (S (Prop $s0 'native').delta.drift_active_s 3) + ' | ' + (T (Prop $s0 'native').delta.logical_drift_count) + ' | ' + (T (Prop $s0 'native').delta.boost_latency_median_ms) + ' | ' + (S (Prop $s0 'space').delta_distance_m 2) + ' | ' + (T (Prop $s0 'native').delta.cw) + '/' + (T (Prop $s0 'native').delta.wcw) + '/' + (T (Prop $s0 'native').delta.cww) + ' |')
            }
        }
        if(@($b.top_gain_sections).Count -gt 0){
            AddFinal ''
            AddFinal '  Time GAIN windows (subject faster, delta < 0), kept separate from loss:'
            AddFinal ''
            AddFinal '  | window | delta (s) | direction | mean sep (m) | entry d (m/s) | min d (m/s) | exit d (m/s) | drift dur d (s) | drift count d | boost lat d (ms) | route dist d (m) | CW/WCW/CWW d |'
            AddFinal '  | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
            foreach($s0 in @($b.top_gain_sections)){
                AddFinal ('  | ' + (T $s0.comparison_window_id) + ' | ' + (S $s0.time.delta_s 3) + ' | ' + (T $s0.time.direction) + ' | ' + (S (Prop $s0 'correspondence').mean_separation_m 2) + ' | ' + (S (Prop $s0 'speed').delta.entry_mps 2) + ' | ' + (S (Prop $s0 'speed').delta.min_mps 2) + ' | ' + (S (Prop $s0 'speed').delta.exit_mps 2) + ' | ' + (S (Prop $s0 'native').delta.drift_active_s 3) + ' | ' + (T (Prop $s0 'native').delta.logical_drift_count) + ' | ' + (T (Prop $s0 'native').delta.boost_latency_median_ms) + ' | ' + (S (Prop $s0 'space').delta_distance_m 2) + ' | ' + (T (Prop $s0 'native').delta.cw) + '/' + (T (Prop $s0 'native').delta.wcw) + '/' + (T (Prop $s0 'native').delta.cww) + ' |')
            }
        }
        AddFinal ''
    }
}
if($any -eq 0){
    AddFinal 'No replay in this corpus produced a time-loss decomposition. This is published as'
    AddFinal '`comparison_unavailable` per replay rather than as an invented result.'
    AddFinal ''
}

$finalText=($flines -join "`r`n")

if(-not [string]::IsNullOrWhiteSpace($BaselineOut)){
    [IO.File]::WriteAllText($BaselineOut,$baselineText,(New-Object System.Text.UTF8Encoding -ArgumentList $true))
    Write-Host ('[Training] baseline report = '+$BaselineOut)
}
if(-not [string]::IsNullOrWhiteSpace($FinalOut)){
    [IO.File]::WriteAllText($FinalOut,$finalText,(New-Object System.Text.UTF8Encoding -ArgumentList $true))
    Write-Host ('[Training] final report = '+$FinalOut)
}
exit 0
