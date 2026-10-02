param(
    # Tools\TrainingAnalysis\<this file> -> Data\App
    # Tools\TrainingAnalysis\<this file> -> Data\App. $PSScriptRoot is reliable under -File.`n    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    # Cold = the caches were cleared (true cold reset) before this run. Warm = caches in place.
    [ValidateSet('Cold','Warm')][string]$Mode='Warm',
    # Reuse the analysis JSONs already in Output instead of driving the production chain again.
    [switch]$SkipAnalyze,
    [string]$Only='',
    [string]$OutDir='',
    [switch]$NoDerivedPurge,
    [switch]$StreamChildOutput
)
# Tools\TrainingAnalysis\<this file> -> Data\App. Derive the app directory from $PSScriptRoot,
# which is populated when the script is invoked with -File.
if([string]::IsNullOrWhiteSpace($AppDir)){ $AppDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}

$dataDir=Split-Path -Parent $AppDir
$root=Split-Path -Parent $dataDir
. (Join-Path $AppDir 'Tests\September2026Corpus.ps1')
. (Join-Path $AppDir 'Tests\TrainingAnalysisCorpus.ps1')
. (Join-Path $AppDir 'Modules\Native\NativeDrivingAnalysis.ps1')
. (Join-Path $AppDir 'Modules\Native\NativeDrivingEpisodes.ps1')
. (Join-Path $AppDir 'Modules\Native\NativeTrainingSections.ps1')
. (Join-Path $AppDir 'Modules\Native\NativeTrainingTimeLoss.ps1')
. (Join-Path $AppDir 'Modules\Native\NativeTrainingAnalysis.ps1')
. (Join-Path $AppDir 'Modules\Replay\Replay.Common.ps1')

# Production telemetry rows for one stream of one analysis. The analysis JSON stores the telemetry
# summary path relative to the project root, so an absolute path must never be joined again.
function Get-RowsForTraining([string]$TelemetrySummaryRel,[string]$StreamId){
    if([string]::IsNullOrWhiteSpace($TelemetrySummaryRel)){ return @() }
    $telPath=$(if([IO.Path]::IsPathRooted($TelemetrySummaryRel)){ $TelemetrySummaryRel }else{ Join-Path $root $TelemetrySummaryRel })
    if(-not(Test-Path -LiteralPath $telPath -PathType Leaf)){ return @() }
    $tel=Read-JsonFile $telPath
    if($null-eq$tel){ return @() }
    $csvRel=''
    foreach($s in @($tel.streams)){ if($null-ne$s-and[string]$s.id-eq$StreamId){$csvRel=[string]$s.csv;break} }
    if([string]::IsNullOrWhiteSpace($csvRel)){ foreach($s in @($tel.streams)){ if($null-ne$s){$csvRel=[string]$s.csv;break} } }
    if([string]::IsNullOrWhiteSpace($csvRel)){ return @() }
    $csv=Join-Path (Split-Path -Parent $telPath) $csvRel
    if(-not(Test-Path -LiteralPath $csv -PathType Leaf)){ return @() }
    return @(NDA-LoadRows $csv)
}

if([string]::IsNullOrWhiteSpace($OutDir)){ $OutDir=Join-Path $dataDir 'Diagnostics\Dev\training' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Read-JsonFile([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)){ return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}
function Prop($Object,[string]$Name){
    if($null -eq $Object){ return $null }
    # A nested block of the training contract is an IDictionary whose KEYS are not visible through
    # `PSObject.Properties`, so an ordered hashtable must be read by key.
    if($Object -is [System.Collections.IDictionary]){
        if($Object.Contains($Name)){ return $Object[$Name] }
        return $null
    }
    if(@($Object.PSObject.Properties.Name) -contains $Name){ return $Object.$Name }
    return $null
}
function Stat($arr,[string]$Which){
    if($null -eq $arr -or $arr.Count -eq 0){ return $null }
    if($Which -eq 'median'){ $m=[int][Math]::Floor($arr.Count/2); if($arr.Count%2 -eq 1){return [Math]::Round($arr[$m],2)}; return [Math]::Round(($arr[$m-1]+$arr[$m])/2.0,2) }
    if($Which -eq 'p90'){ $idx=[int][Math]::Ceiling($arr.Count*0.9)-1; if($idx -lt 0){$idx=0}; return [Math]::Round($arr[$idx],2) }
    if($Which -eq 'max'){ return [Math]::Round($arr[$arr.Count-1],2) }
    return $null
}
function Get-PhaseSecondsFromLog([string]$Text){
    $out=[ordered]@{}
    foreach($m in [regex]::Matches($Text,'\[完成\]\s+(?<what>[^\r\n]*?)\s+用时\s+(?<sec>[0-9.]+)\s*秒')){
        $key=[string]$m.Groups['what'].Value
        if($key -like '读取官方地图身份*'){ $out['map_identity_s']=[double]$m.Groups['sec'].Value }
        elseif($key -like '提取原生 Replay*'){ $out['telemetry_s']=[double]$m.Groups['sec'].Value }
        elseif($key -like '读取官方 Map*'){ $out['native_map_s']=[double]$m.Groups['sec'].Value }
    }
    return $out
}
# Output is a flat directory of `*_analysis.json` / `*_training.json` files that can be several MB
# each. The production entry point writes them as `Output\<replay stem>_analysis.json` /
# `_training.json`, so a corpus entry can be resolved by NAME in O(1). Looking the artifact up by
# scanning every Output file for a matching `replay_sha256` instead re-read and re-parsed the whole
# directory once per corpus entry (O(entries x files) parses, measured at ~18 minutes for the
# 30-entry corpus). The name-derived path is also what the analyzer itself uses, so the two can
# never disagree.
function Get-OutputArtifact($Entry,[string]$Suffix){
    if($null-eq$Entry){return $null}
    $stem=[string](Prop $Entry 'stem')
    if([string]::IsNullOrWhiteSpace($stem)){
        $src=[string](Prop $Entry 'source_path')
        if([string]::IsNullOrWhiteSpace($src)){return $null}
        $stem=[IO.Path]::GetFileNameWithoutExtension($src)
    }
    if([string]::IsNullOrWhiteSpace($stem)){return $null}
    return (Read-JsonFile (Join-Path (Join-Path $script:root 'Output') ($stem+$Suffix)))
}

$corpus=@(Get-TrainingAnalysisCorpus -ProjectRoot $root -YearMonth '2026-09')
if(-not [string]::IsNullOrWhiteSpace($Only)){
    $want=@($Only.Split(',') | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
    $corpus=@($corpus | Where-Object { $want -contains ([string]$_.test_id).ToUpperInvariant() })
}
$inScope=@($corpus | Where-Object { [bool]$_.in_scope })
Write-Host ('[Training] corpus total='+$corpus.Count+' in_scope='+$inScope.Count+' mode='+$Mode)

# ---------------------------------------------------------------------------------------------
# 1. Measure the corpus through the real production entry point.
# ---------------------------------------------------------------------------------------------
$rowsOut=New-Object System.Collections.Generic.List[object]
$entryIndex=0
foreach($e in $corpus){
    $entryIndex++
    $tid=[string]$e.test_id;$sha16=[string]$e.sha16
    # Visible progress: one line per corpus entry, so a long acceptance run can never look hung.
    Write-Host ('[Training] ['+[string]$entryIndex+'/'+[string]$corpus.Count+'] '+$tid+' sha16='+$sha16+' start')
    $entryDir=Join-Path $OutDir $tid
    New-Item -ItemType Directory -Force -Path $entryDir | Out-Null
    $stdoutPath=Join-Path $entryDir 'analyze_stdout.log'
    $elapsedS=$null;$exitCode=$null;$outText=@()
    if(-not $SkipAnalyze){
        $derivedTelemetryDir=Join-Path $dataDir ('Telemetry\'+$sha16)
        if((Test-Path -LiteralPath $derivedTelemetryDir) -and -not $NoDerivedPurge){ Remove-Item -LiteralPath $derivedTelemetryDir -Recurse -Force }
        $sw=[System.Diagnostics.Stopwatch]::StartNew()
        $outText = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $AppDir 'QQReplay.ps1') -Mode Analyze $e.source_path 2>&1 | ForEach-Object { [string]$_ }
        $exitCode=$LASTEXITCODE
        $sw.Stop()
        $elapsedS=[Math]::Round($sw.Elapsed.TotalSeconds,2)
        [IO.File]::WriteAllText($stdoutPath,($outText -join "`r`n"),(New-Object System.Text.UTF8Encoding -ArgumentList $true))
        if($StreamChildOutput){ $outText | ForEach-Object { Write-Host $_ } }
        Write-Host ('[Training] '+$tid+' exit='+[string]$exitCode+' elapsed='+[string]$elapsedS+'s')
    } else {
        if(Test-Path -LiteralPath $stdoutPath -PathType Leaf){ $outText=@(Get-Content -LiteralPath $stdoutPath -Encoding UTF8) }
    }

    $analysis=Get-OutputArtifact $e '_analysis.json'
    $training=Get-OutputArtifact $e '_training.json'
    $summary=Read-JsonFile (Join-Path $dataDir ('Telemetry\'+$sha16+'\telemetry_summary.json'))
    $profile=Read-JsonFile (Join-Path $dataDir ('Telemetry\'+$sha16+'\pipeline_profile.json'))
    $streams=@(Prop $summary 'streams')
    $primary=$null
    if($streams.Count -gt 0){
        $local=@($streams | Where-Object { [string](Prop $_ 'role') -eq 'local_high_frequency' })
        $primary=if($local.Count -gt 0){$local[0]}else{$streams[0]}
    }
    # The per-replay `time_loss` list lives on the TRAINING ARTIFACT (Output/<replay>_training.json),
    # not on the pass-through analysis block. Read it from there; the analysis block only carries the
    # intra-replay comparison summary.
    $artifact=$training
    $timeLossList=@()
    if($null -ne $artifact -and @($artifact.PSObject.Properties.Name) -contains 'time_loss'){ $timeLossList=@($artifact.time_loss) }
    $observedList=@()
    if($null -ne $artifact -and @($artifact.PSObject.Properties.Name) -contains 'observations'){ $observedList=@($artifact.observations) }
    $laps=New-Object System.Collections.Generic.List[object]
    $primaryTrainingStream=$null
    if($null -ne $training){
        $pid2=[string](Prop $training 'primary_stream_id')
        foreach($lr in @(Prop $training 'laps')){
            if($null -eq $lr){continue}
            if(-not [string]::IsNullOrWhiteSpace($pid2) -and [string](Prop $lr 'stream_id') -ne $pid2){continue}
            $laps.Add($lr)
        }
    }
    $lapTimes=@($laps | ForEach-Object { [double](Prop (Prop $_ 'time') 'lap_time_s') } | Where-Object { $_ -gt 0 } | Sort-Object)
    $driftLogical=$null;$driftRaw=$null
    $na=Prop $analysis 'native_actions'
    $prodDrift=Prop (Prop $primary 'production_actions') 'drift'
    if($null -ne $prodDrift){ $driftLogical=Prop $prodDrift 'logical_count';$driftRaw=Prop $prodDrift 'raw_intervals' }
    $episodes=Prop $analysis 'driving_episodes'
    $trainingStatus=Prop $analysis 'training_status'
    $sections=@($laps | ForEach-Object { @(Prop (Prop $_ 'spatial') 'sections') } | Where-Object { $null -ne $_ })
    $intraStatus=[string](Prop (Prop (Prop $training 'intra_replay_comparison') 'status') $null)
    $rowsOut.Add([pscustomobject][ordered]@{
        test_id=$tid
        sha16=$sha16
        sha256=[string]$e.sha256
        # The production entry point names its Output artifacts after the replay file stem; keeping it
        # here lets every later lookup resolve the artifact by name instead of rescanning Output.
        stem=[IO.Path]::GetFileNameWithoutExtension([string]$e.source_path)
        size_bytes=[long]$e.size_bytes
        recorded_at=$e.recorded_at
        origin=[string]$e.origin
        in_scope=[bool]$e.in_scope
        scope_reason=[string]$e.scope_reason
        has_local_shadow=$e.has_local_shadow
        has_network_shadow=$e.has_network_shadow
        analyze_exit=$exitCode
        elapsed_s=$elapsedS
        map=[ordered]@{
            game_map_id=$(Prop $analysis 'game_map_id')
            resource_map_id=$(Prop $analysis 'resource_map_id')
            confidence=[string](Prop (Prop $analysis 'map_resolution') 'confidence')
            native_map_status=[string](Prop (Prop $analysis 'native_map') 'status')
            authoritative=[bool](Prop (Prop $analysis 'native_map') 'authoritative')
        }
        physical=[ordered]@{
            telemetry_status=[string](Prop $analysis 'telemetry_status')
            lap_count=$(if($null -ne $primary){Prop $primary 'lap_count'}else{$null})
            lap_count_status=$(if($null -ne $primary){[string](Prop $primary 'lap_status')}else{$null})
            duration_s=$(if($null -ne $primary){Prop $primary 'duration_s'}else{$null})
            distance_m=$(if($null -ne $primary){Prop $primary 'distance'}else{$null})
        }
        driving=[ordered]@{
            status=[string](Prop $analysis 'status')
            sections_status=[string](Prop (Prop $analysis 'driving_analysis') 'status')
            episode_status=[string](Prop $episodes 'status')
            episode_count=$(Prop $episodes 'episode_count')
            spatial_driving=[string](Prop (Prop $analysis 'driving_status') 'spatial_driving')
            lap_metrics=[string](Prop (Prop $analysis 'driving_status') 'lap_metrics')
        }
        drift=[ordered]@{
            available=$(if($null -ne $prodDrift){[bool](Prop $prodDrift 'available')}else{$false})
            raw_intervals=$driftRaw
            logical_count=$driftLogical
        }
        training=[ordered]@{
            present=($null -ne $training)
            status=$(if($null -ne $training){[string](Prop $training 'status')}else{$null})
            lap_analysis=$(if($null -ne $trainingStatus){[string](Prop $trainingStatus 'lap_analysis')}else{$null})
            episode_analysis=$(if($null -ne $trainingStatus){[string](Prop $trainingStatus 'episode_analysis')}else{$null})
            spatial_section=$(if($null -ne $trainingStatus){[string](Prop $trainingStatus 'spatial_section')}else{$null})
            intra_replay_status=[string](Prop (Prop $training 'comparisons') 'intra_replay.status')
            lap_records=$laps.Count
            lap_times_s=@($lapTimes)
            fastest_lap_s=$(if($lapTimes.Count -gt 0){[double]$lapTimes[0]}else{$null})
            slowest_lap_s=$(if($lapTimes.Count -gt 0){[double]$lapTimes[$lapTimes.Count-1]}else{$null})
            section_count=@($sections).Count
            time_loss_entries=$timeLossList.Count
            time_loss=@($timeLossList)
            observations=$observedList.Count
        }
        timing=[ordered]@{
            telemetry_total_ms=$(if($null -ne $profile){[long](Prop $profile 'total_ms')}else{$null})
            native_action_scan_ms=$(if($null -ne $profile){[long](Prop (Prop $profile 'native_action') 'scan_ms')}else{$null})
            physical_cache_mode=[string](Prop $profile 'physical_cache_mode')
        }
        phases=(Get-PhaseSecondsFromLog (($outText -join "`n")))
    })
}

# ---------------------------------------------------------------------------------------------
# 2. Same-map groups and the same-map A/B cases.
# ---------------------------------------------------------------------------------------------
$byMap=@{}
foreach($r in @($rowsOut.ToArray())){
    if(-not $r.in_scope){continue}
    $key=$(if($null -eq $r.map.resource_map_id){'unresolved'}else{('resource_'+[string][int]$r.map.resource_map_id)})
    if(-not $byMap.ContainsKey($key)){ $byMap[$key]=New-Object System.Collections.Generic.List[object] }
    $byMap[$key].Add($r)
}
$groups=New-Object System.Collections.Generic.List[object]
foreach($k in @($byMap.Keys|Sort-Object)){
    $m=@($byMap[$k].ToArray())
    $groups.Add([pscustomobject][ordered]@{
        group_key=$k
        resource_map_id=$(if($k -eq 'unresolved'){$null}else{[int]($k -replace '^resource_','')})
        replay_count=$m.Count
        test_ids=@($m|ForEach-Object{[string]$_.test_id})
        ab_comparable=($k -ne 'unresolved' -and $m.Count -ge 2)
        multi_lap_replays=@($m|Where-Object{@($_.training.lap_times_s).Count -ge 2}|ForEach-Object{[string]$_.test_id})
    })
}

$abCases=New-Object System.Collections.Generic.List[object]
foreach($g in @($groups.ToArray())){
    if(-not [bool]$g.ab_comparable){continue}
    $members=@($byMap[[string]$g.group_key].ToArray())
    for($i=0;$i -lt $members.Count;$i++){
        for($j=$i+1;$j -lt $members.Count;$j++){
            # SEMANTIC, CONFLICT-FREE NAMES. PowerShell variable names are case-INSENSITIVE, so the
            # previous subject-entry variable and the local |delta| inside the swap loop differed only
            # by CASE and were therefore the SAME variable: the loop overwrote the entry, and the case
            # record was published with an empty subject id while the baseline stayed intact. Never
            # reuse a name at another case.
            $subjectEntry=$members[$i];$baselineEntry=$members[$j]
            $subjectTraining=Get-OutputArtifact $subjectEntry '_training.json'
            $baselineTraining=Get-OutputArtifact $baselineEntry '_training.json'
            if($null -eq $subjectTraining -or $null -eq $baselineTraining){
                $abCases.Add([pscustomobject][ordered]@{test_id_a=[string]$subjectEntry.test_id;test_id_b=[string]$baselineEntry.test_id;status='unavailable_training_artifact_missing';comparison=$null})
                continue
            }
            $subjectAnalysis=Get-OutputArtifact $subjectEntry '_analysis.json';$baselineAnalysis=Get-OutputArtifact $baselineEntry '_analysis.json'
            $subjectTelemetry=Prop $subjectAnalysis 'telemetry_summary';$baselineTelemetry=Prop $baselineAnalysis 'telemetry_summary'
            # The analysis JSON stores the telemetry summary path RELATIVE to the project root, but an
            # absolute path must not be joined again or the CSV is never found and the comparison
            # silently degrades to "no anchor".
            $subjectRows=@();$baselineRows=@()
            try { $subjectRows=@(Get-RowsForTraining $subjectTelemetry $subjectTraining.primary_stream_id) } catch { Write-Host ('[Training] A/B subject rows load failed: '+$_.Exception.Message) }
            try { $baselineRows=@(Get-RowsForTraining $baselineTelemetry $baselineTraining.primary_stream_id) } catch { Write-Host ('[Training] A/B baseline rows load failed: '+$_.Exception.Message) }
            # The analysis JSON pass-through exposes `sections` as the COMPACT descriptor list, while
            # the training artifact carries the FULL contracts (with the measured entry/exit positions
            # the correspondence kernel anchors on). Prefer the full list whenever it is present;
            # never assign from a property that does not exist (in PowerShell `@($null).Count` is 1).
            $subjectCompare=$subjectTraining; $baselineCompare=$baselineTraining
            if(@($subjectTraining.PSObject.Properties.Name) -contains 'lived_sections'){ $subjectCompare.sections=$subjectTraining.lived_sections }
            if(@($baselineTraining.PSObject.Properties.Name) -contains 'lived_sections'){ $baselineCompare.sections=$baselineTraining.lived_sections }
            Write-Host ("[Training] A/B "+[string]$subjectEntry.test_id+" vs "+[string]$baselineEntry.test_id+" sectionsSubject="+[string]@($subjectCompare.sections).Count+" sectionsBaseline="+[string]@($baselineCompare.sections).Count+" rowsSubject="+[string]$subjectRows.Count+" rowsBaseline="+[string]$baselineRows.Count)
            # The subject is the first entry and the baseline is the second, so every signed metric is
            # `subject - baseline`.
            $cmp=Compare-NativeTrainingAnalyses -TrainingA $subjectCompare -TrainingB $baselineCompare -RowsA $subjectRows -RowsB $baselineRows `
                -LabelA ([string]$subjectEntry.test_id) -LabelB ([string]$baselineEntry.test_id)
            # SWAP INVARIANT, measured on the real pair: exchanging the roles must negate the total and
            # every stable matched window. A swap that does not negate is a correctness failure, so it
            # is recorded per case rather than assumed.
            $cmpSwap=Compare-NativeTrainingAnalyses -TrainingA $baselineCompare -TrainingB $subjectCompare -RowsA $baselineRows -RowsB $subjectRows `
                -LabelA ([string]$baselineEntry.test_id) -LabelB ([string]$subjectEntry.test_id)
            $swapTotalDelta=$null;$swapTotalOk=$null;$swapWindowsChecked=0;$swapWorstAbs=$null
            if($null -ne $cmp.overall.total_delta_s -and $null -ne $cmpSwap.overall.total_delta_s){
                $swapSum=[double]$cmp.overall.total_delta_s+[double]$cmpSwap.overall.total_delta_s
                $swapTotalDelta=[Math]::Round($swapSum,4)
                $swapTotalOk=([Math]::Abs($swapSum) -le 0.02)
            }
            $wAB=@($cmp.breakdown.windows);$wBA=@($cmpSwap.breakdown.windows)
            if($wAB.Count -gt 0 -and $wAB.Count -eq $wBA.Count){
                $worst=0.0
                for($wi=0;$wi-lt$wAB.Count;$wi++){
                    $deltaAB=[double]$wAB[$wi].time.delta_s;$deltaBA=[double]$wBA[$wi].time.delta_s
                    $swapAbs=[Math]::Abs($deltaAB+$deltaBA)
                    if($swapAbs-gt$worst){$worst=$swapAbs}
                }
                $swapWindowsChecked=$wAB.Count
                $swapWorstAbs=[Math]::Round($worst,4)
            }
            Write-Host ("[Training] A/B status="+[string]$cmp.status+" windows="+[string]@($cmp.breakdown.windows).Count+" swap_total="+[string]$swapTotalDelta+" swap_worst_window="+[string]$swapWorstAbs)
            $subjectId=[string]$subjectEntry.test_id
            $baselineId=[string]$baselineEntry.test_id
            # HARD GATE on the published identities: a case whose subject or baseline id came back empty
            # is not evidence, and the review snapshot must never carry one. This is the assertion that
            # would have caught the case-collision defect at its source.
            if([string]::IsNullOrWhiteSpace($subjectId) -or [string]::IsNullOrWhiteSpace($baselineId)){
                throw ('same-map A/B case published an empty identity: subject="'+$subjectId+'" baseline="'+$baselineId+'"')
            }
            $abCases.Add([pscustomobject][ordered]@{
                test_id_a=$subjectId;test_id_b=$baselineId
                resource_map_id=$g.resource_map_id
                status=[string]$cmp.status
                faster=[string]$cmp.overall.faster
                total_delta_s=$cmp.overall.total_delta_s
                reconciliation_status=$(if($null-ne$cmp.breakdown){[string]$cmp.breakdown.reconciliation.status}else{$null})
                window_count=$(if($null-ne$cmp.breakdown){[int]$cmp.breakdown.window_count}else{$null})
                matched_window_count=$(if($null-ne$cmp.breakdown){[int]$cmp.breakdown.matched_window_count}else{$null})
                unmatched_window_count=$(if($null-ne$cmp.breakdown){[int]$cmp.breakdown.unmatched_window_count}else{$null})
                coverage=$(if($null-ne$cmp.breakdown){$cmp.breakdown.coverage.combined}else{$null})
                # NOTE: this must be an explicit nested hashtable. `swap={ ... }` would create a
                # ScriptBlock value, which ConvertTo-Json cannot serialise (it aborts the whole
                # report with "Cannot convert value to type System.String").
                swap=[ordered]@{
                    subject_baseline_sum_s=$swapTotalDelta
                    negates=$swapTotalOk
                    windows_checked=$swapWindowsChecked
                    worst_window_sum_abs_s=$swapWorstAbs
                }
                comparison=$cmp
                comparison_swapped=$cmpSwap
            })
        }
    }
}

# ---------------------------------------------------------------------------------------------
# 3. Reports.
# ---------------------------------------------------------------------------------------------
# The comparison verdict census. This is the number the milestone is judged on: how many
# lap-vs-fastest-lap decompositions actually reconcile once both sides share ONE spatial comparison
# instead of sectioning their own course independently.
$compReconciled=0;$compDegradedResidual=0;$compDegradedCoverage=0;$compUnavailable=0;$compTotal=0
foreach($r in @($rowsOut.ToArray())){
    foreach($tl in @($r.training.time_loss)){
        $compTotal++
        $st=[string]$tl.status
        if($st -eq 'reconciled'){$compReconciled++}
        elseif($st -eq 'degraded_low_correspondence_coverage'){$compDegradedCoverage++}
        elseif($st -like 'degraded*'){$compDegradedResidual++}
        else{$compUnavailable++}
    }
}
$measure=@($rowsOut.ToArray()|Where-Object{$null -ne $_.elapsed_s}|ForEach-Object{[double]$_.elapsed_s}|Sort-Object)
$report=[ordered]@{
    schema_version=1
    contract='training_analysis_acceptance_v1'
    mode=$Mode
    generated_at=(Get-Date).ToString('o')
    corpus_contract='TRAINING_ANALYSIS_CORPUS = replay\*.sav + Data\ReplayArchive\**\*.sav (recording month 2026-09), SHA256-deduplicated, ids T01.. by sorted SHA16'
    corpus_count=$rowsOut.Count
    delta_rule='delta = subject - baseline; positive means the subject is slower / larger / more'
    corpus=@($rowsOut.ToArray()|ForEach-Object{
        [pscustomobject][ordered]@{
            test_id=$_.test_id;sha16=$_.sha16;size_bytes=$_.size_bytes;recorded_at=$_.recorded_at
            origin=$_.origin;in_scope=$_.in_scope;scope_reason=$_.scope_reason
            has_local_shadow=$_.has_local_shadow;has_network_shadow=$_.has_network_shadow
        }
    })
    timing_summary=[ordered]@{count=$measure.Count;median_s=(Stat $measure 'median');p90_s=(Stat $measure 'p90');max_s=(Stat $measure 'max')}
    comparison_summary=[ordered]@{
        total=$compTotal
        reconciled=$compReconciled
        degraded=$compDegradedResidual+$compDegradedCoverage
        degraded_residual_exceeds_tolerance=$compDegradedResidual
        degraded_low_correspondence_coverage=$compDegradedCoverage
        unavailable=$compUnavailable
        rule='a comparison reconciles when the residual is inside the derived tolerance and the shared spatial coverage is at least the declared minimum'
    }
    map_groups=@($groups.ToArray())
    same_map_ab_cases=@($abCases.ToArray())
    entries=@($rowsOut.ToArray())
}
$reportPath=Join-Path $OutDir ('training_'+$Mode.ToLowerInvariant()+'.json')
[IO.File]::WriteAllText($reportPath,($report|ConvertTo-Json -Depth 20),(New-Object System.Text.UTF8Encoding -ArgumentList $true))

Write-Host ''
Write-Host ('[Training] entries='+$rowsOut.Count+' in_scope='+$inScope.Count)
$trainReady=@($rowsOut|Where-Object{[string]$_.training.status -eq 'ready'}).Count
$trainLap=@($rowsOut|Where-Object{[string]$_.training.lap_analysis -eq 'ready'}).Count
$trainEps=@($rowsOut|Where-Object{[string]$_.training.episode_analysis -eq 'ready'}).Count
$trainSpatial=@($rowsOut|Where-Object{[string]$_.training.spatial_section -eq 'ready'}).Count
$multiLap=@($rowsOut|Where-Object{@($_.training.lap_times_s).Count -ge 2}).Count
$withLoss=@($rowsOut|Where-Object{[int]$_.training.time_loss_entries -gt 0}).Count
Write-Host ('[Training] training_ready='+$trainReady+' lap='+$trainLap+' episodes='+$trainEps+' spatial='+$trainSpatial+' multi_lap_replays='+$multiLap+' replays_with_time_loss='+$withLoss)
Write-Host ('[Training] comparisons='+$compTotal+' reconciled='+$compReconciled+' degraded_residual='+$compDegradedResidual+' degraded_coverage='+$compDegradedCoverage+' unavailable='+$compUnavailable)
Write-Host ('[Training] map groups='+$groups.Count+' ab_comparable='+@($groups|Where-Object{[bool]$_.ab_comparable}).Count+' ab_cases='+$abCases.Count)
Write-Host ('[Training] timing median='+[string](Stat $measure 'median')+'s p90='+[string](Stat $measure 'p90')+'s max='+[string](Stat $measure 'max')+'s')
Write-Host ('[Training] report = '+$reportPath)
exit 0
