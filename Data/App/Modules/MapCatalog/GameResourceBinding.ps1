function GRB-NormalizeName([string]$Name) {
    if([string]::IsNullOrWhiteSpace($Name)){ return "" }
    $s=$Name.Normalize([System.Text.NormalizationForm]::FormKC).Trim()
    return [regex]::Replace($s,'\s+',' ')
}

function GRB-ToFlatArray([object]$Value) {
    $list=New-Object System.Collections.Generic.List[object]
    if($null -eq $Value){ return $list.ToArray() }
    if($Value -is [System.Array]) {
        foreach($item in $Value) {
            if($item -is [System.Array]) {
                foreach($inner in $item) { if($null -ne $inner){ $list.Add($inner) } }
            } elseif($null -ne $item) {
                $list.Add($item)
            }
        }
    } else {
        $list.Add($Value)
    }
    return $list.ToArray()
}

function GRB-AddIndexId([hashtable]$Index,[string]$Key,[int]$Id) {
    if([string]::IsNullOrWhiteSpace($Key)){ return }
    if(-not $Index.ContainsKey($Key)) {
        $Index[$Key]=New-Object System.Collections.Generic.List[int]
    }
    if(-not $Index[$Key].Contains($Id)){ $Index[$Key].Add($Id) }
}

function GRB-GetIds([hashtable]$Index,[string]$Key) {
    if([string]::IsNullOrWhiteSpace($Key) -or -not $Index.ContainsKey($Key)){ return @() }
    return @($Index[$Key].ToArray()|Sort-Object -Unique)
}

function GRB-LoadRoomCatalogSnapshot {
    $path=Join-Path $PSScriptRoot 'Data\game_room_catalog_2026.json'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ throw ('Game room catalog snapshot is missing: '+$path) }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function GRB-LoadVerifiedAnchors {
    $path=Join-Path $PSScriptRoot 'Data\game_resource_verified_anchors_2026.json'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ return @() }
    $obj=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    return @(GRB-ToFlatArray $obj.anchors)
}

# ---------------------------------------------------------------------------
# user-confirmed Game -> Resource binding authority
# ---------------------------------------------------------------------------
# The authoritative generated routes (verified anchor, resource-declared Game MapID, unique exact
# official name) resolve the known 2026 closure rows such as GameMapID 439 / 一梦青花 and 112 /
# 老街管道. A future row may still have no authoritative Resource mapping; such a row must remain
# unresolved rather than be promoted by a near-name or a +100 offset guess.
#
# Explicit user confirmation is the escape hatch for that future/open case, and it is deliberately
# NOT a heuristic:
#   * a human states the mapping once: GameMapID X == ResourceMapID Y;
#   * it is stored as a user fact beside the other manual user data, survives every derived rebuild
#     and every cold reset, carries explicit provenance, and can be revoked;
#   * nothing in the codebase may create, infer or promote it. Only an explicit user action writes
#     it, and it is written to its own file - never into the generated binding catalog.
#
# Its authority is exactly "the user confirmed it", reported as such, never as `verified`.
$script:GRBUserConfirmedContract='user_confirmed_game_resource_binding_v1'

# Local positive-int coercion so this module stays loadable on its own (no dependency on the map
# identity resolver helpers).
function GRB-TryInt($Value) {
    if($null -eq $Value){ return $null }
    try { $i=[int]$Value; if($i -gt 0){ return $i } } catch {}
    return $null
}

function Get-GRBUserConfirmedBindingPath([string]$DataDir) {
    if([string]::IsNullOrWhiteSpace($DataDir)){ throw 'User-confirmed binding store requires DataDir.' }
    return (Join-Path $DataDir 'MapCatalog\user_confirmed_game_resource_bindings.json')
}

function Read-GRBUserConfirmedBindings([string]$DataDir) {
    $empty=[pscustomobject][ordered]@{schema_version=1;contract=$script:GRBUserConfirmedContract;updated_at=$null;bindings=@()}
    if([string]::IsNullOrWhiteSpace($DataDir)){ return $empty }
    $path=Get-GRBUserConfirmedBindingPath $DataDir
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ return $empty }
    try {
        $obj=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if($null-eq$obj){ return $empty }
        if(@($obj.PSObject.Properties.Name) -notcontains 'bindings'){ return $empty }
        return $obj
    } catch { return $empty }
}

function Write-GRBUserConfirmedBindings([string]$DataDir,[object]$Store) {
    $path=Get-GRBUserConfirmedBindingPath $DataDir
    $dir=Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $dir|Out-Null
    if($null-eq$Store){ throw 'User-confirmed binding store is required.' }
    $Store|Add-Member -NotePropertyName schema_version -NotePropertyValue 1 -Force
    $Store|Add-Member -NotePropertyName contract -NotePropertyValue $script:GRBUserConfirmedContract -Force
    $Store|Add-Member -NotePropertyName updated_at -NotePropertyValue ((Get-Date).ToString('o')) -Force
    $Store|Add-Member -NotePropertyName policy -NotePropertyValue 'Explicit human confirmation only. Never generated, never inferred from a near name, an offset relation or a trajectory. Revocable.' -Force
    $tmp=$path+'.tmp'
    $enc=New-Object System.Text.UTF8Encoding -ArgumentList $true
    [IO.File]::WriteAllText($tmp,($Store|ConvertTo-Json -Depth 8),$enc)
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

function Get-GRBUserConfirmedBindingForGameMapId([string]$DataDir,$GameMapId) {
    $gid=GRB-TryInt $GameMapId
    if($null-eq$gid){ return $null }
    $store=Read-GRBUserConfirmedBindings $DataDir
    $hit=@(@($store.bindings)|Where-Object { $null-ne$_ -and (GRB-TryInt $_.game_map_id) -eq $gid -and $null-ne (GRB-TryInt $_.resource_map_id) })
    $ids=@($hit|ForEach-Object { GRB-TryInt $_.resource_map_id }|Sort-Object -Unique)
    if($ids.Count -ne 1){ return $null }
    return @($hit|Where-Object { (GRB-TryInt $_.resource_map_id) -eq [int]$ids[0] }|Select-Object -First 1)[0]
}

function Set-GRBUserConfirmedBinding([string]$DataDir,[int]$GameMapId,[int]$ResourceMapId,[string]$GameDisplayName='',[string]$ResourceDisplayName='',[string]$Evidence='') {
    if($GameMapId -le 0){ throw 'GameMapId must be a positive integer.' }
    if($ResourceMapId -le 0){ throw 'ResourceMapId must be a positive integer.' }
    $store=Read-GRBUserConfirmedBindings $DataDir
    $kept=New-Object System.Collections.Generic.List[object]
    foreach($b in @($store.bindings)){ if($null-ne$b -and (GRB-TryInt $b.game_map_id) -ne $GameMapId){ $kept.Add($b) } }
    $kept.Add([pscustomobject][ordered]@{
        game_map_id=$GameMapId
        resource_map_id=$ResourceMapId
        game_display_name=$GameDisplayName
        resource_display_name=$ResourceDisplayName
        provenance='user_confirmed'
        confirmed_by='user'
        evidence=$Evidence
        confirmed_at=(Get-Date).ToString('o')
    })
    $store.bindings=@($kept.ToArray()|Sort-Object {[int]$_.game_map_id})
    return (Write-GRBUserConfirmedBindings -DataDir $DataDir -Store $store)
}

function Remove-GRBUserConfirmedBinding([string]$DataDir,[int]$GameMapId) {
    $store=Read-GRBUserConfirmedBindings $DataDir
    $kept=New-Object System.Collections.Generic.List[object]
    $removed=0
    foreach($b in @($store.bindings)){ if($null-ne$b -and (GRB-TryInt $b.game_map_id) -eq $GameMapId){ $removed++ } else { $kept.Add($b) } }
    $store.bindings=@($kept.ToArray()|Sort-Object {[int]$_.game_map_id})
    [void](Write-GRBUserConfirmedBindings -DataDir $DataDir -Store $store)
    return $removed
}

function GRB-BuildBindingsFromData(
    [object[]]$GameRecords,
    [object[]]$ResourceCatalog,
    [object[]]$ManualAliases,
    [object[]]$VerifiedAnchors
) {
    $games=@(GRB-ToFlatArray $GameRecords)
    $resources=@(GRB-ToFlatArray $ResourceCatalog)
    # ManualAliases parameter is accepted only so old callers/tests fail closed; values are ignored.
    $anchors=@(GRB-ToFlatArray $VerifiedAnchors)

    $resourceById=@{}
    $exactIndex=@{}
    # Native-first v3 deliberately ignores display_aliases for physical identity.
    foreach($e in $resources) {
        if($null -eq $e -or $null -eq $e.map_id){ continue }
        $rid=[int]$e.map_id
        $resourceById[[string]$rid]=$e

        $exactNames=New-Object System.Collections.Generic.List[string]
        if($e.PSObject.Properties['primary_name']){ $exactNames.Add([string]$e.primary_name) }
        if($e.PSObject.Properties['all_names']) {
            foreach($n in @(GRB-ToFlatArray $e.all_names)){ $exactNames.Add([string]$n) }
        }
        foreach($n in $exactNames) {
            $norm=GRB-NormalizeName $n
            if(-not [string]::IsNullOrWhiteSpace($norm)){ GRB-AddIndexId $exactIndex $norm $rid }
        }

    }

    # Manual aliases are UI labels only in v3; they are intentionally ignored here.

    $anchorIndex=@{}
    foreach($a in $anchors) {
        if($null -eq $a -or $null -eq $a.game_map_id -or $null -eq $a.resource_map_id){ continue }
        $key=([string][int]$a.game_map_id)+'|'+(GRB-NormalizeName ([string]$a.name))
        $anchorIndex[$key]=$a
    }

    # Resource-declared identity: every `Map\Common Map\MapNN\LapDistanceFile.luc` declares the
    # game-side `mapId` the folder belongs to, so a Game MapID -> Resource MapNN binding can be read
    # without any name join and without assuming `folder == mapid - 100`. A game MapID that two
    # folders declare is a genuine conflict in the official data and fails closed.
    $declaredIndex=@{}
    foreach($e in $resources) {
        if($null -eq $e -or $null -eq $e.map_id){ continue }
        if(-not $e.PSObject.Properties['declared_game_map_id']){ continue }
        $dg=GRB-TryInt $e.declared_game_map_id
        if($null -eq $dg){ continue }
        $key=[string][int]$dg
        if(-not $declaredIndex.ContainsKey($key)) { $declaredIndex[$key]=New-Object System.Collections.Generic.List[int] }
        $rid=[int]$e.map_id
        if(-not $declaredIndex[$key].Contains($rid)){ $declaredIndex[$key].Add($rid) }
    }

    $gameNameCounts=@{}
    foreach($g in $games) {
        $norm=GRB-NormalizeName ([string]$g.name)
        if([string]::IsNullOrWhiteSpace($norm)){ continue }
        if(-not $gameNameCounts.ContainsKey($norm)){ $gameNameCounts[$norm]=0 }
        $gameNameCounts[$norm]=[int]$gameNameCounts[$norm]+1
    }

    $rows=New-Object System.Collections.Generic.List[object]
    foreach($g in $games) {
        if($null -eq $g -or $null -eq $g.game_map_id){ continue }
        $gid=[int]$g.game_map_id
        $name=[string]$g.name
        $norm=GRB-NormalizeName $name
        $resourceId=$null
        $status='unresolved_or_special'
        $source=''
        $evidence=''
        $authoritative=$false
        $resourceName=''
        $ambiguousIds=@()

        $anchorKey=([string]$gid)+'|'+$norm
        if($anchorIndex.ContainsKey($anchorKey)) {
            $a=$anchorIndex[$anchorKey]
            $aid=[int]$a.resource_map_id
            if($resourceById.ContainsKey([string]$aid)) {
                $resourceId=$aid
                $status='verified_cross_namespace'
                $source='verified_anchor'
                $authoritative=$true
                $evidence=([string]$a.game_evidence)+' | '+([string]$a.resource_evidence)
            } else {
                $status='verified_anchor_resource_missing'
                $source='verified_anchor'
                $evidence='Verified anchor exists, but this Resource MapNN is absent from the current catalog.'
            }
        } elseif($declaredIndex.ContainsKey([string]$gid)) {
            $declaredIds=@($declaredIndex[[string]$gid]|Sort-Object)
            if($declaredIds.Count -eq 1) {
                $resourceId=[int]$declaredIds[0]
                $status='verified_cross_namespace'
                $source='resource_declared_map_id'
                $authoritative=$true
                $evidence=('Resource Map'+[string]$declaredIds[0]+' LapDistanceFile.luc declares mapId='+[string]$gid+' (resource-declared game identity).')
            } else {
                $status='ambiguous_declared_map_id'
                $source='resource_declared_map_id'
                $ambiguousIds=@($declaredIds)
                $evidence=('More than one resource folder declares this game MapID in LapDistanceFile.luc: Map'+(($declaredIds|ForEach-Object {[string]$_}) -join ', Map')+'.')
            }
        } elseif(-not [string]::IsNullOrWhiteSpace($norm) -and $gameNameCounts.ContainsKey($norm) -and [int]$gameNameCounts[$norm] -gt 1) {
            $status='ambiguous_game_name'
            $source='duplicate_game_display_name'
            $evidence='The room catalog contains more than one game_map_id for this display name.'
        } else {
            $ids=@(GRB-GetIds $exactIndex $norm)
            if($ids.Count -eq 1) {
                $resourceId=[int]$ids[0]
                $status='verified_cross_namespace'
                $source='exact_resource_catalog_name'
                $authoritative=$true
                $evidence='Unique normalized room display name -> current Resource MapCatalog name.'
            } elseif($ids.Count -gt 1) {
                $status='ambiguous_resource_name'
                $source='exact_resource_catalog_name'
                $ambiguousIds=@($ids)
                $evidence='The normalized room display name maps to multiple Resource MapNN values.'
            } else {
                # No manual/display-alias promotion. Keep the observed +100 relation diagnostic-only.
                $offsetId=$gid-100
                if($offsetId -ge 0 -and $resourceById.ContainsKey([string]$offsetId)) {
                    $resourceId=$offsetId
                    $status='offset_supported_candidate'
                    $source='observed_plus_100_rule_candidate'
                    $evidence='Resource MapNN exists at game_map_id - 100, but no exact official name or verified anchor proved this row.'
                }
            }
        }

        if($null -ne $resourceId -and $resourceById.ContainsKey([string][int]$resourceId)) {
            $re=$resourceById[[string][int]$resourceId]
            if($re.PSObject.Properties['primary_name']){ $resourceName=[string]$re.primary_name }
        }

        $offsetRelation='unknown'
        if($null -ne $resourceId) {
            if(($gid-[int]$resourceId) -eq 100){ $offsetRelation='matches_plus_100' }
            else { $offsetRelation='exception_to_plus_100' }
        }

        $rows.Add([PSCustomObject][ordered]@{
            map_name=$name
            normalized_name=$norm
            game_map_id=$gid
            resource_map_id=$resourceId
            resource_primary_name=$resourceName
            status=$status
            binding_source=$source
            evidence=$evidence
            authoritative_for_cross_namespace_binding=$authoritative
            offset_relation=$offsetRelation
            ambiguous_resource_map_ids=@($ambiguousIds)
        })
    }

    $out=@($rows.ToArray())
    $verified=@($out|Where-Object {[bool]$_.authoritative_for_cross_namespace_binding})
    $offsetVerified=@($verified|Where-Object {[string]$_.offset_relation -eq 'matches_plus_100'})
    $offsetExceptions=@($verified|Where-Object {[string]$_.offset_relation -eq 'exception_to_plus_100'})
    $offsetCandidates=@($out|Where-Object {[string]$_.status -eq 'offset_supported_candidate'})
    $ambiguous=@($out|Where-Object {[string]$_.status -like 'ambiguous_*'})
    $unresolved=@($out|Where-Object {[string]$_.status -eq 'unresolved_or_special' -or [string]$_.status -eq 'verified_anchor_resource_missing'})

    $sourceCounts=@{}
    foreach($x in $verified) {
        $s=[string]$x.binding_source
        if(-not $sourceCounts.ContainsKey($s)){ $sourceCounts[$s]=0 }
        $sourceCounts[$s]=[int]$sourceCounts[$s]+1
    }

    return [PSCustomObject][ordered]@{
        bindings=$out
        summary=[PSCustomObject][ordered]@{
            game_record_count=$games.Count
            resource_catalog_count=$resources.Count
            verified_binding_count=$verified.Count
            declared_binding_count=@($verified|Where-Object {[string]$_.binding_source -eq 'resource_declared_map_id'}).Count
            offset_supported_candidate_count=$offsetCandidates.Count
            ambiguous_count=$ambiguous.Count
            ambiguous_declared_map_id_count=@($out|Where-Object {[string]$_.status -eq 'ambiguous_declared_map_id'}).Count
            unresolved_or_special_count=$unresolved.Count
            verified_plus_100_count=$offsetVerified.Count
            verified_plus_100_exception_count=$offsetExceptions.Count
            verified_plus_100_ratio=$(if($verified.Count -gt 0){[Math]::Round($offsetVerified.Count/[double]$verified.Count,6)}else{$null})
            verified_source_counts=$sourceCounts
        }
        verified_offset_exceptions=@($offsetExceptions)
    }
}

function Invoke-GameResourceBindingBuild(
    [string]$DataDir,
    [object[]]$CatalogOverride
) {
    if([string]::IsNullOrWhiteSpace($DataDir)){ throw 'DataDir is required.' }

    $snapshot=GRB-LoadRoomCatalogSnapshot
    $games=@(GRB-ToFlatArray $snapshot.records)
    $catalog=@(GRB-ToFlatArray $CatalogOverride)
    if($catalog.Count -eq 0 -and $null -ne (Get-Command Ensure-Catalog -ErrorAction SilentlyContinue)) {
        $catalog=@(GRB-ToFlatArray (Ensure-Catalog))
    }
    if($catalog.Count -eq 0){ throw 'Resource MapCatalog is empty.' }

    $anchors=@(GRB-ToFlatArray (GRB-LoadVerifiedAnchors))

    $built=GRB-BuildBindingsFromData -GameRecords $games -ResourceCatalog $catalog -ManualAliases @() -VerifiedAnchors $anchors
    $report=[ordered]@{
        schema_version=1
        generated_at=(Get-Date).ToString('o')
        room_catalog_source=$snapshot.source
        room_catalog_stats=$snapshot.stats
        policy=[ordered]@{
            namespaces='game_map_id and resource_map_id are distinct'
            verified_rule='Authoritative routes: a verified anchor, a resource-declared game MapID (MapNN\LapDistanceFile.luc mapId), or a unique exact official name join. A resource-declared MapID claimed by two folders is ambiguous and fails closed.'
            offset_rule='game_map_id = resource_map_id + 100 is observed evidence only; it is not universal (measured counter-examples exist) and unmatched rows remain candidates.'
            map_identity_promotion='This file does not overwrite Replay.MapIdentityResolver canonical/resource identity.'
        }
        summary=$built.summary
        verified_offset_exceptions=@($built.verified_offset_exceptions)
        bindings=@($built.bindings)
    }

    $catalogDir=Join-Path $DataDir 'MapCatalog'
    $diagDir=Join-Path $DataDir 'Diagnostics\GameResourceBinding'
    New-Item -ItemType Directory -Force -Path $catalogDir,$diagDir | Out-Null
    $jsonPath=Join-Path $catalogDir 'game_resource_bindings.json'
    $latestPath=Join-Path $diagDir 'latest.json'
    $csvPath=Join-Path $catalogDir 'game_resource_bindings.csv'
    $jsonText=$report|ConvertTo-Json -Depth 12
    Write-Utf8Bom $jsonPath $jsonText
    Write-Utf8Bom $latestPath $jsonText
    @($built.bindings)|Select-Object map_name,game_map_id,resource_map_id,resource_primary_name,status,binding_source,authoritative_for_cross_namespace_binding,offset_relation |
        Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    Write-Host '[Game/Resource Binding] complete.'
    Write-Host ('  Room catalog records: '+$report.summary.game_record_count)
    Write-Host ('  Resource catalog entries: '+$report.summary.resource_catalog_count)
    Write-Host ('  Verified bindings: '+$report.summary.verified_binding_count)
    Write-Host ('  Of which resource-declared game MapID: '+$report.summary.declared_binding_count)
    Write-Host ('  +100 verified: '+$report.summary.verified_plus_100_count+'; exceptions: '+$report.summary.verified_plus_100_exception_count)
    Write-Host ('  Offset-only candidates: '+$report.summary.offset_supported_candidate_count)
    Write-Host ('  Ambiguous: '+$report.summary.ambiguous_count+' (declared-conflict: '+$report.summary.ambiguous_declared_map_id_count+'); unresolved/special: '+$report.summary.unresolved_or_special_count)
    foreach($n in @('十一城','瓦特厂房','猫工厂','机械公园')) {
        foreach($x in @($built.bindings|Where-Object {[string]$_.map_name -eq $n})) {
            $rid=$(if($null -ne $x.resource_map_id){'Map'+[string]$x.resource_map_id}else{'unresolved'})
            Write-Host ('  Anchor check: '+$x.map_name+' game='+$x.game_map_id+' <-> '+$rid+' ['+$x.status+']')
        }
    }
    Write-Host ('Output: '+$jsonPath)
    return [PSCustomObject]$report
}
