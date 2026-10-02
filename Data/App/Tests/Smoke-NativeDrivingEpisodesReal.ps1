param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){ if(-not $Ok){ throw $Message } }

# ---------------------------------------------------------------------------
# Driving Analysis v2 -- real replay episode regression (Gold A / Gold B).
#
# Belongs to the Real Regression gate. It runs the production episode builder over the real
# production telemetry of the pinned gold replays and asserts the native-fact invariants:
#   * episode count == production logical drift count (one episode per logical Drift action)
#   * every episode is assigned to exactly one lap, and the lap is a real native lap
#   * episode times are monotonic and every duration is > 0
#   * every published speed value is finite
#   * native episode analysis stays READY even when this test deliberately omits map metadata
#     (spatial sections are a separate, map-dependent status)
#
# The replays themselves are located by SHA256 and skipped explicitly when absent, so a machine
# without the archive degrades to "not-present" instead of failing.
# ---------------------------------------------------------------------------

$dataDir=Split-Path -Parent $AppDir
$archive=Join-Path $dataDir 'ReplayArchive'
$telemetryRoot=Join-Path $dataDir 'Telemetry'

. (Join-Path $AppDir 'Modules\Native\NativeDrivingAnalysis.ps1')
. (Join-Path $AppDir 'Modules\Native\NativeDrivingEpisodes.ps1')

function Find-ReplayBySha([string]$Sha256){
    if(-not(Test-Path -LiteralPath $archive -PathType Container)){return $null}
    foreach($f in @(Get-ChildItem -LiteralPath $archive -Recurse -File -Filter '*.sav' -ErrorAction SilentlyContinue)){
        $sha=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        if($sha-eq$Sha256){return $f}
    }
    return $null
}

function Assert-GoldEpisodes {
    param(
        [string]$Tag,[string]$Sha256,
        [int]$ExpectedEpisodes,[int]$ExpectedLaps,
        [bool]$ExpectSpatialReady,[int]$MapId=-1
    )
    $f=Find-ReplayBySha $Sha256
    if($null-eq$f){ Write-Host ('  ['+$Tag+'] not-present (skipped)'); return $false }
    $sha16=$Sha256.Substring(0,16)
    $telePath=Join-Path $telemetryRoot (Join-Path $sha16 'telemetry_summary.json')
    if(-not(Test-Path -LiteralPath $telePath -PathType Leaf)){ Write-Host ('  ['+$Tag+'] telemetry-not-built (skipped)'); return $false }

    $tele=Get-Content -LiteralPath $telePath -Raw -Encoding UTF8|ConvertFrom-Json
    Require ([string]$tele.source_sha256-eq$Sha256) ($Tag+': telemetry summary source SHA does not match the pinned gold replay')
    $stream=@($tele.streams|Where-Object{[string]$_.role-eq'local_high_frequency'})[0]
    if($null-eq$stream){$stream=@($tele.streams)[0]}
    Require ($null-ne$stream) ($Tag+': no telemetry stream in the summary')
    $pa=$stream.production_actions
    Require ($null-ne$pa-and[bool]$pa.available) ($Tag+': production action semantics must be available')
    Require ([bool]$pa.game_facing_available) ($Tag+': game-facing actions must be validated for a gold replay')
    Require ([string]$pa.semantic_alignment.status-eq'aligned') ($Tag+': gold replay must pass the code2001 semantic alignment gate')

    # The gold replays must keep their pinned native drift accounting: logical actions never
    # outnumber the raw native intervals they were grouped from.
    Require ([int]$pa.drift.logical_count -le [int]$pa.drift.raw_intervals) ($Tag+': logical drift count must not exceed the raw native interval count')
    if($ExpectedEpisodes -gt 0){ Require ([int]$pa.drift.logical_count -eq $ExpectedEpisodes) ($Tag+': pinned logical drift count changed: '+[string]$pa.drift.logical_count+' != '+[string]$ExpectedEpisodes) }

    # Spatial sections additionally need the official map metadata; pass it when this machine has it.
    $mapMetaPath=''
    $drivingSections=$null
    if($MapId-gt0){
        $cand=Join-Path $dataDir ('NativeMaps\Map'+[string]$MapId+'\metadata.json')
        if(Test-Path -LiteralPath $cand -PathType Leaf){
            $mapMetaPath=$cand
            try{$drivingSections=New-NativeDrivingAnalysis -ProjectRoot (Split-Path -Parent $dataDir) -TelemetrySummaryPath $telePath -MapMetadataPath $cand}catch{$drivingSections=$null}
        }
    }
    $episodes=New-NativeDrivingEpisodes -ProjectRoot (Split-Path -Parent $dataDir) -TelemetrySummaryPath $telePath -MapMetadataPath $mapMetaPath -DrivingSections $drivingSections
    Require ([string]$episodes.contract-eq'native_driving_episodes_v1') ($Tag+': episode contract mismatch')
    Require ([string]$episodes.native_episode_analysis-eq'ready') ($Tag+': native episode analysis must be ready for a gold replay, got '+[string]$episodes.native_episode_analysis)
    $es=@($episodes.streams|Where-Object{[string]$_.id-eq[string]$stream.id})[0]
    Require ($null-ne$es) ($Tag+': episode stream missing for '+[string]$stream.id)
    Require ([string]$es.status-eq'ready') ($Tag+': episode stream status not ready: '+[string]$es.status)
    Require ([bool]$es.episode_time_monotonic) ($Tag+': episode times must be monotonic')
    Require ([int]$es.episode_count-eq[int]$pa.drift.logical_count) ($Tag+': episode count '+[string]$es.episode_count+' must equal the production logical drift count '+[string]$pa.drift.logical_count)
    Require ([int]$es.lap_count-eq$ExpectedLaps) ($Tag+': expected '+[string]$ExpectedLaps+' native laps, got '+[string]$es.lap_count)

    $lapSum=0
    $lapIds=New-Object System.Collections.Generic.List[int]
    foreach($lm in @($es.laps)){
        $lapSum+=[int]$lm.logical_drift_count
        $lapIds.Add([int]$lm.lap)
        Require ([double]$lm.lap_time_s-gt0) ($Tag+': lap time must be positive')
        Require ([int]$lm.logical_drift_count-eq@($lm.episodes).Count) ($Tag+': lap '+[string]$lm.lap+' logical drift count must equal its episode count')
        Require ([int]$lm.drift_duration_s.count-eq[int]$lm.logical_drift_count) ($Tag+': lap '+[string]$lm.lap+' drift-duration statistics must cover every episode')
        foreach($ep in @($lm.episodes)){
            Require ([double]$ep.time.duration_s-gt0) ($Tag+': '+[string]$ep.id+' duration must be > 0')
            Require ([int]$ep.lap-eq[int]$lm.lap) ($Tag+': episode '+[string]$ep.id+' lap association must match its lap bucket')
            foreach($v in @($ep.speed.entry,$ep.speed.min,$ep.speed.max,$ep.speed.avg,$ep.speed.exit)){
                Require ($null-ne$v) ($Tag+': '+[string]$ep.id+' speed values must be published')
                Require (-not[double]::IsNaN([double]$v)-and-not[double]::IsInfinity([double]$v)) ($Tag+': '+[string]$ep.id+' speed values must be finite')
            }
            Require ([int]$ep.native_actions.raw_drift_interval_count-ge1) ($Tag+': '+[string]$ep.id+' must carry its raw native interval count')
            Require ([double]$ep.position.distance_traveled_m-gt0) ($Tag+': '+[string]$ep.id+' must carry a positive distance measurement')
        }
    }
    Require ($lapSum -eq [int]$es.episode_count) ($Tag+': lap assignment must be one-to-one (lap sum '+[string]$lapSum+' vs episodes '+[string]$es.episode_count+')')
    Require (@($lapIds|Sort-Object -Unique).Count-eq$ExpectedLaps) ($Tag+': every native lap must be represented exactly once')

    if($ExpectSpatialReady -and -not[string]::IsNullOrWhiteSpace($mapMetaPath)){
        Require ([string]$episodes.spatial_driving-eq'ready') ($Tag+': spatial driving should be ready for a map-resolved gold replay')
    } else {
        Require ([string]$episodes.spatial_driving-eq'unavailable_prerequisite') ($Tag+': spatial driving must stay unavailable_prerequisite without a map identity')
        Require ([string]$episodes.native_episode_analysis-eq'ready') ($Tag+': an unresolved map identity must NOT make native episode analysis unavailable')
    }
    Write-Host ('  ['+$Tag+'] analysis='+[string]$episodes.native_episode_analysis+' spatial='+[string]$episodes.spatial_driving+' episodes='+[string]$es.episode_count+' logical-drift='+[string]$pa.drift.logical_count+' raw-intervals='+[string]$pa.drift.raw_intervals+' laps='+[string]$es.lap_count+' monotonic='+[string]$es.episode_time_monotonic)
    return $true
}

# Gold B -- City Torch (map resolved): 34 raw == 34 logical drift, 3 native laps.
$goldB=Assert-GoldEpisodes -Tag 'goldB' -Sha256 '3164A4F8AFA71A832B30E55A7228C6FA08A9DFCE683689BA33CE8A18CF6A3623' -ExpectedEpisodes 34 -ExpectedLaps 3 -ExpectSpatialReady $true -MapId 29
# Gold A -- Old Street Pipeline: Game112 -> Resource Map12 is authoritative in the current catalog.
# This particular regression intentionally omits MapMetadata to keep the map-independent episode
# path covered; map-resolved Gold A is covered by the training/map-identity regressions.
$goldA=Assert-GoldEpisodes -Tag 'goldA' -Sha256 '50436400DE8FF37EA45363470EE8B06112628DABB2F33C22C3AA577FBA641253' -ExpectedEpisodes 22 -ExpectedLaps 3 -ExpectSpatialReady $false

if(-not($goldA-or$goldB)){ Write-Host '[OK] Driving episodes real regression: gold replays not present on this machine (skipped).' ; exit 0 }

$manifest=Get-Content -LiteralPath (Join-Path $AppDir 'app_manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
Write-Host ('[OK] Native Driving Episodes real regression passed. app='+[string]$manifest.app_version+' goldA='+$(if($goldA){'verified'}else{'not-present'})+' goldB='+$(if($goldB){'verified'}else{'not-present'})+'; episodes==logical-drift + one-lap-per-episode + monotonic + finite-speeds + map-independent-native-analysis')
exit 0
