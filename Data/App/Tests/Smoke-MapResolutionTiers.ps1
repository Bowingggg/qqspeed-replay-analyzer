param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){ if(-not $Ok){ throw $Message } }

# ---------------------------------------------------------------------------
# Map identity resolution tiers -- contract regression.
#
# Guards the map-coverage defect fixed in the Daily-Use Analyzer v1 milestone:
#   tier 0 (trusted room-catalog name -> Game MapID -> verified Resource binding) was skipped
#   whenever the replay filename produced a display hint, so those resolutions lost
#   `game_map_id` and were downgraded from `verified` to `high`.
#
# Synthetic: it exercises the real decision function with synthetic catalog rows, so it needs
# neither the game installation nor the replay archive.
# ---------------------------------------------------------------------------

. (Join-Path $AppDir 'Modules\MapCatalog\Catalog.Naming.ps1')
. (Join-Path $AppDir 'Modules\MapCatalog\Catalog.ReplayResolver.ps1')

# Minimal catalog rows shaped like the real `map_index.json` entries.
function New-Row([int]$Id,[string]$Primary,[string[]]$AllNames){
    return [pscustomobject]@{ map_id = $Id; primary_name = $Primary; all_names = @($AllNames) }
}
$catalog=@(
    (New-Row 29 '城市火炬' @('城市火炬')),
    (New-Row 12 '老街' @('老街')),
    (New-Row 31 '老街车站' @('老街车站')),
    (New-Row 37 '十一城' @('十一城'))
)
$catalogDuplicate=@(
    (New-Row 37 '十一城' @('十一城')),
    (New-Row 38 '十一城' @('十一城'))
)
$roomCityTorch=[pscustomobject]@{ name='城市火炬'; game_map_id=129; source='trusted_room_catalog_filename_prefix' }
$verifiedCityTorch=[pscustomobject]@{ resource_map_id=29; authoritative_for_cross_namespace_binding=$true }
$roomOldStreet=[pscustomobject]@{ name='老街管道'; game_map_id=112; source='trusted_room_catalog_filename_prefix' }

$nameCityTorch='城市火炬-20260930-225857-x.sav'
$nameEleven='十一城-20260922-010838-x.sav'
$nameOldStreet='老街管道-20260930-234714-x.sav'

$synthetic=0

# --- C1: filename hint + tier 0 evidence must BOTH be used (the regression) -----------------
$d1=Get-ReplayMapResolutionDecision -ReplayPath $nameCityTorch -Catalog $catalog -RoomHint $roomCityTorch -VerifiedBinding $verifiedCityTorch
Require ([int]$d1.tier -eq 0) 'C1: a filename hint must not skip tier 0'
Require ([int]$d1.resolved_map_id -eq 29) 'C1: tier 0 must resolve through the verified binding'
Require ([string]$d1.confidence -eq 'verified') 'C1: tier 0 evidence must keep confidence=verified'
Require ([int]$d1.game_map_id -eq 129) 'C1: tier 0 must persist the Game MapID even when a filename hint exists'
Require ([string]$d1.method -eq 'trusted room catalog filename prefix + verified game/resource binding') 'C1: tier 0 method string changed'
Require ([string]$d1.filename_hint -eq '城市火炬') 'C1: the filename hint must still be recorded'
Require ([string]$d1.room_hint_name -eq '城市火炬') 'C1: the trusted room hint must be recorded'
Require ([string]$d1.hint_source -eq 'filename') 'C1: the display hint should stay the filename hint when present'
Require (@($d1.candidates).Count -eq 1) 'C1: tier 0 must emit exactly one resolved candidate'
Require ([int]@($d1.candidates)[0].map_id -eq 29) 'C1: the tier 0 candidate must be the resolved row'
$synthetic++

# --- C2: same replay, no authoritative binding -> tier 1, Game MapID still recorded ---------
$d2=Get-ReplayMapResolutionDecision -ReplayPath $nameCityTorch -Catalog $catalog -RoomHint $roomCityTorch -VerifiedBinding $null
Require ([int]$d2.tier -eq 1) 'C2: without a verified binding the resolver must fall through to tier 1'
Require ([int]$d2.resolved_map_id -eq 29) 'C2: an exact official name match must resolve'
Require ([string]$d2.confidence -eq 'high') 'C2: tier 1 confidence must stay high'
Require ([int]$d2.game_map_id -eq 129) 'C2: the structured Game MapID must be preserved through tier 1'
$synthetic++

# --- C3: no room-catalog row -> tier 1 and no invented Game MapID --------------------------
$d3=Get-ReplayMapResolutionDecision -ReplayPath $nameEleven -Catalog $catalog -RoomHint $null -VerifiedBinding $null
Require ([int]$d3.tier -eq 1) 'C3: an exact official name must resolve without a room row'
Require ([int]$d3.resolved_map_id -eq 37) 'C3: the exact name must resolve to Map37'
Require ($null -eq $d3.game_map_id) 'C3: no room-catalog row means no Game MapID is invented'
$synthetic++

# --- C4: duplicate official names stay unresolved (never disambiguated by guessing) --------
$d4=Get-ReplayMapResolutionDecision -ReplayPath $nameEleven -Catalog $catalogDuplicate -RoomHint $null -VerifiedBinding $null
Require ([int]$d4.tier -eq 1) 'C4: a duplicate exact official name must stop at tier 1'
Require ($null -eq $d4.resolved_map_id) 'C4: a duplicate exact official name must stay unresolved'
Require ([string]$d4.method -eq 'duplicate exact map_desc.map_name') 'C4: duplicate method string changed'
Require (@($d4.candidates).Count -eq 2) 'C4: every duplicate candidate must be preserved'
$synthetic++

# --- C5: a non-authoritative room row + a near name must NOT become identity ---------------
# Negative guard: deliberately omit the now-authoritative Game112 -> Map12 resource-declared
# binding and prove that a near/prefix name alone (`老街管道` vs `老街`) still cannot promote.
$d5=Get-ReplayMapResolutionDecision -ReplayPath $nameOldStreet -Catalog $catalog -RoomHint $roomOldStreet -VerifiedBinding $null
Require ([int]$d5.tier -eq 2) 'C5: a non-authoritative room row must stop at tier 2'
Require ($null -eq $d5.resolved_map_id) 'C5: a near/prefix match must never resolve a map identity'
Require ([int]$d5.game_map_id -eq 112) 'C5: the structured Game MapID is still recorded as evidence'
Require (@($d5.candidates).Count -eq 0) 'C5: no candidate may be emitted without authoritative evidence'
$synthetic++

# --- C6: tier 0 outranks a conflicting filename hint, and the conflict stays visible --------
$d6=Get-ReplayMapResolutionDecision -ReplayPath $nameEleven -Catalog $catalog -RoomHint $roomCityTorch -VerifiedBinding $verifiedCityTorch
Require ([int]$d6.tier -eq 0) 'C6: tier 0 must win over a filename hint'
Require ([int]$d6.resolved_map_id -eq 29) 'C6: tier 0 must resolve through the verified binding'
Require ([string]$d6.filename_hint -eq '十一城') 'C6: the conflicting filename hint must be recorded'
Require ([int]$d6.room_hint_game_map_id -eq 129) 'C6: the tier 0 Game MapID must be recorded'
$synthetic++

# --- C7: hint extraction and normalization -------------------------------------------------
Require ([string](Get-MapHintFromReplayName 'A-20260101-010101-x.sav') -eq 'A') 'C7: timestamped filename hint extraction'
# A plain, punctuation-free name. The previous value here was a review-snapshot placeholder, and the
# angle brackets are illegal path characters, so this case used to throw instead of asserting.
Require ([string](Get-MapHintFromReplayName 'replay-without-a-stamp.sav') -eq '') 'C7: a name without the timestamp pattern yields no hint'
Require ([string](Normalize-MapName '  A   B  ') -eq 'A B') 'C7: name normalization must collapse whitespace'
$synthetic++

Write-Host ('[OK] Map resolution tier regression passed. synthetic='+[string]$synthetic+' cases; tier0-not-skipped-by-filename-hint + tier0-keeps-game-map-id + tier0-outranks-conflicting-hint + duplicate-name guard + near-match rejection.')
exit 0
