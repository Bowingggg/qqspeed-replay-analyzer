# Output-root documents a destructive derived rebuild must never delete.
#
# <PROJECT_ROOT>\Output is the published, user-facing surface: analysis JSON (derived, rebuildable)
# plus the handoff / validation documents a human reads. A milestone cold reset clears the derived
# analysis JSON, but it may never silently remove the documents that tell the user what to verify.
# This is the single declaration of that set, so every reset path preserves exactly the same files.
function Get-QQReplayOutputPreservedNames {
    return @(
        'USER_VALIDATION.md',
        'VALIDATION_SUMMARY.md',
        'MAP_CONFIRMATION_REQUIRED.md',
        'TRAINING_VALIDATION.md',
        'TRAINING_ANALYSIS_BASELINE.md',
        'TRAINING_ANALYSIS_FINAL.md'
    )
}

function Reset-QQReplayDevelopmentDerivedData {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$DataDir,
        # Milestone / acceptance switch. The default daily-use rebuild deliberately keeps the two
        # validated transport/evidence caches (their lifecycles are independent of derived data), so
        # a normal rebuild can never be used as evidence of cold parser coverage. A TRUE COLD run
        # (replay readiness acceptance) must be able to clear them explicitly; that is the only
        # caller of this switch. Replay sources and every user fact are preserved either way.
        [switch]$IncludeValidatedCaches
    )
    $ErrorActionPreference='Stop'
    # PhysicalTelemetryCache (qpf_v1) and NativeActionCache (raw native action evidence + tail window)
    # are validated caches with independent lifecycles; a derived rebuild never clears either.
    function Reset-Dir([string]$Path){if(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Recurse -Force};New-Item -ItemType Directory -Force -Path $Path|Out-Null}
    $outputDir=Join-Path $ProjectRoot 'Output'
    $reset=@($outputDir,(Join-Path $DataDir 'Telemetry'),(Join-Path $DataDir 'ReplayResolution'),(Join-Path $DataDir 'NativeMaps'),(Join-Path $DataDir 'NativeIdentity'),(Join-Path $DataDir 'Diagnostics'),(Join-Path $DataDir 'Logs'),(Join-Path $DataDir 'WebUpload'))
    $validatedCaches=@((Join-Path $DataDir 'PhysicalTelemetryCache'),(Join-Path $DataDir 'NativeActionCache'))
    if($IncludeValidatedCaches){$reset+= $validatedCaches}
    foreach($p in $reset){Reset-Dir $p}
    $catalogDir=Join-Path $DataDir 'MapCatalog';New-Item -ItemType Directory -Force -Path $catalogDir|Out-Null
    # display_aliases_manual.json and user_confirmed_game_resource_bindings.json are USER FACTS, not
    # derived catalog output. A derived rebuild (cold or warm) never deletes either.
    $userFactFiles=@('display_aliases_manual.json','user_confirmed_game_resource_bindings.json')
    foreach($child in @(Get-ChildItem -LiteralPath $catalogDir -Force -ErrorAction SilentlyContinue)){
        if($userFactFiles -contains $child.Name){continue}
        Remove-Item -LiteralPath $child.FullName -Recurse -Force
    }
    $preserved=@((Join-Path $DataDir 'ReplayArchive'),(Join-Path $ProjectRoot 'replay'),(Join-Path $DataDir 'ReplayCatalog'),(Join-Path $DataDir 'settings.json'),(Join-Path $DataDir 'replay_labels.json'),(Join-Path $DataDir 'manual_map_names.json'))
    foreach($f in $userFactFiles){$preserved+=(Join-Path $catalogDir $f)}
    if(-not $IncludeValidatedCaches){$preserved+= $validatedCaches}
    return [ordered]@{ok=$true;policy='native_first_v3_destructive_pre_release_rebuild';true_cold=[bool]$IncludeValidatedCaches;reset_directories=$reset;preserved=$preserved}
}
