function Try-ReplayDataMapMatch([string]$ReplayPath,[object[]]$AllowedIds) {
    $time=Get-ReplayTimeFromName $ReplayPath
    if($null -eq $time){return $null}

    $dir=Join-Path $GamePath "Userdata\ReplayData"
    if(-not (Test-Path -LiteralPath $dir -PathType Container)){return $null}

    $allowedSet=New-Object System.Collections.Generic.HashSet[int]
    foreach($v in @(ConvertTo-FlatObjectArray $AllowedIds)) {
        try { [void]$allowedSet.Add([int]$v) } catch {}
    }

    $rows=New-Object System.Collections.Generic.List[object]
    foreach($f in @(Get-ChildItem -LiteralPath $dir -File -Filter "race_*.json" -ErrorAction SilentlyContinue)) {
        $delta=[Math]::Abs(($f.LastWriteTime-$time).TotalMinutes)
        if($delta -gt 30){continue}

        try {
            $o=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $id=[int]$o.meta.map_id
            if($allowedSet.Count -gt 0 -and -not $allowedSet.Contains($id)){continue}
            $rows.Add([PSCustomObject]@{
                map_id=$id
                delta_minutes=$delta
            })
        } catch {}
    }

    if($rows.Count -eq 0){return $null}

    $near=@($rows|Where-Object {$_.delta_minutes -le 10})
    $ids=@($near|Select-Object -ExpandProperty map_id -Unique)
    if($ids.Count -eq 1) {
        return [PSCustomObject]@{
            map_id=[int]$ids[0]
            method="ReplayData timestamp correlation"
            confidence="high"
            delta_minutes=(@($near|Where-Object {$_.map_id -eq $ids[0]}|Measure-Object delta_minutes -Minimum).Minimum)
        }
    }

    $sorted=@($rows|Sort-Object delta_minutes)
    if($sorted.Count -ge 1 -and $sorted[0].delta_minutes -le 2) {
        if($sorted.Count -eq 1 -or $sorted[1].map_id -eq $sorted[0].map_id -or
           $sorted[1].delta_minutes -ge ($sorted[0].delta_minutes+2)) {
            return [PSCustomObject]@{
                map_id=[int]$sorted[0].map_id
                method="ReplayData nearest timestamp"
                confidence="medium"
                delta_minutes=$sorted[0].delta_minutes
            }
        }
    }

    return $null
}

function Save-ReplayResolution(
    [string]$ReplayPath,
    [string]$MapHint,
    [object[]]$Candidates,
    [object]$ResolvedId,
    [string]$Method,
    [string]$Confidence,
    [object]$GameMapId=$null
) {
    $hash=(Get-FileHash -LiteralPath $ReplayPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $short=$hash.Substring(0,16)
    $time=Get-ReplayTimeFromName $ReplayPath

    $candidateIds=New-Object System.Collections.Generic.List[int]
    foreach($c in @(ConvertTo-FlatObjectArray $Candidates)) {
        try {
            $vals=@($c.map_id)
            foreach($v in $vals) {
                if($null -ne $v){ $candidateIds.Add([int]$v) }
            }
        } catch {}
    }

    $resolvedValue=$null
    if($null -ne $ResolvedId) {
        $rv=@(ConvertTo-FlatObjectArray $ResolvedId)
        if($rv.Count -eq 1) {
            try { $resolvedValue=[int]$rv[0] } catch { $resolvedValue=$null }
        }
    }

    $obj=[ordered]@{
        replay_sha256=$hash
        map_hint=$MapHint
        replay_time_from_filename=$(if($null -ne $time){$time.ToString("s")}else{$null})
        candidate_map_ids=@($candidateIds.ToArray()|Sort-Object -Unique)
        game_map_id=$(if($null-ne$GameMapId){try{[int]$GameMapId}catch{$null}}else{$null})
        resolved_map_id=$resolvedValue
        resolution_method=$Method
        confidence=$Confidence
        note="Player/account suffix from replay filename is not persisted."
    }

    Write-Utf8Bom (Join-Path $resolutionDir ($short+".json")) ($obj|ConvertTo-Json -Depth 8)
}

function Get-MapDetailOnDemand([int]$MapId) {
    Write-Host ("  Loading resource detail on demand for Map"+$MapId+"...")
    $nodes=@([QQMapCatalogCore]::ParseAllMapNodes($GamePath))
    $prefix=("Map\Common Map\Map{0}\" -f $MapId)
    $local=@($nodes|Where-Object {$_.FullPath.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)})

    $descriptors=@([QQMapCatalogCore]::ParseMapDescriptors($local))
    $detail=[ordered]@{
        map_id=$MapId
        descriptor_versions=@($descriptors|ForEach-Object {
            [PSCustomObject]@{
                map_name=$_.MapName
                parsed=$_.Parsed
                parse_status=$_.ParseStatus
                vfs=$_.Vfs
                md5=$_.Md5
            }
        })
        local_resources=@($local|ForEach-Object {$_.FullPath.Substring($prefix.Length)}|Sort-Object -Unique)
    }

    $detailDir=Join-Path $dataDir "Diagnostics\MapDetails"
    New-Item -ItemType Directory -Force -Path $detailDir | Out-Null
    $path=Join-Path $detailDir ("Map"+$MapId+".json")
    Write-Utf8Bom $path ($detail|ConvertTo-Json -Depth 10)
    return $detail
}

function Get-ManualDisplayAliases {
    if(-not (Test-Path -LiteralPath $manualAliasPath -PathType Leaf)){ return @() }
    try { return @(ConvertTo-FlatObjectArray (Get-Content -LiteralPath $manualAliasPath -Raw -Encoding UTF8 | ConvertFrom-Json)) }
    catch { return @() }
}

function Save-ConfirmedDisplayAlias([string]$DisplayName,[int]$MapId,[string]$Evidence) {
    $items=@(Get-ManualDisplayAliases)
    $norm=Normalize-MapName $DisplayName
    $kept=@($items|Where-Object {
        $n=if($_.normalized_name){[string]$_.normalized_name}else{Normalize-MapName ([string]$_.display_name)}
        $n -ne $norm
    })
    $new=[pscustomobject][ordered]@{
        display_name=$DisplayName
        normalized_name=$norm
        map_id=$MapId
        evidence=$Evidence
        confirmed_at=(Get-Date).ToString('o')
    }
    Write-Utf8Bom $manualAliasPath (@($kept)+@($new)|ConvertTo-Json -Depth 8)
}

function Probe-MapNames([string[]]$Names) {
    $catalog=@(Ensure-Catalog)
    $manual=@(Get-ManualDisplayAliases)
    $out=New-Object System.Collections.Generic.List[object]

    foreach($name in $Names) {
        if([string]::IsNullOrWhiteSpace($name)){continue}
        $norm=Normalize-MapName $name

        foreach($entry in $catalog) {
            $mid=[int]$entry.map_id
            foreach($n in @($entry.all_names)) {
                if((Normalize-MapName ([string]$n)) -eq $norm) {
                    $out.Add([PSCustomObject]@{query=$name;map_id=$mid;evidence='catalog exact map_name';known_name=[string]$entry.primary_name})
                    break
                }
            }
            foreach($a in @($entry.display_aliases)) {
                if((Normalize-MapName ([string]$a)) -eq $norm -and (Normalize-MapName ([string]$entry.primary_name)) -ne $norm) {
                    $out.Add([PSCustomObject]@{query=$name;map_id=$mid;evidence='catalog derived display alias';known_name=[string]$entry.primary_name})
                    break
                }
            }
        }

        foreach($m in $manual) {
            $mn=if($m.normalized_name){[string]$m.normalized_name}else{Normalize-MapName ([string]$m.display_name)}
            if($mn -eq $norm) {
                $mid=[int]$m.map_id
                $entry=@($catalog|Where-Object {[int]$_.map_id -eq $mid}|Select-Object -First 1)
                $out.Add([PSCustomObject]@{query=$name;map_id=$mid;evidence='confirmed display-name binding';known_name=$(if($entry.Count -gt 0){[string]$entry[0].primary_name}else{''})})
            }
        }

        # Descriptor raw-text search remains diagnostic only. Generic resource-name tokens
        # are intentionally NOT used: words such as "power" produced unrelated false positives.
        $diagIds=@([QQMapCatalogCore]::SearchDescriptorTextIds($GamePath,$name))
        foreach($mid in $diagIds) {
            $entry=@($catalog|Where-Object {[int]$_.map_id -eq [int]$mid}|Select-Object -First 1)
            $out.Add([PSCustomObject]@{
                query=$name
                map_id=[int]$mid
                evidence='map_desc raw text contains query (diagnostic only)'
                known_name=$(if($entry.Count -gt 0){$entry[0].primary_name}else{''})
            })
        }
    }

    $dedup=@($out.ToArray()|Sort-Object query,map_id,evidence -Unique)
    $probeDir=Join-Path $dataDir 'Diagnostics\NameProbe'
    New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
    $json=Join-Path $probeDir 'probe_results.json'
    Write-Utf8Bom $json ($dedup|ConvertTo-Json -Depth 8)
    $dedup|Export-Csv -LiteralPath (Join-Path $probeDir 'probe_results.csv') -NoTypeInformation -Encoding UTF8

    if($dedup.Count -eq 0) {
        Write-Host 'Name probe results: 0'
        Write-Host '  当前 map_desc / 已确认别名中没有这个显示名。'
        Write-Host '  已禁用 resource path token 猜测，避免 power/factory 等通用资源名产生假候选。'
    } else {
        Write-Host ('Name probe results: '+$dedup.Count)
        foreach($r in $dedup) {
            $known=$(if([string]::IsNullOrWhiteSpace([string]$r.known_name)){'未识别'}else{[string]$r.known_name})
            Write-Host ('  '+$r.query+' -> Map'+$r.map_id+' ['+$r.evidence+']  catalog='+$known)
        }
    }
    Write-Host ('Output: '+$probeDir)
}

