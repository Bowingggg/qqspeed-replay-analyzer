param(
    [Parameter(Mandatory=$true)][string]$ReplayPath,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [string]$ReplaySha256='',
    [string]$PhysicalCacheDir='',
    # Native action cache ROOT: the per-replay directory is <root>\<ReplaySHA前16位>.
    [string]$NativeActionCacheRoot='',
    [switch]$Force,
    [switch]$ForceRaw,
    [switch]$ForceNativeActions
)

$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
$toolVersion='3.8.0-native-first-v3-multishadow1'
# The raw physical cache contract covers the physical stream DETECTOR, not only the record
# decoder: a detector change alters which vehicle streams exist at all, so a cache written by an
# older detector must never be reused (it would keep reporting the old stream count).
$rawCacheContract='qpf_v2_nondec_ts_2026schema1_fastpipe1'
# Physical stream detector contract identity. Kept in script scope so the shadow-summary signature
# can be composed before the C# core is loaded, and cross-checked against the loaded core below.
$script:PhysicalDetectorContract='physical_streams_v2_nondec_ts'
# Derived telemetry summary schema revision. Bump this whenever the summary SHAPE changes (new or
# removed fields), exactly as the contract revisions below are bumped when a decoder contract
# changes: the shadow-summary guard is composed from these, so a shape change must not be masked by
# an already written summary. (18: added telemetry_semantic_signature and the stream max_speed.)
# (19: added the per-stream native action event ownership field and withheld the replay-global
#  native action table from non-local shadows.)
$script:TelemetrySchemaVersion=19
# The native Drift record contract changed: consecutive records are the two boundaries of one
# interval in either write order (see ReplayNativeDriftTimeline.ps1). The derived schema revision
# moves with it so no previously written summary can be reused across the change.
$script:TelemetryDriftTimelineSchemaVersion=4
$script:TelemetrySpeedEffectTimelineSchemaVersion=2

# Shadow-summary guard.
#
# A previously written `telemetry_summary.json` may only be reused when every contract that decides
# its content is unchanged. Keying that reuse on `extractor_version` alone is what let a native
# parser change keep serving the old summary - the "an old cache makes it look fine" failure mode.
# The signature is composed from the parser contracts themselves plus the derived schema revisions,
# so a change to any of them invalidates the shadow summary automatically. A summary that does not
# carry a signature at all fails closed and is rebuilt.
function Get-TelemetrySemanticSignature {
    $parts=@(
        ('schema='+[string]$script:TelemetrySchemaVersion)
        ('extractor='+[string]$toolVersion)
        # The physical stream detector decides how many logical shadows an already written summary
        # describes. It is part of the summary signature so a detector change rebuilds the summary
        # instead of serving the old stream count.
        ('physical_detector='+[string]$script:PhysicalDetectorContract)
        ('raw_cache='+[string]$rawCacheContract)
        ('drift_tl='+[string]$script:TelemetryDriftTimelineSchemaVersion)
        ('effect_tl='+[string]$script:TelemetrySpeedEffectTimelineSchemaVersion)
        ('action_event='+[string](Get-ReplayNativeActionEventContract))
        # The locator contract is part of the summary's semantic signature: a summary produced while
        # the locator could not reach a table must never be reused after the locator changed.
        ('action_event_locator='+[string](Get-ReplayNativeActionEventLocatorContract))
        ('action_semantics='+[string](Get-ReplayNativeActionSemanticsContract))
        ('action_scanner='+[string](Get-NativeActionScannerContract))
    )
    return ($parts -join '|')
}

$scriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
if([string]::IsNullOrWhiteSpace($scriptDir)){ throw 'Telemetry script directory could not be resolved.' }
if([string]::IsNullOrWhiteSpace($ReplayPath)){ throw 'ReplayPath is empty.' }
if([string]::IsNullOrWhiteSpace($OutDir)){ throw 'OutDir is empty.' }
. (Join-Path $scriptDir 'Modules\Telemetry\Telemetry.Analysis.ps1')
. (Join-Path $scriptDir 'Modules\Telemetry\Telemetry.PhysicalStreams.ps1')
. (Join-Path $scriptDir 'Modules\Telemetry\Telemetry.CSharpCore.ps1')
. (Join-Path $scriptDir 'Modules\Telemetry\ReplayNativeDriftTimeline.ps1')
. (Join-Path $scriptDir 'Modules\Telemetry\ReplayNativeSpeedEffects.ps1')
. (Join-Path $scriptDir 'Modules\Telemetry\ReplayNativeComboActions.ps1')
. (Join-Path $scriptDir 'Modules\Telemetry\ReplayNativeActionEvents.ps1')
. (Join-Path $scriptDir 'Modules\Telemetry\ReplayNativeActionSemantics.ps1')
. (Join-Path $scriptDir 'Modules\Telemetry\ReplayNativeActionCache.ps1')

if(-not (Test-Path -LiteralPath $ReplayPath -PathType Leaf)){ throw ('录像不存在: '+$ReplayPath) }
$sourceInfo=Get-Item -LiteralPath $ReplayPath
if([string]::IsNullOrWhiteSpace($ReplaySha256)){$ReplaySha256=(Get-FileHash -LiteralPath $ReplayPath -Algorithm SHA256).Hash.ToUpperInvariant()}
else{$ReplaySha256=$ReplaySha256.ToUpperInvariant()}

$pipelineWatch=[Diagnostics.Stopwatch]::StartNew()
$profileStages=New-Object System.Collections.Generic.List[object]
$lastProfileMs=0L
function Add-PipelineStage([string]$Name){
    $now=[long]$pipelineWatch.ElapsedMilliseconds
    $script:profileStages.Add([ordered]@{name=$Name;elapsed_ms=($now-$script:lastProfileMs);total_ms=$now})
    $script:lastProfileMs=$now
}

$summaryPath=Join-Path $OutDir 'telemetry_summary.json'
$profilePath=Join-Path $OutDir 'pipeline_profile.json'
$evidencePath=Join-Path $OutDir 'native_action_evidence_summary.json'
if(-not $Force -and -not $ForceNativeActions -and -not $ForceRaw -and (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
    try {
        $cached=Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cachedSignature=''
        if(@($cached.PSObject.Properties.Name) -contains 'telemetry_semantic_signature'){$cachedSignature=[string]$cached.telemetry_semantic_signature}
        if([string]$cached.extractor_version -eq $toolVersion -and [string]$cached.source_sha256 -eq $ReplaySha256 -and $cachedSignature -eq (Get-TelemetrySemanticSignature)) {
            Write-Host ('  [影子缓存] '+[IO.Path]::GetFileName($ReplayPath)+' -> '+[string]$cached.logical_stream_count+' 条')
            if(Test-Path -LiteralPath $profilePath -PathType Leaf){try{$cp=Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8|ConvertFrom-Json;Write-Host ('  [性能缓存] total='+[string]$cp.total_ms+'ms · physical='+[string]$cp.physical_cache_mode)}catch{}}
            exit 0
        }
    } catch {}
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if([string]::IsNullOrWhiteSpace($PhysicalCacheDir)){$PhysicalCacheDir=Join-Path $OutDir 'physical'}
$physicalDir=$PhysicalCacheDir
$physicalCachePath=Join-Path $physicalDir 'source_cache.json'
$manifestPath=Join-Path $physicalDir 'manifest.json'
$cacheScope=$(if($physicalDir.StartsWith($OutDir,[StringComparison]::OrdinalIgnoreCase)){'telemetry_local'}else{'persistent_project'})

# -Force rebuilds derived telemetry semantics, but intentionally preserves a validated raw qpf cache.
# -ForceRaw is the explicit escape hatch when the physical extractor itself changes or must be reprobed.
foreach($old in @(Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue | Where-Object{$_.Name -like 'logical_*.csv' -or $_.Name -in @('telemetry_summary.json','pipeline_profile.json','native_action_evidence_summary.json')})){
    Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
}

Write-Host ('  读取车辆流: '+[IO.Path]::GetFileName($ReplayPath))
Initialize-TelemetryCSharpCore -AppDir $scriptDir
Add-PipelineStage 'csharp_core_init'

# The script-scope detector contract identity and the loaded C# detector must be the same contract.
# If they ever drift, the cache descriptor below would describe a detector that is not the one that
# produced the data, so fail closed instead of writing a cache.
$coreDetectorContract=[string][QQReplayPortable]::PhysicalStreamDetectorContract
if($coreDetectorContract -ne [string]$script:PhysicalDetectorContract){
    throw ('physical stream detector contract mismatch: core="'+$coreDetectorContract+'" script="'+[string]$script:PhysicalDetectorContract+'"')
}

$physicalCacheHit=$false
$manifest=$null
if(-not$ForceRaw -and (Test-Path -LiteralPath $physicalCachePath -PathType Leaf) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)){
    try{
        $cache=Get-Content -LiteralPath $physicalCachePath -Raw -Encoding UTF8|ConvertFrom-Json
        # `detector_contract` is a required component of the descriptor. A descriptor written before
        # this field existed carries no detector identity at all, so it fails closed and is rebuilt
        # without the user having to clear derived data by hand.
        if([string]$cache.contract -eq $rawCacheContract -and [string]$cache.detector_contract -eq $coreDetectorContract -and [string]$cache.source_sha256 -eq $ReplaySha256 -and [long]$cache.source_size_bytes -eq [long]$sourceInfo.Length){
            $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
            $allFast=$true;$fastCount=0;$manifestReplays=@($manifest.replays)
            if($manifestReplays.Count-eq0){$allFast=$false}
            foreach($mrep in $manifestReplays){
                $manifestStreams=@($mrep.streams)
                if($manifestStreams.Count-eq0){$allFast=$false;break}
                foreach($ms in $manifestStreams){
                    if([string]$ms.physical_transport-ne'qpf_v1'){$allFast=$false;break}
                    $rel=([string]$ms.fastbin).Replace('/','\')
                    $fastPath=$(if([string]::IsNullOrWhiteSpace($rel)){$null}else{Join-Path $physicalDir $rel})
                    if($null-eq$fastPath -or -not(Test-Path -LiteralPath $fastPath -PathType Leaf) -or -not[QQReplayPortable]::ValidateFastBin($fastPath)){$allFast=$false;break}
                    $fastCount++
                }
                if(-not$allFast){break}
            }
            if($allFast -and $fastCount-gt0){$physicalCacheHit=$true}
        }
    }catch{$physicalCacheHit=$false;$manifest=$null}
}

if(-not$physicalCacheHit){
    if(Test-Path -LiteralPath $physicalDir){Remove-Item -LiteralPath $physicalDir -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $physicalDir|Out-Null
    [QQReplayPortable]::ExtractFastFromDelimited($ReplayPath,$physicalDir)
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    $cache=[ordered]@{schema_version=1;contract=$rawCacheContract;detector_contract=$coreDetectorContract;source_sha256=$ReplaySha256;source_size_bytes=[long]$sourceInfo.Length;source_last_write_utc=$sourceInfo.LastWriteTimeUtc.ToString('o');physical_transport='qpf_v1';cache_scope=$cacheScope}
    Write-JsonUtf8 $physicalCachePath $cache 6
    Write-Host ('  [物理缓存] rebuilt '+$rawCacheContract+' · detector='+$coreDetectorContract)
}else{
    Write-Host ('  [物理缓存] hit '+$rawCacheContract+' · detector='+$coreDetectorContract+' · 跳过原始车辆流重扫')
}
Add-PipelineStage $(if($physicalCacheHit){'physical_cache_reuse'}else{'physical_extract_fast'})

if($null-eq$manifest){$manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json}
$rep=@($manifest.replays)[0]
if($null -eq $rep){ throw '遥测提取器没有返回 replay manifest。' }
Write-Host ('  原始车辆流: '+@($rep.streams).Count)

# Schema-wide semantics belong to the loaded C# production contract, not to a fragile
# physical-stream -> part -> group metadata copy chain.  The extractor manifest is retained
# as a consistency witness, but it is not the sole source of schema-global identity.
$productionSchema=$manifest.production_record_schema_2026
$productionRecordSchemaVersion=[int][QQReplaySchema2026]::SchemaVersion
$productionForwardAxisLocal=[string][QQReplaySchema2026]::VehicleForwardAxisLocal
if($null-ne$productionSchema){
    try{
        $manifestSchemaVersion=[int]$productionSchema.schema_version
        if($manifestSchemaVersion -gt 0 -and $manifestSchemaVersion -ne $productionRecordSchemaVersion){
            throw ('2026 record schema version mismatch: core='+$productionRecordSchemaVersion+' manifest='+$manifestSchemaVersion)
        }
    }catch{ if($_.Exception.Message -like '2026 record schema version mismatch*'){throw} }
    try{
        $manifestForwardAxis=[string]$productionSchema.vehicle_forward_axis_local
        if(-not [string]::IsNullOrWhiteSpace($manifestForwardAxis) -and $manifestForwardAxis -ne $productionForwardAxisLocal){
            throw ('2026 forward-axis mismatch: core='+$productionForwardAxisLocal+' manifest='+$manifestForwardAxis)
        }
    }catch{ if($_.Exception.Message -like '2026 forward-axis mismatch*'){throw} }
}

# Runtime state belongs in the orchestrator, not in the dot-sourced module.
# Native action evidence is persisted as its own cache: raw Drift/effect tables plus the exact tail
# window they were read from. Its validity binds replay identity (SHA256+size) and the native-action
# scanner contract only, so it stays independent of the physical qpf cache lifecycle:
#   -ForceRaw             -> rebuild PhysicalTelemetryCache only
#   -ForceNativeActions   -> rebuild NativeActionCache only
#   -ForceTelemetry       -> reuse both and re-derive every action semantic from cache + telemetry rows
if([string]::IsNullOrWhiteSpace($NativeActionCacheRoot)){$NativeActionCacheRoot=Join-Path $OutDir 'native_actions'}
$nativeActionCacheScope=$(if($NativeActionCacheRoot.StartsWith($OutDir,[StringComparison]::OrdinalIgnoreCase)){'telemetry_local'}else{'persistent_project'})
$nativePhysicalAudit=[ordered]@{
    physical_cache_contract=$rawCacheContract;physical_cache_mode=$(if($physicalCacheHit){'reuse'}else{'rebuilt'});physical_cache_scope=$cacheScope
    streams=@(foreach($mrep in @($manifest.replays)){foreach($ms in @($mrep.streams)){[ordered]@{stream_id=[string]$ms.stream_id;profile=[string]$ms.profile;records=[int]$ms.records}}})
    rule='audit metadata only; native action cache validity binds source identity and the action scanner contract only'
}
$nativeActionScan=Resolve-NativeActionCacheScan -ReplayPath $ReplayPath -CacheRoot $NativeActionCacheRoot -ReplaySha256 $ReplaySha256 -SourceSizeBytes ([long]$sourceInfo.Length) -CacheScope $nativeActionCacheScope -ToolVersion $toolVersion -PhysicalAudit $nativePhysicalAudit -Force:$ForceNativeActions -Source ([ordered]@{sha256=$ReplaySha256;size_bytes=[long]$sourceInfo.Length;last_write_utc=$sourceInfo.LastWriteTimeUtc.ToString('o');file_name=[IO.Path]::GetFileName($ReplayPath)})
$nativeTimelineCandidates=@($nativeActionScan.candidates)
Add-PipelineStage 'native_action_cache_resolve'
Write-Host ('  [动作缓存] '+[string]$nativeActionScan.mode+' · 候选='+[string]$nativeActionScan.candidate_count+' · 效果表='+[string]$nativeActionScan.effect_table_count+' · 查找='+[string]$nativeActionScan.lookup_ms+'ms · 扫描='+[string]$nativeActionScan.scan_ms+'ms · 写出='+[string]$nativeActionScan.write_ms+'ms · '+$(if($nativeActionScan.source_read){'读取原始 SAV'}else{'未读取原始 SAV'}))
if($nativeActionScan.mode-ne'reuse'){
    Write-Host ('    [动作缓存] 状态='+[string]$nativeActionScan.status+' · 写出='+[string]$nativeActionScan.write_status+' · tail='+[string]$nativeActionScan.tail_status+' · 重解析自tail='+[string]$nativeActionScan.tail_rescan)
}
$claimedNativeTimelineOffsets=New-Object System.Collections.Generic.List[long]
$nativeTimelineValidatedStreams=0
# Production native action semantics. The action event table is decoded ONCE per replay: from the
# native-action cache raw tail window when it is usable (zero extra SAV reads on a warm run),
# otherwise from only the container tail that keeps the structural locator exact.
$nativeActionEventTailPath=''
if(-not[string]::IsNullOrWhiteSpace([string]$nativeActionScan.cache_dir)){$nativeActionEventTailPath=Join-Path ([string]$nativeActionScan.cache_dir) 'native_action_tail.bin'}
$nativeActionEventDecode=Get-ReplayNativeActionEventTableFromWindow -ReplayPath $ReplayPath -FileLength ([long]$sourceInfo.Length) -CachedTailPath $nativeActionEventTailPath -CachedTailStartOffset ([long]$nativeActionScan.scan_window.scan_start_offset)
Add-PipelineStage 'native_action_event_decode'
Write-Host ('  [动作事件] status='+[string]$nativeActionEventDecode.status+' · 事件='+$(if([bool]$nativeActionEventDecode.available){[string]$nativeActionEventDecode.event_count}else{'-'})+$(if([bool]$nativeActionEventDecode.available){''}else{' · 原因='+[string]$nativeActionEventDecode.reason}))
$nativeSpeedEffectValidatedStreams=0
$parts=@(Get-PhysicalParts -ReplayManifest $rep -PhysicalDir $physicalDir)
Add-PipelineStage 'physical_transport_load'
Write-Host ('  可读取物理片段: '+$parts.Count)

# 合并同一辆联网影子被切成的连续物理片段；同时存在的两辆车不会被合并。
$groups=New-Object System.Collections.Generic.List[object]
foreach($part in $parts) {
    $best=$null;$bestScore=[double]::PositiveInfinity
    foreach($g in $groups.ToArray()) {
        $gap=$part.t0-$g.t1
        if($gap -lt -0.06 -or $gap -gt 0.35){continue}
        if([Math]::Abs($part.hz-$g.hz) -gt 1.5){continue}
        $dx=$part.x0-$g.x1;$dy=$part.y0-$g.y1;$dz=$part.z0-$g.z1
        $spatial=[Math]::Sqrt($dx*$dx+$dy*$dy+$dz*$dz)
        $allowed=3.0+30.0*[Math]::Max(0.0,$gap)
        if($spatial -gt $allowed){continue}
        $score=$spatial+5.0*[Math]::Abs($gap)+[Math]::Abs($part.hz-$g.hz)
        if($score -lt $bestScore){$best=$g;$bestScore=$score}
    }
    if($null -eq $best) {
        $lst=New-Object System.Collections.Generic.List[object];foreach($r in $part.rows){$lst.Add($r)}
        $ids=New-Object System.Collections.Generic.List[string];$ids.Add($part.id)
        $groups.Add([pscustomobject]@{hz=$part.hz;rows=$lst;parts=$ids;t0=$part.t0;t1=$part.t1;x1=$part.x1;y1=$part.y1;z1=$part.z1;speed_source=[string]$part.speed_source;profile=[string]$part.profile;record_semantic_schema_version=[int]$part.record_semantic_schema_version;vehicle_forward_axis_local=[string]$part.vehicle_forward_axis_local})
    } else {
        $startAt=0
        if($best.rows.Count -gt 0 -and [Math]::Abs($part.rows[0].time-$best.rows[$best.rows.Count-1].time) -lt 0.001){$startAt=1}
        for($i=$startAt;$i -lt $part.rows.Count;$i++){$best.rows.Add($part.rows[$i])}
        $best.parts.Add($part.id);$best.t1=$part.t1;$best.x1=$part.x1;$best.y1=$part.y1;$best.z1=$part.z1
        $best.hz=($best.hz+$part.hz)/2.0
    }
}
$logical=@($groups.ToArray()|Sort-Object @{Expression='hz';Descending=$true})
Add-PipelineStage 'stream_grouping'
Write-Host ('  逻辑影子: '+$logical.Count)

$streamOut=New-Object System.Collections.Generic.List[object]
$streamProfiles=New-Object System.Collections.Generic.List[object]
$evidenceStreams=New-Object System.Collections.Generic.List[object]
for($gi=0;$gi -lt $logical.Count;$gi++) {
    $g=$logical[$gi]
    $role=if($gi -eq 0){'local_high_frequency'}else{'network_low_frequency'}
    $roleLabel=if($gi -eq 0){'本地高频影子'}elseif($gi -eq 1){'联网低频影子'}else{'联网低频影子 '+$gi}
    $id=if($gi -eq 0){'shadow_local'}else{'shadow_network_'+('{0:D2}' -f $gi)}
    $rows=@($g.rows.ToArray())
    $streamWatch=[Diagnostics.Stopwatch]::StartNew()

    # 2026-format replays can contain a few one-frame pose snaps. qpf_v1 typed rows
    # use the C# fast detector; CSV compatibility rows retain the original PowerShell path.
    $edgeStep=New-Object double[] $rows.Count
    $edgeBreak=New-Object bool[] $rows.Count
    $typedFastRows=$null
    $useFastRows=$false
    if($rows.Count-gt0 -and ('QQReplayPhysicalFastRow' -as [type]) -and $rows[0] -is [QQReplayPhysicalFastRow]) {
        try {
            $typedFastRows=[QQReplayPhysicalFastRow[]]$rows
            $poseFast=[QQReplayPortable]::DetectPoseBreaks($typedFastRows)
            $edgeStep=$poseFast.edge_step;$edgeBreak=$poseFast.edge_break;$useFastRows=$true
        } catch {$useFastRows=$false;$typedFastRows=$null}
    }
    if(-not$useFastRows) {
        for($i=1;$i -lt $rows.Count;$i++) {
            $dx=[double]$rows[$i].x-[double]$rows[$i-1].x
            $dy=[double]$rows[$i].y-[double]$rows[$i-1].y
            $dz=[double]$rows[$i].z-[double]$rows[$i-1].z
            $edgeStep[$i]=[Math]::Sqrt($dx*$dx+$dy*$dy+$dz*$dz)
        }
        for($i=1;$i -lt $rows.Count;$i++) {
            $near=New-Object System.Collections.Generic.List[double]
            $lo=[Math]::Max(1,$i-8);$hi=[Math]::Min($rows.Count-1,$i+8)
            for($j=$lo;$j -le $hi;$j++) {
                if([Math]::Abs($j-$i) -le 1){continue}
                $sv=[double]$edgeStep[$j]
                if($sv -gt 0.000001 -and -not [double]::IsNaN($sv) -and -not [double]::IsInfinity($sv)){$near.Add($sv)}
            }
            $localStep=Median-Value ($near.ToArray())
            $yawJump=[Math]::Abs((Normalize-Angle (([double]$rows[$i].yaw)-([double]$rows[$i-1].yaw))))
            $softLimit=[Math]::Max(1.25,5.0*$localStep)
            $hardLimit=[Math]::Max(2.0,8.0*$localStep)
            if(([double]$edgeStep[$i] -gt $softLimit) -and ($yawJump -gt 0.45 -or [double]$edgeStep[$i] -gt $hardLimit)) {$edgeBreak[$i]=$true}
        }
    }

    # The selected speed is replay-native linear velocity on validated 2026 streams and
    # position-derived velocity only on legacy/fallback streams. Pose snaps invalidate route geometry,
    # but they do not corrupt the replay-native velocity vector; only derived speed needs local repair.
    $speedFixed=New-Object double[] $rows.Count
    $poseValid=New-Object bool[] $rows.Count
    for($i=0;$i -lt $rows.Count;$i++){$speedFixed[$i]=Safe-Number ([double]$rows[$i].speed) 0.0;$poseValid[$i]=$true}
    for($i=1;$i -lt $rows.Count;$i++) {
        if(-not $edgeBreak[$i]){continue}
        $preVals=New-Object System.Collections.Generic.List[double]
        for($j=[Math]::Max(0,$i-7);$j -le ($i-2);$j++){
            if($j -lt 0){continue};$v=Safe-Number ([double]$rows[$j].speed) -1.0;if($v -ge 0 -and $v -lt 10000){$preVals.Add($v)}
        }
        $postVals=New-Object System.Collections.Generic.List[double]
        for($j=$i+1;$j -le [Math]::Min($rows.Count-1,$i+6);$j++){
            $v=Safe-Number ([double]$rows[$j].speed) -1.0;if($v -ge 0 -and $v -lt 10000){$postVals.Add($v)}
        }
        $preMed=Median-Value ($preVals.ToArray());$postMed=Median-Value ($postVals.ToArray())
        $repairSelectedSpeed=([string]$g.speed_source -ne 'replay_linear_velocity')
        if($i-1 -ge 0){if($repairSelectedSpeed){$speedFixed[$i-1]=$preMed};$poseValid[$i-1]=$false}
        if($repairSelectedSpeed){$speedFixed[$i]=$postMed};$poseValid[$i]=$false
    }

    $clean=New-Object System.Collections.Generic.List[object]
    $cum=0.0
    for($i=0;$i -lt $rows.Count;$i++) {
        $r=$rows[$i]
        if($i -gt 0 -and -not $edgeBreak[$i]){$cum+=[double]$edgeStep[$i]}
        $rawSpd=Safe-Number ([double]$r.speed) 0.0
        $inputs=@($r.input_bool_candidate)
        if($useFastRows -and $r -is [QQReplayPhysicalFastRow]) {
            $r.time_s=[double]$r.time;$r.speed_raw=$rawSpd;$r.speed=[double]$speedFixed[$i];$r.distance=$cum
            $r.pose_valid=[bool]$poseValid[$i];$r.pose_break_before=[bool]$edgeBreak[$i];$r.vehicle_forward_heading_rad=[double]$r.vehicle_forward_heading
            $r.source_stream=[string]$r.source;$r.system_drift_state='unknown';$r.system_drift_state_source='unresolved_not_found'
            $r.nitro_active=$false;$r.small_boost_active=$false;$r.air_boost_active=$false;$r.landing_boost_active=$false;$r.map_propulsion_active=$false;$r.small_boost_class_active=$false;$r.speed_effect_state_source='replay_native_action_object_speed_effect_table_v2'
            $clean.Add($r)
        } else {
            $clean.Add([pscustomobject]@{time_s=[double]$r.time;x=[double]$r.x;y=[double]$r.y;z=[double]$r.z;speed=[double]$speedFixed[$i];speed_raw=$rawSpd;speed_source=[string]$r.speed_source;speed_direct=(Safe-Number ([double]$r.direct_speed) ([double]::NaN));speed_derived=(Safe-Number ([double]$r.derived_speed) ([double]::NaN));yaw=(Safe-Number ([double]$r.yaw) 0.0);slip=(Safe-Number ([double]$r.slip) 0.0);distance=$cum;pose_valid=[bool]$poseValid[$i];pose_break_before=[bool]$edgeBreak[$i];contact_state=$r.contact_state;contact_state_name=[string]$r.contact_state_name;is_airborne=$r.is_airborne;lap_index=$r.lap_index;vehicle_forward_heading_rad=$r.vehicle_forward_heading;system_drift_state='unknown';system_drift_state_source='unresolved_not_found';input_bool_candidate_60=$(if($inputs.Count-gt0){$inputs[0]}else{$null});input_bool_candidate_61=$(if($inputs.Count-gt1){$inputs[1]}else{$null});input_bool_candidate_62=$(if($inputs.Count-gt2){$inputs[2]}else{$null});input_bool_candidate_63=$(if($inputs.Count-gt3){$inputs[3]}else{$null});input_bool_candidate_64=$(if($inputs.Count-gt4){$inputs[4]}else{$null});input_bool_candidate_65=$(if($inputs.Count-gt5){$inputs[5]}else{$null});source_stream=[string]$r.source;nitro_active=$false;small_boost_active=$false;air_boost_active=$false;landing_boost_active=$false;map_propulsion_active=$false;small_boost_class_active=$false;speed_effect_state_source='replay_native_action_object_speed_effect_table_v2'})
        }
    }
    $cleanRows=$clean.ToArray()
    $geometryPrepMs=[long]$streamWatch.ElapsedMilliseconds
    $duration=if($cleanRows.Count -gt 1){[double]$cleanRows[$cleanRows.Count-1].time_s-[double]$cleanRows[0].time_s}else{0.0}
    $avgSpeed=if($duration -gt 0){$cum/$duration}else{0.0}
    # Level-1 Basic Driving quantity: max observed speed on this stream. Published as a telemetry
    # fact so the product does not have to invent it, and stays $null when the stream carries no rows.
    $maxSpeed=$null
    if($cleanRows.Count -gt 0){
        $maxSpeed=0.0
        foreach($cr in $cleanRows){$sv=[double]$cr.speed;if($sv -gt $maxSpeed){$maxSpeed=$sv}}
    }
    $laps=@(Build-NativeLapSegments $cleanRows)
    $csvName=('logical_{0:D2}.csv' -f ($gi+1));$csvPath=Join-Path $OutDir $csvName
    # Logical CSV is written after native semantic resolution; no heuristic action labels are injected.

    $preview=New-Object System.Collections.Generic.List[object]
    $maxPreview=1400
    $stepN=[Math]::Max(1,[int][Math]::Ceiling($clean.Count/[double]$maxPreview))
    $lastPreviewIndex=-1
    for($i=0;$i -lt $clean.Count;$i+=$stepN) {
        $r=$clean[$i];$p=if($cum -gt 0){[double]$r.distance/$cum}else{0.0}
        $breakBefore=$false
        if($lastPreviewIndex -ge 0){for($j=$lastPreviewIndex+1;$j -le $i;$j++){if($edgeBreak[$j]){$breakBefore=$true;break}}}
        $preview.Add([ordered]@{t=[Math]::Round([double]$r.time_s,4);x=[Math]::Round([double]$r.x,4);y=[Math]::Round([double]$r.y,4);z=[Math]::Round([double]$r.z,4);speed=[Math]::Round([double]$r.speed,3);speed_raw=[Math]::Round([double]$r.speed_raw,3);speed_valid=[bool]$r.pose_valid;break_before=$breakBefore;p=[Math]::Round($p,6);yaw_deg=[Math]::Round(([double]$r.yaw*180.0/[Math]::PI),2);slip_deg=[Math]::Round(([double]$r.slip*180.0/[Math]::PI),2);contact_state=$r.contact_state;contact_state_name=[string]$r.contact_state_name;is_airborne=$r.is_airborne;lap_index=$r.lap_index;forward_heading_deg=$(if(-not[double]::IsNaN([double]$r.vehicle_forward_heading_rad)){[Math]::Round(([double]$r.vehicle_forward_heading_rad*180.0/[Math]::PI),2)}else{$null})})
        $lastPreviewIndex=$i
    }
    if($clean.Count -gt 0 -and (($clean.Count-1)%$stepN) -ne 0){
        $i=$clean.Count-1;$r=$clean[$i];$breakBefore=$false
        if($lastPreviewIndex -ge 0){for($j=$lastPreviewIndex+1;$j -le $i;$j++){if($edgeBreak[$j]){$breakBefore=$true;break}}}
        $preview.Add([ordered]@{t=[Math]::Round([double]$r.time_s,4);x=[Math]::Round([double]$r.x,4);y=[Math]::Round([double]$r.y,4);z=[Math]::Round([double]$r.z,4);speed=[Math]::Round([double]$r.speed,3);speed_raw=[Math]::Round([double]$r.speed_raw,3);speed_valid=[bool]$r.pose_valid;break_before=$breakBefore;p=1.0;yaw_deg=[Math]::Round(([double]$r.yaw*180.0/[Math]::PI),2);slip_deg=[Math]::Round(([double]$r.slip*180.0/[Math]::PI),2);contact_state=$r.contact_state;contact_state_name=[string]$r.contact_state_name;is_airborne=$r.is_airborne;lap_index=$r.lap_index;forward_heading_deg=$(if(-not[double]::IsNaN([double]$r.vehicle_forward_heading_rad)){[Math]::Round(([double]$r.vehicle_forward_heading_rad*180.0/[Math]::PI),2)}else{$null})})
    }

    $breakOut=New-Object System.Collections.Generic.List[object]
    for($i=1;$i -lt $rows.Count;$i++){
        if(-not $edgeBreak[$i]){continue}
        $p0=if($cum -gt 0){[double]$clean[$i-1].distance/$cum}else{0.0}
        $p1=if($cum -gt 0){[double]$clean[$i].distance/$cum}else{0.0}
        $yawJump=[Math]::Abs((Normalize-Angle (([double]$rows[$i].yaw)-([double]$rows[$i-1].yaw))))*180.0/[Math]::PI
        $breakOut.Add([ordered]@{before_i=$i-1;after_i=$i;before_t=[Math]::Round([double]$rows[$i-1].time,4);after_t=[Math]::Round([double]$rows[$i].time,4);before_p=[Math]::Round($p0,6);after_p=[Math]::Round($p1,6);jump_distance=[Math]::Round([double]$edgeStep[$i],4);yaw_jump_deg=[Math]::Round($yawJump,2)})
    }
    # Native-first: SystemDrift comes only from the replay-native suffix timeline.
    # No kinematic/slip fallback is allowed to become an action semantic.
    $semanticStartMs=[long]$streamWatch.ElapsedMilliseconds
    $eligibleNativeCandidateCount=@($nativeTimelineCandidates|Where-Object{[bool]$_.native_object_marker_valid -or ([bool]$_.structural_table_valid -and [bool]$_.adjacent_effect_table_valid -and @($_.intervals).Count -gt 0)}).Count
    Write-Host ('    [语义] '+$role+' Drift候选='+$nativeTimelineCandidates.Count+' · 权威候选='+$eligibleNativeCandidateCount)
    $nativeResolved=Resolve-ReplayNativeDriftTimeline -Candidates $nativeTimelineCandidates -Rows $cleanRows -ExcludedCountOffsets ($claimedNativeTimelineOffsets.ToArray())
    $driftResolveMs=[long]$streamWatch.ElapsedMilliseconds-$semanticStartMs
    Write-Host ('    [语义] Drift解析='+$driftResolveMs+'ms · status='+[string]$nativeResolved.status)
    $nativeDrifts=@()
    $driftConvertMs=0
    if([bool]$nativeResolved.available){
        $driftConvertStartMs=[long]$streamWatch.ElapsedMilliseconds
        $nativeDrifts=@(Convert-ReplayNativeDriftTimelineToSegments -Resolved $nativeResolved -Rows $cleanRows -TotalDistance $cum -Laps $laps)
        $driftConvertMs=[long]$streamWatch.ElapsedMilliseconds-$driftConvertStartMs
        # An authoritative native Drift table may legitimately be empty. Presence/validity is separate from event count.
        $claimedNativeTimelineOffsets.Add([long]$nativeResolved.candidate.count_offset)
        $nativeTimelineValidatedStreams++
    }
    # The replay-native speed-effect table is structurally adjacent to the replay-native drift table
    # for the same logical shadow.  Keep the binding per stream; do not hardcode a suffix offset.
    # On a NativeActionCache hit the raw payload recorded at scan time is replayed verbatim, so the
    # semantic layer receives the identical table object without touching the replay file.
    $nativeEffectTablePayload=$null
    $nativeEffectTableSource='not_required'
    if([bool]$nativeResolved.available){
        $nativeEffectTablePayload=Get-NativeActionEffectTable -Scan $nativeActionScan -CountOffset ([long]$nativeResolved.candidate.end_exclusive)
        $nativeEffectTableSource=$(if($null-ne$nativeEffectTablePayload){'native_action_cache'}else{'replay_sav'})
    }
    $speedResolveStartMs=[long]$streamWatch.ElapsedMilliseconds
    $nativeSpeedEffectResolved=Resolve-ReplayNativeSpeedEffectTimeline -ReplayPath $ReplayPath -EffectTablePayload $nativeEffectTablePayload -NativeDriftResolved $nativeResolved -Rows $cleanRows
    $speedResolveMs=[long]$streamWatch.ElapsedMilliseconds-$speedResolveStartMs
    $speedConvertStartMs=[long]$streamWatch.ElapsedMilliseconds
    $nativeSpeedEffects=Convert-ReplayNativeSpeedEffectsToSegments -Resolved $nativeSpeedEffectResolved -Rows $cleanRows -NativeDriftResolved $nativeResolved
    $speedConvertMs=[long]$streamWatch.ElapsedMilliseconds-$speedConvertStartMs
    $comboResolveStartMs=[long]$streamWatch.ElapsedMilliseconds
    $nativeCombos=Resolve-ReplayNativeComboActions -SpeedEffects $nativeSpeedEffects
    $comboResolveMs=[long]$streamWatch.ElapsedMilliseconds-$comboResolveStartMs
    # Production action authority: replay-native action events. The legacy timing combo detector
    # above stays diagnostic/disagreement only and is never a fallback.
    # -EffectTable supplies the raw toggle records so the published raw counts can be proven to be
    # the table's own content (open/close balance) rather than a begin/end pairing artifact.
    $productionActions=Resolve-ReplayNativeActionSemantics -ActionEvents $nativeActionEventDecode -EffectIntervals $(if([bool]$nativeSpeedEffectResolved.available){@($nativeSpeedEffectResolved.table.intervals)}else{@()}) -DriftIntervals $(if([bool]$nativeResolved.available){@($nativeResolved.candidate.intervals)}else{@()}) -EffectTable $(if([bool]$nativeSpeedEffectResolved.available){$nativeSpeedEffectResolved.table}else{$null}) -DriftTableAvailable ([bool]$nativeResolved.available) -EffectTableAvailable ([bool]$nativeSpeedEffectResolved.available) -LegacyCombos $nativeCombos -ContactAirBoostCount ([int]$nativeSpeedEffects.air_boost_count) -ContactLandingBoostCount ([int]$nativeSpeedEffects.landing_boost_count) -NitroCtrlRiseCount ([int]$nativeSpeedEffectResolved.ctrl_rise_count) -NitroCtrlMatchCount ([int]$nativeSpeedEffectResolved.nitro_ctrl_match_count) -NitroCtrlMatchFraction ([double]$nativeSpeedEffectResolved.nitro_ctrl_match_fraction)
    Write-Host ('    [语义] 生产权威动作 status='+[string]$productionActions.status+' · 空喷='+[string]$productionActions.air_boost.count+' 落地喷='+[string]$productionActions.landing_boost.count+' CW/WCW/CWW='+[string]$productionActions.combo.cw+'/'+[string]$productionActions.combo.wcw+'/'+[string]$productionActions.combo.cww+' · Drift raw/logical='+[string]$productionActions.drift.raw_intervals+'/'+[string]$productionActions.drift.logical_count+' · 遗留Combo='+$(if($null-ne$productionActions.legacy_combo_candidate.cw){[string]$productionActions.legacy_combo_candidate.cw+'/'+[string]$productionActions.legacy_combo_candidate.wcw+'/'+[string]$productionActions.legacy_combo_candidate.cww}else{'unavailable'}))
    Write-Host ('    [语义] SpeedEffect读取='+$speedResolveMs+'ms · 分类='+$speedConvertMs+'ms · Combo='+$comboResolveMs+'ms · status='+[string]$nativeSpeedEffectResolved.status)
    if([bool]$nativeSpeedEffectResolved.available){$nativeSpeedEffectValidatedStreams++}

    $semanticMs=[long]$streamWatch.ElapsedMilliseconds-$semanticStartMs
    $logicalWriteStart=[long]$streamWatch.ElapsedMilliseconds
    $typedLogical=$false
    if($cleanRows.Count-gt0 -and ('QQReplayPhysicalFastRow' -as [type]) -and $cleanRows[0] -is [QQReplayPhysicalFastRow]){
        try{[QQReplayPortable]::WriteLogicalCsv($csvPath,[QQReplayPhysicalFastRow[]]$cleanRows);$typedLogical=$true}catch{$typedLogical=$false}
    }
    if(-not$typedLogical){$cleanRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8}
    $logicalWriteMs=[long]$streamWatch.ElapsedMilliseconds-$logicalWriteStart
    $contactSet=New-Object 'System.Collections.Generic.HashSet[int]';$lapSet=New-Object 'System.Collections.Generic.HashSet[int]'
    foreach($cr in $cleanRows){if($null-ne$cr.contact_state){[void]$contactSet.Add([int]$cr.contact_state)};if($null-ne$cr.lap_index){[void]$lapSet.Add([int]$cr.lap_index)}}
    $contactValues=@($contactSet|Sort-Object);$lapValues=@($lapSet|Sort-Object)
    $resolvedRecordSchemaVersion=[int]$g.record_semantic_schema_version
    $resolvedForwardAxisLocal=[string]$g.vehicle_forward_axis_local
    $is2026LogicalStream=([string]$g.profile -eq '2026' -or [string]$rep.detected_profile -eq '2026')
    if($is2026LogicalStream){
        $resolvedRecordSchemaVersion=$productionRecordSchemaVersion
        $resolvedForwardAxisLocal=$productionForwardAxisLocal
    }
    $codeBuckets=@{}
    foreach($seg in @($nativeSpeedEffects.native_speed_effect_segments)){
        $key=([double]$seg.effect_code).ToString('R',[Globalization.CultureInfo]::InvariantCulture)
        if(-not$codeBuckets.ContainsKey($key)){$codeBuckets[$key]=New-Object System.Collections.Generic.List[object]}
        $codeBuckets[$key].Add($seg)
    }
    $codeEvidence=New-Object System.Collections.Generic.List[object]
    foreach($key in @($codeBuckets.Keys|Sort-Object {[double]$_})){
        $arr=@($codeBuckets[$key].ToArray());$dur=@($arr|ForEach-Object{[double]$_.duration_ms});$sem=@($arr|ForEach-Object{[string]$_.semantic_type}|Sort-Object -Unique)
        $codeEvidence.Add([ordered]@{code=[double]::Parse($key,[Globalization.CultureInfo]::InvariantCulture);intervals=$arr.Count;median_duration_ms=[Math]::Round((Median-Value $dur),3);semantics=$sem;unknown_count=@($arr|Where-Object{[string]$_.semantic_type -eq 'unknown_speed_effect'}).Count})
    }
    $evidenceStreams.Add([ordered]@{
        id=$id;role=$role;native_drift_available=[bool]$nativeResolved.available;drift_count=$nativeDrifts.Count
        native_effect_available=[bool]$nativeSpeedEffectResolved.available;effect_interval_count=@($nativeSpeedEffects.native_speed_effect_segments).Count;effect_codes=$codeEvidence.ToArray()
        nitro_gate=$(if([bool]$nativeSpeedEffectResolved.available){[ordered]@{ctrl_rise_count=[int]$nativeSpeedEffectResolved.ctrl_rise_count;code1_interval_count=[int]$nativeSpeedEffectResolved.nitro_code_interval_count;match_count=[int]$nativeSpeedEffectResolved.nitro_ctrl_match_count;match_fraction=[double]$nativeSpeedEffectResolved.nitro_ctrl_match_fraction;valid=[bool]$nativeSpeedEffectResolved.nitro_semantic_valid}}else{$null})
        combo=[ordered]@{cw=[int]$nativeCombos.cw_count;wcw=[int]$nativeCombos.wcw_count;cww=[int]$nativeCombos.cww_count;total=[int]$nativeCombos.combo_count}
        production_actions=[ordered]@{
            authority='replay_native_action_event';status=[string]$productionActions.status
            air_boost=$productionActions.air_boost.count;landing_boost=$productionActions.landing_boost.count
            cw=$productionActions.combo.cw;wcw=$productionActions.combo.wcw;cww=$productionActions.combo.cww
            code24=$productionActions.combo.code24_count;code25_raw=$productionActions.combo.code25_count;code25_paired=$productionActions.combo.code25_paired_count
            drift_raw_intervals=$productionActions.drift.raw_intervals;drift_logical_count=$productionActions.drift.logical_count
            small_boost_raw=$productionActions.small_boost.raw_effect_count;small_boost_classified=$productionActions.small_boost.classified_count;small_boost_unresolved=$productionActions.small_boost.unresolved_count
            nitro_raw_intervals=$productionActions.nitro.raw_interval_count;nitro_ctrl_rise=$productionActions.nitro.ctrl_rise_count
            legacy_cw=$productionActions.legacy_combo_candidate.cw;legacy_wcw=$productionActions.legacy_combo_candidate.wcw;legacy_cww=$productionActions.legacy_combo_candidate.cww
            combo_disagreement_matches=$productionActions.disagreement.combo.matches
            air_contact_delta=$productionActions.disagreement.air_contact_state.delta;landing_contact_delta=$productionActions.disagreement.landing_contact_state.delta
            unknown_action_codes=@($productionActions.unknown_action_codes)
            evidence_matrix=@($productionActions.evidence_matrix)
        }
    })
    $streamProfiles.Add([ordered]@{id=$id;role=$role;records=$cleanRows.Count;physical_transport=$(if($useFastRows){'qpf_v1'}else{'csv_compat'});geometry_prepare_ms=$geometryPrepMs;semantic_actions_ms=$semanticMs;logical_csv_write_ms=$logicalWriteMs;total_stream_ms=[long]$streamWatch.ElapsedMilliseconds;drift_resolve_ms=$driftResolveMs;drift_convert_ms=$driftConvertMs;speed_effect_resolve_ms=$speedResolveMs;speed_effect_convert_ms=$speedConvertMs;combo_resolve_ms=$comboResolveMs;native_effect_table_source=$nativeEffectTableSource})

    # Ownership boundary. The replay-native action event table is decoded ONCE per replay and the
    # container carries no per-vehicle owner for it, so it may only be published on the local
    # authoritative shadow. A network shadow keeps its own trajectory/time/lap/speed facts, and its
    # native action authority stays unavailable instead of inheriting the local player's events.
    # The decoder and the semantic resolution are deliberately untouched: only attribution is.
    $localActionAuthority=($gi-eq0)
    $streamActionEventAvailable=([bool]$nativeActionEventDecode.available -and $localActionAuthority)
    $streamActionEventStatus=$(if(-not $localActionAuthority){'unattributed_replay_global_table'}else{[string]$nativeActionEventDecode.status})
    $streamActionEventReason=$(if(-not $localActionAuthority){'the replay-native action event table has no per-vehicle owner in the container; it is not published on a non-local shadow'}else{[string]$nativeActionEventDecode.reason})
    # Per-event native action timeline (time + code only, no semantics). An explicit empty array for a
    # non-local shadow, so a consumer sees "no events" instead of a null it might treat as unknown.
    $streamActionEventTimeline=@()
    if($streamActionEventAvailable){
        $streamActionEventTimeline=@($nativeActionEventDecode.events|ForEach-Object{[ordered]@{record_index=[int]$_.record_index;time_ms=[long]$_.time_ms;action_code=[long]$_.action_code}})
    }

    $streamOut.Add([ordered]@{
        id=$id;role=$role;role_label=$roleLabel;sample_hz=[Math]::Round([double]$g.hz,3);records=$clean.Count;speed_source=[string]$g.speed_source
        record_semantic_schema_version=$resolvedRecordSchemaVersion;vehicle_forward_axis_local=$resolvedForwardAxisLocal;contact_state_contract_version=1;contact_state_values=$contactValues;lap_index_values=$lapValues;input_bool_candidate_range='60..65';input_bool_labels_assigned=$false
        duration_s=[Math]::Round($duration,4);distance=[Math]::Round($cum,3);avg_speed=[Math]::Round($avgSpeed,3);max_speed=$(if($null-ne$maxSpeed){[Math]::Round([double]$maxSpeed,3)}else{$null})
        lap_schema_version=2;lap_count=$laps.Count;lap_status=$(if($laps.Count-gt0){'replay_native_lap_index'}else{'unavailable_no_fallback'});lap_source=$(if($laps.Count-gt0){'replay_native_int32_offset_76'}else{$null});laps=$laps
        part_count=$g.parts.Count;source_streams=@($g.parts.ToArray());csv=$csvName;preview=$preview.ToArray()
        pose_discontinuity_schema_version=1;pose_discontinuity_count=$breakOut.Count;pose_discontinuities=$breakOut.ToArray()
        drift_schema_version=5;drift_state_contract_version=5;system_drift_state_available=[bool]$nativeResolved.available;system_drift_state_status=[string]$nativeResolved.status;system_drift_state_source=$(if([bool]$nativeResolved.available){'replay_native_action_object_drift_table_v3'}else{$null});system_drift_segment_count=$nativeDrifts.Count;system_drift_segments=$nativeDrifts;native_drift_timeline_validation=$(if([bool]$nativeResolved.available){[ordered]@{count_offset=[long]$nativeResolved.candidate.count_offset;object_marker_hex=[string]$nativeResolved.candidate.object_marker_hex;validation_basis=[string]$nativeResolved.validation_basis;empty_table=[bool]$nativeResolved.candidate.empty_table;interval_count=[int]$nativeResolved.candidate.interval_count;adjacent_effect_table_valid=[bool]$nativeResolved.candidate.adjacent_effect_table_valid;adjacent_effect_record_count=[int]$nativeResolved.candidate.adjacent_effect_record_count;shift_rise_count=[int]$nativeResolved.shift_rise_count;start_match_count=[int]$nativeResolved.start_match_count;start_match_fraction=[double]$nativeResolved.start_match_fraction;internal_shift_retriggers=[int]$nativeResolved.internal_shift_retriggers;outside_shift_rises=[int]$nativeResolved.outside_shift_rises}}else{[ordered]@{status=[string]$nativeResolved.status;shift_rise_count=[int]$nativeResolved.shift_rise_count}})
        speed_effect_schema_version=2;boost_effect_contract_version=3;speed_effect_state_available=[bool]$nativeSpeedEffectResolved.available;speed_effect_state_status=[string]$nativeSpeedEffectResolved.status;speed_effect_state_source=$(if([bool]$nativeSpeedEffectResolved.available){'replay_native_action_object_speed_effect_table_v2'}else{$null});native_speed_effect_timeline_validation=$(if([bool]$nativeSpeedEffectResolved.available){[ordered]@{count_offset=[long]$nativeSpeedEffectResolved.count_offset;record_count=[int]$nativeSpeedEffectResolved.table.record_count;interval_count=[int]$nativeSpeedEffectResolved.table.interval_count;effect_codes=@($nativeSpeedEffectResolved.table.effect_codes);ctrl_rise_count=[int]$nativeSpeedEffectResolved.ctrl_rise_count;nitro_code_interval_count=[int]$nativeSpeedEffectResolved.nitro_code_interval_count;nitro_ctrl_match_count=[int]$nativeSpeedEffectResolved.nitro_ctrl_match_count;nitro_ctrl_match_fraction=[double]$nativeSpeedEffectResolved.nitro_ctrl_match_fraction;nitro_semantic_valid=[bool]$nativeSpeedEffectResolved.nitro_semantic_valid}}else{[ordered]@{status=[string]$nativeSpeedEffectResolved.status}});native_speed_effect_segment_count=@($nativeSpeedEffects.native_speed_effect_segments).Count;native_speed_effect_segments=@($nativeSpeedEffects.native_speed_effect_segments);nitro_segment_count=@($nativeSpeedEffects.nitro_segments).Count;nitro_segments=@($nativeSpeedEffects.nitro_segments);small_boost_segment_count=@($nativeSpeedEffects.small_boost_segments).Count;small_boost_segments=@($nativeSpeedEffects.small_boost_segments);air_boost_segment_count=@($nativeSpeedEffects.air_boost_segments).Count;air_boost_segments=@($nativeSpeedEffects.air_boost_segments);landing_boost_segment_count=@($nativeSpeedEffects.landing_boost_segments).Count;landing_boost_segments=@($nativeSpeedEffects.landing_boost_segments);other_small_boost_segment_count=@($nativeSpeedEffects.other_small_boost_segments).Count;other_small_boost_segments=@($nativeSpeedEffects.other_small_boost_segments);map_propulsion_effect_segment_count=@($nativeSpeedEffects.map_propulsion_effect_segments).Count;map_propulsion_effect_segments=@($nativeSpeedEffects.map_propulsion_effect_segments);unknown_speed_effect_segment_count=@($nativeSpeedEffects.unknown_speed_effect_segments).Count;unknown_speed_effect_segments=@($nativeSpeedEffects.unknown_speed_effect_segments);combo_action_schema_version=2;combo_action_state_available=[bool]$nativeCombos.available;combo_action_state_status=[string]$nativeCombos.status;cw_count=[int]$nativeCombos.cw_count;wcw_count=[int]$nativeCombos.wcw_count;cww_count=[int]$nativeCombos.cww_count;combo_action_count=[int]$nativeCombos.combo_count;cw_segments=@($nativeCombos.cw_segments);wcw_segments=@($nativeCombos.wcw_segments);cww_segments=@($nativeCombos.cww_segments);native_combo_segments=@($nativeCombos.native_combo_segments)
        native_map_analysis_status='external_native_map_geometry';derived_turn_analysis_status='pending_native_map_turn_model'
        production_action_schema_version=1;production_action_contract=[string]$productionActions.contract;production_action_authority='replay_native_action_event';production_actions=$productionActions
        native_action_event_schema_version=1;native_action_event_available=$streamActionEventAvailable;native_action_event_ownership=$(if($localActionAuthority){'local_authoritative_shadow'}else{'unavailable_non_local_shadow'});native_action_event_locator_contract=[string]$nativeActionEventDecode.locator_contract;native_action_event_locator_path=$(if($streamActionEventAvailable){[string]$nativeActionEventDecode.locator_path}else{$null});native_action_event_status=$streamActionEventStatus;native_action_event_reason=$streamActionEventReason;native_action_event_count=$(if($streamActionEventAvailable){[int]$nativeActionEventDecode.event_count}else{$null});native_action_event_count_offset=$(if($streamActionEventAvailable){[long]$nativeActionEventDecode.count_offset}else{$null});native_action_event_histogram=$(if($streamActionEventAvailable){$nativeActionEventDecode.histogram}else{@{}})
        # Per-event native action timeline (time + code only, no semantics). Driving v2 episodes and
        # the native-marker diagnostics associate markers by time; without this the analysis layer
        # would have to re-decode the action table in a second process.
        native_action_event_timeline=$streamActionEventTimeline
    })
    Write-Host ('    '+$roleLabel+': '+$clean.Count+' 帧 / '+[Math]::Round($duration,3)+'s / '+[Math]::Round([double]$g.hz,2)+'Hz / '+$laps.Count+' 圈')
}

Add-PipelineStage 'logical_stream_analysis'
$evidence=[ordered]@{
    schema_version=1;contract='native_action_evidence_summary_v1';authoritative=$false;source_sha256=$ReplaySha256;replay_file=[IO.Path]::GetFileName($ReplayPath)
    note='Compact evidence index generated from already-decoded native Drift/effect/combo facts; no extra replay scan and no semantic promotion.'
    streams=$evidenceStreams.ToArray()
}
Write-JsonUtf8 $evidencePath $evidence 12
Add-PipelineStage 'evidence_summary_write'

$summary=[ordered]@{
    schema_version=$script:TelemetrySchemaVersion;telemetry_semantic_signature=$(Get-TelemetrySemanticSignature);architecture='native_first_v1';native_first_semantic_contract_version=3;speed_contract_version=2;contact_state_contract_version=1;record_semantic_schema_version=1;lap_schema_version=2;drift_schema_version=5;drift_state_contract_version=5;replay_native_drift_timeline_schema_version=$script:TelemetryDriftTimelineSchemaVersion;replay_native_speed_effect_timeline_schema_version=$script:TelemetrySpeedEffectTimelineSchemaVersion;boost_effect_contract_version=3;combo_action_schema_version=2;semantic_model_contract_version=4;pose_discontinuity_schema_version=1;extractor_version=$toolVersion;replay_file=[IO.Path]::GetFileName($ReplayPath);source_sha256=$ReplaySha256;physical_transport_contract='qpf_v1';physical_cache_mode=$(if($physicalCacheHit){'reuse'}else{'rebuilt'});physical_cache_scope=$cacheScope;pipeline_profile_path='pipeline_profile.json';native_action_evidence_summary_path='native_action_evidence_summary.json';native_action_cache_contract=[string]$nativeActionScan.contract;native_action_cache_scanner_contract=[string]$nativeActionScan.scanner_contract;native_action_cache_mode=[string]$nativeActionScan.mode;native_action_cache_status=[string]$nativeActionScan.status;native_action_cache_scope=[string]$nativeActionScan.scope;native_action_cache_key=$(if([string]::IsNullOrWhiteSpace([string]$nativeActionScan.cache_dir)){$null}else{[IO.Path]::GetFileName([string]$nativeActionScan.cache_dir)});native_action_cache_write_status=[string]$nativeActionScan.write_status;native_action_tail_status=[string]$nativeActionScan.tail_status;native_action_scan_read_source_sav=[bool]$nativeActionScan.source_read;native_action_scan_from_tail=[bool]$nativeActionScan.tail_rescan;native_action_cache_read_ms=[long]$nativeActionScan.lookup_ms;native_action_scan_ms=[long]$nativeActionScan.scan_ms;native_action_cache_write_ms=[long]$nativeActionScan.write_ms;native_action_candidate_count=[int]$nativeActionScan.candidate_count;native_action_effect_table_count=[int]$nativeActionScan.effect_table_count
    speed_contract=[ordered]@{version=2;modern_2026_source='replay_linear_velocity';legacy_fallback='not_authoritative';diagnostic_source='speed_derived';rule='Native-first production uses replay-native linear velocity. Derived position velocity may remain in diagnostics but cannot silently become authoritative.'}
    contact_state_contract=[ordered]@{version=1;source='replay_native_int32_offset_52';enum_source='historical_tencentcar_enmcontactstatus';values=[ordered]@{'0'='in_air';'1'='none_contact';'2'='one_contact';'3'='two_contact';'4'='three_contact';'5'='full_contact'};rule='Preserve the replay-native contact enum. Do not collapse states 1..4 into inferred airborne/full-contact booleans.'}
    semantic_model_contract=[ordered]@{
        architecture='native_first_v1'
        system_drift=[ordered]@{status=$(if($nativeTimelineValidatedStreams-gt0){'authoritative'}else{'unavailable'});source='replay_native_action_object_drift_table_v3';validated_stream_count=$nativeTimelineValidatedStreams;fallback='none';rule='Official action-object marker + structural Drift table is authoritative; adjacent native effect-table structure ranks duplicate empty action objects; Shift is diagnostic only.'}
        replay_native_speed_effects=[ordered]@{status=$(if($nativeSpeedEffectValidatedStreams-gt0){'authoritative'}else{'unavailable'});source='replay_native_action_object_speed_effect_table_v2';validated_stream_count=$nativeSpeedEffectValidatedStreams;nitro='native code 1.0';small_boost_class='native code 2001.0 context-subtyped by ContactState and native Drift';map_propulsion_effect='native code 2003.0 validated from dedicated propulsion-scene recordings + map-fixed/recurrent position evidence + associated replay-native speed response';subtypes=@('drift_small_boost','air_boost','landing_boost','other_small_boost','map_propulsion_effect');unknown_codes='all codes except 1/2001/2003 preserved without semantic promotion'}
        map_geometry=[ordered]@{status='owned_by_native_map_pipeline';source='Map/Common Map/MapNN/map.nif';coordinate='world XY';replay_fit=$false}
        combo_actions=[ordered]@{status='diagnostic_only';source='native_effect_sequence_v2';supported=@('CW','WCW','CWW');authoritative=$false;fallback='none';production_authority='replay_native_action_event';rule='Timing-based sequence labels are a diagnostic/disagreement detector. Production CW/WCW/CWW authority is the replay-native action event table; the legacy detector is never used as a fallback.'}
        production_actions=[ordered]@{
            status='authoritative';source='replay_native_action_event';contract=$script:RNASContract
            air_boost='native action code 8';landing_boost='native action code 9';wcw='native action code 19'
            cw='native action code 25 grouped with a code 24 (500 ms tolerance, no intervening code24/code19 record)'
            cww='remaining native action code 24'
            cw_pair_tolerance_evidence='paired max gap 283ms (Gold A 46801/47084); standalone min gap 850ms (Gold B 121620/122470)'
            drift_logical_grouping='raw native Drift intervals coalesce when BOTH intervals are <= 500 ms long and the gap is <= 100 ms'
            drift_grouping_evidence='merged run: 7 intervals, durations 417..16ms, gaps 0..67ms; must-stay-separate: shortest interval 600ms, smallest gap 217ms (Gold B)'
            small_boost_parity='unresolved: code2001 raw exceeds the reported normal small boosts when air/landing are excluded (Gold B 46 vs 39 -> 7 unexplained). raw/anchored/unresolved are published; no game-facing normal count is invented.'
            nitro_parity='unresolved: game nitro = native code1 interval count + 1 in both gold replays (12 vs 11, 22 vs 21); the raw native count is published unmodified.'
            unknown_codes_rule='every action code without production semantics is published verbatim in unknown_action_codes with its evidence matrix row'
        }
        rule='Derived analysis may explain native facts but may not redefine or replace them.'
    }
    drift_state_contract=[ordered]@{version=5;system_state_available=($nativeTimelineValidatedStreams-gt0);system_state_status=$(if($nativeTimelineValidatedStreams-gt0){'replay_native_action_object_drift_table_validated'}else{'unavailable_no_fallback'});system_state_source='replay_native_action_object_drift_table_v3';system_state_authoritative_when_available=$true;fallback_rule='none';rule='Official action-object marker and structural Drift table define SystemDrift; adjacent effect-table structure only ranks duplicate native action objects; Shift/kinematics never gate or redefine it.'}
    boost_effect_contract=[ordered]@{version=3;native_source='replay_native_action_object_speed_effect_table_v2';native_validated_stream_count=$nativeSpeedEffectValidatedStreams;nitro_authority='code1 native interval';small_boost_class_authority='code2001 native interval with ContactState/native-Drift context';map_propulsion_authority='code2003 native interval validated by dedicated propulsion-scene recordings, authoritative zero-Drift controls, map-fixed/recurrent position evidence, and associated replay-native speed response';unknown_rule='all remaining native codes are preserved';rule='Native effect table is available even when authoritative Drift table is empty.'}
    detected_profile=[string]$rep.detected_profile;production_record_schema_2026=$manifest.production_record_schema_2026;physical_stream_count=@($rep.streams).Count;logical_stream_count=$streamOut.Count;physical_detector_contract=$coreDetectorContract;physical_cache_contract=$rawCacheContract
    streams=$streamOut.ToArray()
}
Write-JsonUtf8 $summaryPath $summary 12
Add-PipelineStage 'telemetry_summary_write'
$profile=[ordered]@{
    schema_version=1;contract='telemetry_pipeline_profile_v1';source_sha256=$ReplaySha256;replay_file=[IO.Path]::GetFileName($ReplayPath)
    native_action_event=[ordered]@{
        contract=[string]$nativeActionEventDecode.contract;status=[string]$nativeActionEventDecode.status;available=[bool]$nativeActionEventDecode.available
        reason=[string]$nativeActionEventDecode.reason;event_count=$(if([bool]$nativeActionEventDecode.available){[int]$nativeActionEventDecode.event_count}else{$null})
        count_offset=$(if([bool]$nativeActionEventDecode.available){[long]$nativeActionEventDecode.count_offset}else{$null})
        histogram=$(if([bool]$nativeActionEventDecode.available){$nativeActionEventDecode.histogram}else{@{}})
        window_source=[string]$nativeActionEventDecode.window_source;elapsed_ms=[long]$nativeActionEventDecode.elapsed_ms
    }
    total_ms=[long]$pipelineWatch.ElapsedMilliseconds;physical_cache_mode=$(if($physicalCacheHit){'reuse'}else{'rebuilt'});physical_cache_scope=$cacheScope;physical_transport='qpf_v1';raw_cache_contract=$rawCacheContract
    native_action=[ordered]@{
        contract=[string]$nativeActionScan.contract;scanner_contract=[string]$nativeActionScan.scanner_contract
        mode=[string]$nativeActionScan.mode;scope=[string]$nativeActionScan.scope;status=[string]$nativeActionScan.status;reason=[string]$nativeActionScan.reason
        tail_status=[string]$nativeActionScan.tail_status;write_status=[string]$nativeActionScan.write_status
        read_source_sav=[bool]$nativeActionScan.source_read;scan_from_tail=[bool]$nativeActionScan.tail_rescan
        cache_read_ms=[long]$nativeActionScan.lookup_ms;scan_ms=[long]$nativeActionScan.scan_ms;write_ms=[long]$nativeActionScan.write_ms
        candidate_count=[int]$nativeActionScan.candidate_count;effect_table_count=[int]$nativeActionScan.effect_table_count
        scan_window=$nativeActionScan.scan_window
    }
    stages=$profileStages.ToArray();streams=$streamProfiles.ToArray()
}
Write-JsonUtf8 $profilePath $profile 10
Write-Host ('  [性能] total='+$profile.total_ms+'ms · physical='+$profile.physical_cache_mode+' · transport=qpf_v1 · cache='+$cacheScope+' · action='+[string]$nativeActionScan.mode)
foreach($sp in @($streamProfiles.ToArray())){Write-Host ('    [性能/'+[string]$sp.role+'] prep='+[string]$sp.geometry_prepare_ms+'ms semantic='+[string]$sp.semantic_actions_ms+'ms csv='+[string]$sp.logical_csv_write_ms+'ms total='+[string]$sp.total_stream_ms+'ms')}
Write-Host ('  [证据索引] '+$evidencePath)
Write-Host ('  影子数据完成: '+$summaryPath)
exit 0
