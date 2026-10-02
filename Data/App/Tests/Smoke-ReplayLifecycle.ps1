param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}

# ---------------------------------------------------------------------------
# Replay lifecycle regression: Source Store vs Replay Catalog vs Derived Store.
#
# Contract:
#   Source exists  !=  Replay active  !=  Derived exists
#
#   import C            -> activates and analyses ONLY C
#   refresh ("重构数据") -> rebuild of the CURRENT LIST INTERSECT catalog active INTERSECT source
#                          present; the derived store alone never resurrects a replay
#   removed             -> never resurrected by source presence
#   explicit re-import  -> removed becomes active again
#   clear derived       -> state unchanged; nothing rebuilt
#
# Reproduction method: the REAL QQReplayRefresh.ps1 and the REAL
# Replay.Catalog.ps1 are copied verbatim into a sandbox laid out exactly like
# production (<root>\Data\App, <root>\Data\ReplayArchive, <root>\Output) and
# executed as the frontend executes them. Byte equality with production is
# asserted (SHA256), so the test cannot drift from the real entry points. Only
# the two heavy leaf children are replaced:
#   QQReplay.ps1           -> records which replay it was asked to analyse
#   QQSpeedMapCatalog.ps1  -> no-op success (map catalog is out of scope)
# ---------------------------------------------------------------------------

$dataDir=Split-Path -Parent $AppDir
$dev=Join-Path $dataDir 'Diagnostics\Dev'
New-Item -ItemType Directory -Force -Path $dev | Out-Null
$sandbox=Join-Path $dev ('lifecycle_'+[Guid]::NewGuid().ToString('N'))
$sandboxData=Join-Path $sandbox 'Data'
$sandboxApp=Join-Path $sandboxData 'App'
$archive=Join-Path $sandboxData 'ReplayArchive'
$outputDir=Join-Path $sandbox 'Output'
$recorderLog=Join-Path $sandboxData 'recorder.log'
$encNoBom=New-Object System.Text.UTF8Encoding($false)
$encBom=New-Object System.Text.UTF8Encoding($true)

function New-SandboxReplay([string]$Name,[int]$Seed){
    [byte[]]$b=New-Object byte[] 4096
    for($i=0;$i -lt $b.Length;$i++){ $b[$i]=[byte](($i*31+$Seed)%251) }
    $ms=New-Object IO.MemoryStream(,$b)
    try { $sha=(Get-FileHash -InputStream $ms -Algorithm SHA256).Hash.ToUpperInvariant() } finally { $ms.Dispose() }
    $dir=Join-Path $archive $sha.Substring(0,16)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $sav=Join-Path $dir $Name
    [IO.File]::WriteAllBytes($sav,$b)
    [IO.File]::WriteAllText((Join-Path $dir 'archive.json'),(ConvertTo-Json -InputObject ([ordered]@{schema_version=1;sha256=$sha;original_name=$Name;archived_at=(Get-Date).ToString('o');source='test'}) -Depth 4),$encBom)
    return [pscustomobject]@{name=$Name;path=$sav;sha=$sha;rel=('Data/ReplayArchive/'+$sha.Substring(0,16)+'/'+$Name);size=[long]$b.Length}
}
function Get-Recorded { if(-not(Test-Path -LiteralPath $recorderLog -PathType Leaf)){return @()}; return @([IO.File]::ReadAllLines($recorderLog)|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}) }
function Reset-Recorder { if(Test-Path -LiteralPath $recorderLog){Remove-Item -LiteralPath $recorderLog -Force} }
function Set-Analysis([object]$R){ New-Item -ItemType Directory -Force -Path $outputDir|Out-Null; $n=($R.name -replace '\.sav$','')+'_analysis.json'; [IO.File]::WriteAllText((Join-Path $outputDir $n),(ConvertTo-Json -InputObject ([ordered]@{replay_file=$R.name;replay_sha256=$R.sha}) -Depth 3),$encBom) }
function Clear-Analysis([object]$R){ $n=($R.name -replace '\.sav$','')+'_analysis.json'; $f=Join-Path $outputDir $n; if(Test-Path -LiteralPath $f){Remove-Item -LiteralPath $f -Force} }
function Get-State([object]$R){ $read=Read-ReplayCatalog -DataDir $sandboxData; foreach($e in @($read.document.entries)){ if([string]$e.sha256 -eq $R.sha){return [string]$e.state} }; return 'absent' }
function Invoke-Analyzer([object]$R){ & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $sandboxApp 'QQReplay.ps1') -Mode Analyze -Items $R.path | Out-Null }
function Invoke-Refresh { & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $sandboxApp 'QQReplayRefresh.ps1') | Out-Null; return [int]$LASTEXITCODE }
# Production import order: archive source -> catalog active -> analyse that replay only.
function Invoke-Import([object]$R){ [void](Add-ReplayCatalogEntry -DataDir $sandboxData -Sha256 $R.sha -SourceRelPath $R.rel -OriginalName $R.name -SizeBytes $R.size -SourcePresent $true); Invoke-Analyzer $R }

$keepSandbox=$true
try {
    # ---- sandbox ----------------------------------------------------------
    New-Item -ItemType Directory -Force -Path $sandboxData | Out-Null
    Copy-Item -LiteralPath $AppDir -Destination $sandboxApp -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $sandboxApp 'Tests') -Recurse -Force -ErrorAction SilentlyContinue
    foreach($rel in @('QQReplayRefresh.ps1','Modules\Replay\Replay.Catalog.ps1')){
        $p=Get-FileHash -LiteralPath (Join-Path $AppDir $rel) -Algorithm SHA256
        $t=Get-FileHash -LiteralPath (Join-Path $sandboxApp $rel) -Algorithm SHA256
        Require ($p.Hash -eq $t.Hash) ('sandbox '+$rel+' must be byte-identical to production')
    }
    [IO.File]::WriteAllText((Join-Path $sandboxApp 'QQReplay.ps1'), @'
$ErrorActionPreference='Stop'
$a=Split-Path -Parent $MyInvocation.MyCommand.Path
$s=Split-Path -Parent $a
$item=''
for($i=0;$i -lt $args.Count;$i++){ if([string]$args[$i] -eq '-Items'){ $item=[string]$args[$i+1] } }
if([string]::IsNullOrWhiteSpace($item)){ $item='(none)' } else { $item=[IO.Path]::GetFileName($item) }
[IO.File]::AppendAllText((Join-Path $s 'recorder.log'), ($item+"`n"), (New-Object System.Text.UTF8Encoding($false)))
exit 0
'@,$encNoBom)
    [IO.File]::WriteAllText((Join-Path $sandboxApp 'QQSpeedMapCatalog.ps1'), "exit 0`n", $encNoBom)
    [IO.File]::WriteAllText((Join-Path $sandboxData 'settings.json'), (ConvertTo-Json -InputObject ([ordered]@{game_path=$sandbox}) -Depth 2), $encBom)

    . (Join-Path $AppDir 'Modules\Replay\Replay.Catalog.ps1')

    $A=New-SandboxReplay -Name 'replayA.sav' -Seed 11
    $B=New-SandboxReplay -Name 'replayB.sav' -Seed 22
    $C=New-SandboxReplay -Name 'replayC.sav' -Seed 33

    # ---- bootstrap: active comes from CURRENT ANALYSES, not from the store --
    Set-Analysis $A; Set-Analysis $B          # A,B have derived data; C has none
    $boot=Initialize-ReplayCatalogFromCurrentAnalyses -DataDir $sandboxData -ProjectRoot $sandbox -AnalysisDir $outputDir
    Require ([bool]$boot.bootstrapped) 'catalog must bootstrap on first run'
    Require ((Get-State $A)-eq'active') 'bootstrap: A has an analysis -> active'
    Require ((Get-State $B)-eq'active') 'bootstrap: B has an analysis -> active'
    Require ((Get-State $C)-eq'removed') 'bootstrap must NOT activate a source that has no analysis'
    $activeCount=@($boot.active)
    Require ([int]$boot.active-eq2) ('bootstrap active must be 2 (A,B), got '+[string]$boot.active)

    # ---- Case A: clearing A derived data must not rebuild A on import of C --
    Reset-Recorder
    Clear-Analysis $A
    Require ((Get-State $A)-eq'active') 'clearing derived data must not change catalog state'
    Invoke-Import $C
    $touched=@(Get-Recorded)
    Require ($touched.Count-eq1) ('Case A: import C must touch exactly 1 replay, saw '+($touched -join ','))
    Require ($touched[0]-eq$C.name) ('Case A: import C must analyse only C, saw '+($touched -join ','))
    Require ((Get-State $A)-eq'active') 'Case A: A stays active (derived absent is a legal state)'
    Require ((Get-State $B)-eq'active') 'Case A: B unchanged'
    Write-Host '[OK] Case A: import C touched only C; A/B untouched, A still active with derived absent'

    # ---- Case B: removed must not resurrect --------------------------------
    Reset-Recorder
    [void](Set-ReplayCatalogEntryState -DataDir $sandboxData -Sha256 $A.sha -State 'removed')
    Require ((Get-State $A)-eq'removed') 'Case B: A must be removed'
    $rc=Invoke-Refresh
    Require ($rc-eq0) ('Case B: refresh must succeed, exit='+$rc)
    $touched=@(Get-Recorded)
    Require (-not($touched -contains $A.name)) ('Case B: refresh must NOT rebuild removed A, saw '+($touched -join ','))
    Require ((Get-State $A)-eq'removed') 'Case B: A must remain removed after refresh'
    Reset-Recorder
    Invoke-Import $C
    Require (-not(@(Get-Recorded) -contains $A.name)) 'Case B: importing unrelated C must not touch removed A'
    Require ((Get-State $A)-eq'removed') 'Case B: A must remain removed after importing C'
    Require (Test-Path -LiteralPath $A.path -PathType Leaf) 'Case B: source of removed A must still exist'
    Write-Host ('[OK] Case B: removed A never resurrected (refresh touched: '+($touched -join ',')+')')

    # ---- Case C: explicit re-import of the SAME replay reactivates it -------
    Reset-Recorder
    Invoke-Import $A
    Require ((Get-State $A)-eq'active') 'Case C: re-import must set A active'
    $touched=@(Get-Recorded)
    Require ($touched.Count-eq1-and$touched[0]-eq$A.name) ('Case C: re-import must analyse A only, saw '+($touched -join ','))
    Write-Host '[OK] Case C: explicit re-import moved A removed -> active and analysed it'

    # ---- Case D: refresh rebuilds the CURRENT LIST, never the derived store ---------
    # The rebuild queue is exactly: the CURRENT analysis list (Output\*_analysis.json) INTERSECT
    # catalog state=active INTERSECT source present. Catalog `active` is user lifecycle state, not a
    # rebuild order, and a stale analysis file is not evidence that a removed replay should come back.
    Reset-Recorder
    [void](Set-ReplayCatalogEntryState -DataDir $sandboxData -Sha256 $B.sha -State 'removed')
    $D=New-SandboxReplay -Name 'replayD.sav' -Seed 44
    Invoke-Import $D                                    # D becomes active, but the user never sees it
    Reset-Recorder                                      # the import itself is not part of the rebuild
    Require ((Get-State $D)-eq'active') 'Case D setup: D is active'
    Require (-not(Test-Path -LiteralPath (Join-Path $outputDir 'replayD_analysis.json') -PathType Leaf)) 'Case D setup: D must have no current analysis'
    Set-Analysis $A
    Set-Analysis $C
    Set-Analysis $B                                     # a stale analysis file that survived on disk
    Require (Test-Path -LiteralPath (Join-Path $outputDir 'replayB_analysis.json') -PathType Leaf) 'Case D setup: removed B still has a stale analysis file'
    Require ((Get-State $A)-eq'active') 'Case D setup: A active'
    Require ((Get-State $B)-eq'removed') 'Case D setup: B removed'
    Require ((Get-State $C)-eq'active') 'Case D setup: C active'
    $rc=Invoke-Refresh
    Require ($rc-eq0) ('Case D: refresh must succeed, exit='+$rc)
    $touched=@(Get-Recorded|Sort-Object)
    $expect=@($A.name,$C.name|Sort-Object)
    Require ($touched.Count-eq2) ('Case D: refresh must rebuild exactly the 2 replays on the current list, saw '+($touched -join ','))
    Require (($touched -join ',')-eq($expect -join ',')) ('Case D: refresh must rebuild A and C only, saw '+($touched -join ','))
    Require (-not($touched -contains $B.name)) 'Case D: removed B must not be rebuilt even though its derived data is still on disk'
    Require (-not($touched -contains $D.name)) 'Case D: an active replay the user cannot see must not be pulled back into the list'
    Write-Host '[OK] Case D: rebuild = current list INTERSECT active INTERSECT source-present (A,C); stale B and off-list D were not resurrected'

    # ---- Case E: concurrent catalog mutation must not lose an update --------
    # Two OS processes mutate the SAME catalog through the REAL production module.
    $catalogModulePath=Join-Path $sandboxApp 'Modules\Replay\Replay.Catalog.ps1'
    Require (Test-Path -LiteralPath $catalogModulePath -PathType Leaf) 'Case E: sandbox catalog module must exist'
    #
    # E-a proves mutual exclusion directly: a marker written inside the critical section must
    # never coexist with the other worker's marker. (Measured on the pre-fix implementation
    # this check reports several overlaps; it is the deterministic discriminator.)
    # E-b proves the contract end to end: a concurrent upsert(C) and remove(A) must BOTH
    # survive, so a lost update fails the gate.
    #
    # Each worker captures its own status artifact (pid / completed iterations / exception
    # type / message / script stack / exit code). stdout+stderr cannot be used for that:
    # Start-Process -PassThru drops ExitCode as soon as -Redirect* is passed, and a
    # concurrent pair must be started without -Wait.
    $workerPath=Join-Path $sandbox 'catalog_worker.ps1'
    [IO.File]::WriteAllText($workerPath, @'
param([string]$Module,[string]$DataDir,[string]$Mode,[string]$Sha,[string]$Rel,[string]$Name,[long]$Size,[int]$Iterations,[string]$StatusPath)
$ErrorActionPreference='Stop'
$status=[ordered]@{mode=$Mode;pid=$PID;iterations_requested=$Iterations;iterations_completed=0;overlaps=0;error='';error_type='';error_position='';error_stack='';exit_code=1}
try {
    . $Module
    if($Mode -eq 'exclusive'){
        $hold=Join-Path $DataDir 'hold'
        New-Item -ItemType Directory -Force -Path $hold | Out-Null
        for($i=0;$i -lt $Iterations;$i++){
            $held=Enter-ReplayCatalogLock -DataDir $DataDir
            if(-not[bool]$held.acquired){ throw ('exclusive: lock not acquired ('+[string]$held.reason+')') }
            $mine=Join-Path $hold ([string]$PID+'_'+[string]$i)
            try {
                [IO.File]::WriteAllText($mine,'1')
                $others=@(Get-ChildItem -LiteralPath $hold -File | Where-Object{$_.Name -ne ([string]$PID+'_'+[string]$i)})
                if($others.Count -gt 0){ $status.overlaps=[int]$status.overlaps+1 }
                Start-Sleep -Milliseconds 5
            } finally {
                Remove-Item -LiteralPath $mine -Force -ErrorAction SilentlyContinue
                Exit-ReplayCatalogLock -DataDir $DataDir -Handle $held.handle
            }
            $status.iterations_completed=[int]($i+1)
        }
    } else {
        for($i=0;$i -lt $Iterations;$i++){
            if($Mode -eq 'upsert'){ [void](Add-ReplayCatalogEntry -DataDir $DataDir -Sha256 $Sha -SourceRelPath $Rel -OriginalName $Name -SizeBytes $Size -SourcePresent $true) }
            else { [void](Set-ReplayCatalogEntryState -DataDir $DataDir -Sha256 $Sha -State 'removed') }
            $status.iterations_completed=[int]($i+1)
        }
    }
    $status.exit_code=0
} catch {
    $status.error=[string]$_.Exception.Message
    $status.error_type=$_.Exception.GetType().FullName
    try { $status.error_position=[string]$_.InvocationInfo.PositionMessage } catch {}
    try { $status.error_stack=[string]$_.ScriptStackTrace } catch {}
    $status.exit_code=1
} finally {
    $encStatus=New-Object System.Text.UTF8Encoding -ArgumentList $true
    [IO.File]::WriteAllText($StatusPath,($status|ConvertTo-Json -Depth 5),$encStatus)
}
exit $status.exit_code
'@, $encNoBom)

    function Start-CatalogWorker([string]$Mode,[string]$Tag,[string]$Sha,[string]$Rel,[string]$Name,[int]$Iterations){
        $statusPath=Join-Path $sandbox ('status_'+$Tag+'.json')
        # -ArgumentList elements are joined verbatim, so a path containing spaces must be quoted.
        $workerArgs=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$workerPath+'"'),
            ('"'+$catalogModulePath+'"'),('"'+$sandboxData+'"'),$Mode,$Sha,$Rel,$Name,'4096',[string]$Iterations,('"'+$statusPath+'"'))
        $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $workerArgs -PassThru -WindowStyle Hidden
        return [pscustomobject]@{process=$p;status_path=$statusPath}
    }
    function Read-CatalogWorkerStatus([string]$Path,[string]$Tag){
        $s=$null
        try { $s=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json } catch {}
        if($null-eq$s){ throw ('Case E: worker '+$Tag+' produced no status artifact ('+$Path+')') }
        if([int]$s.exit_code-ne0){
            throw ('Case E: worker '+$Tag+' failed: '+[string]$s.error+' | '+[string]$s.error_type+' | completed='+[string]$s.iterations_completed+'/'+[string]$s.iterations_requested+' | '+(([string]$s.error_position)-replace "`r?`n",' '))
        }
        return $s
    }
    function Clear-WorkerHold { Remove-Item -LiteralPath (Join-Path $sandboxData 'hold') -Recurse -Force -ErrorAction SilentlyContinue }

    $eIterations=20
    # The exclusivity check needs many hand-offs: measured against the pre-fix implementation
    # (commit 199a7d8) this same check reported 7 and 3 overlapping critical sections per round
    # at 120 iterations and none at 20. Zero overlaps is a structural property of the fixed lock
    # (the kernel holds an exclusive handle for the whole critical section), not luck.
    $eExclusiveIterations=120
    $eRounds=2
    for($er=1;$er -le $eRounds;$er++){
        # ---- E-a: exclusive critical section -------------------------------
        Clear-WorkerHold
        $ea=Start-CatalogWorker -Mode 'exclusive' -Tag ('excl_a_'+$er) -Sha $A.sha -Rel $A.rel -Name $A.name -Iterations $eExclusiveIterations
        $eb=Start-CatalogWorker -Mode 'exclusive' -Tag ('excl_b_'+$er) -Sha $B.sha -Rel $B.rel -Name $B.name -Iterations $eExclusiveIterations
        $ea.process.WaitForExit(); $eb.process.WaitForExit()
        $sa=Read-CatalogWorkerStatus $ea.status_path ('excl_a_'+$er)
        $sb=Read-CatalogWorkerStatus $eb.status_path ('excl_b_'+$er)
        Require ([int]$sa.iterations_completed-eq$eExclusiveIterations) ('Case E-a: worker A completed '+[string]$sa.iterations_completed+'/'+[string]$eExclusiveIterations)
        Require ([int]$sb.iterations_completed-eq$eExclusiveIterations) ('Case E-a: worker B completed '+[string]$sb.iterations_completed+'/'+[string]$eExclusiveIterations)
        Require ([int]$sa.overlaps-eq0-and[int]$sb.overlaps-eq0) ('Case E-a: two writers were inside the catalog critical section at once (overlaps='+[string]$sa.overlaps+'/'+[string]$sb.overlaps+')')
        Require (-not(Test-Path -LiteralPath (Get-ReplayCatalogLockPath $sandboxData))) 'Case E-a: lock must be released after the race'

        # ---- E-b: no lost update under production mutators ------------------
        [void](Set-ReplayCatalogEntryState -DataDir $sandboxData -Sha256 $A.sha -State 'active')
        [void](Set-ReplayCatalogEntryState -DataDir $sandboxData -Sha256 $C.sha -State 'removed')
        Require ((Get-State $A)-eq'active') 'Case E-b setup: A active'
        Require ((Get-State $C)-eq'removed') 'Case E-b setup: C removed'
        $wu=Start-CatalogWorker -Mode 'upsert' -Tag ('upsert_'+$er) -Sha $C.sha -Rel $C.rel -Name $C.name -Iterations $eIterations
        $wr=Start-CatalogWorker -Mode 'remove' -Tag ('remove_'+$er) -Sha $A.sha -Rel $A.rel -Name $A.name -Iterations $eIterations
        $wu.process.WaitForExit(); $wr.process.WaitForExit()
        $su=Read-CatalogWorkerStatus $wu.status_path ('upsert_'+$er)
        $sr=Read-CatalogWorkerStatus $wr.status_path ('remove_'+$er)
        Require ([int]$su.iterations_completed-eq$eIterations) ('Case E-b: upsert worker completed '+[string]$su.iterations_completed+'/'+[string]$eIterations)
        Require ([int]$sr.iterations_completed-eq$eIterations) ('Case E-b: remove worker completed '+[string]$sr.iterations_completed+'/'+[string]$eIterations)
        Require ((Get-State $C)-eq'active') ('Case E-b: concurrent upsert of C must survive (round '+[string]$er+')')
        Require ((Get-State $A)-eq'removed') ('Case E-b: concurrent removal of A must survive - no lost update (round '+[string]$er+')')
        Require (-not(Test-Path -LiteralPath (Get-ReplayCatalogLockPath $sandboxData))) 'Case E-b: lock must be released'
        $eDoc=Get-Content -LiteralPath (Get-ReplayCatalogPath $sandboxData) -Raw -Encoding UTF8|ConvertFrom-Json
        Require ([string]$eDoc.contract-eq'replay_catalog_v1') 'Case E-b: catalog must remain a valid document'
        Require (@($eDoc.entries).Count-eq4) ('Case E-b: catalog must keep every entry, saw '+[string]@($eDoc.entries).Count)
        Write-Host ('[OK] Case E round '+[string]$er+': mutually exclusive critical section; concurrent upsert(C) + remove(A) both persisted; lock released')
    }

    # ---- Case F: bootstrap preview must not mutate anything ----------------
    Set-Analysis $A; Set-Analysis $C
    $catPath=Get-ReplayCatalogPath $sandboxData
    $beforeHash=(Get-FileHash -LiteralPath $catPath -Algorithm SHA256).Hash
    $beforeCount=@(Get-ChildItem -LiteralPath (Get-ReplayCatalogDir $sandboxData) -Force -File).Count
    $prev=Get-ReplayCatalogBootstrapPreview -DataDir $sandboxData -ProjectRoot $sandbox -AnalysisDir $outputDir
    Require ([bool]$prev.preview) 'Case F: preview must be flagged as a preview'
    Require ($beforeHash-eq(Get-FileHash -LiteralPath $catPath -Algorithm SHA256).Hash) 'Case F: preview must not modify the catalog'
    Require (@(Get-ChildItem -LiteralPath (Get-ReplayCatalogDir $sandboxData) -Force -File).Count -eq $beforeCount) 'Case F: preview must not create files'
    Require (-not(Test-Path (Get-ReplayCatalogLockPath $sandboxData))) 'Case F: preview must not leave a lock behind'
    Write-Host ('[OK] Case F: preview wrote nothing (sources={0} active={1} removed={2} ambiguous={3})' -f $prev.source_total,$prev.would_be_active,$prev.would_be_removed,$prev.ambiguous)

    # ---- Case G: source presence cannot activate at bootstrap --------------
    Clear-Analysis $B; Clear-Analysis $C
    Remove-Item -LiteralPath $catPath -Force
    $boot2=Initialize-ReplayCatalogFromCurrentAnalyses -DataDir $sandboxData -ProjectRoot $sandbox -AnalysisDir $outputDir
    Require ([bool]$boot2.bootstrapped) 'Case G: catalog must bootstrap again after removal'
    Require ((Get-State $A)-eq'active') 'Case G: A has an analysis -> active'
    Require ((Get-State $B)-eq'removed') 'Case G: B source present but no analysis -> removed'
    Require ((Get-State $C)-eq'removed') 'Case G: C source present but no analysis -> removed'
    Require (Test-Path -LiteralPath $B.path -PathType Leaf) 'Case G: B source must still exist on disk'
    Write-Host '[OK] Case G: bootstrap activated only the analysed replay; present-but-unanalysed sources stayed removed'

    # ---- Case H: reconciliation may not change state -----------------------
    [void](Set-ReplayCatalogEntryState -DataDir $sandboxData -Sha256 $A.sha -State 'active')
    [void](Set-ReplayCatalogEntryState -DataDir $sandboxData -Sha256 $B.sha -State 'removed')
    [void](Set-ReplayCatalogEntryState -DataDir $sandboxData -Sha256 $C.sha -State 'active')
    $rec2=Update-ReplayCatalogSourceReconciliation -DataDir $sandboxData -ProjectRoot $sandbox
    Require ((Get-State $A)-eq'active') 'Case H: reconciliation must not deactivate A'
    Require ((Get-State $B)-eq'removed') 'Case H: reconciliation must not reactivate removed B'
    Require ((Get-State $C)-eq'active') 'Case H: reconciliation must not change active C'
    Require ([int]$rec2.source_present-eq4) 'Case H: every source on disk (A,B,C,D) must be reported present'
    Write-Host '[OK] Case H: metadata reconciliation updated presence only; active/removed states unchanged'

    # ---- sources untouched throughout --------------------------------------
    foreach($r in @($A,$B,$C,$D)){
        Require (Test-Path -LiteralPath $r.path -PathType Leaf) ('source must survive: '+$r.name)
        Require ((Get-FileHash -LiteralPath $r.path -Algorithm SHA256).Hash.ToUpperInvariant() -eq $r.sha) ('source must be unmodified: '+$r.name)
    }

    Write-Host ('[OK] Replay lifecycle regression passed. cases=A,B,C,D,E,F,G,H; source-store=4; catalog_bootstrap=analyses-based; refresh=current-list-INTERSECT-active-INTERSECT-present; removed=sticky; off-list-never-resurrected; preview=read-only; concurrency=exclusive-proven-no-lost-update')
    $keepSandbox=$false
    exit 0
} finally {
    # A failing gate keeps its sandbox so the per-worker Case E status artifacts survive.
    if($keepSandbox){ Write-Host ('[KEEP] sandbox kept for diagnosis: '+$sandbox) }
    else { if(Test-Path -LiteralPath $sandbox){ Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } }
}
