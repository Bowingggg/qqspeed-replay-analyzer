param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){ if(-not $Ok){ throw $Message } }
function Approx([double]$A,[double]$B,[double]$Tol){ return ([Math]::Abs($A-$B)-le$Tol) }

# ---------------------------------------------------------------------------
# Training Analysis v1.1 -- REAL replay regression.
#
# Belongs to the Real Regression gate. It drives the real production chain over replays that are
# pinned by SHA256 and asserts the training invariants that must hold on real data:
#
#   * lap count == the production telemetry native lap count
#   * per-lap logical drift accounting matches the production native Drift authority
#   * every section time is > 0, every section speed is finite, and the section order is monotonic
#   * the intra-replay comparison publishes ONE delta direction: the outer lap total and the
#     decomposition total are the same number, and matched + unmatched + non_comparison + residual
#     closes onto it
#   * `top_loss_sections` only holds real loss (delta > 0, ranked descending) and
#     `top_gain_sections` only holds real gain (delta < 0, ranked by magnitude descending)
#   * comparison windows are monotonic in shared progress and never separate further than the
#     declared maximum separation
#   * comparing A vs B and B vs A negates the total and every stable matched window (swap invariant)
#   * `unavailable` is published as null and never as 0
#   * the SAME official ResourceMapID is comparable and produces a real decomposition
#   * DIFFERENT official ResourceMapIDs are refused (permanent regression)
#
# The replays are located by SHA256 and skipped explicitly when absent, so a machine without the
# archive degrades to "not-present" instead of failing.
# ---------------------------------------------------------------------------

$dataDir=Split-Path -Parent $AppDir
$root=Split-Path -Parent $dataDir
$outputDir=Join-Path $root 'Output'

. (Join-Path $AppDir 'Tests\September2026Corpus.ps1')
. (Join-Path $AppDir 'Modules\Native\NativeDrivingAnalysis.ps1')
. (Join-Path $AppDir 'Modules\Native\NativeDrivingEpisodes.ps1')
. (Join-Path $AppDir 'Modules\Native\NativeTrainingSections.ps1')
. (Join-Path $AppDir 'Modules\Native\NativeTrainingTimeLoss.ps1')
. (Join-Path $AppDir 'Modules\Native\NativeTrainingAnalysis.ps1')

function Read-JsonFile([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)){ return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}
# Safe property read that also understands an ordered hashtable. The training contracts are built as
# `[pscustomobject][ordered]@{...}`, so a nested block is an IDictionary whose KEYS are NOT visible
# through `PSObject.Properties`. Without this the helper silently returned $null for every nested
# block, which made the assertions below skip instead of run.
function Prop($Object,[string]$Name){
    if($null -eq $Object){ return $null }
    if($Object -is [System.Collections.IDictionary]){
        if($Object.Contains($Name)){ return $Object[$Name] }
        return $null
    }
    if(@($Object.PSObject.Properties.Name) -contains $Name){ return $Object.$Name }
    return $null
}
function Find-AnalysisBySha([string]$Sha256){
    foreach($j in @(Get-ChildItem -LiteralPath $outputDir -File -Filter '*_analysis.json' -ErrorAction SilentlyContinue)){
        $cand=Read-JsonFile $j.FullName
        if($null -ne $cand -and [string](Prop $cand 'replay_sha256') -eq $Sha256){ return $cand }
    }
    return $null
}
function Get-RowsForStream($Analysis,[string]$StreamId){
    $telRel=[string](Prop $Analysis 'telemetry_summary')
    if([string]::IsNullOrWhiteSpace($telRel)){ return @() }
    $telPath=Join-Path $root $telRel
    if(-not(Test-Path -LiteralPath $telPath -PathType Leaf)){ return @() }
    $tel=Read-JsonFile $telPath
    if($null-eq$tel){ return @() }
    $csvRel=''
    foreach($s in @($tel.streams)){ if($null-ne$s-and[string]$s.id -eq $StreamId){$csvRel=[string]$s.csv;break} }
    if([string]::IsNullOrWhiteSpace($csvRel)){ return @() }
    $csv=Join-Path (Split-Path -Parent $telPath) $csvRel
    if(-not(Test-Path -LiteralPath $csv -PathType Leaf)){ return @() }
    try { return @(NDA-LoadRows $csv) } catch { return @() }
}

# The reconciliation and loss/gain contract of ONE comparison, whatever its verdict. Shared by the
# intra-replay and the same-map assertions so both paths are pinned by exactly the same rules.
function Assert-ComparisonContract([string]$Tag,$Comparison){
    $bd=Prop $Comparison 'breakdown'
    if($null-eq$bd){ return $false }
    $rec=Prop $bd 'reconciliation'
    Require ($null-ne$rec) ($Tag+': the comparison must publish a reconciliation block')
    $total=[double](Prop $bd 'total_delta_s')
    $outer=Prop $Comparison 'total_delta_s'
    if($null-ne$outer){
        Require (Approx ([double]$outer) $total 0.0002) ($Tag+': the outer lap delta and the decomposition total must be the SAME number ('+[string]$outer+' vs '+[string]$total+')')
    }
    $matched=Prop $rec 'matched_delta_s'
    if($null-eq$matched){ return $false }
    $sum=[double]$matched+[double](Prop $rec 'unmatched_delta_s')+[double](Prop $rec 'non_comparison_delta_s')+[double](Prop $rec 'residual_s')
    Require (Approx $sum $total 0.001) ($Tag+': matched+unmatched+non_comparison+residual must close onto total ('+[string]$sum+' vs '+[string]$total+')')
    $residualAbs=[Math]::Abs([double](Prop $rec 'residual_s'))
    $tol=[double](Prop $rec 'tolerance_s')
    Require ($tol -gt 0) ($Tag+': the tolerance must be published and positive')
    $bdStatus=[string](Prop $rec 'status')
    if($bdStatus -eq 'reconciled'){
        Require ($residualAbs -le $tol) ($Tag+': a reconciled comparison must be inside the derived tolerance: '+[string]$residualAbs+' > '+[string]$tol)
    } elseif($bdStatus -eq 'degraded_residual_exceeds_tolerance'){
        Require ($residualAbs -gt $tol) ($Tag+': degraded_residual_exceeds_tolerance must mean the residual really exceeded the tolerance')
    } elseif($bdStatus -eq 'degraded_low_correspondence_coverage'){
        $cov=Prop $bd 'coverage'
        Require ([double](Prop $cov 'combined') -lt [double](Prop $cov 'min_coverage')) ($Tag+': degraded_low_correspondence_coverage must mean the coverage really is below the minimum')
    } else {
        Require ($bdStatus -like 'degraded*' -or $bdStatus -like 'comparison_unavailable*') ($Tag+': unexpected reconciliation status '+$bdStatus)
    }
    # loss and gain are separated and ranked inside their own bucket
    $prev=[double]::PositiveInfinity
    foreach($s in @(Prop $bd 'top_loss_sections')){
        $d=[double](Prop (Prop $s 'time') 'delta_s')
        Require ($d -gt 0) ($Tag+': top_loss_sections must only hold time LOSS, found '+[string]$d)
        Require ($d -le $prev+1e-9) ($Tag+': top_loss_sections must be ranked by descending loss')
        $prev=$d
    }
    $prev=[double]::PositiveInfinity
    foreach($s in @(Prop $bd 'top_gain_sections')){
        $d=[double](Prop (Prop $s 'time') 'delta_s')
        Require ($d -lt 0) ($Tag+': top_gain_sections must only hold time GAIN, found '+[string]$d)
        $mag=[Math]::Abs($d)
        Require ($mag -le $prev+1e-9) ($Tag+': top_gain_sections must be ranked by descending magnitude')
        $prev=$mag
    }
    # every window is a real forward interval on the shared progress, inside the separation gate
    $prevEnd=-1.0
    foreach($w in @(Prop $bd 'windows')){
        $sp=Prop (Prop $w 'space') 'subject'
        $s0=[double](Prop $sp 'start_progress');$s1=[double](Prop $sp 'end_progress')
        Require ($s1 -gt $s0) ($Tag+': a comparison window must be a forward interval on the shared progress')
        Require ($s0 -ge $prevEnd-1e-9) ($Tag+': comparison windows must be monotonic in shared progress')
        $prevEnd=$s1
        $cs=Prop $w 'correspondence'
        Require ([double](Prop $cs 'max_separation_m') -le [double](Prop $cs 'max_separation_threshold_m')+1e-6) ($Tag+': a window must never exceed the maximum separation gate')
        $dir=[string](Prop (Prop $w 'time') 'direction')
        $dt=[double](Prop (Prop $w 'time') 'delta_s')
        if($dt -gt 0.0005){ Require ($dir -eq 'slower') ($Tag+': a positive window delta must read slower') }
        elseif($dt -lt -0.0005){ Require ($dir -eq 'faster') ($Tag+': a negative window delta must read faster') }
    }
    # a natural-language observation may never contradict its own sign
    foreach($o in @(Prop $Comparison 'observations')){
        $dt=Prop $o 'delta_time_s'
        if($null-eq$dt){continue}
        $d=[double]$dt
        if($d -gt 0.0005){ Require ([string](Prop $o 'direction') -eq 'slower') ($Tag+': an observation must never call a loss faster') }
        elseif($d -lt -0.0005){ Require ([string](Prop $o 'direction') -eq 'faster') ($Tag+': an observation must never call a gain slower') }
    }
    return $true
}

# ---- 1. per-replay training invariants -----------------------------------------------------
function Assert-Training {
    param([string]$Tag,[string]$Sha256,[int]$ExpectedLaps,[int]$ExpectedDrift,[int]$ExpectedMapId=-1)
    $analysis=Find-AnalysisBySha $Sha256
    if($null-eq$analysis){ Write-Host ('  ['+$Tag+'] analysis-not-present (skipped)'); return $null }
    $tr=Prop $analysis 'training_analysis'
    Require ($null-ne$tr) ($Tag+': the analysis must carry a training_analysis block')
    Require ([string](Prop $tr 'contract') -eq 'native_training_analysis_v1') ($Tag+': training contract mismatch')
    Require ([string](Prop $tr 'status') -like 'ready*') ($Tag+': training status must be ready, got '+[string](Prop $tr 'status'))
    $caps=Prop $tr 'capabilities'
    Require ([string](Prop $caps 'lap_analysis') -eq 'ready') ($Tag+': level 1 lap analysis must be ready')

    $laps=@(Prop $tr 'laps')
    Require ($laps.Count -ge $ExpectedLaps) ($Tag+': expected at least '+[string]$ExpectedLaps+' laps, got '+[string]$laps.Count)
    $streamId=[string](Prop $tr 'primary_stream_id')
    $primary=@($laps|Where-Object{[string](Prop $_ 'stream_id') -eq $streamId})
    Require ($primary.Count -eq $ExpectedLaps) ($Tag+': primary stream lap count mismatch: '+[string]$primary.Count+' != '+[string]$ExpectedLaps)

    $driftSum=0
    foreach($l in $primary){
        $t=Prop $l 'time'
        Require ([double](Prop $t 'lap_time_s') -gt 0) ($Tag+': lap time must be positive')
        Require ([double](Prop $t 'lap_end_s') -gt [double](Prop $t 'lap_start_s')) ($Tag+': lap window must be positive')
        $sp=Prop $l 'speed'
        foreach($k in @('average_mps','max_mps','median_mps','min_mps','moving_min_mps')){
            $v=Prop $sp $k
            Require ($null -ne $v) ($Tag+': lap speed '+$k+' must be published')
            Require (-not[double]::IsNaN([double]$v) -and -not[double]::IsInfinity([double]$v)) ($Tag+': lap speed '+$k+' must be finite')
        }
        Require ([double](Prop $sp 'min_mps') -le [double](Prop $sp 'max_mps')) ($Tag+': lap min speed must not exceed max speed')
        $nat=Prop $l 'native'
        Require ([bool](Prop $nat 'available')) ($Tag+': native drift must be available per lap')
        $driftSum+=[int](Prop $nat 'logical_drift_count')
        $eg=Prop $l 'episode_aggregates'
        Require ([int](Prop $eg 'episode_count') -eq [int](Prop $nat 'logical_drift_count')) ($Tag+': a lap episode count must equal its logical drift count')
        # Section invariants: positive time, finite speed, monotonic order inside the lap.
        $sections=@(Prop (Prop $l 'spatial') 'sections')
        $prevEnd=-1.0;$ordinal=0
        foreach($s in $sections){
            $ordinal++
            Require ([double](Prop $s 'duration_s') -gt 0) ($Tag+': section '+[string](Prop $s 'section_id')+' duration must be > 0')
            Require ([double](Prop $s 'start_t') -lt [double](Prop $s 'end_t')) ($Tag+': section window must be positive')
            Require ([double](Prop $s 'end_t') -ge $prevEnd) ($Tag+': section order must be monotonic')
            $prevEnd=[double](Prop $s 'end_t')
            Require ([int](Prop $s 'ordinal') -eq $ordinal) ($Tag+': section ordinal must be the in-lap sequence position')
            foreach($k in @('entry_speed_mps','min_speed_mps','exit_speed_mps')){
                $v=Prop $s $k
                Require ($null -ne $v) ($Tag+': section speed '+$k+' must be published')
                Require (-not[double]::IsNaN([double]$v) -and -not[double]::IsInfinity([double]$v)) ($Tag+': section speed '+$k+' must be finite')
            }
            # Availability must never propagate: a section keeps its drift annotation even when the
            # action event table is a variant.
            if(-not [bool](Prop (Prop $l 'actions') 'available')){
                Require ($null -eq (Prop $s 'cw')) ($Tag+': an unavailable action event table must null CW, never 0')
                Require ($null -ne (Prop $s 'logical_drift_count')) ($Tag+': an unavailable action event table must NOT null the drift annotation')
            }
        }
    }
    Require ($driftSum -eq $ExpectedDrift) ($Tag+': primary logical drift sum mismatch: '+[string]$driftSum+' != '+[string]$ExpectedDrift)
    if($ExpectedMapId -gt 0){
        Require ([int](Prop $tr 'resource_map_id') -eq $ExpectedMapId) ($Tag+': resource map id mismatch: '+[string](Prop $tr 'resource_map_id')+' != '+[string]$ExpectedMapId)
        Require ([string](Prop $tr 'map_authority') -eq 'authoritative') ($Tag+': map authority must be authoritative')
        Require ([string](Prop $caps 'spatial_section') -eq 'ready') ($Tag+': spatial sections must be ready for a map-resolved replay')
    } else {
        Require ([string](Prop $caps 'spatial_section') -eq 'unavailable_prerequisite') ($Tag+': spatial sections must be unavailable without a map identity')
        Require ([string](Prop $caps 'lap_analysis') -eq 'ready') ($Tag+': an unresolved map identity must NOT make lap analysis unavailable')
        Require ([string](Prop $caps 'episode_analysis') -eq 'ready') ($Tag+': an unresolved map identity must NOT make episode analysis unavailable')
    }
    Write-Host ('  ['+$Tag+'] training='+[string](Prop $tr 'status')+' laps='+[string]$laps.Count+' primary-laps='+[string]$primary.Count+' drift='+[string]$driftSum+' sections='+[string](Prop $tr 'section_count')+' spatial='+[string](Prop $caps 'spatial_section'))
    return $analysis
}

# Gold B -- City Torch, ResourceMapID 29: 34 logical drift, 3 native laps.
$goldB=Assert-Training -Tag 'goldB' -Sha256 '3164A4F8AFA71A832B30E55A7228C6FA08A9DFCE683689BA33CE8A18CF6A3623' -ExpectedLaps 3 -ExpectedDrift 34 -ExpectedMapId 29
# Gold A -- Old Street Pipeline: 22 logical drift, 3 native laps. This replay used to be the real
# example of "no authoritative map identity", so the case doubled as the map-independent /
# map-dependent capability split. The resource folder `Map12` declares `mapId = 112`
# (docs/decisions/0014), so it now carries an authoritative ResourceMapID 12 and the positive half of
# the split applies here; the negative half stays covered by this function's own `else` branch (which
# still fires on a client where that row is not declared) and by `Smoke-NativeDrivingEpisodes.ps1` /
# `Smoke-NativeDrivingEpisodesReal.ps1`.
$goldA=Assert-Training -Tag 'goldA' -Sha256 '50436400DE8FF37EA45363470EE8B06112628DABB2F33C22C3AA577FBA641253' -ExpectedLaps 3 -ExpectedDrift 22 -ExpectedMapId 12

# ---- 2. intra-replay comparison: one delta direction, exact closure -------------------------
$checked=0
foreach($pair in @(@('goldB',$goldB),@('goldA',$goldA))){
    $tag=[string]$pair[0];$analysis=$pair[1]
    if($null-eq$analysis){continue}
    $tr=Prop $analysis 'training_analysis'
    $intra=Prop (Prop $tr 'comparisons') 'intra_replay'
    $cmp=@(Prop $intra 'comparisons')
    if($cmp.Count -eq 0){
        Require ([string](Prop $intra 'status') -like 'unavailable*') ($tag+': a comparison-less intra block must publish an unavailable status')
        Write-Host ('  ['+$tag+'] intra-replay: '+[string](Prop $intra 'status')+' (published, not invented)')
        continue
    }
    foreach($c in $cmp){
        if(-not (Assert-ComparisonContract -Tag ($tag+' intra L'+[string](Prop $c 'lap')) -Comparison $c)){ continue }
        $bd=Prop $c 'breakdown'
        Write-Host ('  ['+$tag+'] intra L'+[string](Prop $c 'lap')+' vs L'+[string](Prop $c 'compared_against_lap')+' total='+[string](Prop $bd 'total_delta_s')+'s status='+[string](Prop (Prop $bd 'reconciliation') 'status')+' windows='+[string](Prop $bd 'window_count')+' loss='+[string]@(Prop $bd 'top_loss_sections').Count+' gain='+[string]@(Prop $bd 'top_gain_sections').Count)
        $checked++
    }
}

# ---- 3. same-map A/B: comparable, reconciling, and swap-invariant --------------------------
$sameMapChecked=0
$byMap=@{}
foreach($a in @(Get-ChildItem -LiteralPath $outputDir -File -Filter '*_analysis.json' -ErrorAction SilentlyContinue)){
    $j=Read-JsonFile $a.FullName
    if($null-eq$j){continue}
    $tr=Prop $j 'training_analysis'
    if($null-eq$tr){continue}
    $rid=Prop $tr 'resource_map_id'
    $auth=[string](Prop $tr 'map_authority')
    $key=$(if($null-eq$rid -or $auth -ne 'authoritative'){'unresolved'}else{('resource_'+[string][int]$rid)})
    if($key -eq 'unresolved'){continue}
    if(-not $byMap.ContainsKey($key)){ $byMap[$key]=New-Object System.Collections.Generic.List[object] }
    $byMap[$key].Add([pscustomobject]@{analysis=$j;training=$tr})
}
foreach($k in @($byMap.Keys|Sort-Object)){
    $m=@($byMap[$k].ToArray()|Sort-Object {[string]$_.training.replay_sha256})
    if($m.Count -lt 2){continue}
    $ta=$m[0].training;$tb=$m[1].training
    $sa=[string](Prop $ta 'primary_stream_id');$sb=[string](Prop $tb 'primary_stream_id')
    $rowsA=Get-RowsForStream $m[0].analysis $sa
    $rowsB=Get-RowsForStream $m[1].analysis $sb
    if($rowsA.Count -eq 0 -or $rowsB.Count -eq 0){
        Write-Host ('  [sameMap '+$k+'] telemetry-not-built (skipped)')
        continue
    }
    $cmp=Compare-NativeTrainingAnalyses -TrainingA $ta -TrainingB $tb -RowsA $rowsA -RowsB $rowsB -LabelA 'A' -LabelB 'B'
    Require ([bool](Prop (Prop $cmp 'gate') 'comparable')) ('sameMap '+$k+': the same authoritative ResourceMapID must be comparable')
    Require ([int](Prop (Prop $cmp 'gate') 'resource_map_id_a') -eq [int](Prop (Prop $cmp 'gate') 'resource_map_id_b')) ('sameMap '+$k+': resource ids must be equal')
    Require ($null -ne (Prop $cmp 'breakdown')) ('sameMap '+$k+': a comparable same-map case must publish a breakdown')
    Require ([string](Prop (Prop $cmp 'subject') 'role') -eq 'subject') ('sameMap '+$k+': the subject role must be explicit')
    Require ([string](Prop (Prop $cmp 'baseline') 'role') -eq 'baseline') ('sameMap '+$k+': the baseline role must be explicit')
    Assert-ComparisonContract -Tag ('sameMap '+$k) -Comparison $cmp | Out-Null

    # SWAP INVARIANT: the same two replays with the roles exchanged must negate every signed metric.
    $cmpSwap=Compare-NativeTrainingAnalyses -TrainingA $tb -TrainingB $ta -RowsA $rowsB -RowsB $rowsA -LabelA 'B' -LabelB 'A'
    $dAB=[double](Prop (Prop $cmp 'overall') 'total_delta_s')
    $dBA=[double](Prop (Prop $cmpSwap 'overall') 'total_delta_s')
    Require (Approx ($dAB+$dBA) 0.0 0.02) ('sameMap '+$k+': the total must negate under swap ('+[string]$dAB+' vs '+[string]$dBA+')')
    $bdAB=Prop $cmp 'breakdown';$bdBA=Prop $cmpSwap 'breakdown'
    if($null -ne $bdAB -and $null -ne $bdBA){
        $wAB=@(Prop $bdAB 'windows');$wBA=@(Prop $bdBA 'windows')
        Require ($wAB.Count -eq $wBA.Count) ('sameMap '+$k+': swapping must not change the shared window partition ('+[string]$wAB.Count+' vs '+[string]$wBA.Count+')')
        for($wi=0;$wi-lt$wAB.Count;$wi++){
            $x=[double](Prop (Prop $wAB[$wi] 'time') 'delta_s')
            $y=[double](Prop (Prop $wBA[$wi] 'time') 'delta_s')
            Require (Approx ($x+$y) 0.0 0.05) ('sameMap '+$k+': window '+[string]$wi+' must negate under swap ('+[string]$x+' vs '+[string]$y+')')
        }
        $lossAB=@(Prop $bdAB 'top_loss_sections');$gainBA=@(Prop $bdBA 'top_gain_sections')
        if($lossAB.Count -gt 0 -and $gainBA.Count -gt 0){
            Require (Approx ([double](Prop (Prop $lossAB[0] 'time') 'delta_s') + [double](Prop (Prop $gainBA[0] 'time') 'delta_s')) 0.0 0.05) ('sameMap '+$k+': the top loss and the swapped top gain must be the same magnitude')
        }
    }
    Write-Host ('  [sameMap '+$k+'] status='+[string](Prop $cmp 'status')+' delta='+[string]$dAB+'s swapped='+[string]$dBA+'s windows='+[string](Prop $bdAB 'window_count')+' rec='+[string](Prop (Prop $bdAB 'reconciliation') 'status'))
    $sameMapChecked++
}
if($sameMapChecked -eq 0){
    Write-Host '  [sameMap] no two authoritative same-map analyses are present (skipped)'
}

# ---- 4. PERMANENT REGRESSION: different ResourceMapID is never compared ---------------------
$refused=Compare-NativeTrainingAnalyses -TrainingA ([ordered]@{resource_map_id=29;map_authority='authoritative';laps=@();episode_streams=@();status='ready'}) -TrainingB ([ordered]@{resource_map_id=45;map_authority='authoritative';laps=@();episode_streams=@();status='ready'}) -LabelA 'A' -LabelB 'B'
Require ([string](Prop $refused 'status') -eq 'comparison_unavailable') 'different ResourceMapIDs must never be compared'
Require ($null -eq (Prop $refused 'breakdown')) 'a refused comparison must publish no breakdown'
Require (@(Prop $refused 'top_loss_sections').Count -eq 0) 'a refused comparison must publish no loss sections'
Require (@(Prop $refused 'top_gain_sections').Count -eq 0) 'a refused comparison must publish no gain sections'

$goldPresent=($null -ne $goldA -or $null -ne $goldB)
if(-not $goldPresent){
    Write-Host '[OK] Training Analysis real regression: gold analyses not present on this machine (skipped).'
    exit 0
}
$manifest=Get-Content -LiteralPath (Join-Path $AppDir 'app_manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
Write-Host ('[OK] Training Analysis real regression passed. app='+[string]$manifest.app_version+' goldA='+$(if($goldA){'verified'}else{'not-present'})+' goldB='+$(if($goldB){'verified'}else{'not-present'})+' intra-compared='+[string]$checked+' same-map-compared='+[string]$sameMapChecked+'; delta=subject-baseline + outer==breakdown + loss-gain-separated + windows-monotonic + swap-invariant + unavailable-is-null + same-map-comparable + different-map-refused')
exit 0
