param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}

# =============================================================================================
# Replay visibility regression (release blocker).
#
# Contract:
#     VisibleAfterImport = VisibleBeforeImport + ExplicitlyImportedReplay - ExplicitlyDeleted
#
# The visible list is the Replay Catalog's EXPLICIT VISIBILITY axis. Two things must never make a
# replay appear:
#   * a derived analysis appearing in Output (a tooling run, an acceptance sweep), and
#   * an absent catalog falling back to "every *_analysis.json in Output".
#
# The REAL Modules\Replay\Replay.Catalog.ps1 and Modules\Frontend\Frontend.Backend.ps1 are copied
# verbatim into a sandbox and dot-sourced, so the gate exercises the production functions
# (Add-ReplayCatalogEntry / Set-ReplayCatalogEntryState / Get-ReplayAnalysisShaIndex /
# Get-ReplayCatalogVisibleEntries / Get-AnalysisList) and not a model of them.
# =============================================================================================
$dataDir=Split-Path -Parent $AppDir
$dev=Join-Path $dataDir 'Diagnostics\Dev'
New-Item -ItemType Directory -Force -Path $dev | Out-Null
$sandbox=Join-Path $dev ('visibility_'+[Guid]::NewGuid().ToString('N'))
$sbData=Join-Path $sandbox 'Data'
$sbApp=Join-Path $sbData 'App'
$sbOutput=Join-Path $sandbox 'Output'
$sbArchive=Join-Path $sbData 'ReplayArchive'
$sbLabels=Join-Path $sbData 'replay_labels.json'
$sbManual=Join-Path $sbData 'manual_map_names.json'
New-Item -ItemType Directory -Force -Path $sbApp,$sbOutput,$sbArchive | Out-Null
Copy-Item -LiteralPath (Join-Path $AppDir 'Modules\Replay\Replay.Catalog.ps1') -Destination (Join-Path $sbApp 'Replay.Catalog.ps1.tmp') -Force
New-Item -ItemType Directory -Force -Path (Join-Path $sbApp 'Modules\Replay'),(Join-Path $sbApp 'Modules\Frontend') | Out-Null
Move-Item -LiteralPath (Join-Path $sbApp 'Replay.Catalog.ps1.tmp') -Destination (Join-Path $sbApp 'Modules\Replay\Replay.Catalog.ps1') -Force
Copy-Item -LiteralPath (Join-Path $AppDir 'Modules\Frontend\Frontend.Backend.ps1') -Destination (Join-Path $sbApp 'Modules\Frontend\Frontend.Backend.ps1') -Force

# Script-scope state that Frontend.Backend.ps1 expects from the frontend entry point.
$root=$sandbox
$outputDir=$sbOutput
$dataDir=$sbData
$replayArchiveRoot=$sbArchive
$labelsPath=$sbLabels
$manualMapNamesPath=$sbManual
$encBom=New-Object System.Text.UTF8Encoding($true)

. (Join-Path $sbApp 'Modules\Replay\Replay.Catalog.ps1')
. (Join-Path $sbApp 'Modules\Frontend\Frontend.Backend.ps1')

function New-VisReplay([string]$Name,[int]$Seed){
    [byte[]]$b=New-Object byte[] 2048
    for($i=0;$i -lt $b.Length;$i++){ $b[$i]=[byte](($i*17+$Seed)%251) }
    $ms=New-Object IO.MemoryStream(,$b)
    try { $sha=(Get-FileHash -InputStream $ms -Algorithm SHA256).Hash.ToUpperInvariant() } finally { $ms.Dispose() }
    $dir=Join-Path $sbArchive $sha.Substring(0,16)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $sav=Join-Path $dir $Name
    [IO.File]::WriteAllBytes($sav,$b)
    [IO.File]::WriteAllText((Join-Path $dir 'archive.json'),(ConvertTo-Json -InputObject ([ordered]@{schema_version=1;sha256=$sha;original_name=$Name;archived_at=(Get-Date).ToString('o');source='web_upload'}) -Depth 4),$encBom)
    return [pscustomobject]@{name=$Name;sha=$sha;sha16=$sha.Substring(0,16);path=$sav;size=[long]$b.Length;rel=('Data/ReplayArchive/'+$sha.Substring(0,16)+'/'+$Name)}
}
# A derived analysis artifact, shaped like the real one (identity early in the document).
function Write-VisAnalysis([object]$R){
    $obj=[ordered]@{
        schema_version=29;contract='native_first_analysis_v1';architecture='native_first_v1'
        compatibility_mode='none';replay_file=$R.name;replay_sha256=$R.sha
        map_name='SYNTH';resource_map_id=900;game_map_id=900;status='native_ready'
        streams=@([ordered]@{id='shadow_local';role='local_high_frequency';records=10;duration_s=1.0;lap_count=1})
    }
    $name=([IO.Path]::GetFileNameWithoutExtension($R.name))+'_analysis.json'
    [IO.File]::WriteAllText((Join-Path $outputDir $name),(ConvertTo-Json -InputObject $obj -Depth 6),$encBom)
    return $name
}
function Remove-VisAnalysis([object]$R){
    $name=([IO.Path]::GetFileNameWithoutExtension($R.name))+'_analysis.json'
    $p=Join-Path $outputDir $name
    if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Force}
}
# The visible set as the UI sees it: the file name (or '') of every card, sorted.
function Get-VisibleSet {
    $names=New-Object System.Collections.Generic.List[string]
    foreach($it in @(Get-AnalysisList)){
        $names.Add([string]$it.file)
    }
    return (@($names.ToArray()|Sort-Object) -join ',')
}
# The real explicit-import sequence: catalog activation first, then the analyzer writes the artifact.
# It follows the CURRENT sandbox ($dataDir/$outputDir), so the legacy scenario can reuse it.
function Invoke-VisImport([object]$R){
    [void](Add-ReplayCatalogEntry -DataDir $dataDir -Sha256 $R.sha -SourceRelPath $R.rel -OriginalName $R.name -SizeBytes $R.size -SourcePresent $true -AnalysisDir $outputDir)
    return (Write-VisAnalysis $R)
}

$keepSandbox=$true
try {
    $A=New-VisReplay -Name 'replayA.sav' -Seed 11
    $B=New-VisReplay -Name 'replayB.sav' -Seed 22
    $C=New-VisReplay -Name 'replayC.sav' -Seed 33
    $D=New-VisReplay -Name 'replayD.sav' -Seed 44
    $X=New-VisReplay -Name 'replayX.sav' -Seed 55
    $Y=New-VisReplay -Name 'replayY.sav' -Seed 66
    $Z=New-VisReplay -Name 'replayZ.sav' -Seed 77

    # ---- 1. an absent catalog must NOT surface the derived store ----------------------------
    foreach($r in @($A,$B,$C,$D)){ [void](Write-VisAnalysis $r) }
    Require ((Get-VisibleSet)-eq'') 'an absent Replay Catalog must produce an EMPTY list, never the whole derived store'
    Write-Host '[OK] absent catalog -> visible list is empty (no derived-store fallback)'

    # ---- 2. explicit import activates exactly one replay ------------------------------------
    [void](Invoke-VisImport $A)
    Require ((Get-VisibleSet)-eq'replayA_analysis.json') ('after importing A the list must be exactly A, saw '+(Get-VisibleSet))
    Write-Host '[OK] first explicit import -> exactly the imported replay'

    # ---- 3. historical derivations stay invisible -------------------------------------------
    # B/C/D all have a derived analysis. Only an explicit import may surface them.
    $Bstate=(Get-ReplayCatalogEntries -DataDir $sbData | Where-Object { $_.sha256 -eq $B.sha })
    if($null-eq$Bstate){ [void](Add-ReplayCatalogEntry -DataDir $sbData -Sha256 $B.sha -SourceRelPath $B.rel -OriginalName $B.name -SizeBytes $B.size -SourcePresent $true -AnalysisDir $sbOutput); [void](Set-ReplayCatalogEntryState -DataDir $sbData -Sha256 $B.sha -State 'removed') }
    Require ((Get-VisibleSet)-eq'replayA_analysis.json') ('a derived analysis for a non-visible replay must not surface it, saw '+(Get-VisibleSet))
    Write-Host '[OK] derived analyses of B/C/D do not surface'

    # ---- 4. upload X, then Y ----------------------------------------------------------------
    [void](Invoke-VisImport $X)
    Require ((Get-VisibleSet)-eq'replayA_analysis.json,replayX_analysis.json') ('after upload X the list must be A,X, saw '+(Get-VisibleSet))
    [void](Invoke-VisImport $Y)
    Require ((Get-VisibleSet)-eq'replayA_analysis.json,replayX_analysis.json,replayY_analysis.json') ('after upload Y the list must be A,X,Y, saw '+(Get-VisibleSet))
    Write-Host '[OK] upload X/Y added exactly X and Y (VisibleAfterImport = VisibleBeforeImport + imported)'

    # ---- 5. explicit delete removes only that replay ----------------------------------------
    [void](Set-ReplayCatalogEntryState -DataDir $sbData -Sha256 $X.sha -State 'removed')
    Remove-VisAnalysis $X
    Require ((Get-VisibleSet)-eq'replayA_analysis.json,replayY_analysis.json') ('after deleting X the list must be A,Y, saw '+(Get-VisibleSet))
    Write-Host '[OK] explicit delete removed exactly X'

    # ---- 6. a tooling run that (re)creates derived analyses must change nothing --------------
    # This is the field failure: an acceptance/batch sweep re-materialised *_analysis.json for the
    # whole archive and a batch of replays reappeared.
    foreach($r in @($B,$C,$D,$X)){ [void](Write-VisAnalysis $r) }
    Require ((Get-VisibleSet)-eq'replayA_analysis.json,replayY_analysis.json') ('a tooling run creating derived analyses must not change the visible list, saw '+(Get-VisibleSet))
    Write-Host '[OK] tooling-created derived analyses did not resurrect anything'

    # ---- 7. re-import of a deleted replay brings back only itself ---------------------------
    [void](Invoke-VisImport $X)
    Require ((Get-VisibleSet)-eq'replayA_analysis.json,replayX_analysis.json,replayY_analysis.json') ('re-importing X must restore exactly X, saw '+(Get-VisibleSet))
    Write-Host '[OK] re-import restored exactly X'

    # ---- 8. reload stability ---------------------------------------------------------------
    $before=Get-VisibleSet
    $again=Get-VisibleSet
    Require ($before-eq$again) 'repeated list reads must be stable'
    Write-Host '[OK] repeated list reads are stable'

    # ---- 9. legacy catalog entries (no `visible` field) are frozen once, conservatively -----
    # A catalog written before the visibility axis existed, with one active entry that has an
    # analysis and one that does not. The current UI shows only the first; the one-time completion
    # must freeze exactly that, so a later analysis for the second can never surface it.
    $legacySandbox=Join-Path $dev ('visibility_legacy_'+[Guid]::NewGuid().ToString('N'))
    $legData=Join-Path $legacySandbox 'Data'
    $legOutput=Join-Path $legacySandbox 'Output'
    New-Item -ItemType Directory -Force -Path (Join-Path $legData 'ReplayCatalog'),$legOutput | Out-Null
    $oldOutput=$outputDir;$oldData=$dataDir
    $outputDir=$legOutput;$dataDir=$legData
    [IO.File]::WriteAllText((Join-Path $legOutput 'replayA_analysis.json'),(ConvertTo-Json -InputObject ([ordered]@{schema_version=29;contract='native_first_analysis_v1';replay_file=$A.name;replay_sha256=$A.sha;status='native_ready';streams=@([ordered]@{id='shadow_local';role='local_high_frequency';records=5})}) -Depth 6),$encBom)
    $legacyDoc=[ordered]@{contract='replay_catalog_v1';schema_version=1;updated_at=(Get-Date).ToString('o');entries=@(
        [ordered]@{sha256=$A.sha;sha16=$A.sha16;source_rel_path=$A.rel;original_name=$A.name;state='active';added_at=(Get-Date).ToString('o');removed_at=$null;size_bytes=1;source_present=$true},
        [ordered]@{sha256=$B.sha;sha16=$B.sha16;source_rel_path=$B.rel;original_name=$B.name;state='active';added_at=(Get-Date).ToString('o');removed_at=$null;size_bytes=1;source_present=$true}
    )}
    [IO.File]::WriteAllText((Join-Path $legData 'ReplayCatalog\replay_catalog.json'),(ConvertTo-Json -InputObject $legacyDoc -Depth 6),$encBom)
    Require ((Get-VisibleSet)-eq'replayA_analysis.json') ('a legacy active entry without an analysis must not be listed, saw '+(Get-VisibleSet))
    [void](Invoke-VisImport $Z)   # this mutation performs the one-time completion
    Require ((Get-VisibleSet)-eq'replayA_analysis.json,replayZ_analysis.json') ('the one-time completion must keep only the currently visible replay, saw '+(Get-VisibleSet))
    Write-Host '[OK] legacy entries froze at the currently visible set during the next explicit import'
    $outputDir=$oldOutput;$dataDir=$oldData

    $keepSandbox=$false
    Write-Host '[OK] Replay visibility regression passed. contract=VisibleAfterImport=VisibleBeforeImport+Imported-Deleted; absent-catalog=empty; derived-does-not-surface; tooling-run=no-resurrection; legacy=one-time-conservative-freeze'
    exit 0
} finally {
    if($keepSandbox){ Write-Host ('[KEEP] sandbox kept for diagnosis: '+$sandbox) }
    else { if(Test-Path -LiteralPath $sandbox){ Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } }
    if(Test-Path -LiteralPath $legacySandbox){ Remove-Item -LiteralPath $legacySandbox -Recurse -Force -ErrorAction SilentlyContinue }
}
