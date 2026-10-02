param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){ if(-not $Ok){ throw $Message } }

# ===========================================================================
# Current-2026 Replay Closure regression (Real Regression gate).
#
# Locks the two product defects the closure milestone fixed, using the user's own real replays:
#
#  A. Action Event locator. `native_action_event_table_v1` used to require the table to end exactly
#     374 bytes before EOF. One recording (320冒险岛-20260928) carries the table ~659 bytes before
#     EOF and resolved as `action_event_count_unresolved`, so a structurally intact, semantically
#     aligned local action table was withheld. The locator contract v2 must reach it, and the v1
#     fixed point must keep resolving every replay that already resolved (no regression).
#
#  B. Capability independence. An undecodable action event table must NOT null out the Drift or the
#     raw effect evidence: those come from their own native action-object tables.
#
# Replays are located by SHA256 and skipped explicitly when absent, so a machine without the archive
# degrades to "not-present" instead of failing.
# ===========================================================================

$dataDir=Split-Path -Parent $AppDir
$archive=Join-Path $dataDir 'ReplayArchive'
$telemetryRoot=Join-Path $dataDir 'Telemetry'

. (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeActionEvents.ps1')

function Find-ReplayBySha([string]$Sha256){
    if(-not(Test-Path -LiteralPath $archive -PathType Container)){return $null}
    foreach($f in @(Get-ChildItem -LiteralPath $archive -Recurse -File -Filter '*.sav' -ErrorAction SilentlyContinue)){
        $sha=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        if($sha-eq$Sha256){return $f}
    }
    return $null
}
function Read-Telemetry([string]$Sha256){
    $p=Join-Path $telemetryRoot (Join-Path $Sha256.Substring(0,16) 'telemetry_summary.json')
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){return $null}
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json)
}

# --- A. locator ---------------------------------------------------------------------------------
# The closure replay: the table does NOT end at fileLength-374.
$closureSha='43067EE8573EA091EA728208BD41292CBD19A50E23C835C8CAD035A9391D4962'
# 320冒险岛-20260928-044907 identity is pinned by SHA16 only (file names carry player nicknames and
# must never enter tracked content).
$closure=Find-ReplayBySha $closureSha
if($null-eq$closure){
    Write-Host '  [closure] not-present (skipped)'
} else {
    $table=Get-ReplayNativeActionEventTable -ReplayPath $closure.FullName
    Require ([bool]$table.available) ('closure: the action event table must resolve; reason='+[string]$table.reason)
    Require ([int]$table.event_count -eq 65) ('closure: pinned action event count changed: '+[string]$table.event_count+' != 65')
    Require ([long]$table.count_offset -eq 4967797) ('closure: pinned action event count offset changed: '+[string]$table.count_offset)
    Require ([string]$table.locator_path -eq 'structural_count_anchored_forward_v2') ('closure: expected the structural locator path, got '+[string]$table.locator_path)
    Require ([long]$table.trailer_bytes_at_locator -eq 659) ('closure: expected 659 trailing bytes, got '+[string]$table.trailer_bytes_at_locator)
    # Every record must still satisfy the documented shape.
    foreach($e in @($table.events)){
        Require ([long]$e.reserved -eq 0) 'closure: a located record has a non-zero reserved field'
        Require ([long]$e.action_code -ge 1 -and [long]$e.action_code -le 200) ('closure: implausible action code '+[string]$e.action_code)
    }
    $tele=Read-Telemetry $closureSha
    if($null-ne$tele){
        $stream=@($tele.streams|Where-Object{[string]$_.role-eq'local_high_frequency'})[0]
        Require ($null-ne$stream) 'closure: no local_high_frequency stream in the telemetry summary'
        $pa=$stream.production_actions
        # Ownership: the table belongs to the LOCAL player, proven by the code2001 anchor alignment.
        Require ([string]$pa.semantic_alignment.status -eq 'aligned') ('closure: the located table must pass the code2001 semantic alignment gate; status='+[string]$pa.semantic_alignment.status)
        Require ([double]$pa.semantic_alignment.alignment_rate -ge 0.9) ('closure: alignment rate too low: '+[string]$pa.semantic_alignment.alignment_rate)
        # Capability independence: Drift and raw effect evidence survive even though the ACTION table
        # is what needed the new locator.
        Require ([bool]$pa.drift.available) 'closure: native Drift must stay available'
        Require ([int]$pa.drift.logical_count -eq 37) ('closure: pinned logical drift count changed: '+[string]$pa.drift.logical_count+' != 37')
        Require ([int]$pa.drift.raw_intervals -eq 54) ('closure: pinned raw drift interval count changed: '+[string]$pa.drift.raw_intervals+' != 54')
        Require ($null-ne$pa.small_boost.raw_effect_count) 'closure: raw code2001 evidence must be published'
        Require ($null-ne$pa.nitro.raw_interval_count) 'closure: raw code1 evidence must be published'
        Require ([bool]$pa.game_facing_available) 'closure: the aligned action table must publish game-facing counts'
        Write-Host ('  [closure] sha16='+$closureSha.Substring(0,16)+' count=65 offset=4967797 trailer=659 alignment=1 drift=54/37 action=ready')
    } else {
        Write-Host '  [closure] telemetry-not-built (action table checked, product wiring skipped)'
    }
}

# --- A'. v1 fixed point must not regress --------------------------------------------------------
# These replays resolved through the 374-byte fixed point before the locator change and must keep
# doing so (proving the new path is additive, not a replacement).
$v1Cases=@(
    @{sha='12BCC7EC6B0F6FAE92E7F20C84FF60F8FD654EFFB53EC04DE0C1AB32B12DC757'; count=75; offset=1631190},
    @{sha='226B51B3BABE06C242121375C9FA75F4D2A93409D018CD418AB0FDE798112578'; count=59; offset=1957678},
    @{sha='260B5B76F23ED3DB05101EC1C9EE338803F3A2EE19D6F9C231451750081C1DC3'; count=67; offset=1891885}
)
$v1Checked=0
foreach($c in $v1Cases){
    $f=Find-ReplayBySha $c.sha
    if($null-eq$f){ continue }
    $t=Get-ReplayNativeActionEventTable -ReplayPath $f.FullName
    Require ([bool]$t.available) ('v1 control '+$c.sha.Substring(0,16)+': must still resolve')
    Require ([string]$t.locator_path -eq 'trailer_fixed_point_v1') ('v1 control '+$c.sha.Substring(0,16)+': must still resolve through the 374-byte fixed point, got '+[string]$t.locator_path)
    Require ([int]$t.event_count -eq [int]$c.count) ('v1 control '+$c.sha.Substring(0,16)+': pinned count changed: '+[string]$t.event_count+' != '+[string]$c.count)
    Require ([long]$t.count_offset -eq [long]$c.offset) ('v1 control '+$c.sha.Substring(0,16)+': pinned count offset changed: '+[string]$t.count_offset)
    $v1Checked++
}
Write-Host ('  [v1-controls] checked='+$v1Checked+'/'+$v1Cases.Count+' (all still on trailer_fixed_point_v1)')

# --- B. capability independence (map-agnostic) ---------------------------------------------------
# A summary whose action event table is unavailable while the Drift table is valid must still carry
# the real Drift count and raw effect counts. This is asserted directly on the published contract so
# the rule cannot be re-broken by a later change to the analysis layer.
$independence=0
foreach($dir in @(Get-ChildItem -LiteralPath $telemetryRoot -Directory -ErrorAction SilentlyContinue)){
    $p=Join-Path $dir.FullName 'telemetry_summary.json'
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){ continue }
    $tele=Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json
    foreach($stream in @($tele.streams)){
        $pa=$stream.production_actions
        if($null-eq$pa){ continue }
        if([bool]$pa.available){ continue }
        if(-not [bool]$pa.drift.available){ continue }
        $independence++
        Require ($null-ne$stream.system_drift_segment_count) ('independence '+$dir.Name+'/'+[string]$stream.id+': drift segment count must be published')
        Require ($null-ne$pa.drift.raw_intervals) ('independence '+$dir.Name+'/'+[string]$stream.id+': raw drift intervals must survive an unavailable action table')
        Require ($null-ne$pa.drift.logical_count) ('independence '+$dir.Name+'/'+[string]$stream.id+': logical drift count must survive an unavailable action table')
        if([bool]$stream.speed_effect_state_available){
            Require ($null-ne$pa.small_boost.raw_effect_count) ('independence '+$dir.Name+'/'+[string]$stream.id+': raw code2001 count must survive an unavailable action table')
            Require ($null-ne$pa.nitro.raw_interval_count) ('independence '+$dir.Name+'/'+[string]$stream.id+': raw code1 count must survive an unavailable action table')
        }
    }
}
Write-Host ('  [independence] action-unavailable + drift-available streams checked='+$independence)

# The synthetic capability-independence contract lives in Smoke-CapabilityIndependence.ps1 (Fast
# Gate) so it is exercised even on a machine without the replay archive.
Write-Host ('[OK] Current-2026 closure regression passed. closure-locator='+$(if($null-ne$closure){'checked'}else{'skipped'})+' v1-controls='+$v1Checked+'/'+$v1Cases.Count+' independence-streams='+$independence)
exit 0
