$ErrorActionPreference='Stop'
$scriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$appDir=Split-Path -Parent $scriptDir
. (Join-Path $appDir 'Modules\Telemetry\Telemetry.Analysis.ps1')
. (Join-Path $appDir 'Modules\Telemetry\Telemetry.PhysicalStreams.ps1')

$tmp=Join-Path ([IO.Path]::GetTempPath()) ('qqreplay_native_speed_'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $csv=Join-Path $tmp 'stream.csv'
    @(
        [pscustomobject]@{time_s='0.000';x='0';y='0';z='0';file_vx='3';file_vy='4';file_vz='0';speed_3d='99';yaw_rad='0';slip_angle_rad='0';contact_state='5';is_airborne='false';lap_index='1';vehicle_forward_heading_rad='0';input_bool_candidate_60='1';input_bool_candidate_61='0';input_bool_candidate_62='0';input_bool_candidate_63='0';input_bool_candidate_64='0';input_bool_candidate_65='0'},
        [pscustomobject]@{time_s='0.016';x='1';y='0';z='0';file_vx='6';file_vy='8';file_vz='0';speed_3d='88';yaw_rad='0';slip_angle_rad='0';contact_state='5';is_airborne='false';lap_index='1';vehicle_forward_heading_rad='0';input_bool_candidate_60='1';input_bool_candidate_61='0';input_bool_candidate_62='0';input_bool_candidate_63='0';input_bool_candidate_64='0';input_bool_candidate_65='0'}
    ) | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

    $meta2026=[pscustomobject]@{csv='stream.csv';stream_id='s1';profile='2026';approx_sample_hz=60;record_semantic_schema_version=1;vehicle_forward_axis_local='-Y'}
    $p2026=Load-PhysicalPart -Meta $meta2026 -PhysicalDir $tmp
    if($null-eq$p2026){throw '2026 physical part did not load.'}
    if([string]$p2026.speed_source -ne 'replay_linear_velocity'){throw ('2026 speed source mismatch: '+[string]$p2026.speed_source)}
    if([Math]::Abs([double]$p2026.rows[0].speed-5.0)-gt0.0001){throw ('2026 selected speed was not direct velocity norm: '+[double]$p2026.rows[0].speed)}
    if([Math]::Abs([double]$p2026.rows[0].derived_speed-99.0)-gt0.0001){throw 'Derived speed diagnostic was not preserved.'}

    $meta2025=[pscustomobject]@{csv='stream.csv';stream_id='s2';profile='2025';approx_sample_hz=60;record_semantic_schema_version=0;vehicle_forward_axis_local=''}
    $p2025=Load-PhysicalPart -Meta $meta2025 -PhysicalDir $tmp
    if($null-eq$p2025){throw '2025 physical part did not load.'}
    if([string]$p2025.speed_source -ne 'derived_position_velocity'){throw ('Legacy speed source changed unexpectedly: '+[string]$p2025.speed_source)}
    if([Math]::Abs([double]$p2025.rows[0].speed-99.0)-gt0.0001){throw 'Legacy fallback speed no longer uses derived position velocity.'}

    Write-Host '[OK] Native speed source smoke passed. 2026=replay_linear_velocity legacy=derived_position_velocity diagnostic=preserved'
}
finally {
    if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue}
}
