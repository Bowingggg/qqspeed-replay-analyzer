function Json-Text([object]$Value,[int]$Depth=12) {
    return (ConvertTo-Json -InputObject $Value -Depth $Depth -Compress)
}
function Read-JsonFile([string]$Path) {
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}
function Analysis-MapName($j) {
    if($null-ne$j -and $null-ne$j.map_identity -and -not [string]::IsNullOrWhiteSpace([string]$j.map_identity.canonical_name)){return [string]$j.map_identity.canonical_name}
    if(-not [string]::IsNullOrWhiteSpace([string]$j.map_name)){return [string]$j.map_name}
    if(-not [string]::IsNullOrWhiteSpace([string]$j.map)){return [string]$j.map}
    if(-not [string]::IsNullOrWhiteSpace([string]$j.map_hint)){return [string]$j.map_hint}
    return '未识别地图'
}
function Comparison-MapNameKey([string]$Name) {
    $n=([string]$Name).Trim()
    if([string]::IsNullOrWhiteSpace($n)-or$n-eq'未识别地图'-or$n-eq'赛道未识别'-or$n-eq'赛道身份待确认'){return ''}
    return ('name:'+([regex]::Replace($n.ToLowerInvariant(),'\s+','')))
}
function Get-AnalysisPath([string]$Name) {
    if([string]::IsNullOrWhiteSpace($Name)-or[IO.Path]::GetFileName($Name)-ne $Name){return $null}
    $p=Join-Path $outputDir $Name
    if(Test-Path -LiteralPath $p -PathType Leaf){return $p}
    return $null
}
function Get-TelemetryPathForObject($j) {
    if($null -eq $j -or [string]::IsNullOrWhiteSpace([string]$j.telemetry_summary)){return $null}
    $rel=([string]$j.telemetry_summary).Replace('/','\').TrimStart('\')
    $full=[IO.Path]::GetFullPath((Join-Path $root $rel))
    $allowed=[IO.Path]::GetFullPath((Join-Path $dataDir 'Telemetry'))
    $prefix=$allowed.TrimEnd('\')+'\'
    if(-not ($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $full.Equals($allowed,[StringComparison]::OrdinalIgnoreCase))){return $null}
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){return $null}
    return $full
}
function Get-TelemetryPathForAnalysis([string]$AnalysisName) {
    $ap=Get-AnalysisPath $AnalysisName
    if($null -eq $ap){return $null}
    return Get-TelemetryPathForObject (Read-JsonFile $ap)
}
function Convert-StreamMeta($s) {
    $lapMeta=@()
    foreach($l in @($s.laps)){
        if($null-eq$l){continue}
        $lapMeta += [ordered]@{
            lap=$l.lap
            start_t=$l.start_t
            end_t=$l.end_t
            duration_s=$l.duration_s
            distance=$l.distance
        }
    }
    return [ordered]@{
        id=[string]$s.id
        role=[string]$s.role
        role_label=[string]$s.role_label
        sample_hz=$s.sample_hz
        records=$s.records
        duration_s=$s.duration_s
        distance=$s.distance
        avg_speed=$s.avg_speed
        speed_source=[string]$s.speed_source
        laps=@($lapMeta)
    }
}
function Get-BytesSha256([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash=$sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    return ([BitConverter]::ToString($hash)).Replace('-','').ToUpperInvariant()
}
function Save-WebReplayArchive([string]$SafeName,[byte[]]$Bytes) {
    $hash=Get-BytesSha256 $Bytes
    $dir=Join-Path $replayArchiveRoot $hash.Substring(0,16)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path=Join-Path $dir $SafeName
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)) { [IO.File]::WriteAllBytes($path,$Bytes) }
    else {
        try {
            $existing=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
            if($existing -ne $hash){ [IO.File]::WriteAllBytes($path,$Bytes) }
        } catch { [IO.File]::WriteAllBytes($path,$Bytes) }
    }
    $meta=[ordered]@{schema_version=1;sha256=$hash;original_name=$SafeName;archived_at=(Get-Date).ToString('o');source='web_upload'}
    $enc=New-Object System.Text.UTF8Encoding -ArgumentList $true
    [IO.File]::WriteAllText((Join-Path $dir 'archive.json'),(ConvertTo-Json -InputObject $meta -Depth 4),$enc)
    return [pscustomobject]@{hash=$hash;path=$path}
}
function Start-RefreshDataTask {
    if(-not(Test-Path -LiteralPath $refreshScript -PathType Leaf)){throw 'QQReplayRefresh.ps1 不存在。'}
    $id=[Guid]::NewGuid().ToString('N')
    $job=Start-Job -ScriptBlock {
        param($Script,$RootPath)
        try {
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        } catch {}
        Set-Location $RootPath
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script 2>&1
        $rc=$LASTEXITCODE
        if($rc -ne 0){throw ('ExitCode='+$rc)}
    } -ArgumentList $refreshScript,$root
    $script:toolTasks[$id]=[pscustomobject]@{job=$job;label='开发阶段全量重建分析缓存';started=(Get-Date);map_id=$null}
    return [ordered]@{ok=$true;task_id=$id}
}


function Get-ResolvedAnalysisMapName($J) {
    if($null -eq $J){ return '' }
    if($null-ne$J.map_identity -and [bool]$J.map_identity.authoritative -and -not[string]::IsNullOrWhiteSpace([string]$J.map_identity.canonical_name)){return ([string]$J.map_identity.canonical_name).Trim()}
    if(-not [string]::IsNullOrWhiteSpace([string]$J.map_name)){ return ([string]$J.map_name).Trim() }
    if(-not [string]::IsNullOrWhiteSpace([string]$J.map)){ return ([string]$J.map).Trim() }
    $hint=[string]$J.map_hint
    if(-not [string]::IsNullOrWhiteSpace($hint) -and $hint.Trim() -ne '未识别地图'){ return $hint.Trim() }
    return ''
}
function Get-ManualMapNames {
    $map=@{}
    if(Test-Path -LiteralPath $manualMapNamesPath -PathType Leaf) {
        try {
            $j=Get-Content -LiteralPath $manualMapNamesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if($null -ne $j) {
                foreach($prop in @($j.PSObject.Properties)) {
                    $map[[string]$prop.Name]=[string]$prop.Value
                }
            }
        } catch {}
    }
    return $map
}
function Save-ManualMapNames([hashtable]$Map) {
    $ordered=[ordered]@{}
    foreach($k in @($Map.Keys | Sort-Object)) { $ordered[$k]=[string]$Map[$k] }
    $enc=New-Object System.Text.UTF8Encoding -ArgumentList $true
    [IO.File]::WriteAllText($manualMapNamesPath,(ConvertTo-Json -InputObject $ordered -Depth 4),$enc)
}
function Get-ManualMapName($J,[string]$FileName,[hashtable]$Names) {
    $keys=New-Object System.Collections.Generic.List[string]
    if($null -ne $J -and -not [string]::IsNullOrWhiteSpace([string]$J.replay_sha256)){ $keys.Add('sha:'+[string]$J.replay_sha256) }
    $keys.Add('file:'+$FileName)
    $keys.Add($FileName)
    if($null -ne $J -and -not [string]::IsNullOrWhiteSpace([string]$J.replay_file)){ $keys.Add('replay:'+[string]$J.replay_file) }
    foreach($k in $keys.ToArray()) {
        if($Names.ContainsKey($k) -and -not [string]::IsNullOrWhiteSpace([string]$Names[$k])){ return [string]$Names[$k] }
    }
    return ''
}
function Set-ManualMapName([string]$AnalysisFile,[string]$MapName) {
    $ap=Get-AnalysisPath $AnalysisFile
    if($null -eq $ap){ throw '录像分析记录不存在。' }
    $j=Read-JsonFile $ap
    $resolved=(Get-ResolvedAnalysisMapName $j)
    if(-not [string]::IsNullOrWhiteSpace($resolved)) { throw '已识别地图不允许手动修改。' }
    $names=Get-ManualMapNames
    $name=([string]$MapName).Trim()
    $keys=New-Object System.Collections.Generic.List[string]
    $keys.Add($AnalysisFile)
    $keys.Add('file:'+$AnalysisFile)
    if($null -ne $j) {
        if(-not [string]::IsNullOrWhiteSpace([string]$j.replay_sha256)){ $keys.Add('sha:'+[string]$j.replay_sha256) }
        if(-not [string]::IsNullOrWhiteSpace([string]$j.replay_file)){ $keys.Add('replay:'+[string]$j.replay_file) }
    }
    foreach($k in $keys.ToArray()) {
        if([string]::IsNullOrWhiteSpace($name)) { [void]$names.Remove($k) }
        else { $names[$k]=$name }
    }
    Save-ManualMapNames $names
    if(-not[string]::IsNullOrWhiteSpace($name) -and (Get-Command Resolve-AnalysisMapIdentity -ErrorAction SilentlyContinue)) {
        try {
            $identity=Resolve-AnalysisMapIdentity -Analysis $j -AnalysisFile $AnalysisFile -DataDir $dataDir
            if($null-ne$identity -and -not[string]::IsNullOrWhiteSpace([string]$identity.course_key)){[void](Update-MapIdentityRegistry -DataDir $dataDir -Identity $identity)}
        } catch {}
    }
    return $name
}
function Remove-ManualMapNamesForAnalysis([string]$AnalysisFile,$J) {
    $names=Get-ManualMapNames
    $keys=New-Object System.Collections.Generic.List[string]
    $keys.Add($AnalysisFile);$keys.Add('file:'+$AnalysisFile)
    if($null -ne $J) {
        if(-not [string]::IsNullOrWhiteSpace([string]$J.replay_sha256)){ $keys.Add('sha:'+[string]$J.replay_sha256) }
        if(-not [string]::IsNullOrWhiteSpace([string]$J.replay_file)){ $keys.Add('replay:'+[string]$J.replay_file) }
    }
    foreach($k in $keys.ToArray()){[void]$names.Remove($k)}
    Save-ManualMapNames $names
}

function Get-ReplayLabels {
    $map=@{}
    if(Test-Path -LiteralPath $labelsPath -PathType Leaf) {
        try {
            $j=Get-Content -LiteralPath $labelsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if($null -ne $j) {
                foreach($prop in @($j.PSObject.Properties)) {
                    $map[[string]$prop.Name]=[string]$prop.Value
                }
            }
        } catch {}
    }
    return $map
}
function Save-ReplayLabels([hashtable]$Map) {
    $ordered=[ordered]@{}
    foreach($k in @($Map.Keys | Sort-Object)) { $ordered[$k]=[string]$Map[$k] }
    $enc=New-Object System.Text.UTF8Encoding -ArgumentList $true
    [IO.File]::WriteAllText($labelsPath,(ConvertTo-Json -InputObject $ordered -Depth 4),$enc)
}
function Get-ReplayDisplayName($J,[string]$FileName,[hashtable]$Labels) {
    $keys=New-Object System.Collections.Generic.List[string]
    if($null -ne $J -and -not [string]::IsNullOrWhiteSpace([string]$J.replay_sha256)){ $keys.Add('sha:'+[string]$J.replay_sha256) }
    $keys.Add('file:'+$FileName)
    $keys.Add($FileName)
    if($null -ne $J -and -not [string]::IsNullOrWhiteSpace([string]$J.replay_file)){ $keys.Add('replay:'+[string]$J.replay_file) }
    foreach($k in $keys.ToArray()) {
        if($Labels.ContainsKey($k) -and -not [string]::IsNullOrWhiteSpace([string]$Labels[$k])){ return [string]$Labels[$k] }
    }
    return ''
}
function Set-ReplayLabel([string]$AnalysisFile,[string]$DisplayName) {
    $ap=Get-AnalysisPath $AnalysisFile
    if($null -eq $ap){ throw '录像分析记录不存在。' }
    $j=Read-JsonFile $ap
    $labels=Get-ReplayLabels
    $name=([string]$DisplayName).Trim()
    $keys=New-Object System.Collections.Generic.List[string]
    $keys.Add($AnalysisFile)
    $keys.Add('file:'+$AnalysisFile)
    if($null -ne $j) {
        if(-not [string]::IsNullOrWhiteSpace([string]$j.replay_sha256)){ $keys.Add('sha:'+[string]$j.replay_sha256) }
        if(-not [string]::IsNullOrWhiteSpace([string]$j.replay_file)){ $keys.Add('replay:'+[string]$j.replay_file) }
    }
    foreach($k in $keys.ToArray()) {
        if([string]::IsNullOrWhiteSpace($name)) { [void]$labels.Remove($k) }
        else { $labels[$k]=$name }
    }
    Save-ReplayLabels $labels
    return $name
}

function Remove-ReplayLabelsForAnalysis([string]$AnalysisFile,$J) {
    $labels=Get-ReplayLabels
    $keys=New-Object System.Collections.Generic.List[string]
    $keys.Add($AnalysisFile);$keys.Add('file:'+$AnalysisFile)
    if($null -ne $J) {
        if(-not [string]::IsNullOrWhiteSpace([string]$J.replay_sha256)){ $keys.Add('sha:'+[string]$J.replay_sha256) }
        if(-not [string]::IsNullOrWhiteSpace([string]$J.replay_file)){ $keys.Add('replay:'+[string]$J.replay_file) }
    }
    foreach($k in $keys.ToArray()){[void]$labels.Remove($k)}
    Save-ReplayLabels $labels
}
function Remove-AnalysisLocal([string]$AnalysisFile) {
    $ap=Get-AnalysisPath $AnalysisFile
    if($null -eq $ap){ throw '录像分析记录不存在。' }
    $j=Read-JsonFile $ap
    $removedTelemetry=$false;$removedResolution=$false
    $tp=Get-TelemetryPathForObject $j
    if($tp) {
        $td=Split-Path -Parent $tp
        $allowed=[IO.Path]::GetFullPath((Join-Path $dataDir 'Telemetry')).TrimEnd('\')+'\'
        $full=[IO.Path]::GetFullPath($td)
        if($full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full -PathType Container)) {
            Remove-Item -LiteralPath $full -Recurse -Force
            $removedTelemetry=$true
        }
    }
    $sha=[string]$j.replay_sha256
    $removedArchive=$false
    $catalogState='not_updated'
    if(-not [string]::IsNullOrWhiteSpace($sha) -and $sha.Length -ge 16) {
        $rp=Join-Path $dataDir ('ReplayResolution\'+$sha.Substring(0,16).ToUpperInvariant()+'.json')
        if(Test-Path -LiteralPath $rp -PathType Leaf){Remove-Item -LiteralPath $rp -Force;$removedResolution=$true}
        # The source SAV stays in the Source Store. Removing a replay is a catalog
        # state change, not a source deletion, and it must survive a rebuild.
        try {
            $cat=Set-ReplayCatalogEntryState -DataDir $dataDir -Sha256 $sha -State 'removed'
            $catalogState=$(if([bool]$cat.ok){'removed'}else{'missing_entry'})
        } catch { $catalogState='error: '+$_.Exception.Message }
    }
    Remove-ReplayLabelsForAnalysis $AnalysisFile $j
    Remove-ManualMapNamesForAnalysis $AnalysisFile $j
    Remove-Item -LiteralPath $ap -Force
    Clear-SegmentComparisonRowCache
    return [ordered]@{ok=$true;file=$AnalysisFile;telemetry_removed=$removedTelemetry;resolution_removed=$removedResolution;archive_removed=$removedArchive;catalog_state=$catalogState}
}
function Clear-AnalysisDataLocal {
    $analysisCount=@(Get-ChildItem -LiteralPath $outputDir -File -ErrorAction SilentlyContinue).Count
    $telemetryRoot=Join-Path $dataDir 'Telemetry'
    $resolutionRoot=Join-Path $dataDir 'ReplayResolution'
    foreach($child in @(Get-ChildItem -LiteralPath $outputDir -Force -ErrorAction SilentlyContinue)){Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction SilentlyContinue}
    foreach($p in @($telemetryRoot,$resolutionRoot,$tempUploadRoot)) {
        if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue}
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }
    foreach($sub in @('Diagnostics\Analyzer','Diagnostics\Frontend')) {
        $p=Join-Path $dataDir $sub
        if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue}
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }
    Clear-SegmentComparisonRowCache
    return [ordered]@{ok=$true;analyses_removed=$analysisCount}
}

function Reset-CacheDirectoryLocal([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path)){ return }
    if(Test-Path -LiteralPath $Path){ Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Clear-RuntimeCacheLocal {
    # v3 Native-First reset: only native runtime products are rebuilt.  V2 inferred
    # topology/map/heuristic state is not a runtime dependency anymore.
    $analysisCount=@(Get-ChildItem -LiteralPath $outputDir -File -ErrorAction SilentlyContinue).Count
    $nativeMapRoot=Join-Path $dataDir 'NativeMaps'
    $nativeMapCount=if(Test-Path -LiteralPath $nativeMapRoot -PathType Container){@(Get-ChildItem -LiteralPath $nativeMapRoot -Directory -ErrorAction SilentlyContinue).Count}else{0}

    $stoppedTasks=0
    foreach($id in @($script:toolTasks.Keys)) {
        try {
            $t=$script:toolTasks[$id]
            if($null -ne $t -and $null -ne $t.job) {
                Stop-Job -Job $t.job -ErrorAction SilentlyContinue
                Remove-Job -Job $t.job -Force -ErrorAction SilentlyContinue
            }
            $stoppedTasks++
        } catch {}
    }
    $script:toolTasks=@{}
    $script:firstRunBootstrapTaskId=''
    Clear-SegmentComparisonRowCache

    foreach($p in @(
        $outputDir,
        (Join-Path $dataDir 'Telemetry'),
        (Join-Path $dataDir 'ReplayResolution'),
        $tempUploadRoot,
        $nativeMapRoot,
        (Join-Path $dataDir 'NativeIdentity'),
        (Join-Path $dataDir 'Diagnostics'),
        (Join-Path $dataDir 'Logs')
    )) { Reset-CacheDirectoryLocal $p }
    New-Item -ItemType Directory -Force -Path (Join-Path $dataDir 'Diagnostics\Analyzer'),(Join-Path $dataDir 'Diagnostics\Frontend') | Out-Null

    return [ordered]@{
        ok=$true
        architecture='native_first_v1'
        analyses_removed=$analysisCount
        native_maps_removed=$nativeMapCount
        background_tasks_stopped=$stoppedTasks
        preserved_map_catalog=(Test-Path -LiteralPath (Join-Path $dataDir 'MapCatalog\map_index.json') -PathType Leaf)
        preserved_descriptor_cache=(Test-Path -LiteralPath (Join-Path $dataDir 'MapCatalog\DescriptorCache') -PathType Container)
        preserved_settings=(Test-Path -LiteralPath $settingsPath -PathType Leaf)
    }
}


















function Get-AnalysisList {
    # The replay list is a list of REPLAY ENTITIES, not a directory listing of derived JSON files.
    # The authority is the Replay Catalog's EXPLICIT VISIBILITY axis: only entries the user made
    # visible by importing (and has not deleted) may surface, and only their canonical
    # *_analysis.json is inspected. Training/comparison artifacts in Output must never grow a second replay card,
    # and a derived analysis appearing on disk (a tooling run, an acceptance sweep) must never make a
    # replay visible again.
    $items=New-Object System.Collections.Generic.List[object]
    $labels=Get-ReplayLabels
    $manualNames=Get-ManualMapNames

    $catalogRead=$null
    $visibleSha=@{}
    try {
        $catalogRead=Read-ReplayCatalog -DataDir $dataDir
        if($null-eq$catalogRead.document){ return @() }
        # A catalog that does not exist is NOT permission to fall back to "every derived analysis in
        # Output". Fail closed: nothing is visible until something is explicitly imported (which
        # creates the catalog with exactly that replay).
        if(-not [bool]$catalogRead.exists){ return @() }
        $analysisIndex=Get-ReplayAnalysisShaIndex -AnalysisDir $outputDir
        foreach($e in @(Get-ReplayCatalogVisibleEntries -DataDir $dataDir -AnalysisShaIndex $analysisIndex)){
            $sha=([string]$e.sha256).Trim().ToUpperInvariant()
            if(-not[string]::IsNullOrWhiteSpace($sha)){$visibleSha[$sha]=$true}
        }
    } catch {
        # A catalog read failure is not permission to infer visibility from archive/output presence.
        # Fail closed: the list stays empty until the catalog is readable again.
        return @()
    }

    foreach($f in @(Get-ChildItem -LiteralPath $outputDir -Filter '*_analysis.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $j=Read-JsonFile $f.FullName
        if($null -eq $j){continue}
        $sha=([string]$j.replay_sha256).Trim().ToUpperInvariant()
        if([string]::IsNullOrWhiteSpace($sha) -or -not $visibleSha.ContainsKey($sha)){continue}
        $streams=@()
        foreach($s in @($j.streams)) { if($null-ne$s){$streams += (Convert-StreamMeta $s)} }
        if($streams.Count -eq 0) {
            $tp=Get-TelemetryPathForObject $j
            if($tp) {
                $tj=Read-JsonFile $tp
                foreach($s in @($tj.streams)) { if($null-ne$s){$streams += (Convert-StreamMeta $s)} }
            }
        }
        $identity=$null
        if(Get-Command Resolve-AnalysisMapIdentity -ErrorAction SilentlyContinue){try{$identity=Resolve-AnalysisMapIdentity -Analysis $j -AnalysisFile $f.Name -DataDir $dataDir}catch{}}
        $resolvedMapName=$(if($null-ne$identity -and -not[string]::IsNullOrWhiteSpace([string]$identity.canonical_name)){[string]$identity.canonical_name}else{Analysis-MapName $j})
        $comparisonNameKey=Comparison-MapNameKey $resolvedMapName
        $items.Add([ordered]@{
            file=$f.Name
            replay_sha256=$sha
            map=$resolvedMapName
            map_id=$(if($null-ne$identity -and $null-ne$identity.canonical_map_id){$identity.canonical_map_id}elseif($null -ne $j.map_id){$j.map_id}else{$null})
            resource_map_id=$(if($null-ne$identity -and $null-ne$identity.resource_map_id){$identity.resource_map_id}elseif($null-ne$j.resource_map_id){$j.resource_map_id}else{$null})
            game_map_id=$(if($null-ne$identity -and $null-ne$identity.game_map_id){$identity.game_map_id}elseif($null-ne$j.game_map_id){$j.game_map_id}else{$null})
            course_key=$(if($null-ne$identity){[string]$identity.course_key}else{''})
            identity_key=$(if($null-ne$identity){[string]$identity.course_key}else{''})
            comparison_map_key=$(if($null-ne$identity -and -not[string]::IsNullOrWhiteSpace([string]$identity.course_key)){[string]$identity.course_key}elseif($null-ne$identity -and $null-ne$identity.game_map_id){'game:'+[string]$identity.game_map_id}elseif($null-ne$j.game_map_id){'game:'+[string]$j.game_map_id}else{$comparisonNameKey})
            comparison_map_source=$(if($null-ne$identity -and -not[string]::IsNullOrWhiteSpace([string]$identity.course_key)){'resource_map_id'}elseif(($null-ne$identity -and $null-ne$identity.game_map_id) -or $null-ne$j.game_map_id){'trusted_game_map_id'}elseif(-not[string]::IsNullOrWhiteSpace($comparisonNameKey)){'exact_same_map_name'}else{'unavailable'})
            map_identity_status=$(if($null-ne$identity){[string]$identity.status}else{'unresolved'})
            map_identity_authoritative=$(if($null-ne$identity){[bool]$identity.authoritative}else{$false})
            replay=$(if(-not [string]::IsNullOrWhiteSpace([string]$j.replay_file)){[string]$j.replay_file}else{$f.BaseName})
            display_name=(Get-ReplayDisplayName $j $f.Name $labels)
            manual_map_name=(Get-ManualMapName $j $f.Name $manualNames)
            status=$(if($j.status){[string]$j.status}else{'preanalysis'})
            telemetry_status=[string]$j.telemetry_status
            architecture=$(if($j.architecture){[string]$j.architecture}else{'unknown'})
            native_map_status=$(if($null-ne$j.native_map){[string]$j.native_map.status}else{'unavailable'})
            native_actions_status=$(if($null-ne$j.native_actions -and -not[string]::IsNullOrWhiteSpace([string]$j.native_actions.status)){[string]$j.native_actions.status}else{'unavailable'})
            driving_analysis_status=$(if($null-ne$j.driving_analysis -and -not[string]::IsNullOrWhiteSpace([string]$j.driving_analysis.status)){[string]$j.driving_analysis.status}else{'unavailable'})
            driving_episodes_status=$(if($null-ne$j.driving_episodes -and -not[string]::IsNullOrWhiteSpace([string]$j.driving_episodes.native_episode_analysis)){[string]$j.driving_episodes.native_episode_analysis}else{'unavailable'})
            driving_spatial_status=$(if($null-ne$j.driving_episodes -and -not[string]::IsNullOrWhiteSpace([string]$j.driving_episodes.spatial_driving)){[string]$j.driving_episodes.spatial_driving}else{'unavailable_prerequisite'})
            stream_count=@($streams).Count
            streams=@($streams)
            modified=$f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        })
    }
    return $items.ToArray()
}
function Get-MapMetadataPath([object]$MapId) {
    try { $mid=[int]$MapId } catch { return $null }
    if($mid -lt 0){ return $null }
    $p=Join-Path $dataDir ('NativeMaps\Map'+$mid+'\metadata.json')
    if(Test-Path -LiteralPath $p -PathType Leaf){ return $p }
    return $null
}

function Get-GamePathLocal {
    if(-not(Test-Path -LiteralPath $settingsPath -PathType Leaf)){ return $null }
    try {
        $j=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $g=[string]$j.game_path
        if(-not [string]::IsNullOrWhiteSpace($g) -and (Test-Path -LiteralPath $g -PathType Container)){ return $g }
    } catch {}
    return $null
}
function Test-MapTransform($Meta) {
    if($null -eq $Meta){ return $false }
    try {
        return ([string]$Meta.contract -eq 'native_map_v1' -and [bool]$Meta.official_source -and $null -ne $Meta.render_transform -and [double]$Meta.render_transform.scale -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$Meta.vector_minimap))
    } catch { return $false }
}



function Save-GamePathLocal([string]$GamePath) {
    $g=([string]$GamePath).Trim().Trim([char]34)
    if([string]::IsNullOrWhiteSpace($g) -or -not(Test-Path -LiteralPath $g -PathType Container)){ throw '游戏目录不存在。' }
    $obj=[ordered]@{game_path=$g}
    $enc=New-Object System.Text.UTF8Encoding -ArgumentList $true
    [IO.File]::WriteAllText($settingsPath,(ConvertTo-Json -InputObject $obj -Depth 4),$enc)
    return $g
}
function Select-GamePathLocal {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dlg=New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description='请选择 QQ飞车 游戏安装目录'
    $dlg.ShowNewFolderButton=$false
    $cur=Get-GamePathLocal
    if($cur){ try{$dlg.SelectedPath=$cur}catch{} }
    if($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK){ return $null }
    return Save-GamePathLocal $dlg.SelectedPath
}

# First-run bootstrap contract. A clean installation is usable after the user selects the game
# directory once: the official resource catalog and GameMapID<->ResourceMapID binding are built in
# the background. Existing valid catalogs are never rebuilt implicitly, so normal startup remains
# cheap and a later game-path edit does not destroy/replace already validated catalog data.
function Get-FirstRunBootstrapStateLocal {
    $mapIndex=Join-Path $dataDir 'MapCatalog\map_index.json'
    $catalogMeta=Join-Path $dataDir 'MapCatalog\catalog_meta.json'
    $bindingPath=Join-Path $dataDir 'MapCatalog\game_resource_bindings.json'
    $mapCount=0;$bindingCount=0;$catalogSchema=0;$mapReady=$false;$bindingReady=$false
    if(Test-Path -LiteralPath $mapIndex -PathType Leaf) {
        try {
            $maps=@(Get-Content -LiteralPath $mapIndex -Raw -Encoding UTF8 | ConvertFrom-Json)
            $mapCount=$maps.Count
            if(Test-Path -LiteralPath $catalogMeta -PathType Leaf){$meta=Get-Content -LiteralPath $catalogMeta -Raw -Encoding UTF8|ConvertFrom-Json;$catalogSchema=[int]$meta.schema_version}
            $mapReady=($mapCount -gt 0 -and $catalogSchema -ge 6)
        } catch {}
    }
    if(Test-Path -LiteralPath $bindingPath -PathType Leaf) {
        try {
            $b=Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if($null-ne$b -and @($b.PSObject.Properties.Name) -contains 'bindings') {
                $bindingCount=@($b.bindings).Count;$bindingReady=($bindingCount -gt 0)
            }
        } catch {}
    }
    $taskId=''
    if(-not[string]::IsNullOrWhiteSpace([string]$script:firstRunBootstrapTaskId) -and $script:toolTasks.ContainsKey([string]$script:firstRunBootstrapTaskId)) {
        $taskId=[string]$script:firstRunBootstrapTaskId
    }
    $dataReady=($mapReady -and $bindingReady)
    $busy=(-not[string]::IsNullOrWhiteSpace($taskId))
    $ready=($dataReady -and -not$busy)
    return [ordered]@{
        ready=$ready
        data_ready=$dataReady
        busy=$busy
        required=(-not$dataReady)
        map_catalog_ready=$mapReady
        map_catalog_schema=$catalogSchema
        map_count=$mapCount
        game_resource_binding_ready=$bindingReady
        binding_count=$bindingCount
        task_id=$taskId
    }
}
function Start-MapCatalogBuildTask([bool]$Force=$false,[string]$Label='初始化游戏资料') {
    $game=Get-GamePathLocal
    if([string]::IsNullOrWhiteSpace([string]$game)){ throw '请先设置游戏目录。' }
    $state=Get-FirstRunBootstrapStateLocal
    if(-not$Force -and [bool]$state.ready){ return [ordered]@{ok=$true;ready=$true;started=$false;task_id='';bootstrap=$state} }
    if(-not[string]::IsNullOrWhiteSpace([string]$script:firstRunBootstrapTaskId) -and $script:toolTasks.ContainsKey([string]$script:firstRunBootstrapTaskId)) {
        $active=$script:toolTasks[[string]$script:firstRunBootstrapTaskId]
        if([string]$active.game_path -eq [string]$game) {
            return [ordered]@{ok=$true;ready=$false;started=$false;task_id=[string]$script:firstRunBootstrapTaskId;bootstrap=$state}
        }
        # The user changed the game directory while the old bootstrap was still running. Never let
        # an old path finish later and overwrite the catalog selected for the new path.
        try{Stop-Job -Job $active.job -ErrorAction SilentlyContinue}catch{}
        try{Remove-Job -Job $active.job -Force -ErrorAction SilentlyContinue}catch{}
        [void]$script:toolTasks.Remove([string]$script:firstRunBootstrapTaskId)
        $script:firstRunBootstrapTaskId=''
    }
    if(-not(Test-Path -LiteralPath $catalogScript -PathType Leaf)){ throw 'QQSpeedMapCatalog.ps1 不存在。' }
    $id=[Guid]::NewGuid().ToString('N')
    $job=Start-Job -ScriptBlock {
        param($Script,$Game,$RootPath)
        try {
            [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false)
            $OutputEncoding=New-Object System.Text.UTF8Encoding($false)
        } catch {}
        Set-Location $RootPath
        Write-Output '[首次初始化] 正在建立官方地图目录...'
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script -Mode Build -GamePath $Game 2>&1
        $rc=$LASTEXITCODE
        if($rc-ne0){throw ('MapCatalog Build ExitCode='+$rc)}
        Write-Output '[首次初始化] 正在建立 GameMapID <-> ResourceMapID 绑定...'
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script -Mode BuildGameResourceBindings -GamePath $Game 2>&1
        $rc=$LASTEXITCODE
        if($rc-ne0){throw ('GameResourceBinding Build ExitCode='+$rc)}
        Write-Output '[首次初始化] 游戏资料已就绪。'
    } -ArgumentList $catalogScript,$game,$root
    $script:toolTasks[$id]=[pscustomobject]@{job=$job;label=$Label;started=(Get-Date);map_id=$null;kind='map_catalog';game_path=$game}
    $script:firstRunBootstrapTaskId=$id
    $state=Get-FirstRunBootstrapStateLocal
    return [ordered]@{ok=$true;ready=$false;started=$true;task_id=$id;bootstrap=$state}
}
function Start-FirstRunBootstrapTask {
    return Start-MapCatalogBuildTask -Force $false -Label '首次初始化游戏资料'
}
function Get-SystemStatusLocal {
    $game=Get-GamePathLocal
    $mapIndex=Join-Path $dataDir 'MapCatalog\map_index.json'
    $maps=@()
    if(Test-Path -LiteralPath $mapIndex -PathType Leaf){try{$maps=@(Get-Content -LiteralPath $mapIndex -Raw -Encoding UTF8|ConvertFrom-Json)}catch{}}
    $named=0;foreach($m in $maps){if(-not[string]::IsNullOrWhiteSpace([string]$m.primary_name)){$named++}}
    $nativeRoot=Join-Path $dataDir 'NativeMaps'
    $nativeCount=if(Test-Path -LiteralPath $nativeRoot){@(Get-ChildItem -LiteralPath $nativeRoot -Directory -ErrorAction SilentlyContinue).Count}else{0}
    $bootstrap=Get-FirstRunBootstrapStateLocal
    return [ordered]@{
        architecture='native_first_v1'
        game_path=$game
        game_path_valid=(-not[string]::IsNullOrWhiteSpace([string]$game))
        catalog_maps=$maps.Count
        catalog_named=$named
        catalog_unnamed=($maps.Count-$named)
        native_map_count=$nativeCount
        analyses=@(Get-ChildItem -LiteralPath $outputDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
        bootstrap=$bootstrap
        comparison_row_cache_entries=$(if($null-ne$script:segmentComparisonRowCache){$script:segmentComparisonRowCache.Count}else{0})
    }
}

function Get-ToolTaskStatus([string]$Id) {
    if([string]::IsNullOrWhiteSpace($Id)-or-not$script:toolTasks.ContainsKey($Id)){return [ordered]@{ok=$false;done=$true;error='任务不存在或已结束。';log=@()}}
    $t=$script:toolTasks[$Id];$j=$t.job
    $lines=@(Receive-Job -Job $j -Keep -ErrorAction SilentlyContinue|ForEach-Object {[string]$_})
    $state=[string]$j.State;$done=$state -in @('Completed','Failed','Stopped','Disconnected')
    $err=''
    if($state -eq 'Failed'){
        try{$err=[string]$j.ChildJobs[0].JobStateInfo.Reason.Message}catch{}
        if([string]::IsNullOrWhiteSpace($err)){$err='后台任务失败。'}
    } elseif($state -eq 'Stopped'){$err='后台任务已停止。'}
    $elapsed=[Math]::Round(((Get-Date)-$t.started).TotalSeconds,1)
    $bootstrap=$(if([string]$t.kind -eq 'map_catalog'){Get-FirstRunBootstrapStateLocal}else{$null})
    $result=[ordered]@{ok=($done -and $state -eq 'Completed');done=$done;state=$state;label=$t.label;map_id=$t.map_id;kind=[string]$t.kind;elapsed_s=$elapsed;log=@($lines|Select-Object -Last 300);error=$err;bootstrap=$bootstrap}
    if($done){
        try{Remove-Job -Job $j -Force -ErrorAction SilentlyContinue}catch{}
        [void]$script:toolTasks.Remove($Id)
        if([string]$script:firstRunBootstrapTaskId -eq $Id){$script:firstRunBootstrapTaskId=''}
        if([string]$t.kind -eq 'map_catalog'){$result.bootstrap=Get-FirstRunBootstrapStateLocal}
    }
    return $result
}

function Invoke-ToolVisible([string]$Script,[string[]]$ToolArgs,[string]$Label) {
    if(-not(Test-Path -LiteralPath $Script -PathType Leaf)){return [ordered]@{ok=$false;error=('缺少 '+[IO.Path]::GetFileName($Script));log=@()}}
    $lines=New-Object System.Collections.Generic.List[string]
    Write-Host ('[网页设置] '+$Label)
    Push-Location $root
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @ToolArgs 2>&1 | ForEach-Object{$t=[string]$_;Write-Host $t;$lines.Add($t)}
        $rc=$LASTEXITCODE
    } finally {Pop-Location}
    return [ordered]@{ok=($rc-eq0);exit_code=$rc;error=$(if($rc-eq0){''}else{'ExitCode='+$rc});log=@($lines.ToArray()|Select-Object -Last 220)}
}
function Invoke-MapToolLocal($Req) {
    $action=[string]$Req.action
    $game=Get-GamePathLocal
    if($action -notin @('status','set_game_path','select_game_path') -and [string]::IsNullOrWhiteSpace($game)){return [ordered]@{ok=$false;error='请先设置游戏目录。';log=@()}}
    switch($action) {
        'rebuild_catalog' {
            return Start-MapCatalogBuildTask -Force $true -Label '重新初始化游戏资料'
        }
        'map_detail' { return Invoke-ToolVisible $catalogScript @('-Mode','Detail','-DetailMapId',([int]$Req.map_id).ToString(),'-GamePath',$game) ('读取 Map'+[int]$Req.map_id+' 官方资源详情') }
        'rebuild_map' { return Invoke-MapRebuild ([int]$Req.map_id) }
        default { return [ordered]@{ok=$false;error='v3 已移除地图猜测/名称深搜/缩略图探针。可用操作：重建官方目录、读取详情、重建官方 map.nif。';log=@()} }
    }
}
function Invoke-MapRebuild([int]$MapId) {
    if($MapId -lt 0){ return [ordered]@{ok=$false;error='Map ID 无效';log_tail=@()} }
    if(-not(Test-Path -LiteralPath $builderScript -PathType Leaf)){ return [ordered]@{ok=$false;error='QQNativeMap.ps1 不存在';log_tail=@()} }
    $game=Get-GamePathLocal
    if([string]::IsNullOrWhiteSpace($game)){ return [ordered]@{ok=$false;error='尚未配置有效的游戏目录';log_tail=@()} }
    $lines=New-Object System.Collections.Generic.List[string]
    Write-Host ('[网页] 重建 Map'+$MapId+' 官方 map.nif 地图...')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builderScript -MapId $MapId -GamePath $game -Force 2>&1 | ForEach-Object {
        $line=[string]$_; Write-Host $line; $lines.Add($line)
    }
    $rc=$LASTEXITCODE
    $mp=Get-MapMetadataPath $MapId
    $meta=if($mp){Read-JsonFile $mp}else{$null}
    $ok=($rc -eq 0 -and (Test-MapTransform $meta))
    $err=''
    if(-not $ok) {
        if($rc -ne 0){$err='官方地图提取失败，ExitCode='+$rc}else{$err='map.nif 已提取但 Native Map contract 未通过'}
    }
    return [ordered]@{ok=$ok;exit_code=$rc;error=$err;log_tail=@($lines.ToArray()|Select-Object -Last 60)}
}

function Get-ContentType([string]$Path) {
    switch(([IO.Path]::GetExtension($Path)).ToLowerInvariant()) {
        '.png' {'image/png'} '.jpg' {'image/jpeg'} '.jpeg' {'image/jpeg'} '.webp' {'image/webp'} '.svg' {'image/svg+xml'}
        '.json' {'application/json; charset=utf-8'} default {'application/octet-stream'}
    }
}
function Safe-UploadFileName([string]$Name) {
    try{$n=[IO.Path]::GetFileName($Name)}catch{return $null}
    if([string]::IsNullOrWhiteSpace($n)){return $null}
    if([IO.Path]::GetExtension($n) -ine '.sav'){return $null}
    return $n
}
function Decode-B64Utf8([string]$Text) {
    try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text)) } catch { return $null }
}
function Invoke-WebAnalysis([string]$SafeName,[byte[]]$Bytes) {
    if(-not(Test-Path -LiteralPath $analyzerScript -PathType Leaf)){throw 'QQReplay.ps1 不存在。'}
    if($Bytes.Length -gt 67108864){throw '录像文件超过 64 MB，已拒绝。'}
    $bootstrap=Get-FirstRunBootstrapStateLocal
    if(-not[bool]$bootstrap.ready) {
        $kick=Start-FirstRunBootstrapTask
        if(-not[bool]$kick.ready){ throw '游戏资料正在首次初始化，请等待完成后再添加录像。' }
    }
    $archive=Save-WebReplayArchive $SafeName $Bytes
    $sourcePath=[string]$archive.path
    # An explicit user import is the ONLY path that activates a replay in the
    # Replay Catalog. Source presence in ReplayArchive never activates anything.
    $catalogState='not_updated'
    try {
        [void](Add-ReplayCatalogEntry -DataDir $dataDir -Sha256 ([string]$archive.hash) -SourceRelPath (Get-ReplaySourceRelativePath -ProjectRoot $root -FullPath $sourcePath) -OriginalName $SafeName -SizeBytes ([long]$Bytes.Length) -SourcePresent $true -AnalysisDir $outputDir)
        $catalogState='active'
    } catch {
        $catalogState='error: '+$_.Exception.Message
        throw ('录像已安全存档，但无法写入可见录像目录；已停止分析，避免出现“分析成功但列表不可见”。'+$_.Exception.Message)
    }
    Write-Host ('[网页分析] '+$SafeName)
    Write-Host ('  [录像存档] '+$sourcePath)
    Write-Host ('  [Catalog] '+$catalogState)
    $lines=New-Object System.Collections.Generic.List[string]
    $started=Get-Date
    Push-Location $root
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $analyzerScript -Mode Analyze -Items $sourcePath 2>&1 | ForEach-Object {
            $s=[string]$_
            Write-Host $s
            $lines.Add($s)
        }
        $rc=$LASTEXITCODE
    } finally { Pop-Location }
    $tail=@($lines.ToArray() | Select-Object -Last 80)
    $analysisName=[IO.Path]::GetFileNameWithoutExtension($SafeName)+'_analysis.json'
    $analysisPath=Join-Path $outputDir $analysisName
    $usable=Test-Path -LiteralPath $analysisPath -PathType Leaf
    try {
        $logPath=Join-Path $frontendDiagDir 'last_web_analysis.log'
        $log=@('file='+$SafeName,'archive_sha256='+[string]$archive.hash,'archive_path='+$sourcePath,'exit_code='+$rc,'analysis_file='+$analysisName,'output_exists='+$usable,'---') + @($lines.ToArray())
        [IO.File]::WriteAllLines($logPath,$log,(New-Object System.Text.UTF8Encoding -ArgumentList $true))
    } catch {}
    return [ordered]@{ok=($rc-eq0 -or $usable);partial=($rc-ne0 -and $usable);exit_code=$rc;analysis_file=$analysisName;replay_archived=$true;log_tail=$tail}
}

# Frontend comparison requests reuse the same 6k-9k-row telemetry CSVs when the user changes a
# corner, counterpart or lap. Keep a small process-local LRU so those typed rows are not re-read from
# disk on every comparison request. File length + LastWriteTimeUtc invalidate stale entries after a
# refresh/re-analysis; the cache is transport-only and carries no semantic authority.
$script:segmentComparisonRowCache=$null
$script:segmentComparisonRowCacheLimit=6
function Initialize-SegmentComparisonRowCache { if($null-eq$script:segmentComparisonRowCache){$script:segmentComparisonRowCache=@{}} }
function Clear-SegmentComparisonRowCache { $script:segmentComparisonRowCache=@{} }
function Get-SegmentComparisonRowsCached([string]$CsvPath) {
    Initialize-SegmentComparisonRowCache
    $full=[IO.Path]::GetFullPath($CsvPath)
    $fi=Get-Item -LiteralPath $full -ErrorAction Stop
    $sig=([string]$fi.Length+'|'+[string]$fi.LastWriteTimeUtc.Ticks)
    if($script:segmentComparisonRowCache.ContainsKey($full)) {
        $hit=$script:segmentComparisonRowCache[$full]
        if([string]$hit.signature -eq $sig) {
            $hit.last_access=[DateTime]::UtcNow.Ticks
            return $hit.rows
        }
        [void]$script:segmentComparisonRowCache.Remove($full)
    }
    $rows=@(NDA-LoadRows $full)
    if($script:segmentComparisonRowCache.Count -ge $script:segmentComparisonRowCacheLimit) {
        $oldKey=@($script:segmentComparisonRowCache.Keys|Sort-Object {[long]$script:segmentComparisonRowCache[$_].last_access}|Select-Object -First 1)
        if($oldKey.Count-gt0){[void]$script:segmentComparisonRowCache.Remove([string]$oldKey[0])}
    }
    $script:segmentComparisonRowCache[$full]=[pscustomobject]@{signature=$sig;rows=$rows;last_access=[DateTime]::UtcNow.Ticks}
    return $rows
}

# ---------------------------------------------------------------------------------------------
# Analysis Closure v1 - symmetric same-map segment comparison (analysis side, not a comparison job)
#
# The comparison unit is the published segmentation contract (`analysis.segment_analysis`,
# contract `native_analysis_segments_v1`): native Drift start -> native recovery end. The two sides
# are corresponded with the already-validated monotone/order-preserving/heading-gated/bounded
# spatial kernel, in a canonical side order. Paired-corner core time keeps the earlier mapped
# Drift start and stops at the earlier mapped natural recovery end; final net time continues to the later recovery end, so single/double-spray
# tail cannot enlarge the efficiency window. A->B and B->A still publish the SAME world intervals
# and every signed metric negates. A side that is not a real replay on the current list is never
# synthesised: a comparison without a real counterpart is refused, not faked.
# ---------------------------------------------------------------------------------------------
function Get-SegmentComparisonSide([string]$AnalysisFile,[string]$StreamSelector,[int]$LapNo){
    $fp=Get-AnalysisPath $AnalysisFile
    if($null-eq$fp){ throw ('analysis not found: '+$AnalysisFile) }
    $j=Read-JsonFile $fp
    if($null-eq$j){ throw ('analysis unreadable: '+$AnalysisFile) }
    $telPath=Get-TelemetryPathForObject $j
    if([string]::IsNullOrWhiteSpace($telPath)){ throw ('telemetry not found for: '+$AnalysisFile) }
    $tel=Read-JsonFile $telPath
    if($null-eq$tel){ throw ('telemetry unreadable for: '+$AnalysisFile) }
    $s=$null
    if(-not [string]::IsNullOrWhiteSpace($StreamSelector)){
        foreach($x in @($tel.streams)){ if([string]$x.id -eq $StreamSelector){ $s=$x; break } }
        if($null-eq$s){
            # Role fallback only when exactly one candidate carries the role: a replay may hold
            # several network_low_frequency shadows, and guessing the owner would compare the wrong
            # car. Ambiguity fails closed.
            $cand=@($tel.streams|Where-Object{$null-ne$_-and[string]$_.role-eq$StreamSelector})
            if($cand.Count-eq1){ $s=$cand[0] }
            elseif($cand.Count-gt1){ throw ('stream selector is ambiguous ('+[string]$cand.Count+' candidates): '+$StreamSelector) }
            else { throw ('no such stream: '+$StreamSelector) }
        }
    }
    if($null-eq$s){ foreach($x in @($tel.streams)){ if([string]$x.role -eq 'local_high_frequency'){ $s=$x; break } } }
    if($null-eq$s -and @($tel.streams).Count -eq 1){ $s=@($tel.streams)[0] }
    if($null-eq$s){ throw ('no unambiguous local stream in: '+$AnalysisFile) }
    $lap=$null
    foreach($l in @($s.laps)){ if([int]$l.lap -eq $LapNo){ $lap=$l; break } }
    if($null-eq$lap){ throw ('lap '+[string]$LapNo+' is not available in: '+$AnalysisFile) }
    $csvName=[string]$s.csv
    if([string]::IsNullOrWhiteSpace($csvName)){ throw ('stream has no CSV in: '+$AnalysisFile) }
    $csvPath=Join-Path (Split-Path -Parent $telPath) $csvName
    if(-not (Test-Path -LiteralPath $csvPath -PathType Leaf)){ throw ('telemetry rows missing for: '+$AnalysisFile) }
    $rows=@(Get-SegmentComparisonRowsCached $csvPath)
    if($rows.Count-lt2){ throw ('telemetry rows unusable for: '+$AnalysisFile) }

    # The segmentation comes from the published contract, never from a second implementation here.
    $segments=@()
    if($null-ne$j.segment_analysis){
        $es=$null
        foreach($x in @($j.segment_analysis.streams)){ if([string]$x.id -eq [string]$s.id){ $es=$x; break } }
        if($null-eq$es){ foreach($x in @($j.segment_analysis.streams)){ if([string]$x.role -eq [string]$s.role){ $es=$x; break } } }
        if($null-ne$es){ foreach($l in @($es.laps)){ if([int]$l.lap -eq $LapNo){ $segments=@($l.segments); break } } }
    }

    $ls=NTA-RowIndexAtTime $rows 0 ($rows.Count-1) ([double]$lap.start_t)
    $le=NTA-RowIndexAtTime $rows 0 ($rows.Count-1) ([double]$lap.end_t)
    $sha=([string]$j.replay_sha256).Trim().ToUpperInvariant()
    $mapName=$(if(-not [string]::IsNullOrWhiteSpace([string]$j.map_name)){[string]$j.map_name}else{Analysis-MapName $j})
    return [pscustomobject][ordered]@{
        key=($sha+':'+[string]$s.id+':L'+[string]$LapNo)
        label=($mapName+' L'+[string]$LapNo)
        resource_map_id=$(if($null-ne$j.resource_map_id){$j.resource_map_id}else{$j.map_id})
        game_map_id=$j.game_map_id
        map_name=$mapName
        map_name_key=(Comparison-MapNameKey $mapName)
        map_authority=$(if($null-ne$j.map_identity -and [bool]$j.map_identity.authoritative){'authoritative'}else{'unresolved'})
        segments=$segments
        rows=$rows
        lap_start_i=$ls
        lap_end_i=$le
        lap=$LapNo
        stream_id=[string]$s.id
        stream_role=[string]$s.role
        speed_effect_state_available=[bool]$s.speed_effect_state_available
        telemetry_status=$(if($null-ne$j.telemetry_status){[string]$j.telemetry_status}else{''})
    }
}

# One comparison request. Body:
#   subject_file_b64 (required), subject_stream (optional), subject_lap (required)
#   compare_file_b64 or compare_stream (required: a real replay file, the SAME replay for a
#                                                     different-lap comparison, or an internal network shadow)
#   compare_lap (required for replay comparisons; it may name another lap of subject_file_b64)
#   mode: 'auto' | 'custom'; custom: {side_key, start_d, end_d} for 'custom'
function Invoke-SegmentComparisonLocal($Req) {
    try {
        $subjectFile=Decode-B64Utf8 ([string]$Req.subject_file_b64)
        if([string]::IsNullOrWhiteSpace($subjectFile)){ throw 'subject_file_b64 is required' }
        $subjectLap=0
        if(-not [int]::TryParse([string]$Req.subject_lap,[ref]$subjectLap)){ throw 'subject_lap is required' }
        $subjectStream=[string]$Req.subject_stream
        $compareFile=Decode-B64Utf8 ([string]$Req.compare_file_b64)
        $compareStream=[string]$Req.compare_stream
        $mode=$(if([string]::IsNullOrWhiteSpace([string]$Req.mode)){'auto'}else{[string]$Req.mode})
        $internal=(-not [string]::IsNullOrWhiteSpace($compareStream))
        if([string]::IsNullOrWhiteSpace($compareFile) -and -not $internal){ throw 'a real comparison counterpart is required' }
        $compareLap=0
        if($internal){
            $compareFile=$subjectFile
            $compareLap=$subjectLap
            if([int]::TryParse([string]$Req.compare_lap,[ref]$compareLap) -and $compareLap-le0){ $compareLap=$subjectLap }
        } else {
            if(-not [int]::TryParse([string]$Req.compare_lap,[ref]$compareLap)){ throw 'compare_lap is required' }
        }
        $a=Get-SegmentComparisonSide -AnalysisFile $subjectFile -StreamSelector $subjectStream -LapNo $subjectLap
        $b=Get-SegmentComparisonSide -AnalysisFile $compareFile -StreamSelector $compareStream -LapNo $compareLap
        $custom=$null
        if($mode-eq'custom'){
            if($null-eq$Req.custom){ throw 'custom mode requires a custom interval' }
            $custom=@{side_key=[string]$Req.custom.side_key;start_d=[double]$Req.custom.start_d;end_d=[double]$Req.custom.end_d}
        }
        $cmp=NSC-BuildComparison -SubjectA $a -SubjectB $b -LabelA 'A' -LabelB 'B' -Mode $mode -CustomInterval $custom
        return [ordered]@{
            ok=$true
            subject=[ordered]@{file=$subjectFile;stream=$a.stream_id;role=$a.stream_role;lap=$subjectLap;key=$a.key;segment_count=@($a.segments).Count}
            baseline=[ordered]@{file=$compareFile;stream=$b.stream_id;role=$b.stream_role;lap=$compareLap;key=$b.key;segment_count=@($b.segments).Count}
            comparison=$cmp
        }
    } catch {
        return [ordered]@{ok=$false;error=[string]$_.Exception.Message}
    }
}






