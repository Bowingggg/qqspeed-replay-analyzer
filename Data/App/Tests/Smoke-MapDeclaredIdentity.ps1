param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){ if(-not $Ok){ throw $Message } }

# ---------------------------------------------------------------------------
# Resource-declared map identity -- contract regression.
#
# `Map\Common Map\MapNN\LapDistanceFile.luc` is a per-map official record that declares
#   * `mapId`   -- the GAME-side MapID (the same namespace `uires\mapsel\maps.luc` stores as `mapid`)
#   * `mapName` -- the maintained display name
#
# Two defects are pinned here:
#   1. the binding was derived only from a display-name join, so a folder whose scene-descriptor
#      `map_name` is stale/duplicated could not be identified (GameMapID 439 `一梦青花` was
#      unresolved, 438 `绝色江西` was ambiguous, and the +100 offset landed on a wrong-named row);
#   2. the catalog's identity NAME came from `map_desc.map_name`, which the client does not keep in
#      step, so two different courses claimed the same name.
#
# The declared mapId is a structural statement and needs neither a name join nor the +100 offset.
# A game MapID declared by two folders is a genuine conflict and must fail closed.
#
# Synthetic first (no game install, no archive); the structural checks against the rebuilt live
# catalog run only when this machine has one.
# ---------------------------------------------------------------------------
. (Join-Path $AppDir 'Modules\MapCatalog\Catalog.Naming.ps1')
. (Join-Path $AppDir 'Modules\MapCatalog\Catalog.Build.ps1')
. (Join-Path $AppDir 'Modules\MapCatalog\GameResourceBinding.ps1')

function New-Game([string]$Name,[int]$GameMapId){ return [pscustomobject]@{name=$Name;game_map_id=$GameMapId} }
function New-Resource([int]$MapId,[string]$Primary,[string[]]$Names,[object]$DeclaredGameMapId,$Declared=[string[]]@()){
    return [pscustomobject]@{
        map_id=$MapId; primary_name=$Primary; all_names=@($Names); display_aliases=@()
        declared_game_map_id=$DeclaredGameMapId; declared_names=@($Declared)
    }
}

$synthetic=0

# --- D1: a resource-declared game MapID is authoritative, with its own source ------------------
$games=@((New-Game '一梦青花' 439),(New-Game '绝色江西' 438))
$resources=@(
    (New-Resource 338 '绝色江西' @('绝色江西') 438 @('绝色江西')),
    (New-Resource 339 '一梦青花' @('青花瓷','一梦青花') 439 @('青花瓷','一梦青花'))
)
$r1=GRB-BuildBindingsFromData -GameRecords $games -ResourceCatalog $resources -ManualAliases @() -VerifiedAnchors @()
$a1=@($r1.bindings|Where-Object {[int]$_.game_map_id -eq 439})[0]
$b1=@($r1.bindings|Where-Object {[int]$_.game_map_id -eq 438})[0]
Require ([int]$a1.resource_map_id -eq 339) 'D1: a declared game MapID must bind GameMapID 439 to Map339'
Require ([bool]$a1.authoritative_for_cross_namespace_binding) 'D1: a declared binding must be authoritative'
Require ([string]$a1.binding_source -eq 'resource_declared_map_id') 'D1: the declared binding source marker changed'
Require ([string]$a1.status -eq 'verified_cross_namespace') 'D1: the declared binding status must be verified_cross_namespace'
Require ([int]$b1.resource_map_id -eq 338) 'D1: the declared channel must also resolve the sibling row'
Require ([int]$r1.summary.declared_binding_count -eq 2) 'D1: declared bindings must be counted separately'
$synthetic++

# --- D2: a stale descriptor name on an unrelated folder must not steal the identity ------------
# Real shape: Map65's scene descriptor still says `51区` while its own record declares GameMapID
# 165 `穿梭之城`; the course that declares 270 `51区` is Map170. A pure name join binds 270 -> 65.
$resources2=@(
    (New-Resource 65 '51区' @('51区') 165 @('穿梭之城')),
    (New-Resource 170 '51区' @('51区') 270 @('51区'))
)
$r2=GRB-BuildBindingsFromData -GameRecords @((New-Game '51区' 270)) -ResourceCatalog $resources2 -ManualAliases @() -VerifiedAnchors @()
$a2=@($r2.bindings)[0]
Require ([int]$a2.resource_map_id -eq 170) 'D2: the declared identity must beat a stale descriptor name'
Require ([string]$a2.binding_source -eq 'resource_declared_map_id') 'D2: the winning source must be the resource declaration'
Require ([string]$a2.status -ne 'ambiguous_resource_name') 'D2: a duplicated descriptor name must not make the row ambiguous when the resource declares its own MapID'
$synthetic++

# --- D3: two folders declaring the same game MapID fail closed ---------------------------------
$resources3=@(
    (New-Resource 314 '顺子大作战' @('顺子大作战') 414 @('顺子大作战')),
    (New-Resource 340 '顺子大作战' @('顺子大作战') 414 @('顺子大作战'))
)
$r3=GRB-BuildBindingsFromData -GameRecords @((New-Game '顺子大作战' 414)) -ResourceCatalog $resources3 -ManualAliases @() -VerifiedAnchors @()
$a3=@($r3.bindings)[0]
Require ([string]$a3.status -eq 'ambiguous_declared_map_id') 'D3: a game MapID declared by two folders must be ambiguous_declared_map_id'
Require (-not[bool]$a3.authoritative_for_cross_namespace_binding) 'D3: a declared conflict must never be authoritative'
Require ($null -eq $a3.resource_map_id) 'D3: a declared conflict must not publish a resource id'
Require ([int]$r3.summary.ambiguous_declared_map_id_count -eq 1) 'D3: the declared conflict must be counted'
$synthetic++

# --- D4: entries without a declared identity keep the exact-name route (backward compatible) ---
$resources4=@([pscustomobject]@{map_id=99;primary_name='Exact Only';all_names=@('Exact Only');display_aliases=@()})
$r4=GRB-BuildBindingsFromData -GameRecords @((New-Game 'Exact Only' 199)) -ResourceCatalog $resources4 -ManualAliases @() -VerifiedAnchors @()
$a4=@($r4.bindings)[0]
Require ([int]$a4.resource_map_id -eq 99) 'D4: the exact-name route must still work when nothing is declared'
Require ([string]$a4.binding_source -eq 'exact_resource_catalog_name') 'D4: the exact-name source marker changed'
$synthetic++

# --- D5: an unproven row still stays a non-authoritative offset candidate ----------------------
$resources5=@([pscustomobject]@{map_id=12;primary_name='老街';all_names=@('老街');display_aliases=@()})
$r5=GRB-BuildBindingsFromData -GameRecords @((New-Game '老街管道' 112)) -ResourceCatalog $resources5 -ManualAliases @() -VerifiedAnchors @()
$a5=@($r5.bindings)[0]
Require ([string]$a5.status -eq 'offset_supported_candidate') 'D5: the +100 relation must stay a non-authoritative candidate'
Require (-not[bool]$a5.authoritative_for_cross_namespace_binding) 'D5: the +100 relation must never be authoritative'
$synthetic++

# --- D6: declared-name validity and version preference -----------------------------------------
Require (-not (Test-MapDeclaredNameUsable '')) 'D6: an empty declared name is not usable'
Require (-not (Test-MapDeclaredNameUsable '???')) 'D6: a placeholder declared name must not be usable'
Require (-not (Test-MapDeclaredNameUsable ' ? ')) 'D6: a whitespace-padded placeholder is not usable'
Require (Test-MapDeclaredNameUsable '一梦青花') 'D6: a real declared name must be usable'
Require (Test-MapDeclaredNameUsable 'Test01') 'D6: a latin declared name must be usable'
$pref=Get-PreferredDeclaredMapName @(
    [pscustomobject]@{MapName='青花瓷';Vfs='data13.vfs'},
    [pscustomobject]@{MapName='一梦青花';Vfs='data21.vfs'},
    [pscustomobject]@{MapName='一梦青花';Vfs='data14.vfs'}
)
Require ($pref -eq '一梦青花') ('D6: the newest archive must win, got '+[string]$pref)
$prefBase=Get-PreferredDeclaredMapName @(
    [pscustomobject]@{MapName='Base';Vfs='data.vfs'},
    [pscustomobject]@{MapName='Patch';Vfs='data9.vfs'}
)
Require ($prefBase -eq 'Patch') 'D6: a numbered patch archive must outrank the bare base archive'
$prefNumeric=Get-PreferredDeclaredMapName @(
    [pscustomobject]@{MapName='Nine';Vfs='data9.vfs'},
    [pscustomobject]@{MapName='Ten';Vfs='data10.vfs'}
)
Require ($prefNumeric -eq 'Ten') 'D6: archive ranks must compare numerically, not lexicographically'
$prefPlaceholder=Get-PreferredDeclaredMapName @(
    [pscustomobject]@{MapName='???';Vfs='data29.vfs'},
    [pscustomobject]@{MapName='Real';Vfs='data21.vfs'}
)
Require ($prefPlaceholder -eq 'Real') 'D6: a placeholder declaration must never be preferred'
$synthetic++

# --- D7: the build index buckets declared records and keeps their map id ----------------------
$node=[pscustomobject]@{Vfs='data21.vfs';FullPath='Map\Common Map\Map339\LapDistanceFile.luc';Name='LapDistanceFile.luc'}
$lap=[pscustomobject]@{MapId=339;Vfs='data21.vfs';MapName='一梦青花';DeclaredGameMapId=439}
$idx=New-MapCatalogBuildIndex -Nodes @($node) -Iips @() -Descriptors @() -LapDistances @($lap)
Require ($idx.lap_distance_by_map.ContainsKey(339)) 'D7: the per-map bucket must carry the declared record'
Require (@($idx.ids) -contains 339) 'D7: a map id known only from a LapDistanceFile record must enter the catalog'
$synthetic++

# --- D8: live rebuilt catalog -- structural consistency (skipped when absent) ------------------
$dataDir=Split-Path -Parent $AppDir
$catalogPath=Join-Path $dataDir 'MapCatalog\map_index.json'
$bindingsPath=Join-Path $dataDir 'MapCatalog\game_resource_bindings.json'
$liveChecked=$false
if((Test-Path -LiteralPath $catalogPath -PathType Leaf) -and (Test-Path -LiteralPath $bindingsPath -PathType Leaf)){
    $cat=@(ConvertTo-FlatObjectArray (Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8|ConvertFrom-Json))
    $bind=Get-Content -LiteralPath $bindingsPath -Raw -Encoding UTF8|ConvertFrom-Json
    $declaredFolders=@{}
    foreach($e in $cat){
        if(-not $e.PSObject.Properties['declared_game_map_id']){continue}
        $dg=$e.declared_game_map_id
        if($null -eq $dg){continue}
        $key=[string][int]$dg
        if(-not $declaredFolders.ContainsKey($key)){$declaredFolders[$key]=New-Object System.Collections.Generic.List[int]}
        [void]$declaredFolders[$key].Add([int]$e.map_id)
    }
    Require ($declaredFolders.Count -gt 0) 'D8: the rebuilt catalog must carry resource-declared game MapIDs'

    # every catalog entry with a usable declared name must publish exactly those identity names
    foreach($e in $cat){
        if(-not $e.PSObject.Properties['declared_names']){continue}
        $usable=@(@($e.declared_names)|Where-Object {Test-MapDeclaredNameUsable $_})
        if($usable.Count -eq 0){continue}
        $all=@($e.all_names|ForEach-Object {[string]$_})
        foreach($n in $usable){ Require ($all -contains [string]$n) ('D8: declared name '+[string]$n+' missing from the identity names of Map'+[string]$e.map_id) }
        foreach($d in @($e.descriptor_names|ForEach-Object {[string]$_})){
            if($usable -contains $d){continue}
            Require (-not ($all -contains $d)) ('D8: stale descriptor name '+$d+' must not be an identity name of Map'+[string]$e.map_id)
        }
    }

    # a uniquely declared game MapID must be the authoritative binding the resolver reads.
    # A game MapID with no room-catalog record has no binding row at all and is skipped: the binding
    # file is keyed by the game-side room catalog, not by the resource inventory.
    $bindByGame=@{}
    foreach($row in @($bind.bindings)){
        $g=GRB-TryInt $row.game_map_id
        if($null -ne $g){ $bindByGame[[string][int]$g]=$row }
    }
    $bound=0
    $conflicts=0
    foreach($k in $declaredFolders.Keys){
        if(-not $bindByGame.ContainsKey([string]$k)){ continue }
        $row=$bindByGame[[string]$k]
        $folders=@($declaredFolders[$k]|Sort-Object -Unique)
        if($folders.Count -eq 1){
            Require ([bool]$row.authoritative_for_cross_namespace_binding) ('D8: declared game MapID '+$k+' must be authoritative')
            Require ([int]$row.resource_map_id -eq $folders[0]) ('D8: declared game MapID '+$k+' must be bound to Map'+[string]$folders[0])
            # an explicit verified anchor may outrank the declaration, but both are official routes
            Require ([string]$row.binding_source -in @('resource_declared_map_id','verified_anchor')) ('D8: declared game MapID '+$k+' must record an official binding source, got '+[string]$row.binding_source)
            $bound++
        } else {
            Require (-not[bool]$row.authoritative_for_cross_namespace_binding) ('D8: conflicted declared game MapID '+$k+' must not be authoritative')
            Require ([string]$row.status -eq 'ambiguous_declared_map_id') ('D8: conflicted declared game MapID '+$k+' must be ambiguous_declared_map_id')
            $conflicts++
        }
    }
    Require ($bound -gt 200) ('D8: expected a large declared-binding set, got '+[string]$bound)
    Require ($conflicts -ge 1) 'D8: the live catalog is expected to contain at least one declared game-MapID conflict'
    $liveChecked=$true
}

Write-Host ('[OK] Resource-declared map identity regression passed. synthetic='+[string]$synthetic+' live-catalog='+$(if($liveChecked){'checked'}else{'skipped(no rebuilt catalog)'})+'; declared-mapId authority + stale-name rejection + declared-conflict fail-closed + exact-name fallback + offset-stays-candidate + declared-name version preference.')
exit 0
