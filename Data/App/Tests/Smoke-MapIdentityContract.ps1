param([string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)))
$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_MapIdentity_Smoke_'+[Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $temp|Out-Null
    . (Join-Path $AppDir 'Modules\Replay\Replay.MapIdentityResolver.ps1')

    $res=[pscustomobject]@{resolved_map_id=166;resolution_method='exact map_desc.map_name catalog match';confidence='high'}
    $id=Resolve-ReplayMapIdentity -Resolution $res -MapId 166 -MapName 'Synthetic Map' -ReplaySha256 'ABC' -ReplayFile 'a.sav' -DataDir $temp
    if([string]$id.course_key-ne'resource:166' -or -not[bool]$id.authoritative -or [int]$id.resource_map_id-ne166){throw 'Resolved resource identity regression.'}
    if([string]$id.identity_key-ne'resource:166' -or [int]$id.canonical_map_id-ne166){throw 'Canonical resource identity aliases regression.'}
    if([string]$id.status-ne'resolved' -or -not[bool]$id.immutable_when_resolved){throw 'Resolved identity lifecycle regression.'}

    [void](Update-MapIdentityRegistry -DataDir $temp -Identity $id)
    $reg=Read-MapIdentityRegistry $temp
    if([int]$reg.schema_version-ne2 -or @($reg.entries).Count-ne1 -or [string]$reg.entries[0].course_key-ne'resource:166'){throw 'Map identity metadata registry regression.'}
    if(-not(Test-Path -LiteralPath (Join-Path $temp 'NativeIdentity\map_registry.json') -PathType Leaf)){throw 'NativeIdentity registry path regression.'}
    if(Test-Path -LiteralPath (Join-Path $temp 'MapModels') -PathType Container){throw 'MapModels must not be recreated by v3 identity registry.'}

    $analysis=[pscustomobject]@{map_id=166;resource_map_id=166;map_name='Synthetic Alias';map_identity=[pscustomobject]@{authoritative=$true;map_id=166;map_name='Synthetic Map'}}
    $fromAnalysis=Resolve-AnalysisMapIdentity -Analysis $analysis -AnalysisFile 'a_analysis.json' -DataDir $temp
    if([string]$fromAnalysis.course_key-ne'resource:166'){throw 'Native analysis identity normalization regression.'}

    $conflict=[pscustomobject]@{map_id=167;resource_map_id=167;map_name='Conflict';map_identity=[pscustomobject]@{authoritative=$true;map_id=166;map_name='Synthetic Map'}}
    $conf=Resolve-AnalysisMapIdentity -Analysis $conflict -AnalysisFile 'conflict.json' -DataDir $temp
    if([string]$conf.status-ne'conflicting' -or -not[string]::IsNullOrWhiteSpace([string]$conf.course_key)){throw 'Conflicting resource map IDs must not resolve.'}

    $manual=[ordered]@{'sha:XYZ'='Manual Test Map'}
    [IO.File]::WriteAllText((Join-Path $temp 'manual_map_names.json'),($manual|ConvertTo-Json),(New-Object Text.UTF8Encoding -ArgumentList $true))
    $manualAnalysis=[pscustomobject]@{replay_sha256='XYZ';replay_file='manual.sav';map_name='未识别地图'}
    $m=Resolve-AnalysisMapIdentity -Analysis $manualAnalysis -AnalysisFile 'manual_analysis.json' -DataDir $temp
    if([string]$m.status-ne'manually_named' -or -not[string]::IsNullOrWhiteSpace([string]$m.course_key) -or [string]$m.display_name-ne'Manual Test Map'){throw 'Manual names must be display-only.'}

    $sameNameA=Resolve-AnalysisMapIdentity -Analysis ([pscustomobject]@{map_name='Same Display Name'}) -AnalysisFile 'n1.json' -DataDir $temp
    $sameNameB=Resolve-AnalysisMapIdentity -Analysis ([pscustomobject]@{map_name='Same Display Name'}) -AnalysisFile 'n2.json' -DataDir $temp
    if((Compare-MapIdentity $sameNameA $sameNameB)-ne'UNKNOWN'){throw 'Name-only identities must not compare SAME.'}

    $catalogDir=Join-Path $temp 'MapCatalog';New-Item -ItemType Directory -Force -Path $catalogDir|Out-Null
    $binding=[ordered]@{schema_version=1;bindings=@([ordered]@{map_name='十一城';game_map_id=137;resource_map_id=37;binding_source='verified_anchor';authoritative_for_cross_namespace_binding=$true})}
    [IO.File]::WriteAllText((Join-Path $catalogDir 'game_resource_bindings.json'),($binding|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding -ArgumentList $true))
    $fromGame=Resolve-AnalysisMapIdentity -Analysis ([pscustomobject]@{game_map_id=137;map_name='十一城'}) -AnalysisFile 'game.json' -DataDir $temp
    $fromResource=Resolve-AnalysisMapIdentity -Analysis ([pscustomobject]@{resource_map_id=37;map_name='十一城'}) -AnalysisFile 'resource.json' -DataDir $temp
    if([string]$fromGame.course_key-ne'resource:37' -or [int]$fromGame.game_map_id-ne137){throw 'Verified Game->Resource binding promotion regression.'}
    if((Compare-MapIdentity $fromGame $fromResource)-ne'SAME'){throw 'Game and Resource identities for the same physical course must compare SAME.'}

    $different=Resolve-AnalysisMapIdentity -Analysis ([pscustomobject]@{resource_map_id=38;map_name='Other'}) -AnalysisFile 'other.json' -DataDir $temp
    if((Compare-MapIdentity $fromResource $different)-ne'DIFFERENT'){throw 'Different resolved Resource MapIDs must compare DIFFERENT.'}

    $unknown=Resolve-AnalysisMapIdentity -Analysis ([pscustomobject]@{map_name='未识别地图'}) -AnalysisFile 'u.json' -DataDir $temp
    if([string]$unknown.status-ne'unresolved' -or -not[string]::IsNullOrWhiteSpace([string]$unknown.course_key)){throw 'Unresolved identity regression.'}

    Write-Host ('[OK] Native Map Identity v3 smoke passed. course='+$id.course_key+' manual=display-only game-binding='+$fromGame.course_key+' compare=SAME/DIFFERENT/UNKNOWN')
    exit 0
} catch {Write-Host ('[FAILED] '+$_.Exception.Message);exit 2} finally {try{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}catch{}}
