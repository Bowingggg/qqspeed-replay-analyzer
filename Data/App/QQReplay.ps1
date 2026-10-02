param(
    [ValidateSet('Frontend','Analyze','Test')][string]$Mode='Frontend',
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Items,
    [switch]$ForceTelemetry,
    [switch]$ForceNativeActions,
    [switch]$ForceRaw
)

$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
$appDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir=Split-Path -Parent $appDir
$root=Split-Path -Parent $dataDir
$outputDir=Join-Path $root 'Output'
$settingsPath=Join-Path $dataDir 'settings.json'
$catalogScript=Join-Path $appDir 'QQSpeedMapCatalog.ps1'
$telemetryScript=Join-Path $appDir 'QQReplayTelemetry.ps1'
$nativeMapScript=Join-Path $appDir 'QQNativeMap.ps1'
New-Item -ItemType Directory -Force -Path $dataDir,$outputDir | Out-Null

. (Join-Path $appDir 'Modules\Replay\Replay.Common.ps1')
. (Join-Path $appDir 'Modules\Replay\Replay.ReadContext.ps1')
. (Join-Path $appDir 'Modules\Replay\Replay.Diagnostics.ps1')
. (Join-Path $appDir 'Modules\Replay\Replay.DevRebuild.ps1')
. (Join-Path $appDir 'Modules\Replay\Replay.MapIdentityResolver.ps1')
. (Join-Path $appDir 'Modules\Native\NativeDrivingAnalysis.ps1')
. (Join-Path $appDir 'Modules\Native\NativeDrivingEpisodes.ps1')
. (Join-Path $appDir 'Modules\Native\NativeTrainingSections.ps1')
. (Join-Path $appDir 'Modules\Native\NativeTrainingTimeLoss.ps1')
. (Join-Path $appDir 'Modules\Native\NativeTrainingAnalysis.ps1')
. (Join-Path $appDir 'Modules\Native\NativeAnalysisSegments.ps1')
. (Join-Path $appDir 'Modules\Native\NativeSegmentComparison.ps1')
. (Join-Path $appDir 'Modules\Native\NativeAnalysis.ps1')

function Test-NativeFirstResolution($Resolution) {
    if($null-eq$Resolution -or $null-eq$Resolution.resolved_map_id){return $false}
    $m=[string]$Resolution.resolution_method
    return ($m -eq 'trusted room catalog filename prefix + verified game/resource binding' -or
            $m -eq 'trusted room catalog filename prefix + user-confirmed game/resource binding' -or
            $m -eq 'exact map_desc.map_name catalog match')
}
function Get-NativeFirstIdentity($Resolution,[string]$ReplaySha,[string]$ReplayFile,[string]$AnalysisFile) {
    $accepted=Test-NativeFirstResolution $Resolution
    $rid=$(if($accepted){$Resolution.resolved_map_id}else{$null})
    $gid=$(if($null-ne$Resolution){$Resolution.game_map_id}else{$null})
    $display=''
    if($null-ne$rid){$entry=Get-MapEntry ([int]$rid);if($null-ne$entry){$display=[string]$entry.primary_name}}
    if([string]::IsNullOrWhiteSpace($display)-and$null-ne$Resolution){$display=[string]$Resolution.map_hint}
    $san=[pscustomobject]@{resolved_map_id=$rid;resolution_method=$(if($accepted){[string]$Resolution.resolution_method}else{'native_first_rejected_'+[string]$Resolution.resolution_method});confidence=$(if($accepted){[string]$Resolution.confidence}else{'unresolved'});game_map_id=$gid}
    $id=Resolve-ReplayMapIdentity -Resolution $san -MapId $rid -GameMapId $gid -MapName $display -ReplaySha256 $ReplaySha -ReplayFile $ReplayFile -AnalysisFile $AnalysisFile -DataDir $dataDir
    # Native-first authority never comes from a manual/display-only name.
    if($null-ne$id -and [bool]$id.authoritative -and $null-ne$id.resource_map_id){return $id}
    return $id
}
function Run-Analyze([string[]]$InputItems) {
    $files=Get-ReplayFiles $InputItems
    if($files.Count-eq0){Write-Host '[取消] 未选择录像。';return 0}
    foreach($p in @($catalogScript,$telemetryScript,$nativeMapScript)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){Write-Host ('[FAILED] 缺少：'+$p);return 1}}
    $game=Get-GamePath -AllowPrompt
    if([string]::IsNullOrWhiteSpace($game)-or-not(Test-Path -LiteralPath $game -PathType Container)){Write-Host '[FAILED] 未配置有效游戏目录。';return 1}

    Write-Host 'QQ飞车录像分析器 v3.7.22 · Native-First'
    Write-Host '规则: 不猜地图、不重建底图、不推断 DriftEnd、不自动 fallback 到旧语义。'
    Write-Host ('录像数: '+$files.Count)
    foreach($f in $files){Write-Host ('  '+[IO.Path]::GetFileName($f))}

    foreach($f in $files) {
        $name=[IO.Path]::GetFileName($f)
        # One read context per replay analysis: source identity is computed on first
        # request here and every downstream consumer reuses that same value.
        $readCtx=New-ReplayReadContext -Path $f
        $hash=Get-ReplayReadContextSha256 $readCtx
        $short=$hash.Substring(0,16)
        $analysisFile=[IO.Path]::GetFileNameWithoutExtension($f)+'_analysis.json'
        Write-Host ''
        Write-Host ('[NativeFirst] '+$name)

        # Map identity: official catalog/verified binding only. No fingerprint, geometry match,
        # replay-fit basemap, manual-name identity, descriptor text guess, or nearest timestamp guess.
        $rc=Invoke-PSChildVisible $catalogScript @('-Mode','Resolve','-GamePath',$game,'-ReplayFiles',[string]$f) ('读取官方地图身份：'+$name)
        if($rc-ne0){Write-Host '[WARN] 官方地图身份解析失败；仍继续提取原生录像数据。'}
        $resPath=Join-Path $dataDir ('ReplayResolution\'+$short+'.json')
        $res=NF-ReadJson $resPath
        $identity=Get-NativeFirstIdentity $res $hash $name $analysisFile
        if($null-ne$identity -and -not[string]::IsNullOrWhiteSpace([string]$identity.course_key)){[void](Update-MapIdentityRegistry -DataDir $dataDir -Identity $identity)}

        $telemetryDir=Join-Path $dataDir ('Telemetry\'+$short)
        $physicalCacheDir=Join-Path $dataDir ('PhysicalTelemetryCache\'+$short)
        # Native action evidence lives in its own validated cache root (<root>\<sha16>). -ForceTelemetry
        # re-derives action semantics from PhysicalTelemetryCache + NativeActionCache without re-scanning the SAV.
        $nativeActionCacheRoot=Join-Path $dataDir 'NativeActionCache'
        $args=@('-ReplayPath',[string]$f,'-OutDir',$telemetryDir,'-ReplaySha256',$hash,'-PhysicalCacheDir',$physicalCacheDir,'-NativeActionCacheRoot',$nativeActionCacheRoot)
        if($ForceTelemetry){$args+=@('-Force')}
        if($ForceNativeActions){$args+=@('-ForceNativeActions')}
        if($ForceRaw){$args+=@('-ForceRaw')}
        $trc=Invoke-PSChildVisible $telemetryScript $args ('提取原生 Replay：'+$name)
        $telemetryPath=Join-Path $telemetryDir 'telemetry_summary.json'
        if($trc-ne0 -or -not(Test-Path -LiteralPath $telemetryPath -PathType Leaf)){$telemetryPath=''}

        $mapMetaPath=''
        if($null-ne$identity -and [bool]$identity.authoritative -and $null-ne$identity.resource_map_id) {
            $mid=[int]$identity.resource_map_id
            $mrc=Invoke-PSChildVisible $nativeMapScript @('-MapId',$mid.ToString(),'-GamePath',$game) ('读取官方 Map'+$mid+' map.nif')
            $candidate=Join-Path $dataDir ('NativeMaps\Map'+$mid+'\metadata.json')
            if($mrc-eq0 -and (Test-Path -LiteralPath $candidate -PathType Leaf)){$mapMetaPath=$candidate}
            else{Write-Host ('[WARN] Map'+$mid+' 官方 map.nif 未就绪；不使用轨迹底图替代。')}
        } else {
            Write-Host '[INFO] 地图身份未达到 Native-First authority；不猜 Map ID，不构建候选底图。'
        }

        # One telemetry CSV load per analyze run, shared by the section and the episode derived
        # analyses (the real 6.4k-9k row CSVs are the dominant warm-path cost).
        $rowsCache=@{}
        $driving=$null
        if(-not[string]::IsNullOrWhiteSpace($telemetryPath) -and -not[string]::IsNullOrWhiteSpace($mapMetaPath)) {
            try {
            $driving=New-NativeDrivingAnalysis -ProjectRoot $root -TelemetrySummaryPath $telemetryPath -MapMetadataPath $mapMetaPath -RowsCache $rowsCache
        } catch {
            Write-Warning ('Native Driving Sections derived analysis failed; native-first core remains valid: '+$_.Exception.Message)
            $driving=[ordered]@{schema_version=1;contract='native_driving_sections_v1';detector_revision=3;status='failed_derived_analysis';authoritative=$false;error=$_.Exception.Message;streams=@()}
        }
        }

        # Driving v2: native driving episodes + lap metrics. These need only the production telemetry
        # and the replay-native action tables, so they are built whether or not the map identity was
        # resolved - a replay without an official map identity keeps its full native training value.
        $episodes=$null
        if(-not[string]::IsNullOrWhiteSpace($telemetryPath)) {
            try {
                $episodes=New-NativeDrivingEpisodes -ProjectRoot $root -TelemetrySummaryPath $telemetryPath -MapMetadataPath $mapMetaPath -DrivingSections $driving -RowsCache $rowsCache
            } catch {
                Write-Warning ('Native Driving Episodes derived analysis failed; native-first core remains valid: '+$_.Exception.Message)
                $episodes=[ordered]@{schema_version=1;contract='native_driving_episodes_v1';status='failed_derived_analysis';native_episode_analysis='unavailable';spatial_driving='unavailable_prerequisite';spatial_driving_reason=$_.Exception.Message;error=$_.Exception.Message;streams=@()}
            }
            # Section v2: attach the native-action measurements to the geometry sections so the
            # section view is a spatial container with native facts, not an action authority.
            if($null-ne$episodes-and$null-ne$driving-and[string]$driving.status-eq'ready') {
                foreach($es in @($episodes.streams)) {
                    $metrics=@($es.spatial.section_metrics)
                    if($metrics.Count-eq0){continue}
                    foreach($ds in @($driving.streams)) {
                        if([string]$ds.id-ne[string]$es.id){continue}
                        $allSecs=New-Object System.Collections.Generic.List[object]
                        foreach($dl in @($ds.laps)){foreach($sec in @($dl.sections)){$allSecs.Add($sec)}}
                        if($allSecs.Count-eq0){foreach($sec in @($ds.representative_sections)){$allSecs.Add($sec)}}
                        foreach($m in $metrics) {
                            foreach($sec in @($allSecs.ToArray())) {
                                if([string]$sec.id-eq[string]$m.section_id){$sec|Add-Member -NotePropertyName native_metrics_v2 -NotePropertyValue $m.metrics -Force}
                            }
                        }
                    }
                }
            }
        }

        # Training Analysis v1: Lap / Native Episode / Spatial Section / intra-replay comparison.
        # Level 1 (lap) and level 2 (native episodes) need no map identity; only level 3 (spatial
        # section) does, and it degrades independently. Nothing here redefines a native fact.
        $training=$null
        if(-not[string]::IsNullOrWhiteSpace($telemetryPath)) {
            try {
                $training=New-NativeTrainingAnalysis -ProjectRoot $root -TelemetrySummaryPath $telemetryPath -ReplaySha256 $hash `
                    -DrivingSections $driving -DrivingEpisodes $episodes -RowsCache $rowsCache -MapInfo $identity
            } catch {
                Write-Warning ('Training Analysis failed; native-first core remains valid: '+$_.Exception.Message)
                $training=[ordered]@{
                    schema_version=1;contract='native_training_analysis_v1';status='failed_derived_analysis'
                    error=$_.Exception.Message;laps=@();episodes=@();sections=@();comparisons=@();time_loss=@();observations=@()
                }
            }
        }

        $out=New-NativeFirstAnalysis -ProjectRoot $root -ReplayPath $f -ReplaySha256 $hash -MapIdentity $identity -Resolution $res -TelemetrySummaryPath $telemetryPath -NativeMapMetadataPath $mapMetaPath -DrivingAnalysis $driving -DrivingEpisodes $episodes -TrainingAnalysis $training
        $outPath=Join-Path $outputDir $analysisFile
        Write-JsonUtf8 $outPath $out
        Write-Host ('输出: '+$outPath)
        # Human-checkable training artifact beside the analysis JSON (same privacy rules: no player
        # nickname, no absolute path, no SAV bytes).
        if($null-ne$training-and[string]$training.contract-eq'native_training_analysis_v1') {
            try {
                $artifact=New-NativeTrainingArtifact -Training $training -SectionContracts @($training.lived_sections)
                $trainingPath=Join-Path $outputDir ([IO.Path]::GetFileNameWithoutExtension($f)+'_training.json')
                Write-JsonUtf8 $trainingPath $artifact
                Write-Host ('训练分析: '+$trainingPath)
            } catch {
                Write-Warning ('Training artifact write failed; the analysis JSON stays authoritative: '+$_.Exception.Message)
            }
        }
        Write-Host ('状态: '+[string]$out.status+' · actions='+[string]$out.native_actions.status+' · map='+[string]$out.native_map.status+' · driving='+[string]$out.driving_analysis.status+' · training='+[string]$out.training_analysis.status)
        if($null-ne$out.driving_analysis -and [string]$out.driving_analysis.status -eq 'ready') {
            foreach($ds in @($out.driving_analysis.streams)) {
                foreach($dl in @($ds.laps)) {
                    $dd=$dl.detector_diagnostics
                    if($null-eq$dd){continue}
                    Write-Host ('[DrivingDiag] '+[string]$ds.id+'/'+[string]$ds.role+' L'+[string]$dl.lap+
                        ' sections='+[string]$dl.section_count+
                        ' samples='+[string]$dd.valid_resampled_samples+'/'+[string]$dd.resampled_samples+
                        ' curve='+[string]$dd.curvature_runs_raw+'/'+[string]$dd.curvature_candidates_accepted+
                        ' reject='+[string]$dd.curvature_candidates_rejected+
                        ' drift='+[string]$dd.native_drift_segments_in_lap+'/'+[string]$dd.native_drift_overlapping_geometry+'/'+[string]$dd.native_drift_near_geometry+'/'+[string]$dd.native_drift_outside_geometry+
                        ' topoMut='+[string]$dd.native_drift_topology_mutations+
                        ' merge='+[string]$dd.premerge_candidates+'->'+[string]$dd.postmerge_candidates+
                        ' sigP95='+[string]$dd.abs_signal_p95_deg)
                }
            }
        }
    }
    return 0
}

function Run-Test {
    Write-Host 'Native-First v3 production chain:'
    Write-Host '  MapIdentity -> QQReplayTelemetry -> NativeActions -> map.nif -> Output'
    Write-Host 'Production authority: official identity / replay-native telemetry+actions / official map.nif'
    Write-Host 'Semantic fallback: none'
}
function Run-Frontend {
    $web=Join-Path $appDir 'QQReplayFrontend.ps1'
    if(Test-Path -LiteralPath $web -PathType Leaf){& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $web;return}
    throw 'QQReplayFrontend.ps1 不存在。'
}

switch($Mode){
    'Analyze' {
        $log=Start-AnalyzerTranscript;$rc=0
        try{$rc=Run-Analyze $Items}catch{Write-Host ('[FAILED] '+$_.Exception.Message);Write-Host ('位置: '+$_.InvocationInfo.PositionMessage);$rc=1}finally{Stop-AnalyzerTranscriptSafe}
        if($log){Write-Host ('诊断日志: '+$log)}
        exit $rc
    }
    'Test' {Run-Test}
    default {Run-Frontend}
}
