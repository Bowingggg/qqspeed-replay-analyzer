# September-2026 Replay Readiness Gate (real-replay acceptance).
#
# This gate is the product-availability contract for current (2026-09) replays:
#   Level 1  Physical + Basic Driving   -> must be ready for every corpus replay
#   Level 2  Native Action              -> must be ready for every corpus replay
#   Level 3  Native Drift / episodes    -> must be ready for every corpus replay
#   Level 4  Official Map               -> ready, or an explicitly recorded pending user
#                                          confirmation (never a silent unresolved)
# plus the hard regression rule: an unavailable quantity is never published as 0.
#
# Evidence comes from the acceptance run written by
#   Tools/September2026/Invoke-SeptemberAcceptance.ps1 -Mode Cold
# which drives the real production entry point (QQReplay.ps1 -Mode Analyze) per corpus replay.
#
# On a machine without the corpus this gate degrades explicitly instead of failing.
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
$appDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dataDir=Split-Path -Parent $appDir
$projectRoot=Split-Path -Parent $dataDir

. (Join-Path $appDir 'Tests\September2026Corpus.ps1')

function Require([bool]$Condition,[string]$Message){ if(-not $Condition){ throw $Message } }
function Read-JsonFile([string]$Path){ if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){ return $null }; try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json } catch { return $null } }

$corpus=@(Get-September2026Corpus -ProjectRoot $projectRoot)
if($corpus.Count -eq 0){
    Write-Host '[SKIP] September-2026 readiness gate: no corpus replay found on this machine (replay\ is empty and no 2026-09 replay is archived).'
    exit 0
}

$reportPath=Join-Path $dataDir 'Diagnostics\Dev\september2026\acceptance_cold.json'
$report=Read-JsonFile $reportPath
Require ($null -ne $report) ('September acceptance evidence is missing: '+$reportPath+'. Run: powershell -NoProfile -ExecutionPolicy Bypass -File Data\App\Tools\September2026\Invoke-SeptemberAcceptance.ps1 -Mode Cold')

$entries=@{}
foreach($e in @($report.entries)){ if($null-ne$e){ $entries[[string]$e.sha16]=$e } }
$covered=0
foreach($c in $corpus){
    Require ($entries.ContainsKey([string]$c.sha16)) ('September acceptance evidence does not cover corpus replay '+[string]$c.test_id+' ('+[string]$c.sha16+'); re-run the acceptance tool.')
    $covered++
}
Require ($covered -eq $corpus.Count) 'September acceptance evidence does not cover the current corpus.'
Require (@($report.entries).Count -eq $corpus.Count) ('September acceptance evidence has '+@($report.entries).Count+' entries for a corpus of '+$corpus.Count+'; it is stale - re-run the acceptance tool.')

$pendingDoc=Read-JsonFile (Join-Path $appDir 'Modules\MapCatalog\Data\map_confirmation_required.json')
$pendingIds=@{}
if($null -ne $pendingDoc){ foreach($e in @($pendingDoc.entries)){ if($null-ne$e){ $pendingIds[[string][int]$e.game_map_id]=$e } } }

$problems=New-Object System.Collections.Generic.List[string]
$mapReady=0;$mapPending=0;$driftReady=0;$actionReady=0;$basicReady=0;$physicalReady=0;$zeroViolations=0
$mandatory=@($corpus|Where-Object{[string]$_.corpus -eq 'mandatory_user'})
$mandatoryBasic=0;$mandatoryDrift=0;$mandatoryAction=0;$mandatoryMap=0

foreach($c in $corpus){
    $e=$entries[[string]$c.sha16]
    $tid=[string]$c.test_id
    $isMandatory=([string]$c.corpus -eq 'mandatory_user')
    $tag=$tid+' ('+[string]$c.sha16+')'

    if($null -ne $e.analyze_exit -and [int]$e.analyze_exit -ne 0){ $problems.Add($tag+': analyze exit code '+[string]$e.analyze_exit) }
    if($null -eq $e.elapsed_s){ $problems.Add($tag+': no wall-clock measurement (the acceptance run did not actually analyse this replay)') }

    $phys=([string]$e.physical.telemetry_status -eq 'ready')
    $basic=([string]$e.basic_driving.status -eq 'ready')
    $drift=[bool]$e.native_drift.available
    $action=[bool]$e.native_action_event.game_facing_available
    $map=[bool]$e.map.official_map_ready
    $gid=$e.map.game_map_id
    $pending=($null -ne $gid) -and $pendingIds.ContainsKey([string][int]$gid)

    if($phys){$physicalReady++}
    if($basic){$basicReady++} else { $problems.Add($tag+': Basic Driving is not ready (status='+[string]$e.basic_driving.status+')') }
    if($drift){$driftReady++} else { $problems.Add($tag+': native Drift is unavailable (status='+[string]$e.native_drift.status+')') }
    if($action){$actionReady++} else { $problems.Add($tag+': native action game-facing counts are unavailable (status='+[string]$e.native_action_event.production_status+')') }
    if($map){$mapReady++}
    elseif($pending){$mapPending++}
    else { $problems.Add($tag+': official map is not ready and this replay is NOT recorded as pending user confirmation (GameMapID '+[string]$gid+')') }

    foreach($q in @($e.capability_audit)){
        if($null-ne$q -and [bool]$q.unavailable_published_as_zero){
            $zeroViolations++
            $problems.Add($tag+': '+[string]$q.quantity+' is unavailable but published as 0')
        }
    }
    if(-not $phys){ $problems.Add($tag+': production telemetry is not ready (status='+[string]$e.physical.telemetry_status+')') }

    if($isMandatory){
        if($basic){$mandatoryBasic++}
        if($drift){$mandatoryDrift++}
        if($action){$mandatoryAction++}
        if($map){$mandatoryMap++} elseif($pending){$mandatoryMap++}
    }
}

$summary=[ordered]@{
    schema_version=1;contract='september2026_readiness_gate_v1';generated_at=(Get-Date).ToString('o')
    corpus_count=$corpus.Count;mandatory_count=$mandatory.Count
    physical_ready=$physicalReady;basic_driving_ready=$basicReady;native_drift_ready=$driftReady
    native_action_ready=$actionReady;official_map_ready=$mapReady;official_map_pending_user_confirmation=$mapPending
    unavailable_published_as_zero=$zeroViolations
    mandatory_basic_driving_ready=$mandatoryBasic
    mandatory_native_drift_ready=$mandatoryDrift
    mandatory_native_action_ready=$mandatoryAction
    mandatory_official_map_ready_or_pending=$mandatoryMap
    problems=@($problems.ToArray())
}
$outDir=Join-Path $dataDir 'Diagnostics\Dev'
New-Item -ItemType Directory -Force -Path $outDir|Out-Null
$enc=New-Object System.Text.UTF8Encoding -ArgumentList $true
[IO.File]::WriteAllText((Join-Path $outDir 'september_readiness.json'),($summary|ConvertTo-Json -Depth 8),$enc)

if($problems.Count -gt 0){
    Write-Host ('[FAILED] September-2026 readiness gate: '+$problems.Count+' problem(s)')
    foreach($p in @($problems.ToArray()|Select-Object -First 40)){ Write-Host ('  - '+$p) }
    if($problems.Count -gt 40){ Write-Host ('  ... +'+($problems.Count-40)+' more') }
    Write-Host ('     evidence: '+(Join-Path $outDir 'september_readiness.json'))
    exit 3
}

Write-Host ('[OK] September-2026 readiness gate passed. corpus='+$corpus.Count+' physical='+$physicalReady+' basic='+$basicReady+' drift='+$driftReady+' action='+$actionReady+' map='+$mapReady+' map_pending_user_confirmation='+$mapPending+' unavailable_as_zero=0')
Write-Host ('     mandatory: basic='+$mandatoryBasic+'/'+$mandatory.Count+' drift='+$mandatoryDrift+'/'+$mandatory.Count+' action='+$mandatoryAction+'/'+$mandatory.Count+' map='+$mandatoryMap+'/'+$mandatory.Count)
Write-Host ('     evidence: '+(Join-Path $outDir 'september_readiness.json'))
exit 0
