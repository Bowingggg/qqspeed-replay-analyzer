param()
$ErrorActionPreference='Stop'
$appDir=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function Read-Text([string]$Rel){$p=Join-Path $appDir $Rel;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw ('Missing: '+$Rel)};return Get-Content -LiteralPath $p -Raw -Encoding UTF8}
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}

$manifest=(Read-Text 'app_manifest.json'|ConvertFrom-Json)
Require ([string]$manifest.app_version -eq '3.7.24') 'app_version must be 3.7.24'
Require ([string]$manifest.architecture -eq 'native_first_v1') 'manifest architecture mismatch'
Require ([int]$manifest.data_schemas.analysis -eq 29) 'analysis schema must be 29'
Require ([int]$manifest.data_schemas.analysis_segments -eq 3) 'analysis segment schema must be 3'
Require ([int]$manifest.data_schemas.native_driving_sections -eq 1) 'native driving sections schema must be 1'
Require ([int]$manifest.data_schemas.telemetry -eq 19) 'telemetry schema must be 19'
Require ([int]$manifest.data_schemas.map_catalog -eq 6) 'map catalog schema must be 6'
Require ([int]$manifest.data_schemas.replay_native_drift_timeline -eq 4) 'native drift timeline schema must be 4'
Require ([int]$manifest.data_schemas.native_driving_episodes -eq 1) 'native driving episodes schema must be 1'
Require ([int]$manifest.data_schemas.native_map -eq 1) 'native map schema must be 1'
Require ([int]$manifest.data_schemas.native_map_reader -eq 2) 'native map reader schema must be 2'
Require ([int]$manifest.data_schemas.drift_state_contract -eq 5) 'drift state contract must be 5'
Require ([int]$manifest.data_schemas.lap -eq 2) 'native lap schema must be 2'
Require ([string]$manifest.repository.stage -eq 'git_baseline_v1') 'repository stage must be git_baseline_v1'
Require (@($manifest.PSObject.Properties.Name) -notcontains 'migration') 'manifest must not carry repository migration state'
Require (@($manifest.PSObject.Properties.Name) -notcontains 'retired_from_production') 'manifest must not carry retired-architecture inventory'

$an=Read-Text 'QQReplay.ps1'
foreach($bad in @('QQSpeedMapBuilder.ps1','QQSpeedMapMatcher.ps1','QQTrackTopology.ps1','ReplayFingerprints\','MapCache\','EvidenceBuild','Invoke-CanonicalTrack','Modules\TrackTopology')){Require (-not $an.Contains($bad)) ('production analyzer still references retired route: '+$bad)}
foreach($must in @('QQReplayTelemetry.ps1','QQNativeMap.ps1','New-NativeDrivingAnalysis','New-NativeFirstAnalysis','Native-First')){Require ($an.Contains($must)) ('production analyzer missing native chain marker: '+$must)}
Require ($an.Contains("native_first_rejected_")) 'production analyzer must reject non-authoritative resolution methods'
Require ($an.Contains('[WARN] Map') -and $an.Contains('官方 map.nif 未就绪；不使用轨迹底图替代')) 'native map failure must degrade without trajectory fallback'

$common=Read-Text 'Modules\Replay\Replay.Common.ps1'
Require ($common.Contains('child_error_stream_isolation_v1')) 'child stderr isolation marker missing from Replay.Common'
Require ($common.Contains('$ErrorActionPreference=''Continue''')) 'Replay.Common child wrapper must neutralize parent Stop during child stderr capture'
$tempChild=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_ChildIsolation_'+[Guid]::NewGuid().ToString('N')+'.ps1')
try {
    [IO.File]::WriteAllText($tempChild,"[Console]::Error.WriteLine('intentional-child-stderr')`r`nexit 0`r`n",(New-Object System.Text.UTF8Encoding($true)))
    . (Join-Path $appDir 'Modules\Replay\Replay.Common.ps1')
    $childRc=Invoke-PSChildVisible $tempChild @() 'WinPS 5.1 child stderr isolation contract'
    Require ([int]$childRc -eq 0) ('child stderr isolation incorrectly terminated parent: '+[string]$childRc)
} finally { Remove-Item -LiteralPath $tempChild -Force -ErrorAction SilentlyContinue }

$resolver=Read-Text 'Modules\MapCatalog\Catalog.ReplayResolver.ps1'
foreach($must in @('trusted room catalog filename prefix + verified game/resource binding','exact map_desc.map_name catalog match','native-first: no authoritative identity match')){Require ($resolver.Contains($must)) ('resolver missing native-first authority route: '+$must)}
foreach($retired in @('manual/display labels are UI metadata only','dynamic alias guess','descriptor-text scan')){Require ($resolver.Contains($retired)) ('resolver must explicitly document retired route: '+$retired)}
Require (-not($resolver -match '(?m)^\s*#\s*Tier 3:')) 'Tier 3 map guessing must not remain active'
Require (-not($resolver -match '(?m)^\s*#\s*Tier 4:')) 'Tier 4 descriptor scan must not remain active'


$catalogTool=Read-Text 'QQSpeedMapCatalog.ps1'
# The mode surface must stay production-only: no research/legacy/fingerprint modes. `UserBinding` is
# production authority (it maintains the persistent user-confirmed Game->Resource binding, ADR 0008),
# so it belongs in this list; anything else must not appear here.
Require ($catalogTool.Contains('[ValidateSet("Build","Resolve","Detail","BuildGameResourceBindings","UserBinding")]')) 'MapCatalog v3 mode surface is not production-only'
foreach($retiredMode in @('DeepProbeName','ProbeThumbnail','CorrelateIds','ProbeRoomMapIds','ProbeRoomMapTable')){Require (-not $catalogTool.Contains('"'+$retiredMode+'"')) ('retired MapCatalog mode still exposed: '+$retiredMode)}
Require (-not $catalogTool.Contains('MapResourceCorrelation.ps1')) 'MapCatalog still loads MapResourceCorrelation'
Require (-not $catalogTool.Contains('RoomMapIdProbe.ps1')) 'MapCatalog still loads RoomMapIdProbe'

$binding=Read-Text 'Modules\MapCatalog\GameResourceBinding.ps1'
Require ($binding.Contains('Manual aliases are UI labels only in v3')) 'Game/Resource binding manual-alias rejection marker missing'
Require (-not $binding.Contains("source='confirmed_display_name_binding'")) 'manual display binding may still become authoritative'
Require (-not $binding.Contains("source='unique_catalog_display_alias'")) 'catalog display alias may still become authoritative'

$tel=Read-Text 'QQReplayTelemetry.ps1'
Require (-not($tel -match '(?m)^\s*Build-DriftSegments\b')) 'telemetry still calls heuristic Build-DriftSegments'
Require (-not($tel -match '(?m)^\s*Build-CornerSegments\b')) 'telemetry still calls legacy Build-CornerSegments'
Require (-not($tel -match '(?m)^\s*Detect-Laps\b')) 'telemetry still calls geometric Detect-Laps'
Require ($tel.Contains('Build-NativeLapSegments')) 'telemetry does not use replay-native lap_index segmentation'
Require ($tel.Contains("lap_schema_version=2")) 'telemetry native lap schema 2 marker missing'
# The summary schema revision is declared once and published from the constant, so a shape change
# cannot be forgotten (ADR 0008) and the shadow-summary guard is composed from it.
Require ($tel.Contains('$script:TelemetrySchemaVersion=')) 'telemetry schema revision constant missing'
Require ($tel.Contains('schema_version=$script:TelemetrySchemaVersion')) 'telemetry does not publish its schema revision'
Require ($tel.Contains('telemetry_semantic_signature')) 'telemetry shadow-summary signature missing'
Require ($tel.Contains('native_action_event_timeline')) 'telemetry per-event native action timeline output missing (driving v2 depends on it)'
Require ($tel.Contains("architecture='native_first_v1'")) 'telemetry native-first marker missing'
Require ($tel.Contains('unavailable_no_fallback')) 'native semantic no-fallback marker missing'
Require (-not($tel -match '(?<!system_)drift_segments=\$nativeDrifts')) 'v2 drift_segments compatibility alias must be removed'
Require ($tel.Contains('ReplayNativeComboActions.ps1')) 'telemetry combo module missing'
Require ($tel.Contains('map_propulsion_effect_segment_count')) 'telemetry code2003 map-propulsion output missing'
Require ($tel.Contains('combo_action_schema_version=2')) 'telemetry combo action schema missing'
Require ($tel.Contains("rawCacheContract='qpf_v2_nondec_ts_2026schema1_fastpipe1'")) 'telemetry qpf_v2 non-decreasing-timestamp raw-cache contract missing'
Require ($tel.Contains('PhysicalCacheDir')) 'telemetry persistent physical-cache parameter missing'
Require ($tel.Contains('pipeline_profile.json')) 'telemetry pipeline profile output missing'
Require ($tel.Contains('native_action_evidence_summary.json')) 'telemetry compact native-action evidence output missing'
Require ($tel.Contains('ExtractFastFromDelimited')) 'telemetry fast physical extractor path missing'
Require ($tel.Contains('NativeActionCacheRoot')) 'telemetry native action cache root parameter missing'
Require ($tel.Contains('ForceNativeActions')) 'telemetry explicit native action cache rebuild switch missing'
Require ($tel.Contains('native_action_cache_mode')) 'telemetry native action cache mode output missing'
Require ($tel.Contains('EffectTablePayload')) 'telemetry must replay the cached native effect table payload'

$actionCache=Read-Text 'Modules\Telemetry\ReplayNativeActionCache.ps1'
foreach($must in @("native_action_cache_v1","replay_native_action_suffix_scan_v2","native_action_tail.bin","Get-NativeActionTailForRescan","native_action_scanner_contract_mismatch","Get-NativeActionEffectTable")){
    Require ($actionCache.Contains($must)) ('native action cache contract marker missing: '+$must)
}
Require (-not($actionCache -match 'qpf_sha256')) 'native action cache validity must not bind the physical qpf hash'
Require (-not($actionCache -match 'semantic_type=')) 'native action cache must store raw evidence only, never semantic labels'

$driftNative=Read-Text 'Modules\Telemetry\ReplayNativeDriftTimeline.ps1'
Require ($driftNative.Contains('structural_drift_plus_adjacent_native_effect_pair')) 'Drift v3 must support the older unmarked Drift + adjacent native-effect action-object layout'
Require ($driftNative.Contains('Shift rises are diagnostic only')) 'Drift v3 must keep Shift diagnostic-only'
Require ($driftNative.Contains('empty_table=($count-eq0)')) 'Drift v2 must preserve authoritative empty table'
$fxNative=Read-Text 'Modules\Telemetry\ReplayNativeSpeedEffects.ps1'
Require ($fxNative.Contains('map_propulsion_effect')) 'code2003 map propulsion native effect contract missing'
$comboNative=Read-Text 'Modules\Telemetry\ReplayNativeComboActions.ps1'
foreach($sig in @('CW','WCW','CWW','native_effect_sequence_v2')){Require ($comboNative.Contains($sig)) ('combo action module missing '+$sig)}

$physical=Read-Text 'Modules\Telemetry\Telemetry.PhysicalStreams.ps1'
Require ($physical.Contains('function TP-ToDouble')) 'physical-stream adapter must own its invariant numeric parser'
Require ($physical.Contains('function TP-NormalizeRawSlip')) 'physical-stream adapter must own raw-slip normalization'
Require (-not $physical.Contains('To-Double $r.')) 'physical-stream adapter still depends on retired global To-Double helper'
Require (-not $physical.Contains('Normalize-RawSlip $rawSlip')) 'physical-stream adapter still depends on retired global Normalize-RawSlip helper'
Require ($physical.Contains('LoadFastRows')) 'physical-stream adapter qpf_v1 typed load missing'
Require ($physical.Contains("transport='qpf_v1'")) 'physical-stream adapter qpf_v1 transport marker missing'

$extractor=Read-Text 'Modules\Telemetry\QQReplayTelemetry.Core.cs'
Require ($extractor.Contains('phase==137')) '2026 embedded precise-pose +137 alias rejection missing'
Require ($extractor.Contains('aliasFiltered')) 'physical stream detector does not filter embedded pose rediscovery'
Require ($extractor.Contains('\"tool_version\":\"0.4.2\"')) 'physical stream extractor cache/tool version is not 0.4.2'
Require ($extractor.Contains('QQPFAST1')) 'qpf_v1 binary transport magic missing'
Require ($extractor.Contains('ValidateFastBin')) 'qpf_v1 structural cache validator missing'
Require ($extractor.Contains('WriteLogicalCsv')) 'typed logical CSV writer missing'
Require ($extractor.Contains('ExtractFastFromDelimited')) 'fast extraction entrypoint missing'

$analysisMod=Read-Text 'Modules\Telemetry\Telemetry.Analysis.ps1'
Require ($analysisMod.Contains('function Build-NativeLapSegments')) 'native lap segment builder missing'
foreach($retiredFn in @('function Detect-Laps','function Build-DriftSegments','function Build-CornerSegments','function Attach-DriftSegmentsToCorners')){Require (-not $analysisMod.Contains($retiredFn)) ('retired telemetry heuristic still present: '+$retiredFn)}

$csharp=Read-Text 'Modules\Telemetry\Telemetry.CSharpCore.ps1'
Require (-not $csharp.Contains('ReplayCore.TrackGeometry.cs')) 'production telemetry still compiles retired TrackGeometry core'
Require (-not $csharp.Contains('ReplayCore.CanonicalPath.cs')) 'production telemetry still compiles retired CanonicalPath core'

$nm=Read-Text 'QQNativeMap.ps1'
Require ($nm.Contains("contract='native_map_v1'")) 'native map contract missing'
Require ($nm.Contains("native_map_parse_diagnostic_v1")) 'unsupported native map must emit parse diagnostic contract'
Require ($nm.Contains("parser_scope='NiTriShape/NiTriStrips + NiTriShapeData/NiTriStripsData'")) 'native map diagnostic must state current parser scope'
Require ($nm.Contains('native_map_parse_diagnostic_collection_v2')) 'native map diagnostic WinPS 5.1 collection marker missing'
Require (-not $nm.Contains('System.Collections.Generic.List[object]')) 'native map unsupported-map diagnostics must not use the WinPS 5.1 generic List[object] array-subexpression path'
Require ($nm.Contains("diagnostic_collection='powershell_object_array_v2'")) 'native map diagnostic document must identify object-array v2 serialization'
Require ($nm.Contains('Diagnostic serialization must never hide the actual unsupported NIF evidence')) 'native map failure evidence must print before JSON serialization'
Require ($nm.Contains('Map\Common Map\Map{0}\map.nif')) 'official map.nif exact-path contract missing'
Require (-not $nm.Contains('SeedTelemetryPath')) 'native map must not accept replay seed fitting'
Require ($nm.Contains('NIF_QQSPEED_20_2_5_23 = 0x14020517u')) 'verified QQSpeed 20.2.5.23 reader version marker missing'
Require ($nm.Contains('QQSpeed 20.2.5.23 AV-tail signature mismatch')) 'modern AV-tail fail-closed signature gate missing'
Require ($nm.Contains('marker!=0||tag!=23u')) 'modern AV-tail exact signature check missing'
Require ($nm.Contains('qqspeed_20_2_5_23_av_tail_v1')) 'modern NativeMap reader profile missing'
Require ($nm.Contains('clean_surface_no_triangle_grid_v1')) 'Native map clean SVG surface style missing'
Require (-not $nm.Contains('stroke=\"#333\" stroke-width=\"0.65\"')) 'Native map triangle grid stroke must remain retired'
Require (-not $nm.Contains('NIF_QQSPEED_20_2_5_24')) '20.2.5.24 must not be promoted without separate evidence'
Require ($nm.Contains('Reader may apply only file-native AV transforms validated from NIF blocks')) 'native map transform authority guard missing'
$modernMapSmoke=Read-Text 'Tests\Smoke-NativeMapModernLayout.ps1'
Require ($modernMapSmoke.Contains('SelfTestModern')) 'modern NativeMap synthetic smoke missing'

# Runtime WinPS 5.1 diagnostic serialization contract used by QQNativeMap unsupported-map branch.
$diagRows=@()
$diagRows += [pscustomobject][ordered]@{source_vfs='data-test.vfs';source_path='Map\Common Map\Map999\map.nif';sha256='abc';decoded=$true;success=$false;error='unsupported-shape';header='Gamebryo File Format';version_hex='0x14020007';user_version=0;user_version2=0;num_blocks=2;block_types=[string[]]@('BSFadeNode','NiMesh');shape_blocks=0;decoded_shapes=0;hidden_shapes=0;vertices=0;triangles=0;best_projection=$null;warnings=[string[]]@('unsupported block type')}
$diagProbe=[ordered]@{contract='native_map_parse_diagnostic_v1';diagnostic_collection='powershell_object_array_v2';candidates=[object[]]$diagRows}
$diagProbeJson=$diagProbe|ConvertTo-Json -Depth 12
$diagProbeRoundTrip=$diagProbeJson|ConvertFrom-Json
Require ([string]$diagProbeRoundTrip.contract -eq 'native_map_parse_diagnostic_v1') 'native map diagnostic JSON round-trip contract failed'
Require (@($diagProbeRoundTrip.candidates).Count -eq 1) 'native map diagnostic JSON round-trip candidate array failed'
Require (@($diagProbeRoundTrip.candidates[0].block_types).Count -eq 2) 'native map diagnostic JSON round-trip block-types failed'

$na=Read-Text 'Modules\Native\NativeAnalysis.ps1'
Require ($na.Contains("schema_version=29")) 'native analysis schema 29 missing'
# DRIFT REGRESSION: the analysis schema is declared in TWO places - the manifest that consumers read
# and the production source that writes it. They silently diverged once (manifest 25, source 26), so
# the manifest value is now asserted to BE the source's value instead of a hand-copied number. The
# match is anchored on the analysis contract line, because the same file also publishes nested
# `schema_version` values for other blocks.
$sourceSchemaMatch=[regex]::Match($na,"schema_version=(\d+)\s*\r?\n\s*contract='native_first_analysis_v1'")
Require ($sourceSchemaMatch.Success) 'native analysis must publish a literal schema_version beside its contract'
Require ([int]$sourceSchemaMatch.Groups[1].Value -eq [int]$manifest.data_schemas.analysis) ('manifest analysis schema must equal the production source schema: manifest='+[string]$manifest.data_schemas.analysis+' source='+[string]$sourceSchemaMatch.Groups[1].Value)
Require ($na.Contains('training_analysis=')) 'native analysis training analysis output missing'
Require ($na.Contains('training_status=')) 'native analysis training status output missing'
Require ($na.Contains('segment_analysis=')) 'native analysis segmentation contract output missing'
Require ($na.Contains("contract='native_analysis_segments_v1'")) 'native analysis must publish the segmentation contract name'
$nas=Read-Text 'Modules\Native\NativeAnalysisSegments.ps1'
Require ($nas.Contains("schema_version=3")) 'native analysis segment schema 3 missing'
Require ($nas.Contains("nitro_recovery_policy='evidence_only_never_extends_segment'")) 'Nitro must remain evidence-only for Drift recovery ownership'
Require ($na.Contains('driving_episodes=')) 'native analysis driving episodes output missing'
Require ($na.Contains('driving_status=')) 'native analysis driving status output missing'
Require ($na.Contains("native_driving_sections_v1")) 'native analysis driving block missing'
Require ($na.Contains("compatibility_mode='none'")) 'native analysis compatibility must be none'
Require ($na.Contains("semantic_fallback='none'")) 'native analysis must explicitly disable semantic fallback'
Require (-not $na.Contains('legacy=[ordered]')) 'native v3 output must not carry a legacy compatibility block'
Require ($na.Contains("supported=@('CW','WCW','CWW')")) 'validated combo action surface missing'
Require ($na.Contains("native_code2003_map_propulsion_effect_validated_scene_geometry_driver_unresolved")) 'map propulsion / dynamic-scene geometry separation marker missing'

$nda=Read-Text 'Modules\Native\NativeDrivingAnalysis.ps1'
foreach($must in @('native_driving_sections_v1','production_telemetry_distance_resampled_curvature_on_official_map_world_xy','distance_resampled_multiscale_hysteresis_geometry_topology_v3','official_map.svg triangle projection','efficiency_semantics','authoritative=$false')){Require ($nda.Contains($must)) ('native driving analysis marker missing: '+$must)}
Require (-not $nda.Contains('track_coordinate_v1')) 'native driving analysis must not consume retired track_coordinate_v1'
Require (-not $nda.Contains('canonical_path')) 'native driving analysis must not consume a canonical path'
Require ($nda.Contains("drift_topology_policy='annotation_only'")) 'native Drift must remain annotation-only for Driving section topology'
Require ($nda.Contains("-ReferencedAssemblies 'System.Xml.dll'")) 'native driving geometry loader must explicitly reference System.Xml.dll for Windows PowerShell 5.1'
$ndg=Read-Text 'Modules\Native\NativeDrivingGeometry.Core.cs'
foreach($must in @('QQNativeDrivingSurfaceIndex','GetElementsByTagName("polygon")','ContainsWorld')){Require ($ndg.Contains($must)) ('native driving geometry core missing: '+$must)}

$fb=Read-Text 'Modules\Frontend\Frontend.Backend.ps1'
Require ($fb.Contains("NativeMaps\Map")) 'frontend backend must use NativeMaps'
Require (-not($fb -match "Join-Path \$dataDir \('MapCache")) 'frontend backend still resolves MapCache as active source'
Require ($fb.Contains('QQNativeMap.ps1') -or (Read-Text 'QQReplayFrontend.ps1').Contains('QQNativeMap.ps1')) 'frontend map builder is not QQNativeMap'
Require ($fb.Contains("else{'unknown'}")) 'frontend list must fail closed to unknown architecture metadata'
Require (-not $fb.Contains("track_coordinate_status='retired_v3'")) 'frontend backend must not emit retired track-coordinate compatibility state'
Require ($fb.Contains("-Filter '*_analysis.json'")) 'frontend replay list must only inspect canonical analysis artifacts'
# The list authority is the catalog's EXPLICIT VISIBILITY axis. The absent-catalog fallback that
# listed every derived analysis is gone, and a derived analysis can never make a replay visible.
Require ($fb.Contains('Read-ReplayCatalog') -and $fb.Contains('Get-ReplayCatalogVisibleEntries')) 'frontend replay list must use the catalog visibility axis as its authority'
Require (-not $fb.Contains('$catalogAuthoritative')) 'the absent-catalog derived-store fallback must not come back'
Require ($fb.Contains('is NOT permission to fall back to "every derived analysis in')) 'frontend list must document its fail-closed rule'
Require ($fb.Contains('Training/comparison artifacts in Output must never grow a second replay card')) 'frontend replay-entity dedupe contract marker missing'

$catMod=Read-Text 'Modules\Replay\Replay.Catalog.ps1'
Require ($catMod.Contains('Get-ReplayAnalysisShaIndex')) 'catalog must index which analyses currently exist'
Require ($catMod.Contains('Complete-ReplayCatalogVisibility')) 'catalog must carry the one-time visibility completion'
Require ($catMod.Contains('Set-ReplayCatalogEntryVisibility')) 'catalog must set visibility for every entry shape it can hold'
Require ($catMod.Contains('Sync-ReplayCatalogVisibility')) 'catalog must expose the explicit visibility sync'
Require ($catMod.Contains('Visibility is a SEPARATE axis from lifecycle')) 'catalog must document the visibility contract'
Require ($catMod.Contains('never make a replay reappear')) 'catalog must document that derived data cannot change visibility'

# The frontend source is split across index.html + css/app.css + js/app.js.
# Every frontend assertion below applies to the combined frontend source, so the
# split cannot silently drop an asserted behaviour marker.
#
# Product UI contract (ADR 0012 map-centric workspace, ADR 0013 Drift-segment default, and the
# Analysis Closure v1 segmentation/comparison contracts): the map is the navigator, the automatic
# unit is the analyzer's published segment (native Drift start -> native recovery end), and the
# comparison NUMBERS come from the server contract. The browser is a renderer, never a second
# authority, so the retired in-browser matchers are asserted ABSENT.
$frontendParts=@('Modules\Frontend\index.html','Modules\Frontend\css\app.css','Modules\Frontend\js\app.js')
$html=(@($frontendParts | ForEach-Object { Read-Text $_ }) -join "`n")
Require ($html.Contains("contract==='native_map_v1'")) 'frontend native map contract gate missing'
Require ($html.Contains('/api/map-meta')) 'frontend native map metadata endpoint missing'
Require ($html.Contains('nativeMapContractOk')) 'frontend must fail closed on a non-native map metadata payload'
Require (-not $html.Contains('Data\\MapCache\\Map')) 'frontend HTML still loads MapCache'
Require (-not $html.Contains("?'Native':'Legacy'")) 'frontend list must not expose Legacy architecture mode'
Require (-not $html.Contains("?'Native-First':'Legacy'")) 'frontend detail must not expose Legacy architecture mode'
Require ($html.Contains('if(!lap)return null')) 'same-lap compare must not silently fall back to full replay when B lap is absent'
Require (-not $html.Contains('matchSections(A,B)')) 'the retired browser section matcher must not return'
Require (-not $html.Contains('monotonicSectionAlignmentV2(A,B)')) 'the retired browser section alignment must not return'
Require (-not $html.Contains('spatialGateAlignment')) 'the retired browser common-gate matcher must not return'
Require (-not $html.Contains('continuousSectionCompare')) 'the retired browser continuous comparison core must not return'
Require (-not $html.Contains('各自实际路程 0–100% 归一化')) 'retired independent-progress continuous A/B semantics must not remain active'
Require (-not $html.Contains('0–1 漂移效率')) 'the retired derived-efficiency boundary text must not return'
# Analysis Closure v1: segmentation and comparison come from the analyzer's published contracts.
Require ($html.Contains('native_analysis_segments_v1')) 'frontend must consume the published segmentation contract'
Require ($html.Contains('serverSegmentsForLap')) 'frontend must read the automatic segment list from the contract'
Require ($html.Contains('/api/segment-comparison')) 'frontend must request the authoritative comparison contract'
Require ($html.Contains('native_segment_comparison_v1')) 'frontend must name the comparison contract it consumes'
Require ($html.Contains('serverWindowForSector')) 'frontend must join its own segment to the authoritative window'
# The browser is a renderer of the server contract, never a second authority: every published
# segment metric (A/B side by side, in its display unit) must be rendered from `serverMetrics`.
# The surface moved from a single joined summary string into a dedicated metric panel, so the
# assertion tracks the capability: the metric table, the display conversion and the renderer.
Require ($html.Contains('METRIC_LABELS') -and $html.Contains('metricDisplayValue') -and $html.Contains('renderSectorMetrics') -and $html.Contains('serverMetrics')) 'frontend must render the published segment metrics'
Require ($html.Contains("game_speed")) 'frontend must render published speeds through the game display unit'
Require ($html.Contains('uiSegmentFromServer') -and $html.Contains('uiSegmentFromMerge')) 'frontend must carry one normalized UI segment shape'
Require ($html.Contains('recoverySource')) 'frontend must record whether a recovery end came from the contract'
Require ($html.Contains('ensureViewModel') -and $html.Contains('invalidateViewModel')) 'frontend must cache the derived analysis view model'
Require ($html.Contains('viewRevision')) 'frontend must expose the view-model rebuild counter used by the no-recompute contract'
Require ($html.Contains('view.x=e.clientX;view.y=e.clientY;redrawCanvas()')) 'panning must only redraw the canvas, never rebuild the analysis'
Require ($html.Contains('function redrawCanvas')) 'frontend must separate canvas redraw from analysis recomputation'
Require ($html.Contains('streamByRoleIfUnique')) 'stream ownership must resolve by exact identity with a unique-role fallback only'
Require ($html.Contains('DRIFT_SEGMENT_MERGE_GAP_S=.15')) 'the durable 0.15 s logical-Drift merge must stay pinned'
Require ($html.Contains('EXIT_SMALL_BOOST_WINDOW_S=2.0')) 'the durable 2.0 s recovery window must stay pinned'
# Product surface: map-centric local inspector, custom path from A only, no faked comparison.
Require ($html.Contains('renderInspector')) 'frontend local section inspector missing'
Require ($html.Contains('hitSector')) 'frontend route hit-testing for local inspection missing'
Require ($html.Contains('autoMapCustomReference')) 'frontend custom path must map B from the A interval'
Require ($html.Contains('setCompareControlEnabled')) 'frontend comparison control must be disable-able when no counterpart exists'
Require ($html.Contains('没有可比圈')) 'frontend must state that no comparable lap exists instead of faking one'
Require ($html.Contains('data-route-mode="recovery"')) 'frontend must keep the Drift-start to recovery-end route mode'
Require ($html.Contains('class="modeBtn active" data-route-mode="recovery"')) 'the default route mode must be Drift start -> recovery end'
Require ($html.Contains('function firstLap')) 'frontend must open on lap 1 without a fastest-lap fallback'
Require ($html.Contains("laps.find(l=>Number(l.lap)===1)")) 'frontend lap-1 rule missing'
Require ($html.Contains('data-route-mode="custom"')) 'frontend custom path mode missing'
Require (-not $html.Contains("algorithm:'monotonic_xy_common_gate_preview_v2'")) 'the retired browser common-gate quality marker must not return'

$refresh=Read-Text 'QQReplayRefresh.ps1'
Require (-not $refresh.Contains('Retire-QQReplayLegacyArchitecture')) 'refresh must not contain source-retirement migration logic'
Require ($refresh.Contains('child_error_stream_isolation_v1')) 'refresh child stderr isolation marker missing'
Require ($refresh.Contains('child_argument_forwarding_v1') -and $refresh.Contains('@ChildArguments') -and $refresh.Contains('-ChildArguments @(') -and -not $refresh.Contains('@Args')) 'refresh must explicitly forward child arguments without reusing automatic $Args'
Require ($refresh.Contains('NativeMap ready=')) 'refresh must report native map ready/missing corpus counts'
Require (-not $refresh.Contains('QQTrackTopology.ps1')) 'refresh must not rebuild TrackTopology'
Require ($refresh.Contains('底图=官方 map.nif')) 'refresh native map summary missing'
Require (-not($refresh -match 'Reset-Dir\s+.*ReplayArchive')) 'refresh must preserve raw ReplayArchive'

$dev=Read-Text 'Modules\Replay\Replay.DevRebuild.ps1'
Require ($dev.Contains("'NativeIdentity'")) 'NativeIdentity reset contract missing'
Require (-not($dev -match "Reset-Dir\s+\(Join-Path \$DataDir 'ReplayArchive'")) 'development rebuild must preserve ReplayArchive'
Require (-not $dev.Contains('Retire-QQReplayLegacyArchitecture')) 'development rebuild module must not contain source-retirement migration logic'
foreach($obsolete in @('V2_Retired_App','ReplayFingerprints','MapCache','TrackModels','MapModels','ValidatedEvidence')){Require (-not $dev.Contains($obsolete)) ('development rebuild still carries pre-cutover path: '+$obsolete)}

$bootstrap=Read-Text 'ProjectBootstrap.ps1'
Require ($bootstrap.Contains('QQReplayFrontend.ps1')) 'bootstrap must launch the frontend entrypoint'
foreach($obsolete in @('RootMigration','Data\Legacy','Get-ChildItem -LiteralPath $projectRoot','Move-Item')){Require (-not $bootstrap.Contains($obsolete)) ('bootstrap still carries root-migration behavior: '+$obsolete)}

# Runtime preservation contract: development rebuild may clear current derived outputs,
# but must not touch raw replay or validated persistent caches.
$tempRebuildRoot=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_RebuildContract_'+[Guid]::NewGuid().ToString('N'))
try {
    $tempRebuildData=Join-Path $tempRebuildRoot 'Data'
    New-Item -ItemType Directory -Force -Path $tempRebuildData|Out-Null
    . (Join-Path $appDir 'Modules\Replay\Replay.DevRebuild.ps1')
    $cacheSentinel=Join-Path $tempRebuildData 'PhysicalTelemetryCache\sentinel.qpf'
    $actionCacheSentinel=Join-Path $tempRebuildData 'NativeActionCache\ABCDEF0123456789\manifest.json'
    $rawSentinel=Join-Path $tempRebuildData 'ReplayArchive\sentinel.sav'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cacheSentinel)|Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $actionCacheSentinel)|Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $rawSentinel)|Out-Null
    [IO.File]::WriteAllBytes($cacheSentinel,[byte[]](1,2,3,4))
    [IO.File]::WriteAllText($actionCacheSentinel,'{"contract":"native_action_cache_v1"}',(New-Object System.Text.UTF8Encoding($true)))
    [IO.File]::WriteAllBytes($rawSentinel,[byte[]](5,6,7,8))
    $devProbe=Reset-QQReplayDevelopmentDerivedData -ProjectRoot $tempRebuildRoot -DataDir $tempRebuildData
    Require (Test-Path -LiteralPath $cacheSentinel -PathType Leaf) 'development rebuild must preserve validated physical telemetry cache'
    Require (Test-Path -LiteralPath $actionCacheSentinel -PathType Leaf) 'development rebuild must preserve validated native action cache'
    Require (Test-Path -LiteralPath $rawSentinel -PathType Leaf) 'development rebuild must preserve ReplayArchive'
    Require (@($devProbe.preserved) -contains (Join-Path $tempRebuildData 'PhysicalTelemetryCache')) 'development rebuild manifest must report physical telemetry cache preservation'
    Require (@($devProbe.preserved) -contains (Join-Path $tempRebuildData 'NativeActionCache')) 'development rebuild manifest must report native action cache preservation'
} finally { Remove-Item -LiteralPath $tempRebuildRoot -Recurse -Force -ErrorAction SilentlyContinue }

$idr=Read-Text 'Modules\Replay\Replay.MapIdentityResolver.ps1'
Require ($idr.Contains("NativeIdentity\map_registry.json")) 'identity registry must live under NativeIdentity'
Require (-not $idr.Contains("MapModels\map_registry.json")) 'identity registry must not recreate retired MapModels'

Write-Host '[OK] Native-First Architecture v1 smoke passed. app=3.7.24 production=official-identity/production-telemetry/native-actions/map.nif(native-reader-v2)/native-driving-sections(detector-v3) combos=CW/WCW/CWW map-propulsion=2003 migration=absent semantic-fallback=none'
exit 0
