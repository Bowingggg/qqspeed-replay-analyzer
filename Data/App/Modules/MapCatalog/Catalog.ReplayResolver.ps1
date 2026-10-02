function Get-TrustedRoomCatalogHintFromReplayName([string]$ReplayPath) {
    if([string]::IsNullOrWhiteSpace($ReplayPath)){ return $null }
    if($null -eq (Get-Command GRB-LoadRoomCatalogSnapshot -ErrorAction SilentlyContinue)){ return $null }
    $stem=[IO.Path]::GetFileNameWithoutExtension($ReplayPath)
    if([string]::IsNullOrWhiteSpace($stem)){ return $null }
    $stemNorm=Normalize-MapName $stem
    try{$snapshot=GRB-LoadRoomCatalogSnapshot}catch{return $null}
    $roomCandidates=New-Object System.Collections.Generic.List[object]
    foreach($r in @(ConvertTo-FlatObjectArray $snapshot.records)) {
        if($null -eq $r -or $null -eq $r.game_map_id){continue}
        $name=[string]$r.name
        $norm=Normalize-MapName $name
        if([string]::IsNullOrWhiteSpace($norm)){continue}
        $ok=$false
        if([string]::Equals($stemNorm,$norm,[StringComparison]::OrdinalIgnoreCase)){$ok=$true}
        elseif($stemNorm.Length -gt $norm.Length -and $stemNorm.StartsWith($norm,[StringComparison]::OrdinalIgnoreCase)) {
            $next=$stemNorm.Substring($norm.Length,1)
            if($next -match '[-_‐‑–—－\s\(\[【（]'){$ok=$true}
        }
        if($ok){
            $roomCandidates.Add([pscustomobject][ordered]@{name=$name;normalized_name=$norm;game_map_id=[int]$r.game_map_id;name_length=$norm.Length})
        }
    }
    if($roomCandidates.Count -eq 0){return $null}
    $maxLen=($roomCandidates.ToArray()|Measure-Object name_length -Maximum).Maximum
    $best=@($roomCandidates.ToArray()|Where-Object {$_.name_length -eq $maxLen})
    $ids=@($best|ForEach-Object {[int]$_.game_map_id}|Sort-Object -Unique)
    $names=@($best|ForEach-Object {[string]$_.name}|Sort-Object -Unique)
    if($ids.Count -ne 1 -or $names.Count -ne 1){return $null}
    return [pscustomobject][ordered]@{
        name=[string]$names[0]
        game_map_id=[int]$ids[0]
        source='trusted_room_catalog_filename_prefix'
    }
}

# Tier decision for one replay. Pure: it takes the catalog and the already-resolved tier evidence
# (trusted room hint + authoritative Game->Resource binding) and returns the decision. Keeping the
# decision separate from `Save-ReplayResolution` is what makes the "a filename hint must never
# suppress the higher-authority tier 0" contract testable without the real catalog or replays.
#
# Authority order (Native-First, decisions/0001 + docs/MAP_IDENTITY_AUDIT.md):
#   tier 0  trusted room-catalog display name -> Game MapID -> verified Resource binding
#   tier 1  exact official map_desc.map_name catalog match
#   tier 2  unresolved (no guessing)
function Get-ReplayMapResolutionDecision {
    param(
        [Parameter(Mandatory=$true)][string]$ReplayPath,
        [AllowEmptyCollection()][object[]]$Catalog=@(),
        [object]$RoomHint=$null,
        [object]$VerifiedBinding=$null,
        # Persistent user-confirmed Game->Resource binding. Same authority class as the verified
        # binding for resolution purposes (tier 0) but reported with its own confidence, because the
        # evidence really is "a human confirmed it", not "the official resources proved it".
        [object]$UserConfirmedBinding=$null
    )
    $filenameHint=Get-MapHintFromReplayName $ReplayPath
    $roomHintName=$(if($null-ne$RoomHint){[string]$RoomHint.name}else{''})
    $roomHintGameMapId=$(if($null-ne$RoomHint){[int]$RoomHint.game_map_id}else{$null})
    $hint=$filenameHint
    $hintSource='filename'
    if([string]::IsNullOrWhiteSpace($hint) -and $null-ne$RoomHint){$hint=$roomHintName;$hintSource='trusted_room_catalog'}
    $norm=Normalize-MapName $hint
    $catalog=@($Catalog)

    # Tier 0. Promotion requires BOTH a single structured room-catalog Game MapID and an
    # authoritative Game -> Resource binding; the filename text alone is never identity.
    if($null-ne$RoomHint-and$null-ne$VerifiedBinding){
        $rid=[int]$VerifiedBinding.resource_map_id
        $byId=@($catalog|Where-Object {[int]$_.map_id -eq $rid})
        return [pscustomobject][ordered]@{
            tier=0
            hint=$hint
            filename_hint=$filenameHint
            room_hint_name=$roomHintName
            room_hint_game_map_id=$roomHintGameMapId
            hint_source=$hintSource
            resolved_map_id=$rid
            candidates=$byId
            method='trusted room catalog filename prefix + verified game/resource binding'
            confidence='verified'
            game_map_id=[int]$RoomHint.game_map_id
        }
    }

    # Tier 0 (user-confirmed). Reached only when the official resources provide no authoritative
    # binding AND the user has explicitly confirmed one for this GameMapID. Never inferred.
    if($null-ne$RoomHint-and$null-ne$UserConfirmedBinding){
        $rid=[int]$UserConfirmedBinding.resource_map_id
        $byId=@($catalog|Where-Object {[int]$_.map_id -eq $rid})
        return [pscustomobject][ordered]@{
            tier=0
            hint=$hint
            filename_hint=$filenameHint
            room_hint_name=$roomHintName
            room_hint_game_map_id=$roomHintGameMapId
            hint_source=$hintSource
            resolved_map_id=$rid
            candidates=$byId
            method='trusted room catalog filename prefix + user-confirmed game/resource binding'
            confidence='user_confirmed'
            game_map_id=[int]$RoomHint.game_map_id
        }
    }

    # Tier 1.
    $exact=@($catalog|Where-Object {
        $matched=$false
        foreach($n in @($_.all_names)) {
            if((Normalize-MapName ([string]$n)) -eq $norm){$matched=$true;break}
        }
        $matched
    })
    $gameMapId=$null
    if($null-ne$RoomHint){$gameMapId=[int]$RoomHint.game_map_id}
    if($exact.Count -eq 1) {
        return [pscustomobject][ordered]@{
            tier=1
            hint=$hint
            filename_hint=$filenameHint
            room_hint_name=$roomHintName
            room_hint_game_map_id=$roomHintGameMapId
            hint_source=$hintSource
            resolved_map_id=[int]$exact[0].map_id
            candidates=$exact
            method='exact map_desc.map_name catalog match'
            confidence='high'
            game_map_id=$gameMapId
        }
    }
    if($exact.Count -gt 1) {
        return [pscustomobject][ordered]@{
            tier=1
            hint=$hint
            filename_hint=$filenameHint
            room_hint_name=$roomHintName
            room_hint_game_map_id=$roomHintGameMapId
            hint_source=$hintSource
            resolved_map_id=$null
            candidates=$exact
            method='duplicate exact map_desc.map_name'
            confidence='unresolved'
            game_map_id=$gameMapId
        }
    }

    # Tier 2: v3 Native-First stops here. No dynamic alias guess, descriptor-text scan,
    # duration/fingerprint fit, 0xD6 interpretation, collision match, or replay geometry match.
    return [pscustomobject][ordered]@{
        tier=2
        hint=$hint
        filename_hint=$filenameHint
        room_hint_name=$roomHintName
        room_hint_game_map_id=$roomHintGameMapId
        hint_source=$hintSource
        resolved_map_id=$null
        candidates=@()
        method='native-first: no authoritative identity match'
        confidence='unresolved'
        game_map_id=$gameMapId
    }
}

function Resolve-Replays {
    $catalog=@(ConvertTo-FlatObjectArray (Ensure-Catalog))

    if(-not $ReplayFiles -or $ReplayFiles.Count -eq 0) {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        $ofd=New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter="QQ飞车录像 (*.sav)|*.sav|All files (*.*)|*.*"
        $ofd.Multiselect=$true
        if($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:ReplayFiles=@($ofd.FileNames)
        }
    }

    $files=@($ReplayFiles|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf})
    if($files.Count -eq 0){throw "No replay selected."}

    if($catalog.Count -eq 0){throw "Map Catalog is empty after loading."}
    $shapeBad=@($catalog|Where-Object {$null -eq $_.map_id}).Count
    if($shapeBad -gt 0) {
        throw ("Map Catalog load shape is invalid: "+$shapeBad+" entries have no scalar map_id.")
    }
    Write-Host ("Catalog loaded: "+$catalog.Count+" map entries.")

    foreach($replay in $files) {
        Write-Host ""
        Write-Host ("Replay: "+[System.IO.Path]::GetFileName($replay))
        # Tier 0 evidence is derived independently of the display hint. A filename hint must never
        # suppress the higher-authority route (structured room-catalog name -> Game MapID ->
        # verified Game/Resource binding); skipping it only loses the recorded game_map_id.
        # The filename text still never becomes identity by itself: promotion happens only when
        # the room catalog yields one Game MapID and the generated binding marks it authoritative.
        $roomHint=Get-TrustedRoomCatalogHintFromReplayName $replay
        $binding=$null
        $userBinding=$null
        if($null -ne $roomHint) {
            $binding=MI-GetVerifiedResourceFromGameMapId -DataDir $dataDir -GameMapId $roomHint.game_map_id
            # Only consulted when the official resources have no authoritative binding. The user's
            # explicit confirmation is the last resort before staying unresolved; it is never
            # inferred from a near name, an offset relation or replay geometry.
            if($null -eq $binding) {
                if($null -ne (Get-Command Get-GRBUserConfirmedBindingForGameMapId -ErrorAction SilentlyContinue)) {
                    $userBinding=Get-GRBUserConfirmedBindingForGameMapId -DataDir $dataDir -GameMapId $roomHint.game_map_id
                }
            }
        }
        $decision=Get-ReplayMapResolutionDecision -ReplayPath $replay -Catalog $catalog -RoomHint $roomHint -VerifiedBinding $binding -UserConfirmedBinding $userBinding
        $hint=[string]$decision.hint

        if([int]$decision.tier -eq 0) {
            Write-Host ('  Resolved by trusted room name + '+[string]$decision.confidence+' binding: '+$hint+' · Game '+$decision.game_map_id+' -> Map'+$decision.resolved_map_id)
        } elseif($null -ne $roomHint) {
            Write-Host ('  Trusted room name found: '+$hint+' · Game '+[string]$roomHint.game_map_id+'; no authoritative Resource binding, continuing resource-name lookup.')
        }

        if([int]$decision.tier -eq 0) {
            Save-ReplayResolution $replay $hint $decision.candidates $decision.resolved_map_id $decision.method $decision.confidence $decision.game_map_id
            continue
        }

        if([int]$decision.tier -eq 1 -and $null -ne $decision.resolved_map_id) {
            Write-Host ("  Resolved by exact catalog name: "+$hint+" -> Map"+[string]$decision.resolved_map_id)
            Save-ReplayResolution $replay $hint $decision.candidates $decision.resolved_map_id $decision.method $decision.confidence $decision.game_map_id
            continue
        }

        if([int]$decision.tier -eq 1) {
            $ids=@($decision.candidates|ForEach-Object {[int]$_.map_id})
            Write-Host ("  Exact map name maps to multiple IDs: "+($ids -join ", "))
            Write-Host "  保持未解析；ReplayData.meta.map_id 与资源 MapID 不是同一命名空间，不能用于消歧。"
            Save-ReplayResolution $replay $hint $decision.candidates $null $decision.method $decision.confidence $decision.game_map_id
            continue
        }

        # v3 Native-First: manual/display labels are UI metadata only and never physical identity.
        # Production stops after verified Game->Resource binding or exact official map_desc.map_name.
        # No dynamic alias guess, descriptor-text scan, duration/fingerprint fit, 0xD6
        # interpretation, collision match, or replay geometry match.
        Write-Host "  Unresolved: no authoritative native/official identity evidence."
        Save-ReplayResolution $replay $hint @() $null $decision.method $decision.confidence $decision.game_map_id
    }

    Write-Host ""
    Write-Host ("Resolution output: "+$resolutionDir)
}
