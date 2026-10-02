function TP-NullableInt($Value) {
    if($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)){return $null}
    try{return [int]::Parse(([string]$Value),[Globalization.CultureInfo]::InvariantCulture)}catch{return $null}
}
function TP-NullableBool($Value) {
    if($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)){return $null}
    $t=([string]$Value).Trim().ToLowerInvariant();if($t-eq'true'-or$t-eq'1'){return $true};if($t-eq'false'-or$t-eq'0'){return $false};return $null
}
function TP-GetCsvField($Row,[string]$Name) {
    if($null -eq $Row -or [string]::IsNullOrWhiteSpace($Name)){return $null}
    $prop=$Row.PSObject.Properties[$Name]
    if($null -eq $prop){return $null}
    return $prop.Value
}

function TP-ToDouble($Value) {
    if($null -eq $Value){return [double]::NaN}
    try { return [double]::Parse(([string]$Value),[Globalization.CultureInfo]::InvariantCulture) } catch { return [double]::NaN }
}
function TP-NormalizeRawSlip([double]$Raw) {
    if([double]::IsNaN($Raw) -or [double]::IsInfinity($Raw)){ return 0.0 }
    $mag=[Math]::Abs([Math]::Abs($Raw)-([Math]::PI/2.0))
    if($mag -gt ([Math]::PI/2.0)){ $mag=[Math]::PI/2.0 }
    return $(if($Raw -lt 0){-$mag}else{$mag})
}

function Load-PhysicalPart {
    param(
        [Parameter(Mandatory=$true)]$Meta,
        [Parameter(Mandatory=$true)][string]$PhysicalDir
    )

    $rows=$null
    $transport='csv_compat'
    $fastRel=([string]$Meta.fastbin).Replace('/','\')
    if(-not[string]::IsNullOrWhiteSpace($fastRel) -and ('QQReplayPortable' -as [type])) {
        $fastPath=Join-Path -Path $PhysicalDir -ChildPath $fastRel
        if(Test-Path -LiteralPath $fastPath -PathType Leaf) {
            try {
                $rows=[QQReplayPortable]::LoadFastRows($fastPath,[string]$Meta.profile,[string]$Meta.stream_id)
                if($null-ne$rows -and $rows.Count-ge2){$transport='qpf_v1'}else{$rows=$null}
            } catch {
                $csvRel=[string]$Meta.csv
                if([string]::IsNullOrWhiteSpace($csvRel)){throw ('Fast physical cache load failed and no CSV compatibility stream exists: '+$_.Exception.Message)}
                Write-Warning ('Fast physical cache load failed; falling back to CSV: '+$_.Exception.Message)
                $rows=$null
            }
        }
    }

    if($null-eq$rows) {
        $rel=([string]$Meta.csv).Replace('/','\')
        if([string]::IsNullOrWhiteSpace($rel)){ return $null }
        $csv=Join-Path -Path $PhysicalDir -ChildPath $rel
        if(-not (Test-Path -LiteralPath $csv -PathType Leaf)){ return $null }

        $list=New-Object System.Collections.Generic.List[object]
        foreach($r in @(Import-Csv -LiteralPath $csv)) {
            $t=TP-ToDouble $r.time_s; $x=TP-ToDouble $r.x; $y=TP-ToDouble $r.y; $z=TP-ToDouble $r.z
            if([double]::IsNaN($t)-or[double]::IsNaN($x)-or[double]::IsNaN($y)-or[double]::IsNaN($z)){continue}
            $derivedSpeed=TP-ToDouble $r.speed_3d
            $directVx=TP-ToDouble (TP-GetCsvField -Row $r -Name 'file_vx')
            $directVy=TP-ToDouble (TP-GetCsvField -Row $r -Name 'file_vy')
            $directVz=TP-ToDouble (TP-GetCsvField -Row $r -Name 'file_vz')
            $directSpeed=[double]::NaN
            $directFinite=(-not [double]::IsNaN($directVx)) -and (-not [double]::IsInfinity($directVx)) -and (-not [double]::IsNaN($directVy)) -and (-not [double]::IsInfinity($directVy)) -and (-not [double]::IsNaN($directVz)) -and (-not [double]::IsInfinity($directVz))
            if($directFinite){$directSpeed=[Math]::Sqrt($directVx*$directVx+$directVy*$directVy+$directVz*$directVz)}
            $useReplayVelocity=([string]$Meta.profile -eq '2026' -and $directFinite)
            $spd=$(if($useReplayVelocity){$directSpeed}else{$derivedSpeed})
            $speedSource=$(if($useReplayVelocity){'replay_linear_velocity'}else{'derived_position_velocity'})
            $yaw=TP-ToDouble $r.yaw_rad
            $rawSlip=TP-ToDouble $r.slip_angle_rad
            $slip=TP-NormalizeRawSlip $rawSlip
            $contact=TP-NullableInt -Value (TP-GetCsvField -Row $r -Name 'contact_state')
            $contactName=[string](TP-GetCsvField -Row $r -Name 'contact_state_name')
            $air=TP-NullableBool -Value (TP-GetCsvField -Row $r -Name 'is_airborne')
            $lap=TP-NullableInt -Value (TP-GetCsvField -Row $r -Name 'lap_index')
            $forwardHeading=TP-ToDouble (TP-GetCsvField -Row $r -Name 'vehicle_forward_heading_rad')
            $inputCandidate=@(
                (TP-NullableInt -Value (TP-GetCsvField -Row $r -Name 'input_bool_candidate_60')),
                (TP-NullableInt -Value (TP-GetCsvField -Row $r -Name 'input_bool_candidate_61')),
                (TP-NullableInt -Value (TP-GetCsvField -Row $r -Name 'input_bool_candidate_62')),
                (TP-NullableInt -Value (TP-GetCsvField -Row $r -Name 'input_bool_candidate_63')),
                (TP-NullableInt -Value (TP-GetCsvField -Row $r -Name 'input_bool_candidate_64')),
                (TP-NullableInt -Value (TP-GetCsvField -Row $r -Name 'input_bool_candidate_65'))
            )
            $list.Add([pscustomobject]@{time=$t;x=$x;y=$y;z=$z;speed=$spd;speed_raw=$spd;speed_source=$speedSource;direct_speed=$directSpeed;derived_speed=$derivedSpeed;direct_vx=$directVx;direct_vy=$directVy;direct_vz=$directVz;yaw=$yaw;slip=$slip;raw_slip=$rawSlip;contact_state=$contact;contact_state_name=$contactName;is_airborne=$air;lap_index=$lap;vehicle_forward_heading=$forwardHeading;vehicle_forward_heading_rad=$forwardHeading;input_bool_candidate=$inputCandidate;source=[string]$Meta.stream_id})
        }
        $rows=$list.ToArray()
    }
    if($null-eq$rows -or $rows.Count-lt2){return $null}

    $parsedContacts=0;$parsedLaps=0;$directCount=0
    foreach($rr in $rows){
        if($null-ne$rr.contact_state){$parsedContacts++}
        if($null-ne$rr.lap_index){$parsedLaps++}
        if([string]$rr.speed_source -eq 'replay_linear_velocity'){$directCount++}
    }
    if([string]$Meta.profile -eq '2026') {
        if($parsedContacts-eq0){throw ('Physical adapter lost promoted contact_state values: '+[string]$Meta.stream_id)}
        if($parsedLaps-eq0){throw ('Physical adapter lost promoted lap_index values: '+[string]$Meta.stream_id)}
        if($directCount-eq0){throw ('Physical adapter lost promoted replay linear velocity values: '+[string]$Meta.stream_id)}
    }
    $speedSource=if($directCount -eq $rows.Count){'replay_linear_velocity'}elseif($directCount -gt 0){'mixed_replay_velocity_with_derived_fallback'}else{'derived_position_velocity'}

    return [pscustomobject]@{
        id=[string]$Meta.stream_id
        hz=[double]$Meta.approx_sample_hz
        profile=[string]$Meta.profile
        transport=$transport
        speed_source=$speedSource
        record_semantic_schema_version=$(if($null-ne$Meta.record_semantic_schema_version){[int]$Meta.record_semantic_schema_version}else{0})
        vehicle_forward_axis_local=[string]$Meta.vehicle_forward_axis_local
        rows=$rows
        t0=[double]$rows[0].time;t1=[double]$rows[$rows.Count-1].time
        x0=[double]$rows[0].x;y0=[double]$rows[0].y;z0=[double]$rows[0].z
        x1=[double]$rows[$rows.Count-1].x;y1=[double]$rows[$rows.Count-1].y;z1=[double]$rows[$rows.Count-1].z
    }
}

function Get-PhysicalParts {
    param(
        [Parameter(Mandatory=$true)]$ReplayManifest,
        [Parameter(Mandatory=$true)][string]$PhysicalDir
    )

    $parts=New-Object System.Collections.Generic.List[object]
    foreach($meta in @($ReplayManifest.streams)) {
        if($null -eq $meta){ continue }
        $p=Load-PhysicalPart -Meta $meta -PhysicalDir $PhysicalDir
        if($null -ne $p){$parts.Add($p)}
    }
    return @($parts.ToArray() | Sort-Object t0,t1)
}
