param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){ if(-not $Ok){ throw $Message } }

# ===========================================================================
# Capability independence contract (Fast Gate, synthetic - no replay needed).
#
# Product rule this milestone closed: every capability is gated by the availability of ITS OWN native
# authority. An undecodable action event table must null ONLY the action-event fields (air / landing /
# CW / WCW / CWW / unknown codes) and must never null out:
#   * native Drift (its own replay-native action-object Drift table), or
#   * raw effect evidence (the replay-native speed-effect table).
#
# The motivating defect: 320冒险岛 carried 54 validated raw Drift intervals and a logical drift count
# of 37, yet the interface showed 漂移 = N/A because the action event table was withheld for unrelated
# reasons. "unavailable is not zero" applies per capability, not globally.
# ===========================================================================

. (Join-Path $AppDir 'Modules\Native\NativeAnalysis.ps1')

function New-IndependenceStream {
    [pscustomobject]@{
        id='shadow_local';role='local_high_frequency';sample_hz=58.8;records=100;duration_s=100.0
        distance=1000.0;avg_speed=10.0;max_speed=20.0;lap_count=2;speed_source='replay_linear_velocity'
        system_drift_state_available=$true;system_drift_segment_count=54
        system_drift_state_source='replay_native_action_object_drift_table_v3'
        speed_effect_state_available=$true;speed_effect_state_source='replay_native_action_object_speed_effect_table_v2'
        nitro_segment_count=24;small_boost_segment_count=29;other_small_boost_segment_count=2
        map_propulsion_effect_segment_count=0;unknown_speed_effect_segment_count=0
        production_actions=[pscustomobject][ordered]@{
            contract='production_native_action_semantics_v1'
            architecture='native_first_v1'
            # The action event table is unavailable; the Drift and effect tables are intact.
            available=$false
            game_facing_available=$false
            status='native_action_event_table_unavailable'
            action_event_status='unavailable'
            action_event_reason='action_event_count_unresolved'
            semantic_alignment=[pscustomobject]@{status='not_applicable_no_anchor_code_events';game_facing_allowed=$true}
            drift=[pscustomobject][ordered]@{authority='replay_native_action_object_drift_table';available=$true;status='replay_native_drift_table_validated';game_facing=$true;raw_intervals=54;logical_count=37;merged_group_count=5;groups=@()}
            air_boost=[pscustomobject]@{authority='replay_native_action_event';native_code=8;count=$null;game_facing=$false}
            landing_boost=[pscustomobject]@{authority='replay_native_action_event';native_code=9;count=$null;game_facing=$false}
            combo=[pscustomobject]@{authority='replay_native_action_event';game_facing=$false;cw=$null;wcw=$null;cww=$null}
            small_boost=[pscustomobject]@{raw_effect_count=43;classified_count=0;unresolved_count=43;game_facing_normal_count=$null;game_facing=$false;game_facing_parity='unresolved'}
            nitro=[pscustomobject]@{raw_interval_count=24;logical_count=24;unresolved_count=0;game_facing_count=$null;game_facing=$false;game_facing_parity='unresolved'}
            legacy_combo_candidate=[pscustomobject]@{authoritative=$false;cw=5;wcw=0;cww=3}
            disagreement=[pscustomobject]@{air_contact_state=[pscustomobject]@{contact_state_air_boost=9};landing_contact_state=[pscustomobject]@{contact_state_landing_boost=3};combo=[pscustomobject]@{matches=$false}}
            unknown_action_codes=@()
        }
    }
}

$synthetic=NF-NativeActionSummary ([pscustomobject]@{streams=@(New-IndependenceStream)})

# --- the action-event capability is withheld ----------------------------------------------------
Require ([string]$synthetic.status -eq 'native_actions_partial') ('expected native_actions_partial, got '+[string]$synthetic.status)
Require (-not [bool]$synthetic.game_facing_available) 'game-facing counts must stay withheld'
Require (-not [bool]$synthetic.action_event_table_available) 'the action event table must be reported unavailable'
Require ($null -eq $synthetic.actions.air_boost.count) 'an unavailable action quantity must be null, not 0'
Require ($null -eq $synthetic.actions.landing_boost.count) 'an unavailable action quantity must be null, not 0'
Require ($null -eq $synthetic.actions.combo.cw) 'combo CW must be null, not 0'
Require ($null -eq $synthetic.actions.combo.wcw) 'combo WCW must be null, not 0'
Require ($null -eq $synthetic.actions.combo.cww) 'combo CWW must be null, not 0'
Require (-not [bool]$synthetic.air_boost.available) 'air boost availability must be false'
Require (-not [bool]$synthetic.landing_boost.available) 'landing boost availability must be false'

# --- Drift survives on its own authority --------------------------------------------------------
Require ([bool]$synthetic.drift_table_available) 'the drift table must be reported available'
Require ([bool]$synthetic.drift.available) 'native Drift must stay available'
Require ([int]$synthetic.drift.logical_count -eq 37) ('drift logical count must be published (37), got '+[string]$synthetic.drift.logical_count)
Require ([int]$synthetic.drift.raw_intervals -eq 54) ('drift raw intervals must be published (54), got '+[string]$synthetic.drift.raw_intervals)
Require ([int]$synthetic.actions.drift.logical_count -eq 37) ('actions.drift.logical_count must be published, got '+[string]$synthetic.actions.drift.logical_count)
Require ([int]$synthetic.actions.drift.raw_intervals -eq 54) ('actions.drift.raw_intervals must be published, got '+[string]$synthetic.actions.drift.raw_intervals)
Require ([int]$synthetic.drift.count -eq 54) ('drift timeline segment count must be published, got '+[string]$synthetic.drift.count)
Require ([int]$synthetic.statistics_contract.primary.drift.value -eq 37) 'the statistics contract must publish the logical drift count'

# --- raw effect evidence survives ---------------------------------------------------------------
Require ([bool]$synthetic.effect_table_available) 'the effect table must be reported available'
Require ([int]$synthetic.nitro.raw_interval_count -eq 24) ('raw code1 count must survive, got '+[string]$synthetic.nitro.raw_interval_count)
Require ([int]$synthetic.actions.small_boost.raw_effect_count -eq 43) ('raw code2001 count must survive, got '+[string]$synthetic.actions.small_boost.raw_effect_count)
Require ([int]$synthetic.statistics_contract.raw_only.small_boost_native_effects.value -eq 43) 'raw_only small-boost evidence must be published'
Require ([int]$synthetic.statistics_contract.raw_only.drift_raw_intervals.value -eq 54) 'raw_only drift intervals must be published'

Write-Host '[OK] Capability independence contract passed. unavailable-action + ready-drift -> drift=54/37 published, action fields null, raw code2001=43 / code1=24 preserved'
exit 0
