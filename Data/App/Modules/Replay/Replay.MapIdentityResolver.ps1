function MI-NormalizeName([string]$Name) {
    if([string]::IsNullOrWhiteSpace($Name)){return ''}
    $n=$Name.Trim()
    if($n -eq '未识别地图'){return ''}
    return $n.ToLowerInvariant()
}
function MI-TryInt($Value) {
    if($null -eq $Value){return $null}
    try{$i=[int]$Value;if($i -gt 0){return $i}}catch{}
    return $null
}
function Get-MapIdentityRegistryPath([string]$DataDir) {
    if([string]::IsNullOrWhiteSpace($DataDir)){throw 'Map Identity registry requires DataDir.'}
    return (Join-Path $DataDir 'NativeIdentity\map_registry.json')
}
function Read-MapIdentityRegistry([string]$DataDir) {
    $path=Get-MapIdentityRegistryPath $DataDir
    if(Test-Path -LiteralPath $path -PathType Leaf){
        try{$j=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json;if($null -ne $j){return $j}}catch{}
    }
    return [pscustomobject][ordered]@{schema_version=2;updated_at=$null;entries=@()}
}
function Write-MapIdentityRegistry([string]$DataDir,$Registry) {
    $path=Get-MapIdentityRegistryPath $DataDir
    $dir=Split-Path -Parent $path;New-Item -ItemType Directory -Force -Path $dir|Out-Null
    $tmp=$path+'.tmp';$enc=New-Object Text.UTF8Encoding -ArgumentList $true
    $Registry.schema_version=2;$Registry.updated_at=(Get-Date).ToString('o')
    [IO.File]::WriteAllText($tmp,(ConvertTo-Json -InputObject $Registry -Depth 12),$enc)
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}
function MI-GetManualName([string]$DataDir,$Analysis,[string]$AnalysisFile='') {
    if([string]::IsNullOrWhiteSpace($DataDir)){return ''}
    $path=Join-Path $DataDir 'manual_map_names.json'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return ''}
    try{$j=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return ''}
    if($null -eq $j){return ''}
    $keys=New-Object System.Collections.Generic.List[string]
    if($null -ne $Analysis){
        if(-not [string]::IsNullOrWhiteSpace([string]$Analysis.replay_sha256)){$keys.Add('sha:'+[string]$Analysis.replay_sha256)}
        if(-not [string]::IsNullOrWhiteSpace([string]$Analysis.replay_file)){$keys.Add('replay:'+[string]$Analysis.replay_file)}
    }
    if(-not [string]::IsNullOrWhiteSpace($AnalysisFile)){$keys.Add('file:'+$AnalysisFile);$keys.Add($AnalysisFile)}
    foreach($k in $keys.ToArray()){
        $p=$j.PSObject.Properties[[string]$k]
        if($null -ne $p -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)){return ([string]$p.Value).Trim()}
    }
    return ''
}
function MI-GetVerifiedResourceFromGameMapId([string]$DataDir,$GameMapId) {
    $gid=MI-TryInt $GameMapId
    if($null -eq $gid -or [string]::IsNullOrWhiteSpace($DataDir)){return $null}
    $path=Join-Path $DataDir 'MapCatalog\game_resource_bindings.json'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    try{$j=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
    $matches=@($j.bindings|Where-Object {
        (MI-TryInt $_.game_map_id) -eq $gid -and [bool]$_.authoritative_for_cross_namespace_binding -and $null -ne (MI-TryInt $_.resource_map_id)
    })
    $ids=@($matches|ForEach-Object {MI-TryInt $_.resource_map_id}|Where-Object {$null -ne $_}|Sort-Object -Unique)
    if($ids.Count -ne 1){return $null}
    $row=@($matches|Where-Object {(MI-TryInt $_.resource_map_id) -eq [int]$ids[0]}|Select-Object -First 1)
    return [pscustomobject][ordered]@{
        game_map_id=[int]$gid
        resource_map_id=[int]$ids[0]
        map_name=$(if($row.Count){[string]$row[0].map_name}else{''})
        binding_source=$(if($row.Count){[string]$row[0].binding_source}else{'verified_game_resource_binding'})
    }
}
# Persistent user-confirmed Game -> Resource binding. Consulted only when the official resources
# provide no authoritative binding, and reported with its own confidence because the evidence is an
# explicit human confirmation rather than an official name/anchor proof. Never inferred.
function MI-GetUserConfirmedResourceFromGameMapId([string]$DataDir,$GameMapId) {
    $gid=MI-TryInt $GameMapId
    if($null -eq $gid -or [string]::IsNullOrWhiteSpace($DataDir)){return $null}
    if($null -eq (Get-Command Get-GRBUserConfirmedBindingForGameMapId -ErrorAction SilentlyContinue)){return $null}
    $b=Get-GRBUserConfirmedBindingForGameMapId -DataDir $DataDir -GameMapId $gid
    if($null -eq $b){return $null}
    return [pscustomobject][ordered]@{
        game_map_id=[int]$gid
        resource_map_id=[int]$b.resource_map_id
        map_name=[string]$b.game_display_name
        binding_source='user_confirmed_game_resource_binding'
    }
}
function New-MapIdentityObject {
    param(
        [string]$CourseKey,[string]$Status,$ResourceMapId,$GameMapId,[string]$DisplayName,[string]$Source,
        [string]$Confidence='',[object[]]$Aliases=@(),[object[]]$Evidence=@()
    )
    $rid=MI-TryInt $ResourceMapId;$gid=MI-TryInt $GameMapId
    $resolved=($Status -eq 'resolved' -and $null -ne $rid -and -not [string]::IsNullOrWhiteSpace($CourseKey))
    return [pscustomobject][ordered]@{
        schema_version=3
        status=$Status
        resolved=$resolved
        course_key=$CourseKey
        resource_map_id=$rid
        game_map_id=$gid
        display_name=$DisplayName
        resolution_source=$Source
        confidence=$Confidence
        evidence=@($Evidence)
        aliases=@($Aliases|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)}|Select-Object -Unique)
        authoritative=$resolved
        immutable_when_resolved=$resolved
        identity_key=$CourseKey
        canonical_map_id=$rid
        canonical_name=$DisplayName
        source=$Source
        map_id=$rid
        map_name=$DisplayName
        rule='Same-map decisions compare course_key only. Only a resolved physical Resource MapID may create course_key. Names, manual labels, visual basemaps, collision geometry, and trajectory similarity are non-authoritative.'
    }
}
function MI-NewResolvedResourceIdentity($ResourceMapId,$GameMapId,[string]$DisplayName,[string]$Source,[string]$Confidence,[object[]]$Evidence=@()) {
    $rid=MI-TryInt $ResourceMapId
    if($null -eq $rid){return New-MapIdentityObject -CourseKey '' -Status 'unresolved' -ResourceMapId $null -GameMapId $GameMapId -DisplayName $DisplayName -Source $Source -Confidence $Confidence -Evidence $Evidence}
    return New-MapIdentityObject -CourseKey ('resource:'+$rid) -Status 'resolved' -ResourceMapId $rid -GameMapId $GameMapId -DisplayName $DisplayName -Source $Source -Confidence $Confidence -Aliases @($DisplayName) -Evidence $Evidence
}
function Resolve-ReplayMapIdentity {
    param($Resolution,$MapId,$GameMapId,[string]$MapName='',[string]$ReplaySha256='',[string]$ReplayFile='',[string]$AnalysisFile='',[string]$DataDir='')
    $resourceIds=New-Object System.Collections.Generic.List[int]
    $mid=MI-TryInt $MapId;if($null -ne $mid){$resourceIds.Add([int]$mid)}
    if($null -ne $Resolution){$rid=MI-TryInt $Resolution.resolved_map_id;if($null -ne $rid){$resourceIds.Add([int]$rid)}}
    $unique=@($resourceIds.ToArray()|Sort-Object -Unique)
    if($unique.Count -gt 1){return New-MapIdentityObject -CourseKey '' -Status 'conflicting' -ResourceMapId $null -GameMapId $GameMapId -DisplayName $MapName -Source 'conflicting_resource_map_ids' -Evidence @($unique|ForEach-Object{[ordered]@{kind='resource_map_id';value=$_}})}
    if($unique.Count -eq 1){
        $id=[int]$unique[0];$method=$(if($null -ne $Resolution){[string]$Resolution.resolution_method}else{'resource_map_id'});$confidence=$(if($null -ne $Resolution){[string]$Resolution.confidence}else{'resolved'})
        return MI-NewResolvedResourceIdentity -ResourceMapId $id -GameMapId $GameMapId -DisplayName $MapName -Source $method -Confidence $confidence -Evidence @([ordered]@{kind='resource_map_id';value=$id})
    }
    $binding=MI-GetVerifiedResourceFromGameMapId -DataDir $DataDir -GameMapId $GameMapId
    if($null -ne $binding){
        $name=$MapName;if([string]::IsNullOrWhiteSpace($name)){$name=[string]$binding.map_name}
        return MI-NewResolvedResourceIdentity -ResourceMapId $binding.resource_map_id -GameMapId $binding.game_map_id -DisplayName $name -Source 'verified_game_resource_binding' -Confidence 'verified' -Evidence @([ordered]@{kind='game_resource_binding';game_map_id=$binding.game_map_id;resource_map_id=$binding.resource_map_id;source=$binding.binding_source})
    }
    $userBinding=MI-GetUserConfirmedResourceFromGameMapId -DataDir $DataDir -GameMapId $GameMapId
    if($null -ne $userBinding){
        $name=$MapName;if([string]::IsNullOrWhiteSpace($name)){$name=[string]$userBinding.map_name}
        return MI-NewResolvedResourceIdentity -ResourceMapId $userBinding.resource_map_id -GameMapId $userBinding.game_map_id -DisplayName $name -Source 'user_confirmed_game_resource_binding' -Confidence 'user_confirmed' -Evidence @([ordered]@{kind='user_confirmed_game_resource_binding';game_map_id=$userBinding.game_map_id;resource_map_id=$userBinding.resource_map_id;provenance='user_confirmed'})
    }
    $stub=[pscustomobject]@{replay_sha256=$ReplaySha256;replay_file=$ReplayFile}
    $manual=MI-GetManualName -DataDir $DataDir -Analysis $stub -AnalysisFile $AnalysisFile
    if(-not [string]::IsNullOrWhiteSpace($manual)){return New-MapIdentityObject -CourseKey '' -Status 'manually_named' -ResourceMapId $null -GameMapId $GameMapId -DisplayName $manual -Source 'manual_map_name' -Confidence 'display_only' -Aliases @($manual) -Evidence @([ordered]@{kind='manual_name';value=$manual})}
    $norm=MI-NormalizeName $MapName
    if(-not [string]::IsNullOrWhiteSpace($norm)){return New-MapIdentityObject -CourseKey '' -Status 'named_unverified' -ResourceMapId $null -GameMapId $GameMapId -DisplayName $MapName -Source 'observed_name' -Confidence 'display_only' -Aliases @($MapName) -Evidence @([ordered]@{kind='observed_name';value=$MapName})}
    return New-MapIdentityObject -CourseKey '' -Status 'unresolved' -ResourceMapId $null -GameMapId $GameMapId -DisplayName '' -Source 'none'
}
function Resolve-AnalysisMapIdentity {
    param($Analysis,[string]$AnalysisFile='',[string]$DataDir='')
    if($null -eq $Analysis){return New-MapIdentityObject -CourseKey '' -Status 'unresolved' -ResourceMapId $null -GameMapId $null -DisplayName '' -Source 'missing_analysis'}
    $resourceIds=New-Object System.Collections.Generic.List[int]
    $identityName='';$identityResourceId=$null;$gameMapId=MI-TryInt $Analysis.game_map_id
    try{
        if($null -ne $Analysis.map_identity){
            $identityResourceId=MI-TryInt $(if($null -ne $Analysis.map_identity.resource_map_id){$Analysis.map_identity.resource_map_id}elseif($null -ne $Analysis.map_identity.canonical_map_id){$Analysis.map_identity.canonical_map_id}else{$Analysis.map_identity.map_id})
            $identityName=$(if(-not [string]::IsNullOrWhiteSpace([string]$Analysis.map_identity.display_name)){[string]$Analysis.map_identity.display_name}elseif(-not [string]::IsNullOrWhiteSpace([string]$Analysis.map_identity.canonical_name)){[string]$Analysis.map_identity.canonical_name}else{[string]$Analysis.map_identity.map_name})
            if($null -eq $gameMapId){$gameMapId=MI-TryInt $Analysis.map_identity.game_map_id}
            if([bool]$Analysis.map_identity.authoritative -and $null -ne $identityResourceId){$resourceIds.Add([int]$identityResourceId)}
            elseif(-not [string]::IsNullOrWhiteSpace([string]$Analysis.map_identity.course_key) -and ([string]$Analysis.map_identity.course_key -match '^resource:(\d+)$')){$resourceIds.Add([int]$Matches[1])}
            elseif(-not [string]::IsNullOrWhiteSpace([string]$Analysis.map_identity.identity_key) -and ([string]$Analysis.map_identity.identity_key -match '^(?:resource|map):(\d+)$')){$resourceIds.Add([int]$Matches[1])}
        }
    }catch{}
    $explicitResource=MI-TryInt $Analysis.resource_map_id;if($null -ne $explicitResource){$resourceIds.Add([int]$explicitResource)}
    $flatId=MI-TryInt $Analysis.map_id;if($null -ne $flatId){$resourceIds.Add([int]$flatId)}
    $unique=@($resourceIds.ToArray()|Sort-Object -Unique)
    if($unique.Count -gt 1){return New-MapIdentityObject -CourseKey '' -Status 'conflicting' -ResourceMapId $null -GameMapId $gameMapId -DisplayName $identityName -Source 'analysis_conflicting_resource_ids' -Evidence @($unique|ForEach-Object{[ordered]@{kind='resource_map_id';value=$_}})}
    if($unique.Count -eq 1){
        $id=[int]$unique[0];$name=$identityName;if([string]::IsNullOrWhiteSpace($name)){$name=[string]$Analysis.map_name}
        return MI-NewResolvedResourceIdentity -ResourceMapId $id -GameMapId $gameMapId -DisplayName $name -Source 'analysis_resource_map_id' -Confidence $(if($null -ne $Analysis.confidence){[string]$Analysis.confidence}else{'resolved'}) -Evidence @([ordered]@{kind='analysis_resource_map_id';value=$id})
    }
    $binding=MI-GetVerifiedResourceFromGameMapId -DataDir $DataDir -GameMapId $gameMapId
    if($null -ne $binding){
        $name=$identityName;if([string]::IsNullOrWhiteSpace($name)){$name=[string]$Analysis.map_name};if([string]::IsNullOrWhiteSpace($name)){$name=[string]$binding.map_name}
        return MI-NewResolvedResourceIdentity -ResourceMapId $binding.resource_map_id -GameMapId $binding.game_map_id -DisplayName $name -Source 'verified_game_resource_binding' -Confidence 'verified' -Evidence @([ordered]@{kind='game_resource_binding';game_map_id=$binding.game_map_id;resource_map_id=$binding.resource_map_id;source=$binding.binding_source})
    }
    $userBinding=MI-GetUserConfirmedResourceFromGameMapId -DataDir $DataDir -GameMapId $gameMapId
    if($null -ne $userBinding){
        $name=$identityName;if([string]::IsNullOrWhiteSpace($name)){$name=[string]$Analysis.map_name};if([string]::IsNullOrWhiteSpace($name)){$name=[string]$userBinding.map_name}
        return MI-NewResolvedResourceIdentity -ResourceMapId $userBinding.resource_map_id -GameMapId $userBinding.game_map_id -DisplayName $name -Source 'user_confirmed_game_resource_binding' -Confidence 'user_confirmed' -Evidence @([ordered]@{kind='user_confirmed_game_resource_binding';game_map_id=$userBinding.game_map_id;resource_map_id=$userBinding.resource_map_id;provenance='user_confirmed'})
    }
    $manual=MI-GetManualName -DataDir $DataDir -Analysis $Analysis -AnalysisFile $AnalysisFile
    if(-not [string]::IsNullOrWhiteSpace($manual)){return New-MapIdentityObject -CourseKey '' -Status 'manually_named' -ResourceMapId $null -GameMapId $gameMapId -DisplayName $manual -Source 'manual_map_name' -Confidence 'display_only' -Aliases @($manual)}
    $name=$identityName;if([string]::IsNullOrWhiteSpace($name)){$name=[string]$Analysis.map_name}
    $norm=MI-NormalizeName $name
    if(-not [string]::IsNullOrWhiteSpace($norm)){return New-MapIdentityObject -CourseKey '' -Status 'named_unverified' -ResourceMapId $null -GameMapId $gameMapId -DisplayName $name -Source 'observed_name' -Confidence 'display_only' -Aliases @($name)}
    return New-MapIdentityObject -CourseKey '' -Status 'unresolved' -ResourceMapId $null -GameMapId $gameMapId -DisplayName '' -Source 'none'
}
function Compare-MapIdentity($Left,$Right) {
    if($null -eq $Left -or $null -eq $Right){return 'UNKNOWN'}
    $lk=[string]$Left.course_key;$rk=[string]$Right.course_key
    if([string]::IsNullOrWhiteSpace($lk) -or [string]::IsNullOrWhiteSpace($rk)){return 'UNKNOWN'}
    if([string]::Equals($lk,$rk,[StringComparison]::OrdinalIgnoreCase)){return 'SAME'}
    return 'DIFFERENT'
}
function Update-MapIdentityRegistry([string]$DataDir,$Identity) {
    if($null -eq $Identity -or [string]::IsNullOrWhiteSpace([string]$Identity.course_key)){return $null}
    $registry=Read-MapIdentityRegistry $DataDir;$entries=New-Object System.Collections.Generic.List[object]
    foreach($e in @($registry.entries)){if([string]$e.course_key -ne [string]$Identity.course_key -and [string]$e.identity_key -ne [string]$Identity.course_key){$entries.Add($e)}}
    $entries.Add([pscustomobject][ordered]@{
        course_key=[string]$Identity.course_key;resource_map_id=$Identity.resource_map_id;game_map_id=$Identity.game_map_id
        display_name=[string]$Identity.display_name;source=[string]$Identity.resolution_source;confidence=[string]$Identity.confidence
        aliases=@($Identity.aliases);last_seen_at=(Get-Date).ToString('o')
        identity_key=[string]$Identity.course_key;canonical_map_id=$Identity.resource_map_id;canonical_name=[string]$Identity.display_name
    })
    $registry.entries=@($entries.ToArray()|Sort-Object course_key)
    return Write-MapIdentityRegistry -DataDir $DataDir -Registry $registry
}
