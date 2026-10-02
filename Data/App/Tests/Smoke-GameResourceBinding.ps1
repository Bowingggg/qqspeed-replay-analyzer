$ErrorActionPreference='Stop'
$appDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $appDir 'Modules\MapCatalog\GameResourceBinding.ps1')

$games=@(
    [pscustomobject]@{name='十一城';game_map_id=137},
    [pscustomobject]@{name='猫工厂';game_map_id=154},
    [pscustomobject]@{name='Only Offset';game_map_id=199},
    [pscustomobject]@{name='重复';game_map_id=300},
    [pscustomobject]@{name='重复';game_map_id=301},
    [pscustomobject]@{name='AliasOnly';game_map_id=500},
    [pscustomobject]@{name='ManualOnly';game_map_id=501}
)
$resources=@(
    [pscustomobject]@{map_id=37;primary_name='十一城';all_names=@('十一城');display_aliases=@()},
    [pscustomobject]@{map_id=54;primary_name='猫工厂';all_names=@('猫工厂');display_aliases=@()},
    [pscustomobject]@{map_id=99;primary_name='Other';all_names=@('Other');display_aliases=@('AliasOnly')}
)
$manual=@([pscustomobject]@{display_name='ManualOnly';normalized_name='ManualOnly';map_id=37;evidence='synthetic manual label'})
$anchors=@([pscustomobject]@{
    name='十一城';game_map_id=137;resource_map_id=37
    game_evidence='synthetic game';resource_evidence='synthetic resource'
})

$r=GRB-BuildBindingsFromData -GameRecords $games -ResourceCatalog $resources -ManualAliases $manual -VerifiedAnchors $anchors
$a=@($r.bindings|Where-Object {$_.game_map_id -eq 137})[0]
$b=@($r.bindings|Where-Object {$_.game_map_id -eq 154})[0]
$c=@($r.bindings|Where-Object {$_.game_map_id -eq 199})[0]
$d=@($r.bindings|Where-Object {$_.game_map_id -eq 300})[0]
$e=@($r.bindings|Where-Object {$_.game_map_id -eq 500})[0]
$f=@($r.bindings|Where-Object {$_.game_map_id -eq 501})[0]

if($a.resource_map_id -ne 37 -or -not $a.authoritative_for_cross_namespace_binding -or $a.binding_source -ne 'verified_anchor'){throw 'Verified anchor path failed.'}
if($b.resource_map_id -ne 54 -or -not $b.authoritative_for_cross_namespace_binding -or $b.binding_source -ne 'exact_resource_catalog_name'){throw 'Exact-name join failed.'}
if($c.resource_map_id -ne 99 -or $c.authoritative_for_cross_namespace_binding -or $c.status -ne 'offset_supported_candidate'){throw 'Offset candidate policy failed.'}
if($d.status -ne 'ambiguous_game_name' -or $d.authoritative_for_cross_namespace_binding){throw 'Duplicate game-name guard failed.'}
if($e.authoritative_for_cross_namespace_binding -or $null -ne $e.resource_map_id){throw 'Display alias must not promote physical map identity in v3.'}
if($f.authoritative_for_cross_namespace_binding -or $null -ne $f.resource_map_id){throw 'Manual display label must not promote physical map identity in v3.'}

Write-Host '[OK] Game/Resource binding smoke passed. verified anchors + exact official name + non-authoritative +100 + alias/manual rejection + duplicate-name guard.'
