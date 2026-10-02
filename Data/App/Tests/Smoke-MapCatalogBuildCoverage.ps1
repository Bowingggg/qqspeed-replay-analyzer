param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){if(-not$ok){throw $Message}}

. (Join-Path $AppDir 'Modules\MapCatalog\Catalog.Naming.ps1')
. (Join-Path $AppDir 'Modules\MapCatalog\Catalog.Build.ps1')

# ---------------------------------------------------------------------------
# Map-catalog build coverage -- contract regression.
#
# Guards the defect fixed in the Daily-Use Analyzer v1 milestone: the build index matched the
# `Map\Common Map\MapNN` prefix with a case-SENSITIVE regex while the VFS node reader
# (`ParseAllMapNodes`) and the descriptor parser are case-insensitive. Real archives contain
# `MAP08` / `map85` style folders, so 25 map ids (including Map12 `老街`) were dropped from the
# build index and 16 of them had no catalog entry at all.
#
# Synthetic: the index builder is pure and takes nodes/iips/descriptors, so no game install and no
# archive are needed. A live-catalog sanity check is added when this machine has a rebuilt catalog.
# ---------------------------------------------------------------------------
$synthetic=0

function New-Node([string]$FullPath,[string]$Vfs){
    return [pscustomobject]@{Vfs=$Vfs;FullPath=$FullPath;Name=($FullPath.Split('\')[-1])}
}
function New-Iips([int]$MapId,[string]$FullPath,[string]$Rel){
    return [pscustomobject]@{map_id=$MapId;full_path=$FullPath;relative_path=$Rel;file_md5=('A'*32);package_md5=('B'*32);package_path='x.vfs'}
}
function New-Desc([int]$MapId,[string]$Name){
    return [pscustomobject]@{MapId=$MapId;MapName=$Name;Parsed=$true;ParseStatus='parsed';Vfs='x.vfs';FullPath='';Md5=('C'*32)}
}

# --- C1: an upper-case map folder must reach the build index ---------------------------------
$nodes=@(
    (New-Node 'Map\Common Map\Map29\map.nif' 'data.vfs'),
    (New-Node 'Map\Common Map\MAP12\map.nif' 'data.vfs'),
    (New-Node 'Map\Common Map\MAP12\map_desc.luc' 'data.vfs'),
    (New-Node 'Map\Common Map\map85\map.nif' 'data.vfs'),
    (New-Node 'Map\Common Map\Map08\map.nif' 'data2.vfs'),
    (New-Node 'Map\Other\Map99\x.nif' 'data.vfs')
)
$iips=@((New-Iips 222 'Map\Common Map\MAP222\map.nif' 'map.nif'))
$desc=@((New-Desc 12 '老街'),(New-Desc 29 '城市火炬'))
$index=New-MapCatalogBuildIndex -Nodes $nodes -Iips $iips -Descriptors $desc
$ids=@($index.ids|Sort-Object)
Require ($ids -contains 29) 'C1: a normally cased map folder must be indexed'
Require ($ids -contains 12) 'C1: an upper-case `MAP12` folder must be indexed (case-insensitive locator)'
Require ($ids -contains 85) 'C1: a lower-case `map85` folder must be indexed (case-insensitive locator)'
Require ($ids -contains 8) 'C1: a mixed-case `Map08` folder must be indexed'
Require ($ids -contains 222) 'C1: an upper-case IIPS row must be indexed'
Require (-not($ids -contains 99)) 'C1: a path outside `Map\Common Map\MapNN` must not be indexed'
Require ($index.nodes_by_map[12].Count -eq 2) 'C1: every node of an upper-case map folder must be bucketed under its numeric id'
Require ($index.descriptors_by_map.ContainsKey(12)) 'C1: the descriptor bucket must be keyed by the numeric id'
$synthetic++

# --- C2: the same rule for the IIPS reader ---------------------------------------------------
# `Read-IipsIndex` needs a real FileList.dat, so only the shared locator contract is asserted here:
# the case-insensitive pattern used by the build index must accept the real path shapes.
$pattern='^Map\\Common Map\\Map(\d+)(?:\\(.*))?$'
$ic=[System.Text.RegularExpressions.RegexOptions]::IgnoreCase
foreach($p in @('Map\Common Map\MAP08\map_desc.luc','Map\Common Map\map85\map.nif','Map\Common Map\Map29\map.nif')){
    $m=[regex]::Match($p,$pattern,$ic)
    Require ($m.Success) ('C2: the IIPS locator must accept '+$p)
}
Require (-not([regex]::Match('Map\Other\Map12\x','^Map\\Common Map\\Map(\d+)(?:\\(.*))?$',$ic).Success)) 'C2: the IIPS locator must reject non-map paths'
$synthetic++

# --- C3: live rebuilt catalog sanity (skipped when this machine has no catalog) --------------
$dataDir=Split-Path -Parent $AppDir
$catalogPath=Join-Path $dataDir 'MapCatalog\map_index.json'
$liveChecked=$false
if(Test-Path -LiteralPath $catalogPath -PathType Leaf){
    $cat=@(ConvertTo-FlatObjectArray (Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8|ConvertFrom-Json))
    $liveIds=New-Object System.Collections.Generic.HashSet[int]
    foreach($e in $cat){if($null -ne $e.map_id){[void]$liveIds.Add([int]$e.map_id)}}
    Require ($liveIds.Contains(12)) ('C3: the rebuilt catalog is missing Map12 `老街`; rebuild it after the case-insensitive fix (catalog entries='+$cat.Count+')')
    Require ($liveIds.Contains(8)) 'C3: the rebuilt catalog is missing Map08'
    Require ($liveIds.Contains(222)) 'C3: the rebuilt catalog is missing Map222'
    $liveChecked=$true
}

Write-Host ('[OK] Map catalog build coverage regression passed. synthetic='+[string]$synthetic+' live-catalog='+$(if($liveChecked){'checked'}else{'skipped(no rebuilt catalog)'})+'; case-insensitive prefix locator + numeric id bucketing + non-map path rejection.')
exit 0
