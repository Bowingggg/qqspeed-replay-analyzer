# Replay Catalog -- the logical "currently active replay" set.
#
# Separates three concepts that used to be one:
#
#   Source Store   Data/ReplayArchive/<sha16>/<name>.sav + archive.json
#                  content-addressed, immutable, append-only. Presence here
#                  means only "we still have the bytes".
#
#   Replay Catalog Data/ReplayCatalog/replay_catalog.json  (this module)
#                  the user's active logical replay set. state = active|removed.
#
#   Derived Store  Output / Telemetry / PhysicalTelemetryCache / NativeActionCache
#                  / ReplayResolution / NativeMaps / NativeIdentity / Diagnostics
#                  entirely rebuildable; presence here means nothing about intent.
#
# Hard rule enforced by this module: a .sav existing in the Source Store must
# NEVER be used as evidence that a replay should be analysed. Only an explicit
# import activates an entry. Reconciliation may refresh metadata only, never
# state.
#
# Definition-only module: no runtime actions at import scope.

$script:ReplayCatalogContract='replay_catalog_v1'
$script:ReplayCatalogSchemaVersion=1
$script:ReplayCatalogActive='active'
$script:ReplayCatalogRemoved='removed'

function Get-ReplayCatalogContract { return $script:ReplayCatalogContract }
function Get-ReplayCatalogSchemaVersion { return [int]$script:ReplayCatalogSchemaVersion }
function Get-ReplayCatalogDir([string]$DataDir) { return (Join-Path $DataDir 'ReplayCatalog') }
function Get-ReplayCatalogPath([string]$DataDir) { return (Join-Path (Get-ReplayCatalogDir $DataDir) 'replay_catalog.json') }
function Get-ReplayCatalogLockPath([string]$DataDir) { return (Join-Path (Get-ReplayCatalogDir $DataDir) 'replay_catalog.lock') }

# ---------------------------------------------------------------------------
# Single-writer lock for every catalog mutation.
#
# Atomic JSON replace alone only guarantees an intact FILE; it cannot prevent a
# read-modify-write lost update when two processes mutate concurrently. All
# mutations therefore serialise on one lock file inside the workspace.
#
# The lock IS an OS handle, not the file's existence:
#   * acquire = FileMode::CreateNew with FileShare::None, and the handle is HELD for the
#     whole critical section. Only one process can hold such a handle at a time, so the
#     exclusion is enforced by the kernel, not by a heuristic.
#   * a leftover lock FILE (killed writer) is detected by successfully opening it with
#     FileShare::None: that can only succeed when nobody holds it. Only then may the file
#     be deleted. "The file exists" therefore never means "the lock is held", and no
#     contender ever deletes a live lock - which is exactly the check-then-act race that
#     used to admit two writers (deleting a lock observed as missing/old after the holder
#     had already released AND another writer had re-created it).
#   * crash recovery is immediate: the kernel closes the handle when the writer dies, so
#     the next acquire reclaims the file at once. No age/staleness window is involved.
#   * release closes the handle first and only then best-effort deletes the file. A
#     leftover file is harmless because the handle - not the file - is the lock.
# Acquisition failure is fail-closed (the mutation throws).
# ---------------------------------------------------------------------------
$script:ReplayCatalogLockTimeoutMs=15000
$script:ReplayCatalogLockPollMs=25
$script:ReplayCatalogLockReleaseAttempts=5
$script:ReplayCatalogLockReleaseRetryMs=20
# Path of the lock this process currently holds ('' when none). Lets the in-process
# reader distinguish "our own critical section" from a foreign writer without asking
# the kernel about a handle we already own.
$script:ReplayCatalogHeldLockPath=''

function New-ReplayCatalogLockToken { return [Guid]::NewGuid().ToString('N') }

# True when ANOTHER live process currently holds the catalog lock. Used by the reader so
# that a transient absence of the catalog file is never interpreted as "the catalog is
# empty". Returns $false whenever the state cannot be proven to be foreign (fail-open to
# the normal read path, which itself fails closed on an unreadable file).
function Test-ReplayCatalogForeignWriterActive {
    param([Parameter(Mandatory=$true)][string]$DataDir)
    $lock=Get-ReplayCatalogLockPath $DataDir
    if(-not(Test-Path -LiteralPath $lock -PathType Leaf)){return $false}
    if($script:ReplayCatalogHeldLockPath-eq$lock){return $false}
    try {
        # A successful exclusive open proves nobody holds it.
        $probe=[IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        try { return $false } finally { $probe.Dispose() }
    } catch [System.IO.FileNotFoundException] {
        return $false
    } catch {
        return $true
    }
}

function Enter-ReplayCatalogLock {
    param(
        [Parameter(Mandatory=$true)][string]$DataDir,
        [int]$TimeoutMs=$script:ReplayCatalogLockTimeoutMs,
        [int]$PollMs=$script:ReplayCatalogLockPollMs
    )
    New-Item -ItemType Directory -Force -Path (Get-ReplayCatalogDir $DataDir) | Out-Null
    $lock=Get-ReplayCatalogLockPath $DataDir
    $sw=[System.Diagnostics.Stopwatch]::StartNew()
    $recovered=$false
    $token=New-ReplayCatalogLockToken
    while($true){
        $fs=$null
        # CreateNew is the atomic test-and-set, and the handle is kept for the whole critical
        # section with FileShare::None, so the kernel enforces exclusion.
        try { $fs=[IO.File]::Open($lock,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch { $fs=$null }
        if($null-eq$fs){
            # The file exists. Either a live writer holds it (exclusive open fails with a sharing
            # violation) or a killed writer left the file behind (exclusive open succeeds).
            $probe=$null
            try { $probe=[IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch { $probe=$null }
            if($null-ne$probe){
                # Proven unheld. Holding this exclusive handle is what licenses the delete: a
                # contender that cannot get the handle can never delete a live lock.
                $probe.Dispose()
                try { Remove-Item -LiteralPath $lock -Force -ErrorAction Stop; $recovered=$true } catch {}
                continue
            }
            if($sw.ElapsedMilliseconds-ge$TimeoutMs){
                return [pscustomobject]@{acquired=$false;path=$lock;token='';handle=$null;waited_ms=$sw.ElapsedMilliseconds;stale_recovered=$recovered;reason='lock_timeout'}
            }
            Start-Sleep -Milliseconds $PollMs
            continue
        }
        # We own the lock: record identity in the file for diagnostics while holding the handle.
        try {
            $payload=ConvertTo-Json -Compress -InputObject ([ordered]@{pid=$PID;token=$token;started_at=(Get-Date).ToString('o')})
            $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
            $fs.SetLength(0); $fs.Write($bytes,0,$bytes.Length); $fs.Flush()
        } catch {
            try{$fs.Dispose()}catch{}
            throw
        }
        $script:ReplayCatalogHeldLockPath=$lock
        return [pscustomobject]@{acquired=$true;path=$lock;token=$token;handle=$fs;waited_ms=$sw.ElapsedMilliseconds;stale_recovered=$recovered;reason=''}
    }
}

# Releases the lock by CLOSING THE HANDLE first; the file delete is best-effort. A
# leftover file can never block a later acquire (the acquire path reclaims an unheld
# file immediately), so a failed delete is not a correctness problem.
function Exit-ReplayCatalogLock {
    param([Parameter(Mandatory=$true)][string]$DataDir,[object]$Handle=$null)
    $lock=Get-ReplayCatalogLockPath $DataDir
    if($null-ne$Handle){try{$Handle.Dispose()}catch{}}
    if($script:ReplayCatalogHeldLockPath-eq$lock){$script:ReplayCatalogHeldLockPath=''}
    for($attempt=1;$attempt -le $script:ReplayCatalogLockReleaseAttempts;$attempt++){
        try {
            if(Test-Path -LiteralPath $lock -PathType Leaf){Remove-Item -LiteralPath $lock -Force -ErrorAction Stop}
            return
        } catch { Start-Sleep -Milliseconds $script:ReplayCatalogLockReleaseRetryMs }
    }
}

# Runs a catalog mutation under the single-writer lock. Fail-closed on timeout.
function Invoke-ReplayCatalogMutation {
    param([Parameter(Mandatory=$true)][string]$DataDir,[Parameter(Mandatory=$true)][scriptblock]$Action)
    $held=Enter-ReplayCatalogLock -DataDir $DataDir
    if(-not [bool]$held.acquired){ throw ('Replay catalog is locked by another writer ('+[string]$held.reason+').') }
    try { return & $Action } finally { Exit-ReplayCatalogLock -DataDir $DataDir -Handle $held.handle }
}

function RC-AsBool($Value) {
    if($null-eq$Value){return $false}
    if($Value-is[bool]){return [bool]$Value}
    $s=[string]$Value
    return ($s-eq'True'-or$s-eq'true'-or$s-eq'1')
}

# Atomic JSON write: a unique temp file in the SAME directory, then a true atomic
# replace. A crash can therefore never leave a half-written catalog behind, and -
# unlike "delete then move" - a reader can never observe a moment where the
# catalog does not exist. Write-JsonUtf8 (Modules/Telemetry/Telemetry.Analysis.ps1)
# carries the same replace contract for derived summaries.
$script:ReplayCatalogReplaceAttempts=6
$script:ReplayCatalogReplaceRetryMs=25

function Write-JsonFileAtomic([string]$Path,[object]$Value,[int]$Depth=12) {
    $dir=Split-Path -Parent $Path
    if($dir){New-Item -ItemType Directory -Force -Path $dir | Out-Null}
    # Unique per writer: two processes must never share a temp path even if a future
    # regression lets them overlap again.
    $tmp=$Path+'.'+[string]$PID+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    $enc=New-Object System.Text.UTF8Encoding -ArgumentList $true
    try {
        [IO.File]::WriteAllText($tmp,($Value|ConvertTo-Json -Depth $Depth),$enc)
        # File.Replace is the platform atomic replace (ReplaceFile): the destination path never
        # disappears, so a reader can never observe "no catalog". [NullString]::Value is required
        # - passing $null marshals to an empty string and ReplaceFile rejects that.
        # The existence test and the publish are inside the retry loop on purpose: File.Exists
        # reports false when the metadata query itself fails transiently, and a plain Move then
        # fails because the destination appeared. Each retry re-evaluates which publish applies.
        $lastError=$null
        for($attempt=1;$attempt -le $script:ReplayCatalogReplaceAttempts;$attempt++){
            try {
                if([IO.File]::Exists($Path)){[IO.File]::Replace($tmp,$Path,[NullString]::Value,$true)}
                else{[IO.File]::Move($tmp,$Path)}
                return
            } catch {
                $lastError=$_
                Start-Sleep -Milliseconds $script:ReplayCatalogReplaceRetryMs
            }
        }
        # Never downgraded to delete-then-move: that would reintroduce the missing-destination
        # window this contract exists to remove.
        throw ('Atomic replace of '+$Path+' failed after '+[string]$script:ReplayCatalogReplaceAttempts+' attempts: '+$lastError.Exception.Message)
    } catch {
        if([IO.File]::Exists($tmp)){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
        throw
    }
}

function New-ReplayCatalogDocument {
    return [ordered]@{
        contract=$script:ReplayCatalogContract
        schema_version=$script:ReplayCatalogSchemaVersion
        updated_at=(Get-Date).ToString('o')
        entries=@()
    }
}

function New-ReplayCatalogEntry {
    param(
        [Parameter(Mandatory=$true)][string]$Sha256,
        [string]$Sha16='',
        [string]$SourceRelPath='',
        [string]$OriginalName='',
        [string]$State=$script:ReplayCatalogRemoved,
        [long]$SizeBytes=0,
        [bool]$SourcePresent=$false,
        [string]$AddedAt='',
        [string]$RemovedAt='',
        # Visibility is a SEPARATE axis from lifecycle `state`. `state` records whether the user
        # still holds the replay in their library; `visible` records whether the UI list may show it.
        # Only an explicit user action (import / re-import / delete) may change either one, so a
        # tooling run that (re)creates derived analyses can never make a replay reappear.
        # A missing value is derived from the lifecycle state, which is the pre-`visible` behaviour.
        [object]$Visible=$null
    )
    $sha=$Sha256.ToUpperInvariant()
    $s16=$(if([string]::IsNullOrWhiteSpace($Sha16)){ $(if($sha.Length-ge16){$sha.Substring(0,16)}else{$sha}) }else{$Sha16.ToUpperInvariant()})
    $st=$(if([string]::IsNullOrWhiteSpace($State)){$script:ReplayCatalogRemoved}else{$State})
    $vis=$(if($null-eq$Visible){($st-eq$script:ReplayCatalogActive)}else{[bool]$Visible})
    return [ordered]@{
        sha256=$sha
        sha16=$s16
        source_rel_path=$SourceRelPath
        original_name=$OriginalName
        state=$st
        visible=[bool]$vis
        added_at=$(if([string]::IsNullOrWhiteSpace($AddedAt)){(Get-Date).ToString('o')}else{$AddedAt})
        removed_at=$(if($st-eq$script:ReplayCatalogRemoved-and[string]::IsNullOrWhiteSpace($RemovedAt)){(Get-Date).ToString('o')}else{$(if([string]::IsNullOrWhiteSpace($RemovedAt)){$null}else{$RemovedAt})})
        size_bytes=[long]$SizeBytes
        source_present=[bool]$SourcePresent
    }
}

# Sets the `visible` axis on a catalog entry whatever shape the entry currently has. An entry read
# back from JSON is a PSCustomObject, and on this platform assigning a property the object does not
# already carry throws, so a missing field is added explicitly. A dictionary entry gains a key.
function Set-ReplayCatalogEntryVisibility {
    param([Parameter(Mandatory=$true)][object]$Entry,[Parameter(Mandatory=$true)][bool]$Visible)
    if($Entry -is [System.Collections.IDictionary]){
        $Entry['visible']=$Visible
        return $Entry
    }
    if(@($Entry.PSObject.Properties.Name)-contains'visible'){ $Entry.visible=$Visible; return $Entry }
    $Entry|Add-Member -NotePropertyName 'visible' -NotePropertyValue $Visible -Force
    return $Entry
}

# Which versions currently have a derived analysis, keyed by SHA256. Only the head of each
# `*_analysis.json` is read: `replay_sha256` is the sixth property the analyzer writes, so a small
# prefix is enough and a 19 MB analysis document is never parsed just to learn its identity.
function Get-ReplayAnalysisShaIndex {
    param([Parameter(Mandatory=$true)][string]$AnalysisDir)
    $index=@{}
    if(-not(Test-Path -LiteralPath $AnalysisDir -PathType Container)){return $index}
    foreach($f in @(Get-ChildItem -LiteralPath $AnalysisDir -Filter '*_analysis.json' -File -ErrorAction SilentlyContinue)){
        $head=$null
        try {
            $fs=[IO.File]::Open($f.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            try {
                $n=[int][Math]::Min(8192,$fs.Length)
                if($n-le0){continue}
                $buf=New-Object byte[] $n
                [void]$fs.Read($buf,0,$n)
                $head=[Text.Encoding]::UTF8.GetString($buf)
            } finally { $fs.Dispose() }
        } catch { continue }
        $m=[regex]::Match($head,'"replay_sha256"\s*:\s*"(?<sha>[0-9A-Fa-f]{16,64})"')
        if(-not$m.Success){continue}
        $sha=$m.Groups['sha'].Value.ToUpperInvariant()
        $index[$sha]=$f.Name
    }
    return $index
}

# One-time, conservative completion of the `visible` axis for entries written before it existed.
# An entry is frozen as visible only when it is BOTH active AND currently backed by a derived
# analysis, i.e. exactly what the list shows at that instant. After this runs, visibility is
# explicit and a tooling run can no longer change it.
function Complete-ReplayCatalogVisibility {
    param(
        [AllowEmptyCollection()][object[]]$Entries=@(),
        [Parameter(Mandatory=$true)][hashtable]$AnalysisShaIndex
    )
    $out=New-Object System.Collections.Generic.List[object]
    $completed=0;$visibleCount=0
    foreach($e in @($Entries)){
        if($null-eq$e){continue}
        $hasField=(@($e.PSObject.Properties.Name)-contains'visible')
        if($e -is [System.Collections.IDictionary]){ $hasField=$e.Contains('visible') }
        if(-not$hasField -or ($null-eq $e.visible)){
            $sha=([string]$e.sha256).Trim().ToUpperInvariant()
            $vis=(([string]$e.state-eq$script:ReplayCatalogActive)-and$AnalysisShaIndex.ContainsKey($sha))
            [void](Set-ReplayCatalogEntryVisibility -Entry $e -Visible $vis)
            $completed++
        }
        if([bool]$e.visible){$visibleCount++}
        $out.Add($e)
    }
    return [pscustomobject][ordered]@{
        entries=@($out.ToArray())
        completed=$completed
        visible=$visibleCount
        total=$out.Count
    }
}

# Reads the catalog text without ever blocking a concurrent atomic replace: the handle is
# opened with FileShare::ReadWrite|Delete, so a lock-free reader can never make a writer's
# ReplaceFile fail, and it can never fail itself because a writer is replacing the file.
# Returns $null when the read itself failed (transient), never "" for a real file.
function Read-ReplayCatalogRawText([string]$Path) {
    $fs=$null
    try {
        $fs=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $enc=New-Object System.Text.UTF8Encoding -ArgumentList $false
        $sr=New-Object System.IO.StreamReader -ArgumentList $fs,$enc,$true
        try { return $sr.ReadToEnd() } finally { $sr.Dispose(); $fs=$null }
    } catch {
        return $null
    } finally {
        if($null-ne$fs){try{$fs.Dispose()}catch{}}
    }
}

function Read-ReplayCatalog {
    param([Parameter(Mandatory=$true)][string]$DataDir)
    $path=Get-ReplayCatalogPath $DataDir
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){
        # A missing catalog file is a legitimate "no catalog yet" state ONLY when no other
        # writer is active. While another writer holds the catalog lock, a transient absence
        # (first creation) must NEVER be reported as an empty document: the caller would then
        # write that empty document and silently drop every entry. Fail closed instead and let
        # the caller retry.
        if(Test-ReplayCatalogForeignWriterActive -DataDir $DataDir){
            return [pscustomobject]@{exists=$false;path=$path;document=$null;invalid=$true;reason='catalog_write_in_progress'}
        }
        return [pscustomobject]@{exists=$false;path=$path;document=(New-ReplayCatalogDocument);reason='catalog_absent'}
    }
    $raw=Read-ReplayCatalogRawText $path
    if($null-eq$raw){
        # The read itself failed. This is NOT a contract problem and must never be reported as
        # an empty or invalid catalog; the caller retries.
        return [pscustomobject]@{exists=$true;path=$path;document=$null;invalid=$true;reason='catalog_read_failed'}
    }
    $doc=$null
    try { $doc=$raw|ConvertFrom-Json } catch { $doc=$null }
    if($null-eq$doc-or[string]$doc.contract-ne$script:ReplayCatalogContract){
        # Content was read but is not this contract: fail closed, do not migrate.
        return [pscustomobject]@{exists=$true;path=$path;document=$null;invalid=$true;reason='catalog_unsupported_contract'}
    }
    return [pscustomobject]@{exists=$true;path=$path;document=$doc;reason=''}
}

# Mutation-side read: a catalog that is momentarily unreadable because another writer is
# replacing it is retried, never silently treated as empty. A genuine contract problem
# returns immediately so the caller can fail closed.
function Read-ReplayCatalogForMutation {
    param([Parameter(Mandatory=$true)][string]$DataDir,[int]$TimeoutMs=$script:ReplayCatalogLockTimeoutMs)
    $sw=[System.Diagnostics.Stopwatch]::StartNew()
    while($true){
        $read=Read-ReplayCatalog -DataDir $DataDir
        if($null-ne$read.document){return $read}
        if([string]$read.reason-ne'catalog_write_in_progress'-and[string]$read.reason-ne'catalog_read_failed'){return $read}
        if($sw.ElapsedMilliseconds-ge$TimeoutMs){return $read}
        Start-Sleep -Milliseconds 25
    }
}

function Assert-ReplayCatalogReadable([object]$Read) {
    if($null-ne$Read.document){return}
    if([string]$Read.reason-eq'catalog_write_in_progress'){
        throw 'Replay catalog is being written by another process; refusing to write over an unread catalog.'
    }
    if([string]$Read.reason-eq'catalog_read_failed'){
        throw 'Replay catalog could not be read; refusing to write over an unread catalog.'
    }
    throw 'Replay catalog has an unsupported contract; refusing to migrate.'
}

function Write-ReplayCatalog {
    param([Parameter(Mandatory=$true)][string]$DataDir,[Parameter(Mandatory=$true)][object]$Catalog)
    $path=Get-ReplayCatalogPath $DataDir
    $doc=[ordered]@{
        contract=$script:ReplayCatalogContract
        schema_version=$script:ReplayCatalogSchemaVersion
        updated_at=(Get-Date).ToString('o')
        entries=@($Catalog.entries)
    }
    Write-JsonFileAtomic -Path $path -Value $doc -Depth 8
    return $path
}

function Get-ReplayCatalogEntries {
    param([Parameter(Mandatory=$true)][string]$DataDir,[string[]]$State=@())
    $read=Read-ReplayCatalog -DataDir $DataDir
    if($null-eq$read.document){return @()}
    $entries=@($read.document.entries)
    if($State.Count-gt0){$entries=@($entries|Where-Object{$State -contains [string]$_.state})}
    return $entries
}

function Get-ReplayCatalogActiveEntries {
    param([Parameter(Mandatory=$true)][string]$DataDir,[switch]$PresentOnly)
    $entries=@(Get-ReplayCatalogEntries -DataDir $DataDir -State @($script:ReplayCatalogActive))
    if($PresentOnly){$entries=@($entries|Where-Object{RC-AsBool $_.source_present})}
    return $entries
}

function RCC-FindEntryIndex {
    param([Parameter(Mandatory=$true)][object]$Catalog,[Parameter(Mandatory=$true)][string]$Sha256)
    $sha=$Sha256.ToUpperInvariant()
    $entries=@($Catalog.entries)
    for($i=0;$i -lt $entries.Count;$i++){
        if([string]$entries[$i].sha256 -eq $sha){return $i}
    }
    return -1
}

# Explicit activation. This is the ONLY path that may set state=active.
# A removed entry re-imported by the user becomes active again.
function Add-ReplayCatalogEntry {
    param(
        [Parameter(Mandatory=$true)][string]$DataDir,
        [Parameter(Mandatory=$true)][string]$Sha256,
        [string]$SourceRelPath='',
        [string]$OriginalName='',
        [long]$SizeBytes=0,
        [bool]$SourcePresent=$true,
        # When supplied, every entry that predates the `visible` axis is frozen exactly once, using
        # the analyses that exist at THIS moment. Doing it inside the import mutation means the very
        # next user action closes the historical-resurrection window, before the new analysis is
        # written.
        [string]$AnalysisDir=''
    )
    $sha=$Sha256.ToUpperInvariant()
    if($sha.Length-lt16){throw 'Replay catalog requires a SHA256 of at least 16 characters.'}
    return Invoke-ReplayCatalogMutation -DataDir $DataDir -Action {
    $read=Read-ReplayCatalogForMutation -DataDir $DataDir
    Assert-ReplayCatalogReadable $read
    $doc=$read.document
    $entries=New-Object System.Collections.Generic.List[object]
    foreach($e in @($doc.entries)){$entries.Add($e)}
    $completed=0
    if(-not[string]::IsNullOrWhiteSpace($AnalysisDir)){
        $index=Get-ReplayAnalysisShaIndex -AnalysisDir $AnalysisDir
        $done=Complete-ReplayCatalogVisibility -Entries @($entries.ToArray()) -AnalysisShaIndex $index
        $entries=New-Object System.Collections.Generic.List[object]
        foreach($e in @($done.entries)){$entries.Add($e)}
        $completed=[int]$done.completed
    }
    $idx=RCC-FindEntryIndex -Catalog $doc -Sha256 $sha
    $now=(Get-Date).ToString('o')
    if($idx-lt0){
        $entries.Add((New-ReplayCatalogEntry -Sha256 $sha -SourceRelPath $SourceRelPath -OriginalName $OriginalName -State $script:ReplayCatalogActive -SizeBytes $SizeBytes -SourcePresent $SourcePresent -AddedAt $now -Visible $true))
    } else {
        $e=$entries[$idx]
        $e.state=$script:ReplayCatalogActive
        [void](Set-ReplayCatalogEntryVisibility -Entry $e -Visible $true)
        $e.removed_at=$null
        $e.added_at=$(if([string]::IsNullOrWhiteSpace([string]$e.added_at)){$now}else{$e.added_at})
        if(-not[string]::IsNullOrWhiteSpace($SourceRelPath)){$e.source_rel_path=$SourceRelPath}
        if(-not[string]::IsNullOrWhiteSpace($OriginalName)){$e.original_name=$OriginalName}
        if($SizeBytes-gt0){$e.size_bytes=[long]$SizeBytes}
        $e.source_present=[bool]$SourcePresent
        $entries[$idx]=$e
    }
    $doc.entries=@($entries.ToArray())
    [void](Write-ReplayCatalog -DataDir $DataDir -Catalog $doc)
    return [pscustomobject]@{sha256=$sha;state=$script:ReplayCatalogActive;visible=$true;created=($idx-lt0);visibility_completed=$completed}
    }
}

# The UI list authority: entries the user explicitly made visible, backed by a derived analysis.
# A missing `visible` field is read as the pre-`visible` behaviour (state=active) until the
# one-time completion above writes it.
function Get-ReplayCatalogVisibleEntries {
    param(
        [Parameter(Mandatory=$true)][string]$DataDir,
        [Parameter(Mandatory=$true)][hashtable]$AnalysisShaIndex
    )
    $read=Read-ReplayCatalog -DataDir $DataDir
    if($null-eq$read.document){return @()}
    $out=New-Object System.Collections.Generic.List[object]
    foreach($e in @($read.document.entries)){
        if($null-eq$e){continue}
        $sha=([string]$e.sha256).Trim().ToUpperInvariant()
        if([string]::IsNullOrWhiteSpace($sha)){continue}
        $hasField=(@($e.PSObject.Properties.Name)-contains'visible')
        $vis=$(if($hasField-and$null-ne$e.visible){[bool]$e.visible}else{([string]$e.state-eq$script:ReplayCatalogActive)})
        if(-not$vis){continue}
        if(-not$AnalysisShaIndex.ContainsKey($sha)){continue}
        $out.Add($e)
    }
    return @($out.ToArray())
}

# Explicit one-time completion of the `visible` axis (same rule as the import path). Called by the
# user-triggered rebuild, never by a read path.
function Sync-ReplayCatalogVisibility {
    param([Parameter(Mandatory=$true)][string]$DataDir,[Parameter(Mandatory=$true)][string]$AnalysisDir)
    return Invoke-ReplayCatalogMutation -DataDir $DataDir -Action {
    $read=Read-ReplayCatalogForMutation -DataDir $DataDir
    if(-not$read.exists){return [pscustomobject]@{ok=$false;reason='catalog_absent';completed=0;visible=0;total=0}}
    Assert-ReplayCatalogReadable $read
    $index=Get-ReplayAnalysisShaIndex -AnalysisDir $AnalysisDir
    $done=Complete-ReplayCatalogVisibility -Entries @($read.document.entries) -AnalysisShaIndex $index
    if([int]$done.completed-eq0){return [pscustomobject]@{ok=$true;reason='already_complete';completed=0;visible=[int]$done.visible;total=[int]$done.total}}
    $doc=$read.document
    $doc.entries=@($done.entries)
    [void](Write-ReplayCatalog -DataDir $DataDir -Catalog $doc)
    return [pscustomobject]@{ok=$true;reason='completed';completed=[int]$done.completed;visible=[int]$done.visible;total=[int]$done.total}
    }
}

function Set-ReplayCatalogEntryState {
    param(
        [Parameter(Mandatory=$true)][string]$DataDir,
        [Parameter(Mandatory=$true)][string]$Sha256,
        [Parameter(Mandatory=$true)][ValidateSet('active','removed')][string]$State
    )
    $sha=$Sha256.ToUpperInvariant()
    return Invoke-ReplayCatalogMutation -DataDir $DataDir -Action {
    $read=Read-ReplayCatalogForMutation -DataDir $DataDir
    Assert-ReplayCatalogReadable $read
    $doc=$read.document
    $idx=RCC-FindEntryIndex -Catalog $doc -Sha256 $sha
    if($idx-lt0){return [pscustomobject]@{ok=$false;reason='entry_not_found';sha256=$sha}}
    $entries=New-Object System.Collections.Generic.List[object]
    foreach($e in @($doc.entries)){$entries.Add($e)}
    $e=$entries[$idx]
    $e.state=$State
    # Delete/restore are explicit user actions, so they also move the visibility axis: a deleted
    # replay must never be shown again, and an explicitly restored one is shown again.
    [void](Set-ReplayCatalogEntryVisibility -Entry $e -Visible ($State-eq$script:ReplayCatalogActive))
    $e.removed_at=$(if($State-eq$script:ReplayCatalogRemoved){(Get-Date).ToString('o')}else{$null})
    $entries[$idx]=$e
    $doc.entries=@($entries.ToArray())
    [void](Write-ReplayCatalog -DataDir $DataDir -Catalog $doc)
    return [pscustomobject]@{ok=$true;sha256=$sha;state=$State}
    }
}

function Get-ReplaySourceRelativePath {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot,[Parameter(Mandatory=$true)][string]$FullPath)
    $root=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
    $full=[IO.Path]::GetFullPath($FullPath)
    if($full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){return $full.Substring($root.Length+1).Replace('\','/')}
    return $full.Replace('\','/')
}

# Cheap enumeration of the Source Store: file name + size + archive.json only.
# NO SHA256, NO ReadAllBytes.
function Get-ReplaySourceInventory {
    param([Parameter(Mandatory=$true)][string]$DataDir)
    $archiveRoot=Join-Path $DataDir 'ReplayArchive'
    $out=New-Object System.Collections.Generic.List[object]
    if(-not(Test-Path -LiteralPath $archiveRoot -PathType Container)){return @()}
    foreach($dir in @(Get-ChildItem -LiteralPath $archiveRoot -Directory -ErrorAction SilentlyContinue)){
        $sav=@(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.sav' -ErrorAction SilentlyContinue|Select-Object -First 1)
        $meta=Join-Path $dir.FullName 'archive.json'
        $j=$null
        if(Test-Path -LiteralPath $meta -PathType Leaf){
            try { $j=Get-Content -LiteralPath $meta -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $j=$null }
        }
        $sha=$(if($null-ne$j-and-not[string]::IsNullOrWhiteSpace([string]$j.sha256)){[string]$j.sha256}else{''})
        $name=$(if($null-ne$j-and-not[string]::IsNullOrWhiteSpace([string]$j.original_name)){[string]$j.original_name}else{$(if($sav.Count-gt0){[string]$sav[0].Name}else{''})})
        $out.Add([pscustomobject]@{
            sha16=$dir.Name
            sha256=$sha
            original_name=$name
            sav_path=$(if($sav.Count-gt0){[string]$sav[0].FullName}else{''})
            size_bytes=$(if($sav.Count-gt0){[long]$sav[0].Length}else{[long]0})
            metadata_present=($null-ne$j)
        })
    }
    return @($out.ToArray())
}

# Metadata-only reconciliation. May update source_present / source_rel_path /
# size_bytes / original_name. May NOT change state, and never activates anything.
function Update-ReplayCatalogSourceReconciliation {
    param([Parameter(Mandatory=$true)][string]$DataDir,[Parameter(Mandatory=$true)][string]$ProjectRoot)
    return Invoke-ReplayCatalogMutation -DataDir $DataDir -Action {
    $read=Read-ReplayCatalogForMutation -DataDir $DataDir
    Assert-ReplayCatalogReadable $read
    $doc=$read.document
    $entries=New-Object System.Collections.Generic.List[object]
    foreach($e in @($doc.entries)){$entries.Add($e)}
    $inv=@(Get-ReplaySourceInventory -DataDir $DataDir)
    $bySha=@{}
    foreach($s in $inv){ if(-not[string]::IsNullOrWhiteSpace($s.sha256)){$bySha[[string]$s.sha256.ToUpperInvariant()]=$s} }

    $present=0;$missing=0;$discovered=@()
    for($i=0;$i -lt $entries.Count;$i++){
        $e=$entries[$i]
        $sha=[string]$e.sha256
        if($bySha.ContainsKey($sha)){
            $s=$bySha[$sha]
            $e.source_present=$true
            $e.source_rel_path=(Get-ReplaySourceRelativePath -ProjectRoot $ProjectRoot -FullPath $s.sav_path)
            $e.size_bytes=[long]$s.size_bytes
            if(-not[string]::IsNullOrWhiteSpace([string]$s.original_name)){$e.original_name=[string]$s.original_name}
            $present++
        } else {
            $e.source_present=$false
            $missing++
        }
        $entries[$i]=$e
    }
    # Sources present in the store but absent from the catalog are recorded as
    # removed: they exist, but nothing asked for them. They are never activated.
    foreach($k in @($bySha.Keys)){
        # NOTE: parenthesise the call before comparing, otherwise PowerShell parses
        # "-ge" as a parameter name of the command.
        $probe=[pscustomobject]@{entries=@($entries.ToArray())}
        if((RCC-FindEntryIndex -Catalog $probe -Sha256 $k) -ge 0){continue}
        $s=$bySha[$k]
        $discovered+=$k
        $entries.Add((New-ReplayCatalogEntry -Sha256 $k -Sha16 $s.sha16 -SourceRelPath (Get-ReplaySourceRelativePath -ProjectRoot $ProjectRoot -FullPath $s.sav_path) -OriginalName $s.original_name -State $script:ReplayCatalogRemoved -SizeBytes $s.size_bytes -SourcePresent $true))
    }
    $doc.entries=@($entries.ToArray())
    [void](Write-ReplayCatalog -DataDir $DataDir -Catalog $doc)
    return [pscustomobject]@{
        total_entries=$entries.Count
        source_present=$present
        source_missing=$missing
        discovered_as_removed=@($discovered)
        active=@($entries|Where-Object{[string]$_.state-eq$script:ReplayCatalogActive}).Count
        removed=@($entries|Where-Object{[string]$_.state-eq$script:ReplayCatalogRemoved}).Count
    }
    }
}

# First-time bootstrap. This is an explicit, one-time MIGRATION, not a visibility decision: the
# lifecycle record is taken from the analyses that currently exist, but nothing is made VISIBLE.
# "An analysis exists" is derived data and must never be evidence that the user wants a replay on
# their list (see the visible axis in New-ReplayCatalogEntry). The user's first list therefore comes
# from an explicit import, and every entry the user had already imported keeps its lifecycle record.
# Ambiguity is reported, never guessed.
function Initialize-ReplayCatalogFromCurrentAnalyses {
    param(
        [Parameter(Mandatory=$true)][string]$DataDir,
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$AnalysisDir
    )
    $existing=Read-ReplayCatalog -DataDir $DataDir
    if($existing.exists-and$null-ne$existing.document){
        return [pscustomobject]@{bootstrapped=$false;reason='catalog_already_exists';path=$existing.path}
    }
    if($existing.exists-and$null-eq$existing.document-and[string]$existing.reason-ne'catalog_write_in_progress'-and[string]$existing.reason-ne'catalog_read_failed'){
        throw 'Replay catalog exists with an unsupported contract; refusing to migrate.'
    }
    return Invoke-ReplayCatalogMutation -DataDir $DataDir -Action {
        # Re-check under the lock: another writer may have bootstrapped meanwhile.
        $again=Read-ReplayCatalogForMutation -DataDir $DataDir
        if($again.exists-and$null-ne$again.document){
            return [pscustomobject]@{bootstrapped=$false;reason='catalog_already_exists';path=$again.path}
        }
        # A catalog that cannot be read as a document must never be replaced by a fresh
        # bootstrap: that would drop the entries of a live catalog. (document=$null with
        # exists=$false means another writer is mid-write.)
        Assert-ReplayCatalogReadable $again
        $plan=Get-ReplayCatalogBootstrapPlan -DataDir $DataDir -ProjectRoot $ProjectRoot -AnalysisDir $AnalysisDir
        $doc=New-ReplayCatalogDocument
        $doc.entries=@($plan.entries)
        $path=Write-ReplayCatalog -DataDir $DataDir -Catalog $doc
        return [pscustomobject]@{
            bootstrapped=$true
            path=$path
            sources=$plan.source_total
            active=$plan.would_be_active
            removed=$plan.would_be_removed
            ambiguous_sources=@($plan.ambiguous_sources)
            analysis_without_source=@($plan.analysis_without_source)
            unreadable_analyses=@($plan.unreadable_analyses)
        }
    }
}

# ---------------------------------------------------------------------------
# Read-only bootstrap plan. Used by BOTH the never-writing preview and the real
# bootstrap, so the preview cannot disagree with what bootstrap would do.
# Touches only: filenames, file sizes, archive.json, analysis metadata.
# Never hashes a SAV, never reads SAV bytes, never analyses, never writes.
# ---------------------------------------------------------------------------
function Get-ReplayCatalogBootstrapPlan {
    param(
        [Parameter(Mandatory=$true)][string]$DataDir,
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$AnalysisDir
    )
    $activeSha=@{}
    $analysisTotal=0
    $analysisWithoutSource=New-Object System.Collections.Generic.List[string]
    $unreadable=New-Object System.Collections.Generic.List[string]
    if(Test-Path -LiteralPath $AnalysisDir -PathType Container){
        foreach($f in @(Get-ChildItem -LiteralPath $AnalysisDir -Filter '*.json' -File -ErrorAction SilentlyContinue)){
            $j=$null
            try { $j=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $unreadable.Add($f.Name); continue }
            $sha=[string]$j.replay_sha256
            if([string]::IsNullOrWhiteSpace($sha)-or$sha.Length-lt16){$unreadable.Add($f.Name);continue}
            $analysisTotal++
            $activeSha[$sha.ToUpperInvariant()]=[string]$j.replay_file
        }
    }

    $inv=@(Get-ReplaySourceInventory -DataDir $DataDir)
    $entries=New-Object System.Collections.Generic.List[object]
    $rows=New-Object System.Collections.Generic.List[object]
    $ambiguous=New-Object System.Collections.Generic.List[string]
    $noAnalysis=New-Object System.Collections.Generic.List[string]
    foreach($s in $inv){
        if([string]::IsNullOrWhiteSpace($s.sha256)){
            # No archive.json -> this source cannot be tied to an analysis. Never guessed.
            $ambiguous.Add($s.sha16)
            $entries.Add((New-ReplayCatalogEntry -Sha256 $s.sha16 -Sha16 $s.sha16 -SourceRelPath (Get-ReplaySourceRelativePath -ProjectRoot $ProjectRoot -FullPath $s.sav_path) -OriginalName $s.original_name -State $script:ReplayCatalogRemoved -SizeBytes $s.size_bytes -SourcePresent $true -Visible $false))
            $rows.Add([ordered]@{display_name=[string]$s.original_name;sha16=[string]$s.sha16;planned_state=$script:ReplayCatalogRemoved;reason='ambiguous_source_without_archive_json'})
            continue
        }
        $sha=$s.sha256.ToUpperInvariant()
        $hasAnalysis=$activeSha.ContainsKey($sha)
        $state=$(if($hasAnalysis){$script:ReplayCatalogActive}else{$script:ReplayCatalogRemoved})
        if(-not$hasAnalysis){$noAnalysis.Add($s.sha16)}
        $entries.Add((New-ReplayCatalogEntry -Sha256 $sha -Sha16 $s.sha16 -SourceRelPath (Get-ReplaySourceRelativePath -ProjectRoot $ProjectRoot -FullPath $s.sav_path) -OriginalName $s.original_name -State $state -SizeBytes $s.size_bytes -SourcePresent $true -Visible $false))
        $rows.Add([ordered]@{display_name=[string]$s.original_name;sha16=[string]$s.sha16;planned_state=$state;reason=$(if($hasAnalysis){'has_current_analysis'}else{'source_present_but_no_analysis'})})
    }
    $knownSha=@{}
    foreach($e in @($entries.ToArray())){$knownSha[[string]$e.sha256]=$true}
    foreach($k in @($activeSha.Keys)){ if(-not$knownSha.ContainsKey($k)){$analysisWithoutSource.Add($k)} }

    $all=@($entries.ToArray())
    return [pscustomobject]@{
        source_total=$inv.Count
        analysis_total=$analysisTotal
        would_be_active=@($all|Where-Object{[string]$_.state-eq$script:ReplayCatalogActive}).Count
        would_be_removed=@($all|Where-Object{[string]$_.state-eq$script:ReplayCatalogRemoved}).Count
        ambiguous=$ambiguous.Count
        # "source_missing" = an analysis exists but its source bytes are gone.
        source_missing=$analysisWithoutSource.Count
        sources_without_analysis=$noAnalysis.Count
        ambiguous_sources=@($ambiguous.ToArray())
        sources_without_analysis_sources=@($noAnalysis.ToArray())
        analysis_without_source=@($analysisWithoutSource.ToArray())
        unreadable_analyses=@($unreadable.ToArray())
        rows=@($rows.ToArray())
        entries=@($all)
    }
}

# Read-only preview: identical planning to bootstrap, but it NEVER writes.
function Get-ReplayCatalogBootstrapPreview {
    param(
        [Parameter(Mandatory=$true)][string]$DataDir,
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$AnalysisDir
    )
    $existing=Read-ReplayCatalog -DataDir $DataDir
    $plan=Get-ReplayCatalogBootstrapPlan -DataDir $DataDir -ProjectRoot $ProjectRoot -AnalysisDir $AnalysisDir
    return [pscustomobject]@{
        preview=$true
        catalog_exists=[bool]$existing.exists
        catalog_contract_ok=$(if($existing.exists){$null-ne$existing.document}else{$null})
        source_total=$plan.source_total
        analysis_total=$plan.analysis_total
        would_be_active=$plan.would_be_active
        would_be_removed=$plan.would_be_removed
        ambiguous=$plan.ambiguous
        source_missing=$plan.source_missing
        sources_without_analysis=$plan.sources_without_analysis
        ambiguous_sources=@($plan.ambiguous_sources)
        sources_without_analysis_sources=@($plan.sources_without_analysis_sources)
        analysis_without_source=@($plan.analysis_without_source)
        unreadable_analyses=@($plan.unreadable_analyses)
        rows=@($plan.rows)
    }
}

# Read-only inspection of an already-bootstrapped catalog. Reports drift between
# catalog state, source presence and current analyses WITHOUT changing anything.
function Get-ReplayCatalogInspection {
    param(
        [Parameter(Mandatory=$true)][string]$DataDir,
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$AnalysisDir
    )
    $read=Read-ReplayCatalog -DataDir $DataDir
    if(-not $read.exists){return [pscustomobject]@{exists=$false;valid=$false}}
    if($null-eq$read.document){return [pscustomobject]@{exists=$true;valid=$false;reason='unsupported_contract'}}

    $analysisSha=@{}
    if(Test-Path -LiteralPath $AnalysisDir -PathType Container){
        foreach($f in @(Get-ChildItem -LiteralPath $AnalysisDir -Filter '*.json' -File -ErrorAction SilentlyContinue)){
            $j=$null
            try { $j=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            $sha=[string]$j.replay_sha256
            if(-not[string]::IsNullOrWhiteSpace($sha)-and$sha.Length-ge16){$analysisSha[$sha.ToUpperInvariant()]=$true}
        }
    }
    $inv=@(Get-ReplaySourceInventory -DataDir $DataDir)
    $sourceSha=@{}
    foreach($s in $inv){ if(-not[string]::IsNullOrWhiteSpace($s.sha256)){$sourceSha[$s.sha256.ToUpperInvariant()]=$true} }

    $entries=@($read.document.entries)
    $drift=New-Object System.Collections.Generic.List[object]
    $activeWithAnalysis=0;$activeWithoutAnalysis=0
    foreach($e in $entries){
        $sha=[string]$e.sha256
        $hasSource=$sourceSha.ContainsKey($sha)
        $hasAnalysis=$analysisSha.ContainsKey($sha)
        if([string]$e.state-eq$script:ReplayCatalogActive){ if($hasAnalysis){$activeWithAnalysis++}else{$activeWithoutAnalysis++} }
        if([bool]$e.source_present -ne $hasSource){
            $drift.Add([ordered]@{sha16=[string]$e.sha16;field='source_present';catalog=[bool]$e.source_present;observed=$hasSource})
        }
        if([string]$e.state-eq$script:ReplayCatalogActive-and-not$hasSource){
            $drift.Add([ordered]@{sha16=[string]$e.sha16;field='active_source_missing';catalog=$true;observed=$false})
        }
    }
    $catalogSha=@{}
    foreach($e in $entries){$catalogSha[[string]$e.sha256]=$true}
    $analysisNotInCatalog=@(@($analysisSha.Keys)|Where-Object{-not$catalogSha.ContainsKey($_)})
    $sourceNotInCatalog=@(@($sourceSha.Keys)|Where-Object{-not$catalogSha.ContainsKey($_)})

    return [pscustomobject]@{
        exists=$true
        valid=$true
        path=$read.path
        total=$entries.Count
        active=@($entries|Where-Object{[string]$_.state-eq$script:ReplayCatalogActive}).Count
        removed=@($entries|Where-Object{[string]$_.state-eq$script:ReplayCatalogRemoved}).Count
        source_total=$inv.Count
        analysis_total=$analysisSha.Count
        active_with_analysis=$activeWithAnalysis
        active_without_analysis=$activeWithoutAnalysis
        analysis_not_in_catalog=$analysisNotInCatalog.Count
        source_not_in_catalog=$sourceNotInCatalog.Count
        drift=$drift.Count
        drift_rows=@($drift.ToArray())
    }
}

function Get-ReplayCatalogStatus {
    param([Parameter(Mandatory=$true)][string]$DataDir)
    $read=Read-ReplayCatalog -DataDir $DataDir
    if($null-eq$read.document){return [pscustomobject]@{exists=$read.exists;valid=$false;total=0;active=0;removed=0;active_present=0;active_source_missing=0}}
    $entries=@($read.document.entries)
    $active=@($entries|Where-Object{[string]$_.state-eq$script:ReplayCatalogActive})
    return [pscustomobject]@{
        exists=$true
        valid=$true
        path=$read.path
        total=$entries.Count
        active=$active.Count
        removed=@($entries|Where-Object{[string]$_.state-eq$script:ReplayCatalogRemoved}).Count
        active_present=@($active|Where-Object{RC-AsBool $_.source_present}).Count
        active_source_missing=@($active|Where-Object{-not(RC-AsBool $_.source_present)}).Count
    }
}
