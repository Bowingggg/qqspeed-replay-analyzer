param()
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
$appDir=Split-Path -Parent $MyInvocation.MyCommand.Path;$dataDir=Split-Path -Parent $appDir;$root=Split-Path -Parent $dataDir
$outputDir=Join-Path $root 'Output';$settingsPath=Join-Path $dataDir 'settings.json';$archiveRoot=Join-Path $dataDir 'ReplayArchive';$webUploadRoot=Join-Path $dataDir 'WebUpload'
$analyzerScript=Join-Path $appDir 'QQReplay.ps1';$catalogScript=Join-Path $appDir 'QQSpeedMapCatalog.ps1'
. (Join-Path $appDir 'Modules\Replay\Replay.DevRebuild.ps1')
. (Join-Path $appDir 'Modules\Replay\Replay.Catalog.ps1')
function Read-J([string]$p){try{Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json}catch{$null}}
function Write-J([string]$p,$v){Write-JsonFileAtomic -Path $p -Value $v -Depth 6}
function Get-GamePathLocal{if(Test-Path -LiteralPath $settingsPath){$j=Read-J $settingsPath;$g=[string]$j.game_path;if(-not[string]::IsNullOrWhiteSpace($g)-and(Test-Path -LiteralPath $g -PathType Container)){return $g}};return $null}
function Invoke-Child([string]$Script,[string[]]$ChildArguments,[string]$Label) {
    Write-Host ''
    Write-Host ('[开始] '+$Label)
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $rc=1
    $parentEap=$ErrorActionPreference
    Push-Location $root
    try {
        # child_error_stream_isolation_v1: redirected child stderr is diagnostic output.
        # child_argument_forwarding_v1: never reuse PowerShell's automatic $Args variable.
        $ErrorActionPreference='Continue'
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @ChildArguments 2>&1 |
            ForEach-Object { Write-Host ([string]$_) }
        $rc=$LASTEXITCODE
    } finally {
        $ErrorActionPreference=$parentEap
        Pop-Location
        $sw.Stop()
    }
    if($rc -eq 0) {
        Write-Host ('[完成] '+$Label+'  '+[Math]::Round($sw.Elapsed.TotalSeconds,1)+' 秒')
    } else {
        Write-Host ('[FAILED] '+$Label+'  ExitCode='+$rc+'  '+[Math]::Round($sw.Elapsed.TotalSeconds,1)+' 秒')
    }
    return [int]$rc
}
function Save-Archive([string]$Source,[string]$Sha,[string]$Name,[string]$From){if([string]::IsNullOrWhiteSpace($Sha)-or$Sha.Length-lt16){return};$dir=Join-Path $archiveRoot $Sha.Substring(0,16).ToUpperInvariant();New-Item -ItemType Directory -Force -Path $dir|Out-Null;$safe=[IO.Path]::GetFileName($Name);if([IO.Path]::GetExtension($safe)-ine'.sav'){$safe='replay.sav'};$dst=Join-Path $dir $safe;if(-not(Test-Path -LiteralPath $dst)){$tmp=$dst+'.tmp';Copy-Item -LiteralPath $Source -Destination $tmp -Force;Move-Item -LiteralPath $tmp -Destination $dst -Force};Write-J (Join-Path $dir 'archive.json') ([ordered]@{schema_version=1;sha256=$Sha;original_name=$safe;recovered_from=$From;archived_at=(Get-Date).ToString('o')})}
# Leftover web uploads are archived as SOURCE bytes only. Archiving never activates a replay:
# only an explicit import does that.
function Archive-WebUploads{if(-not(Test-Path -LiteralPath $webUploadRoot)){return};foreach($f in @(Get-ChildItem -LiteralPath $webUploadRoot -Filter '*.sav' -File -Recurse -ErrorAction SilentlyContinue)){try{$sha=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToUpperInvariant();Save-Archive $f.FullName $sha $f.Name 'web_upload_pre_v3_rebuild'}catch{}}}

if(-not(Test-Path -LiteralPath $analyzerScript)){throw 'QQReplay.ps1 不存在。'}
$game=Get-GamePathLocal;if([string]::IsNullOrWhiteSpace($game)){throw '尚未配置有效游戏目录。'}
New-Item -ItemType Directory -Force -Path $archiveRoot|Out-Null
Write-Host 'QQ飞车录像分析 v3.7.22 · Native-First development rebuild'
Write-Host '重建当前派生输出；只重建当前分析列表中的录像；Replay Catalog 只提供 source/lifecycle 信息，不再充当重建队列。'

# ---------------------------------------------------------------------------
# The replay set comes from the Replay Catalog, never from the Source Store.
# A .sav sitting in Data\ReplayArchive is NOT a request to analyse it.
# ---------------------------------------------------------------------------
$boot=Initialize-ReplayCatalogFromCurrentAnalyses -DataDir $dataDir -ProjectRoot $root -AnalysisDir $outputDir
if([bool]$boot.bootstrapped){
    Write-Host ('[Catalog] 首次建立 Replay Catalog：source='+[string]$boot.sources+' active='+[string]$boot.active+' removed='+[string]$boot.removed+'（lifecycle 取自当前已存在的分析结果；可见性不由此决定，不自动显示任何旧派生录像）')
    if(@($boot.ambiguous_sources).Count-gt0){Write-Host ('[Catalog][WARN] 缺少 archive.json 无法判定身份的 source（一律按 removed 处理，不自动激活）：'+(@($boot.ambiguous_sources)-join ','))}
    if(@($boot.analysis_without_source).Count-gt0){Write-Host ('[Catalog][WARN] 存在分析结果但找不到对应 source：'+(@($boot.analysis_without_source)-join ','))}
    if(@($boot.unreadable_analyses).Count-gt0){Write-Host ('[Catalog][WARN] 无法读取的分析结果（未纳入 active）：'+(@($boot.unreadable_analyses)-join ','))}
} else {
    Write-Host '[Catalog] 复用现有 Replay Catalog。'
}
$recon=Update-ReplayCatalogSourceReconciliation -DataDir $dataDir -ProjectRoot $root
Write-Host ('[Catalog] 元数据对账：entries='+[string]$recon.total_entries+' source_present='+[string]$recon.source_present+' source_missing='+[string]$recon.source_missing+' active='+[string]$recon.active+' removed='+[string]$recon.removed+'（对账只更新 metadata，从不改变 state）')
if(@($recon.discovered_as_removed).Count-gt0){Write-Host ('[Catalog] 归档中新发现、未在 catalog 中的 source 记为 removed（'+[string]@($recon.discovered_as_removed).Count+' 条），不自动分析。')}
# One-time, conservative completion of the explicit visibility axis: an entry written before the
# axis existed is frozen as visible only when it is active AND currently backed by an analysis, i.e.
# exactly what the list shows right now. After this, a tooling run that recreates derived analyses
# can no longer make a replay reappear.
$vis=Sync-ReplayCatalogVisibility -DataDir $dataDir -AnalysisDir $outputDir
Write-Host ('[Catalog] 可见性固化：completed='+[string]$vis.completed+' visible='+[string]$vis.visible+'/'+[string]$vis.total+'（'+[string]$vis.reason+'；此后可见性只由显式导入/删除改变）')

# Rebuild exactly the replay set currently visible in the analysis list.  Catalog
# `active` means user lifecycle state; it is deliberately NOT the rebuild queue.  A
# replay that was imported months ago may still be active while absent from Output, and
# clicking "重建活动录像派生" must not resurrect it into the current list.
$visibleSha=@{}
foreach($f in @(Get-ChildItem -LiteralPath $outputDir -Filter '*_analysis.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)){
    $j=Read-J $f.FullName
    $sha=([string]$j.replay_sha256).Trim().ToUpperInvariant()
    if($sha -match '^[0-9A-F]{64}$'){$visibleSha[$sha]=$true}
    else{Write-Host ('[列表][WARN] 当前分析缺少有效 replay_sha256，重建时跳过：'+$f.Name)}
}
$catalogActive=@(Get-ReplayCatalogActiveEntries -DataDir $dataDir)
$active=@($catalogActive | Where-Object { (RC-AsBool $_.source_present) -and $visibleSha.ContainsKey(([string]$_.sha256).ToUpperInvariant()) })
$activeMissing=@($catalogActive | Where-Object { $visibleSha.ContainsKey(([string]$_.sha256).ToUpperInvariant()) -and -not (RC-AsBool $_.source_present) })
$catalogOnly=@($catalogActive | Where-Object { -not $visibleSha.ContainsKey(([string]$_.sha256).ToUpperInvariant()) })
Write-Host ('[列表] 本次重构目标来自当前 Output 列表：visible='+[string]$visibleSha.Count+' · 可重建='+[string]$active.Count+' · source_missing='+[string]$activeMissing.Count+'；Catalog 中其它 active='+[string]$catalogOnly.Count+' 条不会重建。')
foreach($e in $activeMissing){Write-Host ('[列表][WARN] 列表中录像 source 缺失，跳过且不猜测位置：'+[string]$e.sha256+' · '+[string]$e.original_name)}

Archive-WebUploads
$reset=Reset-QQReplayDevelopmentDerivedData -ProjectRoot $root -DataDir $dataDir
Write-Host '[清理] Output / Telemetry / ReplayResolution / NativeMaps / NativeIdentity / Diagnostics / Logs / WebUpload 已重建；PhysicalTelemetryCache 与 NativeActionCache 保留。'
$rc=Invoke-Child -Script $catalogScript -ChildArguments @('-Mode','Build','-GamePath',$game) -Label '从当前游戏资源建立官方 MapCatalog';if($rc-ne0){exit 1}
$rc=Invoke-Child -Script $catalogScript -ChildArguments @('-Mode','BuildGameResourceBindings','-GamePath',$game) -Label '建立 Game MapID ↔ Resource Map 官方绑定';if($rc-ne0){exit 1}

$ok=0;$bad=0;$skipped=0;$i=0
foreach($e in $active){
    $rel=[string]$e.source_rel_path
    $rp=''
    if(-not[string]::IsNullOrWhiteSpace($rel)){
        $candidate=[IO.Path]::GetFullPath((Join-Path $root ($rel -replace '/','\')))
        $rootFull=[IO.Path]::GetFullPath($root).TrimEnd('\')+'\'
        if($candidate.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)-and(Test-Path -LiteralPath $candidate -PathType Leaf)){$rp=$candidate}
    }
    if([string]::IsNullOrWhiteSpace($rp)){Write-Host ('[Catalog][WARN] active entry source 不可用，跳过：'+[string]$e.sha256);$skipped++;continue}
    $i++
    $rc=Invoke-Child -Script $analyzerScript -ChildArguments @('-Mode','Analyze','-ForceTelemetry','-Items',[string]$rp) -Label ('NativeFirst ['+$i+'/'+$active.Count+'] '+[IO.Path]::GetFileName($rp))
    if($rc-eq0){$ok++}else{$bad++}
}

# Native Driving v1 corpus summary is descriptive calibration evidence only.
# It does not promote thresholds or redefine any native/official fact.
$driveReady=0;$driveOther=0;$driveSections=0;$nativeMapReady=0;$nativeMapMissing=0
foreach($f in @(Get-ChildItem -LiteralPath $outputDir -Filter '*_analysis.json' -File -ErrorAction SilentlyContinue|Sort-Object Name)){
    $j=Read-J $f.FullName;if($null-eq$j){continue};$d=$j.driving_analysis
    if($null-ne$j.native_map -and [string]$j.native_map.status-eq'ready'){$nativeMapReady++}else{$nativeMapMissing++;Write-Host ('[NativeMap] '+[string]$j.replay_file+' · status='+[string]$j.native_map.status+' · map='+$(if($null-ne$j.resource_map_id){'Map'+[string]$j.resource_map_id}else{'unresolved'}))}
    if($null-eq$d){continue}
    $local=@($d.streams|Where-Object{[string]$_.role-eq'local_high_frequency'}|Select-Object -First 1);if($local.Count-eq0){$local=@($d.streams|Select-Object -First 1)}
    $ds=$(if($local.Count-gt0){$local[0]}else{$null})
    if([string]$d.status-eq'ready'){$driveReady++}else{$driveOther++}
    if($null-ne$ds){$driveSections+=[int]$ds.section_count;$lapParts=@();foreach($l in @($ds.laps)){$lapParts+=(([string]$l.lap)+':'+([string]$l.section_count))};$cov=$(if($null-ne$ds.official_surface_sample_coverage){([Math]::Round(100.0*[double]$ds.official_surface_sample_coverage,1)).ToString()+'%'}else{'—'});Write-Host ('[Driving] '+[string]$j.replay_file+' · status='+[string]$d.status+' · sections='+[string]$ds.section_count+' · laps='+($lapParts-join ',')+' · surface='+$cov)}
    else{Write-Host ('[Driving] '+[string]$j.replay_file+' · status='+[string]$d.status+' · no stream result')}
}
Write-Host ''
Write-Host ('[汇总] Native-First v3.7.22 重构完成：active='+[string]$active.Count+' · 成功='+$ok+' / 失败='+$bad+' / 跳过='+$skipped+'；ReplayArchive='+[string]@(Get-ReplaySourceInventory -DataDir $dataDir).Count+'（source 存在不等于 active）；NativeMap ready='+$nativeMapReady+' / missing='+$nativeMapMissing+'；Driving ready='+$driveReady+' / other='+$driveOther+' / sections='+$driveSections+'；语义回退=none；底图=官方 map.nif。')
if($bad-gt0){exit 1};exit 0
