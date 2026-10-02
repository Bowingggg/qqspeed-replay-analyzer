function Get-SourceSignature {
    $items=New-Object System.Collections.Generic.List[string]

    foreach($f in @(Get-ChildItem -LiteralPath $GamePath -File -Filter "*.vfs" -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $items.Add(("VFS|{0}|{1}|{2}" -f $f.Name,$f.Length,$f.LastWriteTimeUtc.Ticks))
    }

    foreach($base in @("Releasephysx27\IIPS","Releasephysx27_64\IIPS")) {
        $r=Join-Path $GamePath $base
        if(-not (Test-Path -LiteralPath $r -PathType Container)){continue}
        foreach($f in @(Get-ChildItem -LiteralPath $r -Recurse -File -Filter "FileList.dat" -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            $rel=$f.FullName.Substring($GamePath.Length).TrimStart('\')
            $items.Add(("IIPS|{0}|{1}|{2}" -f $rel,$f.Length,$f.LastWriteTimeUtc.Ticks))
        }
    }

    $joined=[string]::Join("`n",$items.ToArray())
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes=[System.Text.Encoding]::UTF8.GetBytes($joined)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-","")
    } finally {$sha.Dispose()}
}

function Read-IipsIndex {
    $rows=New-Object System.Collections.Generic.List[object]

    foreach($base in @("Releasephysx27\IIPS","Releasephysx27_64\IIPS")) {
        $r=Join-Path $GamePath $base
        if(-not (Test-Path -LiteralPath $r -PathType Container)){continue}

        foreach($fl in @(Get-ChildItem -LiteralPath $r -Recurse -File -Filter "FileList.dat" -ErrorAction SilentlyContinue)) {
            try {
                foreach($line in [System.IO.File]::ReadLines($fl.FullName)) {
                    if([string]::IsNullOrWhiteSpace($line)){continue}
                    $p=$line.Split('|')
                    if($p.Count -lt 7){continue}
                    # The VFS/IIPS path case is not guaranteed: real archives contain
                    # `MAP08` / `map85` style folders. The prefix builder below and the
                    # descriptor parser are already case-insensitive, so this locator must
                    # be too, otherwise those maps silently lose their IIPS evidence.
                    $m=[regex]::Match($p[0],'^Map\\Common Map\\Map(\d+)(?:\\(.*))?$',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    if(-not $m.Success){continue}

                    $mid=[int]$m.Groups[1].Value
                    $prefix=("Map\Common Map\Map{0}\" -f $mid)
                    $rel=""
                    if($p[0].StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)) {
                        $rel=$p[0].Substring($prefix.Length)
                    }

                    $rows.Add([PSCustomObject]@{
                        map_id=$mid
                        full_path=$p[0]
                        relative_path=$rel
                        file_md5=$p[3].ToUpperInvariant()
                        package_md5=$p[4].ToUpperInvariant()
                        package_path=$p[6]
                    })
                }
            } catch {}
        }
    }

    return $rows.ToArray()
}


function New-MapCatalogBuildIndex([object[]]$Nodes,[object[]]$Iips,[object[]]$Descriptors,[object[]]$LapDistances=@()) {
    $ids=New-Object System.Collections.Generic.HashSet[int]
    $nodesByMap=@{}
    $iipsByMap=@{}
    $descriptorsByMap=@{}
    $lapDistanceByMap=@{}

    foreach($n in @($Nodes)) {
        # Case-insensitive to match `ParseAllMapNodes` (which admits any case of the
        # `Map\Common Map\MapNN` prefix) and `ParseMapDescriptors`. A case-sensitive
        # locator here drops every upper-case map folder from the build index.
        $m=[regex]::Match([string]$n.FullPath,'^Map\\Common Map\\Map(\d+)(?:\\|$)',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if(-not $m.Success){ continue }
        $mid=[int]$m.Groups[1].Value
        [void]$ids.Add($mid)
        if(-not $nodesByMap.ContainsKey($mid)) {
            $nodesByMap[$mid]=New-Object System.Collections.Generic.List[object]
        }
        $nodesByMap[$mid].Add($n)
    }

    foreach($r in @($Iips)) {
        $mid=[int]$r.map_id
        [void]$ids.Add($mid)
        if(-not $iipsByMap.ContainsKey($mid)) {
            $iipsByMap[$mid]=New-Object System.Collections.Generic.List[object]
        }
        $iipsByMap[$mid].Add($r)
    }

    foreach($d in @($Descriptors)) {
        $mid=[int]$d.MapId
        if(-not $descriptorsByMap.ContainsKey($mid)) {
            $descriptorsByMap[$mid]=New-Object System.Collections.Generic.List[object]
        }
        $descriptorsByMap[$mid].Add($d)
    }

    foreach($l in @($LapDistances)) {
        if($null -eq $l){ continue }
        $mid=[int]$l.MapId
        [void]$ids.Add($mid)
        if(-not $lapDistanceByMap.ContainsKey($mid)) {
            $lapDistanceByMap[$mid]=New-Object System.Collections.Generic.List[object]
        }
        $lapDistanceByMap[$mid].Add($l)
    }

    return [pscustomobject][ordered]@{
        ids=@($ids)
        nodes_by_map=$nodesByMap
        iips_by_map=$iipsByMap
        descriptors_by_map=$descriptorsByMap
        lap_distance_by_map=$lapDistanceByMap
    }
}

# VFS archive order. The client ships map resources in numbered patch archives (`data13.vfs`,
# `data21.vfs`, ...) that also exist under a bare `data.vfs` base archive. The per-map
# `LapDistanceFile.luc` was renamed in place for several maps, so a folder can declare more than one
# name across archives; the newest archive holds the current name. Measured on the real install:
# for every multi-name folder the highest-ranked archive's name is the one the live room table
# (`uires\mapsel\maps.luc`) uses for that folder's declared game MapID.
function Get-VfsArchiveRank([string]$Vfs) {
    $m=[regex]::Match([string]$Vfs,'(?i)^data(\d*)\.vfs$')
    if(-not $m.Success){ return -1 }
    if([string]::IsNullOrWhiteSpace($m.Groups[1].Value)){ return 0 }
    return [int]$m.Groups[1].Value
}

# The declared name that belongs to the newest archive that declares one.
function Get-PreferredDeclaredMapName([object[]]$Records) {
    $bestName=''
    $bestRank=-2
    $bestOrder=-1
    $i=0
    foreach($r in @($Records)) {
        $i++
        if($null -eq $r){ continue }
        $name=[string]$r.MapName
        if(-not (Test-MapDeclaredNameUsable $name)){ continue }
        $rank=Get-VfsArchiveRank ([string]$r.Vfs)
        if($rank -gt $bestRank -or ($rank -eq $bestRank -and $i -gt $bestOrder)) {
            $bestRank=$rank
            $bestOrder=$i
            $bestName=$name
        }
    }
    return $bestName
}

function Build-MapCatalog {
    Write-Host "[2/5] Parsing all current VFS map nodes..."
    $nodes=@([QQMapCatalogCore]::ParseAllMapNodes($GamePath))
    Write-Host ("  Local Map nodes: "+$nodes.Count)

    Write-Host "[3/5] Parsing exact map_name from every map_desc.luc..."
    $descriptors=@([QQMapCatalogCore]::ParseMapDescriptors($nodes))
    $parsedCount=@($descriptors|Where-Object {$_.Parsed}).Count
    Write-Host ("  Descriptor versions: "+$descriptors.Count+"; exact map_name parsed: "+$parsedCount)

    Write-Host "[3b/5] Parsing the resource-declared identity from every LapDistanceFile.luc..."
    $declaredWatch=[Diagnostics.Stopwatch]::StartNew()
    $lapDistances=@([QQMapCatalogCore]::ParseLapDistanceDescriptors($nodes))
    $declaredWatch.Stop()
    Write-Host ("  Declared identity records: "+$lapDistances.Count+" parsed in "+[math]::Round($declaredWatch.Elapsed.TotalSeconds,2)+"s")

    Write-Host "[4/5] Reading IIPS map index and building indexed union catalog..."
    $iipsWatch=[Diagnostics.Stopwatch]::StartNew()
    $iips=@(Read-IipsIndex)
    $iipsWatch.Stop()
    Write-Host ("  IIPS rows: "+$iips.Count+"; read in "+[math]::Round($iipsWatch.Elapsed.TotalSeconds,1)+"s")

    # Build per-map buckets once. The old implementation rescanned all ~68k VFS
    # nodes for every map ID during step 4, which made this stage O(maps * nodes).
    # Keep the same output semantics while reducing the hot path to near-linear work.
    $indexWatch=[Diagnostics.Stopwatch]::StartNew()
    $buildIndex=New-MapCatalogBuildIndex -Nodes $nodes -Iips $iips -Descriptors $descriptors -LapDistances $lapDistances
    $ids=@($buildIndex.ids)
    $indexWatch.Stop()
    Write-Host ("  Per-map index: "+$ids.Count+" IDs in "+[math]::Round($indexWatch.Elapsed.TotalSeconds,2)+"s")

    $entryWatch=[Diagnostics.Stopwatch]::StartNew()
    $entries=New-Object System.Collections.Generic.List[object]
    $descExport=New-Object System.Collections.Generic.List[object]

    foreach($d in $descriptors) {
        $descExport.Add([PSCustomObject]@{
            map_id=$d.MapId
            map_name=$d.MapName
            parsed=$d.Parsed
            parse_status=$d.ParseStatus
            vfs=$d.Vfs
            md5=$d.Md5
        })
    }

    foreach($mid in @($ids|Sort-Object)) {
        $local=@()
        if($buildIndex.nodes_by_map.ContainsKey($mid)){ $local=@($buildIndex.nodes_by_map[$mid].ToArray()) }
        $ii=@()
        if($buildIndex.iips_by_map.ContainsKey($mid)){ $ii=@($buildIndex.iips_by_map[$mid].ToArray()) }
        $dd=@()
        if($buildIndex.descriptors_by_map.ContainsKey($mid)){ $dd=@($buildIndex.descriptors_by_map[$mid].ToArray()) }
        $ll=@()
        if($buildIndex.lap_distance_by_map.ContainsKey($mid)){ $ll=@($buildIndex.lap_distance_by_map[$mid].ToArray()) }

        $descMd5=New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        foreach($x in @($ii|Where-Object {$_.relative_path -ieq "map_desc.luc"})) {
            if($x.file_md5 -match '^[0-9A-F]{32}$'){[void]$descMd5.Add($x.file_md5)}
        }

        $descriptorNames=@($dd|Where-Object {$_.Parsed -and -not [string]::IsNullOrWhiteSpace($_.MapName)} |
            ForEach-Object {$_.MapName} | Sort-Object -Unique)

        $matchedNames=@($dd|Where-Object {
            $_.Parsed -and $descMd5.Contains($_.Md5) -and -not [string]::IsNullOrWhiteSpace($_.MapName)
        } | ForEach-Object {$_.MapName} | Sort-Object -Unique)

        $descriptorPrimary=""
        $descriptorNameStatus=""
        if($matchedNames.Count -eq 1) {
            $descriptorPrimary=$matchedNames[0]
            $descriptorNameStatus="iips_md5_exact"
        } elseif($descriptorNames.Count -eq 1) {
            $descriptorPrimary=$descriptorNames[0]
            $descriptorNameStatus="single_exact_local_name"
        } elseif($descriptorNames.Count -gt 1) {
            $descriptorNameStatus="multiple_descriptor_names"
        } else {
            $descriptorNameStatus="name_unavailable"
        }

        # Resource-declared identity: `Map\Common Map\MapNN\LapDistanceFile.luc` declares the
        # game-side `mapId` and the map's `mapName`. The scene descriptor's `map_name` is a label the
        # client does not keep in step (it is duplicated across folders and contradicts the live room
        # table on several new maps), so a usable declared name carries the identity name and the
        # descriptor name is retained as reference data only.
        $declaredNames=@($ll|Where-Object {$null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.MapName)} |
            ForEach-Object {[string]$_.MapName} | Sort-Object -Unique)
        $usableDeclaredNames=@($declaredNames|Where-Object {Test-MapDeclaredNameUsable $_})
        $declaredIds=@($ll|Where-Object {$null -ne $_ -and $null -ne $_.DeclaredGameMapId} |
            ForEach-Object {[int]$_.DeclaredGameMapId} | Sort-Object -Unique)
        $declaredGameMapId=$null
        $declaredIdStatus='absent'
        if($declaredIds.Count -eq 1) { $declaredGameMapId=[int]$declaredIds[0]; $declaredIdStatus='unanimous' }
        elseif($declaredIds.Count -gt 1) { $declaredIdStatus='conflicting' }
        $declaredNameStatus=$(if($declaredNames.Count -eq 0){'absent'}elseif($usableDeclaredNames.Count -eq 0){'placeholder_only'}else{'usable'})

        $identityNames=@($descriptorNames)
        $nameSource='map_desc'
        $primary=$descriptorPrimary
        $nameStatus=$descriptorNameStatus
        if($usableDeclaredNames.Count -gt 0) {
            $identityNames=@($usableDeclaredNames)
            $nameSource='lap_distance'
            $declaredPrimary=Get-PreferredDeclaredMapName $ll
            if(-not [string]::IsNullOrWhiteSpace($declaredPrimary)){ $primary=$declaredPrimary }
            $nameStatus='declared_lapdistance_name'
        }

        $localRel=New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        foreach($n in $local) {
            $prefix=("Map\Common Map\Map{0}\" -f $mid)
            if($n.FullPath.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$localRel.Add($n.FullPath.Substring($prefix.Length))
            }
        }

        $iipsRel=New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        foreach($x in $ii) {
            if(-not [string]::IsNullOrWhiteSpace($x.relative_path)){[void]$iipsRel.Add($x.relative_path)}
        }

        $union=New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        foreach($x in $localRel){[void]$union.Add($x)}
        foreach($x in $iipsRel){[void]$union.Add($x)}

        $entries.Add([PSCustomObject]@{
            map_id=$mid
            primary_name=$primary
            normalized_primary_name=(Normalize-MapName $primary)
            name_status=$nameStatus
            name_source=$nameSource
            all_names=$identityNames
            declared_names=@($declaredNames)
            declared_game_map_id=$declaredGameMapId
            declared_identity_status=$declaredIdStatus
            declared_name_status=$declaredNameStatus
            descriptor_names=@($descriptorNames)
            descriptor_primary_name=$descriptorPrimary
            descriptor_name_status=$descriptorNameStatus
            display_aliases=@($identityNames | ForEach-Object { Get-MapDisplayAlias ([string]$_) } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
            descriptor_versions=$dd.Count
            descriptor_parse_failures=@($dd|Where-Object {-not $_.Parsed}).Count
            local_resource_count=$localRel.Count
            iips_resource_count=$iipsRel.Count
            has_checkpoint=$union.Contains("checkpoint.luc")
            has_bezier=$union.Contains("BazierPathPoint.luc")
            has_phxdata=$union.Contains("phxdata.cook")
            has_pick=$union.Contains("pick.nif")
            has_map_nif=$union.Contains("map.nif")
            has_scene=$union.Contains("sc.nif")
            local_resources=@($localRel|Sort-Object)
            iips_resources=@($iipsRel|Sort-Object)
        })
    }

    $entryWatch.Stop()
    Write-Host ("  Union entries: "+$entries.Count+" built in "+[math]::Round($entryWatch.Elapsed.TotalSeconds,1)+"s")

    $nameIndex=@{}
    foreach($e in $entries) {
        foreach($n in @($e.all_names)) {
            $key=Normalize-MapName $n
            if([string]::IsNullOrWhiteSpace($key)){continue}
            if(-not $nameIndex.ContainsKey($key)){$nameIndex[$key]=New-Object System.Collections.Generic.List[int]}
            if(-not $nameIndex[$key].Contains([int]$e.map_id)){$nameIndex[$key].Add([int]$e.map_id)}
        }
    }

    $duplicates=New-Object System.Collections.Generic.List[object]
    foreach($k in @($nameIndex.Keys|Sort-Object)) {
        if($nameIndex[$k].Count -gt 1) {
            $duplicates.Add([PSCustomObject]@{
                normalized_name=$k
                map_ids=@($nameIndex[$k]|Sort-Object)
            })
        }
    }

    $aliasIndex=@{}
    foreach($e in $entries) {
        foreach($a in @($e.display_aliases)) {
            $key=Normalize-MapName ([string]$a)
            if([string]::IsNullOrWhiteSpace($key)){continue}
            if(-not $aliasIndex.ContainsKey($key)){$aliasIndex[$key]=New-Object System.Collections.Generic.List[int]}
            if(-not $aliasIndex[$key].Contains([int]$e.map_id)){$aliasIndex[$key].Add([int]$e.map_id)}
        }
    }

    $aliasCollisions=New-Object System.Collections.Generic.List[object]
    foreach($k in @($aliasIndex.Keys|Sort-Object)) {
        if($aliasIndex[$k].Count -gt 1) {
            $aliasCollisions.Add([PSCustomObject]@{
                alias_name=$k
                map_ids=@($aliasIndex[$k]|Sort-Object)
            })
        }
    }

    # Build a deliberately small resolver index. Heavy resource inventories remain
    # discoverable on demand by Map ID and are not required for everyday replay resolution.
    $minimal=New-Object System.Collections.Generic.List[object]
    foreach($e in $entries) {
        $minimal.Add([PSCustomObject]@{
            map_id=[int]$e.map_id
            primary_name=[string]$e.primary_name
            all_names=@($e.all_names)
            display_aliases=@($e.display_aliases)
            name_status=[string]$e.name_status
            name_source=[string]$e.name_source
            declared_names=@($e.declared_names)
            declared_game_map_id=$e.declared_game_map_id
            descriptor_names=@($e.descriptor_names)
        })
    }

    $signature=Get-SourceSignature
    $meta=[ordered]@{
        schema_version=6
        generated_at=(Get-Date).ToString("o")
        source_signature=$signature
        map_id_count=$entries.Count
        exact_named_map_count=@($entries|Where-Object {-not [string]::IsNullOrWhiteSpace($_.primary_name)}).Count
        unnamed_map_count=@($entries|Where-Object {[string]::IsNullOrWhiteSpace($_.primary_name)}).Count
        duplicate_name_count=$duplicates.Count
        alias_collision_count=$aliasCollisions.Count
        descriptor_version_count=$descriptors.Count
        descriptor_exact_parse_count=$parsedCount
        declared_identity_record_count=$lapDistances.Count
        declared_identity_map_count=@($entries|Where-Object {$null -ne $_.declared_game_map_id}).Count
        declared_identity_conflict_count=@($entries|Where-Object {[string]$_.declared_identity_status -eq 'conflicting'}).Count
        declared_name_used_map_count=@($entries|Where-Object {[string]$_.name_source -eq 'lap_distance'}).Count
        descriptor_name_stale_map_count=@($entries|Where-Object {
            [string]$_.name_source -eq 'lap_distance' -and @($_.descriptor_names) -notcontains [string]$_.primary_name
        }).Count
    }

    Write-Utf8Bom (Join-Path $catalogDir "catalog_meta.json") ($meta|ConvertTo-Json -Depth 8)
    Write-Utf8Bom (Join-Path $catalogDir "map_index.json") ($minimal.ToArray()|ConvertTo-Json -Depth 8)
    Write-Utf8Bom (Join-Path $catalogDir "duplicate_names.json") ($duplicates.ToArray()|ConvertTo-Json -Depth 8)
    Write-Utf8Bom (Join-Path $catalogDir "alias_collisions.json") ($aliasCollisions.ToArray()|ConvertTo-Json -Depth 8)

    $minimal.ToArray() |
        Select-Object map_id,primary_name,name_status |
        Export-Csv -LiteralPath (Join-Path $catalogDir "maps.csv") -NoTypeInformation -Encoding UTF8

    $descExport.ToArray() |
        Export-Csv -LiteralPath (Join-Path $catalogDir "descriptor_versions.csv") -NoTypeInformation -Encoding UTF8

    $entries.ToArray() | Where-Object {
        [string]::IsNullOrWhiteSpace($_.primary_name) -or $_.name_status -eq "multiple_descriptor_names"
    } |
        Select-Object map_id,primary_name,name_status,descriptor_versions,descriptor_parse_failures |
        Export-Csv -LiteralPath (Join-Path $catalogDir "unresolved_maps.csv") -NoTypeInformation -Encoding UTF8

    Write-Host "[5/5] Catalog complete."
    Write-Host ("  Map IDs: "+$entries.Count)
    Write-Host ("  Exact named maps: "+$meta.exact_named_map_count)
    Write-Host ("  Unnamed/ambiguous IDs: "+$meta.unnamed_map_count)
    Write-Host ("  Duplicate exact names: "+$duplicates.Count)
    Write-Host ("  Alias collisions: "+$aliasCollisions.Count)
    Write-Host ("  Resource-declared identity: "+$meta.declared_identity_map_count+" folders ("+$meta.declared_identity_conflict_count+" conflicting)")
    Write-Host ("  Declared-name identity: "+$meta.declared_name_used_map_count+" folders; stale descriptor names: "+$meta.descriptor_name_stale_map_count)
    Log ("Catalog built: maps="+$entries.Count+" named="+$meta.exact_named_map_count+" duplicates="+$duplicates.Count)

    return $entries.ToArray()
}

function Ensure-Catalog {
    $metaPath=Join-Path $catalogDir "catalog_meta.json"
    $catPath=Join-Path $catalogDir "map_index.json"

    if(-not (Test-Path -LiteralPath $metaPath) -or -not (Test-Path -LiteralPath $catPath)) {
        throw "地图目录不存在。请进入‘地图测试’执行‘完整重建地图目录’。"
    }

    try {
        $parsed=Get-Content -LiteralPath $catPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @(ConvertTo-FlatObjectArray $parsed)
    } catch {
        throw "地图目录读取失败。请进入‘地图测试’执行‘完整重建地图目录’。"
    }
}

function Repair-MapNamesFast {
    $metaPath=Join-Path $catalogDir "catalog_meta.json"
    $catPath=Join-Path $catalogDir "map_index.json"
    if(-not (Test-Path -LiteralPath $catPath)) {
        throw "地图目录不存在，无法快速修复。请先完整重建一次。"
    }

    Write-Host "[1/4] 读取现有地图目录与 descriptor 缓存..."
    $catalog=@(ConvertTo-FlatObjectArray (Get-Content -LiteralPath $catPath -Raw -Encoding UTF8 | ConvertFrom-Json))
    $cacheFiles=@(Get-ChildItem -LiteralPath $descriptorCacheDir -File -Filter "*.luc" -ErrorAction SilentlyContinue)
    if($cacheFiles.Count -eq 0) {
        throw "没有 descriptor 缓存。请先运行‘导出未识别地图格式诊断’，之后再执行快速修复。"
    }
    Write-Host ("  地图条目: "+$catalog.Count+"；缓存 descriptor: "+$cacheFiles.Count)

    Write-Host "[2/4] 解析缓存中的 map_desc.luc..."
    $parsedCache=New-Object System.Collections.Generic.List[object]
    foreach($f in $cacheFiles) {
        $m=[regex]::Match($f.Name,'^Map(\d+)_')
        if(-not $m.Success){continue}
        $mid=[int]$m.Groups[1].Value
        try {
            $bytes=[IO.File]::ReadAllBytes($f.FullName)
            $info=[QQMapCatalogCore]::ParseDescriptorBytes($mid,$f.Name,$bytes)
            $parsedCache.Add($info)
        } catch {}
    }
    $ok=@($parsedCache.ToArray()|Where-Object {$_.Parsed}).Count
    Write-Host ("  成功解析: "+$ok+" / "+$parsedCache.Count)

    Write-Host "[3/4] 读取当前 IIPS 哈希并修补名称..."
    $iips=@(Read-IipsIndex)
    $currentDesc=@{}
    foreach($r in $iips) {
        if([string]$r.relative_path -ine 'map_desc.luc'){continue}
        $mid=[int]$r.map_id
        if(-not $currentDesc.ContainsKey($mid)) {
            $currentDesc[$mid]=New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        }
        if(([string]$r.file_md5) -match '^[0-9A-F]{32}$') {[void]$currentDesc[$mid].Add(([string]$r.file_md5).ToUpperInvariant())}
    }

    $changed=0
    foreach($e in $catalog) {
        $mid=[int]$e.map_id
        $cand=@($parsedCache.ToArray()|Where-Object {[int]$_.MapId -eq $mid -and $_.Parsed -and -not [string]::IsNullOrWhiteSpace([string]$_.MapName)})
        if($cand.Count -eq 0){continue}

        $allNames=@($cand|ForEach-Object {[string]$_.MapName}|Sort-Object -Unique)
        $matched=@()
        if($currentDesc.ContainsKey($mid)) {
            $hs=$currentDesc[$mid]
            $matched=@($cand|Where-Object {$hs.Contains(([string]$_.Md5).ToUpperInvariant())})
        }
        $matchedNames=@($matched|ForEach-Object {[string]$_.MapName}|Sort-Object -Unique)

        $declaredNames=@()
        if($e.PSObject.Properties['declared_names']){ $declaredNames=@($e.declared_names) }
        $declaredUsable=@($declaredNames|Where-Object {Test-MapDeclaredNameUsable $_})
        $declaredIdentity=($declaredUsable.Count -gt 0)

        $old=[string]$e.primary_name
        $new=$old
        $status=[string]$e.name_status
        # A resource-declared identity (`LapDistanceFile.luc`) outranks the descriptor cache: the
        # fast repair must not push a stale `map_desc.map_name` back as the identity name.
        if(-not $declaredIdentity) {
            if($matchedNames.Count -eq 1) {
                $new=$matchedNames[0]
                $status='iips_md5_exact_cached'
            } elseif($matchedNames.Count -gt 1) {
                $new=''
                $status='multiple_current_descriptor_names'
            } elseif($allNames.Count -eq 1 -and [string]::IsNullOrWhiteSpace($old)) {
                $new=$allNames[0]
                $status='single_exact_cached_name'
            }
        }

        $descriptorNames=@()
        if($e.PSObject.Properties['descriptor_names']){ $descriptorNames=@($e.descriptor_names) }
        $descriptorMerged=@(($descriptorNames + $allNames) | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)} | ForEach-Object {[string]$_} | Sort-Object -Unique)
        $merged=$(if($declaredIdentity){@($declaredUsable)}else{@($descriptorMerged)})
        $aliases=@($merged | ForEach-Object {Get-MapDisplayAlias ([string]$_)} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | Sort-Object -Unique)
        # Older catalog schemas do not contain normalized_primary_name.
        # Use Add-Member -Force so fast repair also performs an in-place schema migration
        # instead of requiring a full VFS rebuild.
        $e | Add-Member -NotePropertyName primary_name -NotePropertyValue $new -Force
        $e | Add-Member -NotePropertyName normalized_primary_name -NotePropertyValue (Normalize-MapName $new) -Force
        $e | Add-Member -NotePropertyName name_status -NotePropertyValue $status -Force
        $e | Add-Member -NotePropertyName all_names -NotePropertyValue $merged -Force
        $e | Add-Member -NotePropertyName descriptor_names -NotePropertyValue $descriptorMerged -Force
        $e | Add-Member -NotePropertyName display_aliases -NotePropertyValue $aliases -Force
        if($old -ne $new){$changed++}
    }

    # Update descriptor_versions.csv with newly parsed cached records when hashes match.
    $descCsv=Join-Path $catalogDir 'descriptor_versions.csv'
    if(Test-Path -LiteralPath $descCsv) {
        try {
            $rows=@(Import-Csv -LiteralPath $descCsv -Encoding UTF8)
            foreach($r in $rows) {
                $mid=[int]$r.map_id
                $md5=([string]$r.md5).ToUpperInvariant()
                $hit=@($parsedCache.ToArray()|Where-Object {[int]$_.MapId -eq $mid -and ([string]$_.Md5).ToUpperInvariant() -eq $md5}|Select-Object -First 1)
                if($hit.Count -gt 0) {
                    $r.parsed=[string][bool]$hit[0].Parsed
                    $r.map_name=[string]$hit[0].MapName
                    $r.parse_status=[string]$hit[0].ParseStatus
                }
            }
            $rows|Export-Csv -LiteralPath $descCsv -NoTypeInformation -Encoding UTF8
        } catch {}
    }

    # Recompute derived indexes without touching VFS.
    $nameIndex=@{}
    foreach($e in $catalog) {
        foreach($n in @($e.all_names)) {
            $k=Normalize-MapName ([string]$n)
            if([string]::IsNullOrWhiteSpace($k)){continue}
            if(-not $nameIndex.ContainsKey($k)){$nameIndex[$k]=New-Object System.Collections.Generic.List[int]}
            if(-not $nameIndex[$k].Contains([int]$e.map_id)){$nameIndex[$k].Add([int]$e.map_id)}
        }
    }
    $duplicates=New-Object System.Collections.Generic.List[object]
    foreach($k in @($nameIndex.Keys|Sort-Object)) {
        if($nameIndex[$k].Count -gt 1){$duplicates.Add([pscustomobject]@{normalized_name=$k;map_ids=@($nameIndex[$k]|Sort-Object)})}
    }

    $aliasIndex=@{}
    foreach($e in $catalog) {
        foreach($a in @($e.display_aliases)) {
            $k=Normalize-MapName ([string]$a)
            if([string]::IsNullOrWhiteSpace($k)){continue}
            if(-not $aliasIndex.ContainsKey($k)){$aliasIndex[$k]=New-Object System.Collections.Generic.List[int]}
            if(-not $aliasIndex[$k].Contains([int]$e.map_id)){$aliasIndex[$k].Add([int]$e.map_id)}
        }
    }
    $aliasCollisions=New-Object System.Collections.Generic.List[object]
    foreach($k in @($aliasIndex.Keys|Sort-Object)) {
        if($aliasIndex[$k].Count -gt 1){$aliasCollisions.Add([pscustomobject]@{alias_name=$k;map_ids=@($aliasIndex[$k]|Sort-Object)})}
    }

    Write-Utf8Bom $catPath ($catalog|ConvertTo-Json -Depth 8)
    Write-Utf8Bom (Join-Path $catalogDir 'duplicate_names.json') ($duplicates.ToArray()|ConvertTo-Json -Depth 8)
    Write-Utf8Bom (Join-Path $catalogDir 'alias_collisions.json') ($aliasCollisions.ToArray()|ConvertTo-Json -Depth 8)
    $catalog|Select-Object map_id,primary_name,name_status|Export-Csv -LiteralPath (Join-Path $catalogDir 'maps.csv') -NoTypeInformation -Encoding UTF8
    $catalog | Where-Object {[string]::IsNullOrWhiteSpace([string]$_.primary_name) -or [string]$_.name_status -like 'multiple*'} | Select-Object map_id,primary_name,name_status | Export-Csv -LiteralPath (Join-Path $catalogDir 'unresolved_maps.csv') -NoTypeInformation -Encoding UTF8

    $meta=$null
    if(Test-Path -LiteralPath $metaPath) {
        try {$meta=Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8|ConvertFrom-Json} catch {}
    }
    if($null -eq $meta){$meta=[pscustomobject]@{}}
    $meta|Add-Member -NotePropertyName schema_version -NotePropertyValue 6 -Force
    $meta|Add-Member -NotePropertyName reader_revision -NotePropertyValue 3 -Force
    $meta|Add-Member -NotePropertyName last_name_repair_at -NotePropertyValue ((Get-Date).ToString('o')) -Force
    $meta|Add-Member -NotePropertyName map_id_count -NotePropertyValue $catalog.Count -Force
    $meta|Add-Member -NotePropertyName exact_named_map_count -NotePropertyValue (@($catalog|Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_.primary_name)}).Count) -Force
    $meta|Add-Member -NotePropertyName unnamed_map_count -NotePropertyValue (@($catalog|Where-Object {[string]::IsNullOrWhiteSpace([string]$_.primary_name)}).Count) -Force
    $meta|Add-Member -NotePropertyName duplicate_name_count -NotePropertyValue $duplicates.Count -Force
    $meta|Add-Member -NotePropertyName alias_collision_count -NotePropertyValue $aliasCollisions.Count -Force
    Write-Utf8Bom $metaPath ($meta|ConvertTo-Json -Depth 8)

    Write-Host "[4/4] 快速修复完成。"
    Write-Host ("  名称发生变化: "+$changed)
    Write-Host ("  当前有名称地图: "+$meta.exact_named_map_count)
    Write-Host ("  当前未识别地图: "+$meta.unnamed_map_count)
    Write-Host "  本次没有扫描全部 VFS。"
}

