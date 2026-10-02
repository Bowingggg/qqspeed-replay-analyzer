# Smoke: persistent user-confirmed Game -> Resource binding authority.
#
# Contract under test (ADR-level, see docs/ARCHITECTURE.md + docs/september2026/):
#   * a user-confirmed GameMapID <-> ResourceMapID pair resolves at tier 0 and is reported with
#     provenance `user_confirmed`, never as `verified`;
#   * it is only consulted when the official resources provide no authoritative binding, and it
#     never overrides a verified binding;
#   * nothing in the build path may create it, and it is never inferred from a near name, an offset
#     relation or replay geometry;
#   * it is a user fact: cold/derived rebuilds preserve it, and it can be revoked.
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
$appDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dataRoot=Split-Path -Parent $appDir
$projectRoot=Split-Path -Parent $dataRoot

function Require([bool]$Condition,[string]$Message){ if(-not $Condition){ throw $Message } }

. (Join-Path $appDir 'Modules\MapCatalog\Catalog.Naming.ps1')
. (Join-Path $appDir 'Modules\MapCatalog\GameResourceBinding.ps1')
. (Join-Path $appDir 'Modules\Replay\Replay.MapIdentityResolver.ps1')
. (Join-Path $appDir 'Modules\MapCatalog\Catalog.ReplayResolver.ps1')
. (Join-Path $appDir 'Modules\Replay\Replay.DevRebuild.ps1')

$tmp=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_UserConfirmedBinding_'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'MapCatalog')|Out-Null
try {
    # --- A. empty store resolves nothing ------------------------------------------------
    Require ($null -eq (Get-GRBUserConfirmedBindingForGameMapId -DataDir $tmp -GameMapId 439)) 'A1: an empty store must resolve nothing'
    $store=Read-GRBUserConfirmedBindings $tmp
    Require ([string]$store.contract -eq 'user_confirmed_game_resource_binding_v1') 'A2: store contract marker missing'
    Require (@($store.bindings).Count -eq 0) 'A3: store must start empty'

    # --- B. the build path never creates it ---------------------------------------------
    $games=@([pscustomobject]@{name='一梦青花';game_map_id=439})
    $resources=@([pscustomobject]@{map_id=339;primary_name='绝色江西';all_names=@('绝色江西');display_aliases=@()})
    $built=GRB-BuildBindingsFromData -GameRecords $games -ResourceCatalog $resources -ManualAliases @() -VerifiedAnchors @()
    $row=@($built.bindings)[0]
    Require (-not[bool]$row.authoritative_for_cross_namespace_binding) 'B1: the generated catalog must not authoritatively bind an unnamed game row'
    Require ([string]$row.status -eq 'offset_supported_candidate') ('B2: expected the +100 relation to stay a non-authoritative candidate, got '+[string]$row.status)
    Require ($null -eq (Get-GRBUserConfirmedBindingForGameMapId -DataDir $tmp -GameMapId 439)) 'B3: building the catalog must never write a user-confirmed binding'

    # --- C. explicit confirmation is authoritative, with its own provenance --------------
    [void](Set-GRBUserConfirmedBinding -DataDir $tmp -GameMapId 439 -ResourceMapId 339 -GameDisplayName='一梦青花' -ResourceDisplayName='绝色江西' -Evidence='synthetic smoke confirmation')
    $b=Get-GRBUserConfirmedBindingForGameMapId -DataDir $tmp -GameMapId 439
    Require ($null -ne $b -and [int]$b.resource_map_id -eq 339) 'C1: confirmed binding not readable'
    Require ([string]$b.provenance -eq 'user_confirmed') 'C2: provenance must be user_confirmed'
    $ident=MI-GetUserConfirmedResourceFromGameMapId -DataDir $tmp -GameMapId 439
    Require ($null -ne $ident -and [int]$ident.resource_map_id -eq 339) 'C3: identity helper must use the confirmed binding'
    Require ([string]$ident.binding_source -eq 'user_confirmed_game_resource_binding') 'C4: identity helper provenance mismatch'

    # --- D. tier 0 with user-confirmed confidence ---------------------------------------
    $catalog=@([pscustomobject]@{map_id=339;primary_name='绝色江西';all_names=@('绝色江西')})
    $roomHint=[pscustomobject]@{name='一梦青花';game_map_id=439;source='trusted_room_catalog_filename_prefix'}
    $d1=Get-ReplayMapResolutionDecision -ReplayPath '一梦青花-20260916-212329-x.sav' -Catalog $catalog -RoomHint $roomHint -VerifiedBinding $null -UserConfirmedBinding $b
    Require ([int]$d1.tier -eq 0) 'D1: a user-confirmed binding must resolve at tier 0'
    Require ([int]$d1.resolved_map_id -eq 339) 'D2: tier-0 resource id mismatch'
    Require ([string]$d1.confidence -eq 'user_confirmed') 'D3: confidence must be user_confirmed, never verified'
    Require ([string]$d1.method -eq 'trusted room catalog filename prefix + user-confirmed game/resource binding') 'D4: user-confirmed method marker missing'

    # --- E. a verified binding always wins ----------------------------------------------
    $verified=[pscustomobject]@{game_map_id=439;resource_map_id=37;map_name='verified';binding_source='exact_resource_catalog_name'}
    $d2=Get-ReplayMapResolutionDecision -ReplayPath '一梦青花-20260916-212329-x.sav' -Catalog $catalog -RoomHint $roomHint -VerifiedBinding $verified -UserConfirmedBinding $b
    Require ([int]$d2.resolved_map_id -eq 37 -and [string]$d2.confidence -eq 'verified') 'E1: a verified binding must outrank a user-confirmed one'

    # --- F. the confirmed binding only applies to its own game id -----------------------
    $d3=Get-ReplayMapResolutionDecision -ReplayPath '一梦青花-20260916-212329-x.sav' -Catalog $catalog -RoomHint ([pscustomobject]@{name='other';game_map_id=112;source='trusted_room_catalog_filename_prefix'}) -VerifiedBinding $null -UserConfirmedBinding $null
    Require ([int]$d3.tier -ne 0 -or $null -eq $d3.resolved_map_id) 'F1: an unconfirmed game id must stay unresolved'

    # --- G. a cold/derived rebuild preserves the user fact ------------------------------
    $aliasPath=Join-Path $tmp 'MapCatalog\display_aliases_manual.json'
    [IO.File]::WriteAllText($aliasPath,'[]',(New-Object System.Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText((Join-Path $tmp 'settings.json'),'{"game_path":"x"}',(New-Object System.Text.UTF8Encoding($true)))
    $reset=Reset-QQReplayDevelopmentDerivedData -ProjectRoot $tmp -DataDir $tmp -IncludeValidatedCaches
    Require (Test-Path -LiteralPath (Get-GRBUserConfirmedBindingPath $tmp) -PathType Leaf) 'G1: a true cold reset must preserve the user-confirmed binding store'
    Require (Test-Path -LiteralPath $aliasPath -PathType Leaf) 'G2: a true cold reset must preserve manual display aliases'
    $afterReset=Get-GRBUserConfirmedBindingForGameMapId -DataDir $tmp -GameMapId 439
    Require ($null -ne $afterReset -and [int]$afterReset.resource_map_id -eq 339) 'G3: the confirmed binding must survive a cold reset'
    Require (@($reset.preserved) -contains (Get-GRBUserConfirmedBindingPath $tmp)) 'G4: the reset contract must report the binding store as preserved'
    Require (@($reset.preserved) -contains (Join-Path $tmp 'ReplayArchive')) 'G5: the reset contract must report the replay archive as preserved'

    # --- H. revoke removes it -----------------------------------------------------------
    $removed=Remove-GRBUserConfirmedBinding -DataDir $tmp -GameMapId 439
    Require ([int]$removed -eq 1) 'H1: revoke must report the removed binding'
    Require ($null -eq (Get-GRBUserConfirmedBindingForGameMapId -DataDir $tmp -GameMapId 439)) 'H2: revoked binding must not resolve'
    $d4=Get-ReplayMapResolutionDecision -ReplayPath '一梦青花-20260916-212329-x.sav' -Catalog $catalog -RoomHint $roomHint -VerifiedBinding $null -UserConfirmedBinding $null
    Require ([int]$d4.tier -ne 0) 'H3: after revoke the replay must fall back to unresolved/named_unverified handling'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host '[OK] User-confirmed Game/Resource binding smoke passed. tier0=user_confirmed verified-outranks=yes build-never-creates=yes cold-reset-preserves=yes revocable=yes'
exit 0
