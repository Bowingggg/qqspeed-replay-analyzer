param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
$script:toolTasks=@{}
$script:firstRunBootstrapTaskId=''

function Require([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}

$dataRoot=Split-Path -Parent $AppDir
$devRoot=Join-Path $dataRoot 'Diagnostics\Dev'
$work=Join-Path $devRoot ('Smoke-FirstRunBootstrap-'+[Diagnostics.Process]::GetCurrentProcess().Id)
try {
    if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
    $root=$work
    $dataDir=Join-Path $work 'Data'
    $outputDir=Join-Path $work 'Output'
    $fakeApp=Join-Path $work 'App'
    $game=Join-Path $work 'Game'
    $settingsPath=Join-Path $dataDir 'settings.json'
    $tempUploadRoot=Join-Path $dataDir 'WebUpload'
    $replayArchiveRoot=Join-Path $dataDir 'ReplayArchive'
    $labelsPath=Join-Path $dataDir 'replay_labels.json'
    $manualMapNamesPath=Join-Path $dataDir 'manual_map_names.json'
    $frontendDiagDir=Join-Path $dataDir 'Diagnostics\Frontend'
    $refreshScript=Join-Path $fakeApp 'MissingRefresh.ps1'
    $builderScript=Join-Path $fakeApp 'MissingMap.ps1'
    $analyzerScript=Join-Path $fakeApp 'MissingAnalyzer.ps1'
    $catalogScript=Join-Path $fakeApp 'FakeCatalog.ps1'
    $script:toolTasks=@{}
    $script:firstRunBootstrapTaskId=''
    New-Item -ItemType Directory -Force -Path $dataDir,$outputDir,$fakeApp,$game,$tempUploadRoot,$replayArchiveRoot,$frontendDiagDir | Out-Null

    $fake=@'
param([string]$Mode,[string]$GamePath)
$ErrorActionPreference='Stop'
$dataDir=Join-Path (Split-Path -Parent $PSScriptRoot) 'Data'
$cat=Join-Path $dataDir 'MapCatalog'
New-Item -ItemType Directory -Force -Path $cat | Out-Null
$enc=New-Object System.Text.UTF8Encoding -ArgumentList $true
if($Mode -eq 'Build') {
    [IO.File]::WriteAllText((Join-Path $cat 'map_index.json'),'[{"map_id":37,"primary_name":"Test"}]',$enc)
    [IO.File]::WriteAllText((Join-Path $cat 'catalog_meta.json'),'{"schema_version":6,"map_id_count":1}',$enc)
} elseif($Mode -eq 'BuildGameResourceBindings') {
    [IO.File]::WriteAllText((Join-Path $cat 'game_resource_bindings.json'),'{"schema_version":1,"bindings":[{"game_map_id":137,"resource_map_id":37}]}',$enc)
} else { throw ('unexpected mode: '+$Mode) }
exit 0
'@
    [IO.File]::WriteAllText($catalogScript,$fake,(New-Object System.Text.UTF8Encoding -ArgumentList $true))

    . (Join-Path $AppDir 'Modules\Frontend\Frontend.Backend.ps1')

    $s0=Get-FirstRunBootstrapStateLocal
    Require (-not[bool]$s0.ready) 'clean workspace must require first-run bootstrap'
    [void](Save-GamePathLocal $game)
    $started=Start-FirstRunBootstrapTask
    Require ([bool]$started.started) 'first-run bootstrap did not start after game path was set'
    Require (-not[string]::IsNullOrWhiteSpace([string]$started.task_id)) 'first-run bootstrap did not return a task id'

    $done=$null
    for($i=0;$i-lt200;$i++){
        Start-Sleep -Milliseconds 100
        $done=Get-ToolTaskStatus ([string]$started.task_id)
        if([bool]$done.done){break}
    }
    Require ($null-ne$done -and [bool]$done.done) 'first-run bootstrap did not finish in time'
    Require ([bool]$done.ok) ('first-run bootstrap failed: '+[string]$done.error)
    $s1=Get-FirstRunBootstrapStateLocal
    Require ([bool]$s1.ready) 'catalog + binding are not ready after first-run bootstrap'
    Require ([int]$s1.map_count -eq 1) 'map catalog count mismatch after bootstrap'
    Require ([int]$s1.binding_count -eq 1) 'binding count mismatch after bootstrap'

    $again=Start-FirstRunBootstrapTask
    Require ([bool]$again.ready -and -not[bool]$again.started) 'ready catalog must not rebuild implicitly on ordinary startup'

    $src=Get-Content -LiteralPath (Join-Path $AppDir 'QQReplayFrontend.ps1') -Raw -Encoding UTF8
    Require ($src.Contains('Start-FirstRunBootstrapTask')) 'frontend startup does not trigger first-run bootstrap'
    Require ($src.Contains("'/api/settings/game-path'")) 'frontend game-path endpoint missing'
    $js=Get-Content -LiteralPath (Join-Path $AppDir 'Modules\Frontend\js\app.js') -Raw -Encoding UTF8
    Require ($js.Contains('ensureCatalogTaskMonitor')) 'frontend does not monitor background bootstrap'
    Require ($js.Contains("upload.disabled=!j?.game_path_valid||!ready")) 'upload button is not gated until first-run data is ready'
    $backend=Get-Content -LiteralPath (Join-Path $AppDir 'Modules\Frontend\Frontend.Backend.ps1') -Raw -Encoding UTF8
    Require ($backend.Contains('$script:segmentComparisonRowCacheLimit=6')) 'segment comparison row cache limit missing'
    Require ($backend.Contains('Get-SegmentComparisonRowsCached')) 'segment comparison row cache helper missing'
    Require ($backend.Contains('$rows=@(Get-SegmentComparisonRowsCached $csvPath)')) 'comparison path bypasses row cache'
    Require ($backend.Contains('已停止分析，避免出现“分析成功但列表不可见”')) 'web import must fail closed when ReplayCatalog activation fails'

    Write-Host '[OK] First-run bootstrap smoke passed. game-path-only setup=covered background-build=covered ready-no-rebuild=covered upload-gate=covered comparison-row-cache=covered catalog-activation-fail-closed=covered'
    exit 0
} finally {
    foreach($id in @($script:toolTasks.Keys)){
        try{Stop-Job -Job $script:toolTasks[$id].job -ErrorAction SilentlyContinue}catch{}
        try{Remove-Job -Job $script:toolTasks[$id].job -Force -ErrorAction SilentlyContinue}catch{}
    }
    if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
}
