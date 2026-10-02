param()
$ErrorActionPreference='Stop'
$appDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $appDir 'Modules\Native\NativeDrivingAnalysis.ps1')
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}
function Write-Utf8BomLocal([string]$Path,[string]$Text){$enc=New-Object System.Text.UTF8Encoding -ArgumentList $true;[IO.File]::WriteAllText($Path,$Text,$enc)}

$tmp=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_NativeDriving_'+[Guid]::NewGuid().ToString('N'))
try {
    $root=Join-Path $tmp 'Project';$teleDir=Join-Path $root 'Data\Telemetry\synthetic';$mapDir=Join-Path $root 'Data\NativeMaps\Map999'
    New-Item -ItemType Directory -Force -Path $teleDir,$mapDir | Out-Null
    $rows=New-Object System.Collections.Generic.List[object]
    $laps=New-Object System.Collections.Generic.List[object]
    $drifts=New-Object System.Collections.Generic.List[object]
    $cum=0.0;$time=0.0;$globalIndex=0
    for($lap=0;$lap-lt2;$lap++){
        $lapStart=$globalIndex;$lapStartD=$cum;$lapStartT=$time;$lastX=$null;$lastY=$null;$arcStartT=$null;$arcEndT=$null
        $pts=New-Object System.Collections.Generic.List[object]
        for($x=0;$x-le50;$x+=2){$pts.Add([pscustomobject]@{x=[double]$x;y=0.0;turn=$false})}
        for($k=1;$k-le20;$k++){$a=(-90.0+90.0*$k/20.0)*[Math]::PI/180.0;$pts.Add([pscustomobject]@{x=50.0+20.0*[Math]::Cos($a);y=20.0+20.0*[Math]::Sin($a);turn=$true})}
        for($y=22;$y-le70;$y+=2){$pts.Add([pscustomobject]@{x=70.0;y=[double]$y;turn=$false})}
        for($pi=0;$pi-lt$pts.Count;$pi++){
            $p=$pts[$pi]
            if($null-ne$lastX){$dx=[double]$p.x-[double]$lastX;$dy=[double]$p.y-[double]$lastY;$cum+=[Math]::Sqrt($dx*$dx+$dy*$dy)}
            $speed=if([bool]$p.turn){155.0+8.0*[Math]::Sin($pi)}else{210.0}
            if([bool]$p.turn -and $null-eq$arcStartT){$arcStartT=$time}
            if([bool]$p.turn){$arcEndT=$time}
            $rows.Add([pscustomobject]@{time_s=[Math]::Round($time,4);x=[Math]::Round([double]$p.x,5);y=[Math]::Round([double]$p.y,5);z=0;speed=[Math]::Round($speed,4);distance=[Math]::Round($cum,5);lap_index=$lap;pose_valid=$true;pose_break_before=($pi-eq0-and$lap-gt0)})
            $lastX=[double]$p.x;$lastY=[double]$p.y;$time+=0.10;$globalIndex++
        }
        $lapEnd=$globalIndex-1
        $laps.Add([ordered]@{lap=$lap;start_i=$lapStart;end_i=$lapEnd;start_t=[Math]::Round($lapStartT,4);end_t=[Math]::Round($time-0.10,4);duration_s=[Math]::Round(($time-0.10)-$lapStartT,4);start_distance=[Math]::Round($lapStartD,4);end_distance=[Math]::Round($cum,4);distance=[Math]::Round($cum-$lapStartD,4);source='replay_native_lap_index'})
        $drifts.Add([ordered]@{id=$lap+1;start_t=[Math]::Round([double]$arcStartT+0.20,4);end_t=[Math]::Round([double]$arcEndT-0.10,4);duration_s=[Math]::Round(([double]$arcEndT-[double]$arcStartT)-0.30,4)})
        $time+=0.50
    }
    $csv=Join-Path $teleDir 'logical_01.csv';$rows.ToArray()|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    $stream=[ordered]@{id='shadow_local';role='local_high_frequency';csv='logical_01.csv';lap_count=2;laps=$laps.ToArray();system_drift_segments=$drifts.ToArray();nitro_segments=@();small_boost_segments=@();air_boost_segments=@();landing_boost_segments=@();map_propulsion_effect_segments=@();native_combo_segments=@()}

    # Same geometric path at roughly half the sampling density. Detector v2 must keep
    # section counts stable because detection is performed on a fixed-distance grid.
    $lowRows=New-Object System.Collections.Generic.List[object];$lowLaps=New-Object System.Collections.Generic.List[object]
    foreach($l in $laps.ToArray()){
        $newStart=$lowRows.Count;$srcStart=[int]$l.start_i;$srcEnd=[int]$l.end_i
        for($ri=$srcStart;$ri-le$srcEnd;$ri+=2){$lowRows.Add($rows[$ri])}
        if((($srcEnd-$srcStart)%2)-ne0){$lowRows.Add($rows[$srcEnd])}
        $newEnd=$lowRows.Count-1
        $lowLaps.Add([ordered]@{lap=[int]$l.lap;start_i=$newStart;end_i=$newEnd;start_t=[double]$l.start_t;end_t=[double]$l.end_t;duration_s=[double]$l.duration_s;start_distance=[double]$l.start_distance;end_distance=[double]$l.end_distance;distance=[double]$l.distance;source='replay_native_lap_index'})
    }
    $csvLow=Join-Path $teleDir 'logical_02.csv';$lowRows.ToArray()|Export-Csv -LiteralPath $csvLow -NoTypeInformation -Encoding UTF8
    $streamLow=[ordered]@{id='shadow_network_01';role='network_low_frequency';csv='logical_02.csv';lap_count=2;laps=$lowLaps.ToArray();system_drift_segments=@();nitro_segments=@();small_boost_segments=@();air_boost_segments=@();landing_boost_segments=@();map_propulsion_effect_segments=@();native_combo_segments=@()}
    $tele=[ordered]@{schema_version=16;architecture='native_first_v1';streams=@($stream,$streamLow)}
    $telePath=Join-Path $teleDir 'telemetry_summary.json';Write-Utf8BomLocal $telePath ($tele|ConvertTo-Json -Depth 12)

    $svg=Join-Path $mapDir 'official_map.svg'
    $svgText='<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width="1200" height="1200" viewBox="0 0 1200 1200"><polygon points="50,1150 1150,1150 1150,50"/><polygon points="50,1150 1150,50 50,50"/></svg>'
    [IO.File]::WriteAllText($svg,$svgText,(New-Object System.Text.UTF8Encoding -ArgumentList $false))
    $meta=[ordered]@{schema_version=1;contract='native_map_v1';official_source=$true;resource_map_id=999;vector_minimap='official_map.svg';render_transform=[ordered]@{canvas_width=1200;canvas_height=1200;world_min_x=0;world_min_y=0;world_max_x=100;world_max_y=100;scale=11.0;offset_x=50.0;offset_y=50.0;y_inverted=$true}}
    $metaPath=Join-Path $mapDir 'metadata.json';Write-Utf8BomLocal $metaPath ($meta|ConvertTo-Json -Depth 8)

    $out=New-NativeDrivingAnalysis -ProjectRoot $root -TelemetrySummaryPath $telePath -MapMetadataPath $metaPath
    Require ([string]$out.contract-eq'native_driving_sections_v1') 'driving contract mismatch'
    Require ([int]$out.detector_revision-eq3) 'detector revision must be 3'
    Require ([string]$out.detector.name-eq'distance_resampled_multiscale_hysteresis_geometry_topology_v3') 'detector v3 marker missing'
    Require ([string]$out.detector.drift_topology_policy-eq'annotation_only') 'native Drift must be annotation-only for section topology'
    Require ([string]$out.status-eq'ready') ('driving status not ready: '+$out.status+'; type='+[string]$out.error_type+'; error='+[string]$out.error)
    Require (-not[bool]$out.authoritative) 'derived driving sections must never be authoritative'
    Require ([int]$out.surface_triangle_count-eq2) 'official surface triangle index mismatch'
    $ds=@($out.streams|Where-Object{[string]$_.id-eq'shadow_local'})[0]
    $dsLow=@($out.streams|Where-Object{[string]$_.id-eq'shadow_network_01'})[0]
    Require ([string]$ds.status-eq'ready') ('stream driving status not ready: '+$ds.status)
    Require ([string]$dsLow.status-eq'ready') ('low-rate stream driving status not ready: '+$dsLow.status)
    Require (@($ds.laps).Count-eq2) 'native lap sections missing'
    Require (@($dsLow.laps).Count-eq2) 'low-rate native lap sections missing'
    Require ([double]$ds.official_surface_sample_coverage-ge0.98) ('official surface coverage too low: '+$ds.official_surface_sample_coverage)
    for($li=0;$li-lt2;$li++){
        $ha=@($ds.laps)[$li];$lo=@($dsLow.laps)[$li]
        Require ([int]$ha.section_count-ge1) ('lap '+$ha.lap+' has no observed turn section')
        Require ([int]$ha.section_count-eq[int]$lo.section_count) ('sampling-rate section count drift on lap '+$ha.lap+': high='+$ha.section_count+' low='+$lo.section_count)
        Require ($null-ne$ha.detector_diagnostics) ('high-rate detector diagnostics missing on lap '+$ha.lap)
        Require ($null-ne$lo.detector_diagnostics) ('low-rate detector diagnostics missing on lap '+$lo.lap)
        Require ([int]$ha.detector_diagnostics.resampled_samples-gt0) ('high-rate resampled sample diagnostics missing on lap '+$ha.lap)
        Require ([int]$lo.detector_diagnostics.resampled_samples-gt0) ('low-rate resampled sample diagnostics missing on lap '+$lo.lap)
        Require ([int]$ha.detector_diagnostics.postmerge_candidates-eq[int]$ha.section_count) ('high-rate postmerge diagnostic mismatch on lap '+$ha.lap)
        Require ([int]$lo.detector_diagnostics.postmerge_candidates-eq[int]$lo.section_count) ('low-rate postmerge diagnostic mismatch on lap '+$lo.lap)
        Require ([int]$ha.detector_diagnostics.native_drift_segments_in_lap-ge1) ('high-rate native Drift diagnostic missing on lap '+$ha.lap)
        Require ([int]$lo.detector_diagnostics.native_drift_segments_in_lap-eq0) ('low-rate control must intentionally omit native Drift on lap '+$lo.lap)
        Require ([int]$ha.detector_diagnostics.native_drift_topology_mutations-eq0) ('high-rate native Drift mutated topology on lap '+$ha.lap)
        Require ([int]$lo.detector_diagnostics.native_drift_topology_mutations-eq0) ('low-rate topology mutation counter must stay zero on lap '+$lo.lap)
        Require (([int]$ha.detector_diagnostics.native_drift_overlapping_geometry+[int]$ha.detector_diagnostics.native_drift_near_geometry+[int]$ha.detector_diagnostics.native_drift_outside_geometry)-eq[int]$ha.detector_diagnostics.native_drift_segments_in_lap) ('high-rate Drift overlay diagnostics do not account for every segment on lap '+$ha.lap)
    }
    Require ([int]$ds.section_count-eq[int]$dsLow.section_count) ('sampling-rate total section count drift: high='+$ds.section_count+' low='+$dsLow.section_count)
    $rep=@($ds.representative_sections);$repLow=@($dsLow.representative_sections)
    Require ($rep.Count-eq$repLow.Count) 'representative section count differs across sampling rates'
    if($rep.Count-gt0){$dx=[double]$rep[0].anchor.x-[double]$repLow[0].anchor.x;$dy=[double]$rep[0].anchor.y-[double]$repLow[0].anchor.y;$ad=[Math]::Sqrt($dx*$dx+$dy*$dy);Require ($ad-le2.5) ('sampling-rate anchor drift too large: '+$ad)}
    $turn=@($rep|Where-Object{[string]$_.kind-eq'turn'-and[string]$_.direction-eq'left'-and[int]$_.native_actions.drift_count-ge1}|Select-Object -First 1)
    Require ($turn.Count-eq1) 'left turn with authoritative native Drift overlap was not produced'
    Require ($null-ne$turn[0].drift_efficiency_index) 'derived drift efficiency index missing'
    Require ([double]$turn[0].drift_efficiency_index-ge0.0-and[double]$turn[0].drift_efficiency_index-le1.0) 'drift efficiency index outside 0..1'
    Require ([double]$turn[0].official_surface_sample_coverage-ge0.98) 'turn does not validate against official static surface'

    Write-Host ('[OK] Native Driving Sections v3 geometry-topology smoke passed. laps=2 high/low-sections='+$ds.section_count+'/'+$dsLow.section_count+' surface='+$ds.official_surface_sample_coverage+' drift-efficiency='+$turn[0].drift_efficiency_index+' sampling=distance-normalized drift-topology=annotation-only authority=derived-only')
    exit 0
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
