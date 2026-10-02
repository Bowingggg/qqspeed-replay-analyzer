# Real-replay gate: Map Coverage for the September-2026 acceptance corpus.
#
# For every corpus replay this gate reconstructs the production map-identity decision in-process
# (trusted room-catalog name -> GameMapID -> verified binding -> user-confirmed binding -> exact
# official map_desc name) and then requires an actual official map render artifact for the resolved
# Resource MapID.
#
# It fails closed on the failure mode this milestone exists to remove: an unresolved map that is not
# recorded as an open question. Every unresolved corpus row must appear in
# Modules/MapCatalog/Data/map_confirmation_required.json, so "unresolved" is always accompanied by a
# named reason and a user action instead of being silent.
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
$appDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dataDir=Split-Path -Parent $appDir
$projectRoot=Split-Path -Parent $dataDir

. (Join-Path $appDir 'Tests\September2026Corpus.ps1')
. (Join-Path $appDir 'Modules\MapCatalog\Catalog.Naming.ps1')
. (Join-Path $appDir 'Modules\MapCatalog\GameResourceBinding.ps1')
. (Join-Path $appDir 'Modules\Replay\Replay.MapIdentityResolver.ps1')
. (Join-Path $appDir 'Modules\MapCatalog\Catalog.ReplayResolver.ps1')
. (Join-Path $appDir 'Modules\MapCatalog\Catalog.Resolve.ps1')

function Require([bool]$Condition,[string]$Message){ if(-not $Condition){ throw $Message } }
function Read-JsonFile([string]$Path){ if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){ return $null }; try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json } catch { return $null } }

$catalogPath=Join-Path $dataDir 'MapCatalog\map_index.json'
Require (Test-Path -LiteralPath $catalogPath -PathType Leaf) 'Resource MapCatalog is missing; run QQSpeedMapCatalog.ps1 -Mode Build first.'
$catalog=@(ConvertTo-FlatObjectArray ((Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8|ConvertFrom-Json)))

$corpus=@(Get-September2026Corpus -ProjectRoot $projectRoot)
Require ($corpus.Count -gt 0) 'September corpus is empty.'

$pendingDoc=Read-JsonFile (Join-Path $appDir 'Modules\MapCatalog\Data\map_confirmation_required.json')
Require ($null -ne $pendingDoc) 'map_confirmation_required.json is missing.'
$pendingIds=@{}
foreach($e in @($pendingDoc.entries)){ if($null-ne$e){ $pendingIds[[string][int]$e.game_map_id]=$e } }

$rows=New-Object System.Collections.Generic.List[object]
$mandatoryPending=0
foreach($c in $corpus){
    $roomHint=Get-TrustedRoomCatalogHintFromReplayName $c.source_path
    $verified=$null;$confirmed=$null
    if($null -ne $roomHint){
        $verified=MI-GetVerifiedResourceFromGameMapId -DataDir $dataDir -GameMapId $roomHint.game_map_id
        if($null -eq $verified){ $confirmed=Get-GRBUserConfirmedBindingForGameMapId -DataDir $dataDir -GameMapId $roomHint.game_map_id }
    }
    $decision=Get-ReplayMapResolutionDecision -ReplayPath $c.source_path -Catalog $catalog -RoomHint $roomHint -VerifiedBinding $verified -UserConfirmedBinding $confirmed
    $rid=if($null -ne $decision.resolved_map_id){[int]$decision.resolved_map_id}else{$null}
    $render=($null -ne $rid) -and (Test-Path -LiteralPath (Join-Path $dataDir ('NativeMaps\Map'+[string]$rid+'\metadata.json')) -PathType Leaf)
    $svg=($null -ne $rid) -and (Test-Path -LiteralPath (Join-Path $dataDir ('NativeMaps\Map'+[string]$rid+'\official_map.svg')) -PathType Leaf)
    $gid=$(if($null -ne $roomHint){[int]$roomHint.game_map_id}else{$null})
    $pending=($null -ne $gid) -and $pendingIds.ContainsKey([string]$gid)
    if($null -eq $rid -and $pending -and $c.corpus -eq 'mandatory_user'){ $mandatoryPending++ }
    $rows.Add([pscustomobject][ordered]@{
        test_id=[string]$c.test_id
        sha16=[string]$c.sha16
        corpus=[string]$c.corpus
        game_map_id=$gid
        resource_map_id=$rid
        tiers_method=[string]$decision.method
        confidence=[string]$decision.confidence
        official_map_ready=$render
        official_map_svg_present=$svg
        pending_user_confirmation=$pending
    })
}

# ---- Map Identity Closure pins (resource-declared identity) ------------------------------------
# The binding authority under test is the resource's own per-map record
# (`Map\Common Map\MapNN\LapDistanceFile.luc` fields `mapId` / `mapName`), which is an official
# structural statement: it needs neither a display-name join nor the observed +100 offset.
$bindings=Read-JsonFile (Join-Path $dataDir 'MapCatalog\game_resource_bindings.json')
Require ($null -ne $bindings) 'game_resource_bindings.json is missing.'

# A. the row this milestone exists for: GameMapID 439 一梦青花
$row339=@($catalog|Where-Object {[int]$_.map_id -eq 339})
Require ($row339.Count -eq 1) 'Map339 is missing from the rebuilt catalog.'
Require ([int]$row339[0].declared_game_map_id -eq 439) 'Map339 must declare game MapID 439 (LapDistanceFile.luc mapId)'
Require (@($row339[0].all_names) -contains '一梦青花') 'Map339 identity names must include the maintained name 一梦青花'
Require (-not(@($row339[0].all_names) -contains '绝色江西')) 'the stale scene-descriptor name 绝色江西 must not be a Map339 identity name'
$b439=@($bindings.bindings|Where-Object {[int]$_.game_map_id -eq 439})
Require ($b439.Count -eq 1) 'GameMapID 439 must have exactly one binding row'
Require ([bool]$b439[0].authoritative_for_cross_namespace_binding) 'GameMapID 439 must hold an authoritative binding'
Require ([int]$b439[0].resource_map_id -eq 339) 'GameMapID 439 must bind to Resource Map339'
Require ([string]$b439[0].binding_source -eq 'resource_declared_map_id') 'GameMapID 439 must be bound by the resource declaration'

# B. the sibling row must keep the row it always had
$b438=@($bindings.bindings|Where-Object {[int]$_.game_map_id -eq 438})
Require ($b438.Count -eq 1) 'GameMapID 438 must have exactly one binding row'
Require ([bool]$b438[0].authoritative_for_cross_namespace_binding -and [int]$b438[0].resource_map_id -eq 338) 'GameMapID 438 绝色江西 must stay bound to Resource Map338'

# C. previously verified rows must not regress, and the two rows whose old binding came from a
#    stale descriptor name must land on the declared course instead.
$knownPairs=@{
    137=37; 129=29; 145=45; 448=348; 169=69; 427=327; 134=34; 381=281; 254=154; 160=60;
    435=335; 162=62; 187=87; 196=96; 256=156; 141=41; 112=12; 158=58; 325=225;
    270=170; 316=216; 438=338; 439=339
}
foreach($g in @($knownPairs.Keys)){
    $pairRows=@($bindings.bindings|Where-Object {[int]$_.game_map_id -eq [int]$g})
    Require ($pairRows.Count -eq 1) ('GameMapID '+[string]$g+' must have exactly one binding row')
    Require ([bool]$pairRows[0].authoritative_for_cross_namespace_binding) ('GameMapID '+[string]$g+' lost its authoritative binding')
    Require ([int]$pairRows[0].resource_map_id -eq [int]($knownPairs[$g])) ('GameMapID '+[string]$g+' must bind Map'+[string]($knownPairs[$g])+', got '+[string]$pairRows[0].resource_map_id)
}

# D. a game MapID declared by two resource folders is a genuine conflict and must fail closed
$declaredConflicts=@($bindings.bindings|Where-Object {[string]$_.status -eq 'ambiguous_declared_map_id'})
Require ($declaredConflicts.Count -ge 1) 'the declared-conflict guard is expected to fire on the live catalog'
foreach($r in $declaredConflicts){
    Require (-not[bool]$r.authoritative_for_cross_namespace_binding) 'a declared conflict must never be authoritative'
    Require ($null -eq $r.resource_map_id) 'a declared conflict must not publish a resource id'
}

# E. an unproven row must never be promoted, and no unknown source may be authoritative
$offsetRows=@($bindings.bindings|Where-Object {[string]$_.status -eq 'offset_supported_candidate'})
Require ($offsetRows.Count -ge 1) 'the offset-candidate class must still exist'
foreach($r in $offsetRows){
    Require (-not[bool]$r.authoritative_for_cross_namespace_binding) 'an offset-only candidate must never be authoritative'
}
$authRows=@($bindings.bindings|Where-Object {[bool]$_.authoritative_for_cross_namespace_binding})
Require (@($authRows|Where-Object {[string]$_.binding_source -notin @('resource_declared_map_id','verified_anchor','exact_resource_catalog_name')}).Count -eq 0) 'an unknown binding source must not be authoritative'

# F. the user-confirmed escape hatch keeps its priority contract; pinned in the Fast gate by
#    Smoke-UserConfirmedBinding.ps1 (a verified/declared binding always outranks it, and the build
#    path never creates one). Only the state of the real store is reported here.
$userStore=Read-JsonFile (Join-Path $dataDir 'MapCatalog\user_confirmed_game_resource_bindings.json')
$userConfirmed=@()
if($null -ne $userStore){ $userConfirmed=@($userStore.bindings) }

# G. same-map comparability: the corpus must carry the 一梦青花 pair on ONE authoritative
#    ResourceMapID. Same-map A/B authorises a comparison on the authoritative ResourceMapID alone,
#    so two corpus rows sharing it are comparable by construction (and the real A/B path itself is
#    exercised by Smoke-TrainingAnalysisReal.ps1).
$map339Corpus=@($rows.ToArray()|Where-Object {$null -ne $_.resource_map_id -and [int]$_.resource_map_id -eq 339})
Require ($map339Corpus.Count -ge 2) 'the corpus must contain at least two replays on Resource Map339 (一梦青花) for the same-map acceptance'
foreach($r in $map339Corpus){
    Require ([string]$r.confidence -eq 'verified') ('Resource Map339 corpus row '+[string]$r.test_id+' must be confidence=verified')
    Require ([int]$r.game_map_id -eq 439) ('Resource Map339 corpus row '+[string]$r.test_id+' must record GameMapID 439')
}

# ---- corpus assertions ------------------------------------------------------------------------
foreach($r in $rows.ToArray()){
    if($null -ne $r.resource_map_id){
        Require ([bool]$r.official_map_ready) ('Map'+[string]$r.resource_map_id+' resolved for '+[string]$r.test_id+' but no official map render exists; run QQNativeMap.ps1 -MapId '+[string]$r.resource_map_id)
        Require ([bool]$r.official_map_svg_present) ('official_map.svg missing for Map'+[string]$r.resource_map_id)
        Require ([string]$r.confidence -in @('verified','user_confirmed','high')) ('unexpected resolution confidence for '+[string]$r.test_id+': '+[string]$r.confidence)
    } else {
        if($r.corpus -eq 'mandatory_user'){
            Require ([bool]$r.pending_user_confirmation) ('mandatory corpus replay '+[string]$r.test_id+' is silently unresolved (GameMapID '+[string]$r.game_map_id+'); record it in Modules/MapCatalog/Data/map_confirmation_required.json or confirm a binding')
        } elseif(-not [bool]$r.pending_user_confirmation){
            Require $false ('extension corpus replay '+[string]$r.test_id+' is silently unresolved (GameMapID '+[string]$r.game_map_id+')')
        }
    }
}

$ready=@($rows.ToArray()|Where-Object{[bool]$_.official_map_ready}).Count
$resolved=@($rows.ToArray()|Where-Object{$null -ne $_.resource_map_id}).Count
$mandatory=@($rows.ToArray()|Where-Object{[string]$_.corpus -eq 'mandatory_user'})
$mandatoryReady=@($mandatory|Where-Object{[bool]$_.official_map_ready}).Count

$report=[ordered]@{
    schema_version=2;contract='map_coverage_gate_v1';generated_at=(Get-Date).ToString('o')
    corpus_count=$rows.Count;resolved_count=$resolved;official_map_ready_count=$ready
    mandatory_corpus_count=$mandatory.Count;mandatory_official_map_ready_count=$mandatoryReady;mandatory_pending_user_confirmation_count=$mandatoryPending
    declared_binding_count=$bindings.summary.declared_binding_count
    declared_conflict_binding_count=$bindings.summary.ambiguous_declared_map_id_count
    offset_candidate_count=$bindings.summary.offset_supported_candidate_count
    user_confirmed_binding_count=$userConfirmed.Count
    map_identity_pins=[ordered]@{
        game_439_resource=339;game_438_resource=338;game_112_resource=12;game_158_resource=58;game_325_resource=225
        changed_from_previous_verified=[ordered]@{'270'=170;'316'=216}
    }
    entries=$rows.ToArray()
}
$outDir=Join-Path $dataDir 'Diagnostics\Dev'
New-Item -ItemType Directory -Force -Path $outDir|Out-Null
$enc=New-Object System.Text.UTF8Encoding -ArgumentList $true
[IO.File]::WriteAllText((Join-Path $outDir 'map_coverage.json'),($report|ConvertTo-Json -Depth 8),$enc)

Write-Host ('[OK] Map coverage gate passed. corpus='+$rows.Count+' resolved='+$resolved+' official_map_ready='+$ready+' mandatory='+$mandatoryReady+'/'+$mandatory.Count+' mandatory_pending_user_confirmation='+$mandatoryPending+' declared_bindings='+$bindings.summary.declared_binding_count+' declared_conflicts='+$bindings.summary.ambiguous_declared_map_id_count)
Write-Host ('     evidence: '+(Join-Path $outDir 'map_coverage.json'))
exit 0
