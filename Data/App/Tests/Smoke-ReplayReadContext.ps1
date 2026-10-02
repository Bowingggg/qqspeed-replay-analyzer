param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}
function Put-U32([byte[]]$D,[int]$O,[uint32]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}

. (Join-Path $AppDir 'Modules\Replay\Replay.ReadContext.ps1')
. (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeActionEvents.ps1')

# ReplayReadContext: lazy, reused, single-replay, and it must let a consumer that
# accepts -Data avoid a second file read.

$dataDir=Split-Path -Parent $AppDir
$dev=Join-Path $dataDir 'Diagnostics\Dev'
New-Item -ItemType Directory -Force -Path $dev | Out-Null
$sandbox=Join-Path $dev ('readctx_'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

function New-ActionEventSav([string]$Path,[long[]]$Times,[long[]]$Codes){
    $count=$Times.Count
    $len=374+4+12*$count
    [byte[]]$b=New-Object byte[] $len
    $co=$len-374-4-12*$count
    Put-U32 $b $co ([uint32]$count)
    for($i=0;$i -lt $count;$i++){
        $p=$co+4+12*$i
        Put-U32 $b $p ([uint32]$Times[$i])
        Put-U32 $b ($p+4) ([uint32]$Codes[$i])
        Put-U32 $b ($p+8) ([uint32]0)
    }
    [IO.File]::WriteAllBytes($Path,$b)
    return [pscustomobject]@{path=$Path;count=$count;bytes=$b}
}

try {
    $savA=New-ActionEventSav -Path (Join-Path $sandbox 'a.sav') -Times @(1000,2000,3000) -Codes @(8,19,24)
    $savB=New-ActionEventSav -Path (Join-Path $sandbox 'b.sav') -Times @(500,900) -Codes @(9,25)

    Reset-ReplayIoCounters

    # ---- 1. sha256 requested twice -> hashed once ---------------------------
    $ctxA=New-ReplayReadContext -Path $savA.path
    $s1=Get-ReplayReadContextSha256 $ctxA
    $s2=Get-ReplayReadContextSha256 $ctxA
    Require ($s1-ceq$s2) 'repeated sha256 requests must return the same value'
    Require ($s1 -match '^[0-9A-F]{64}$') 'sha256 must be a 64-char uppercase hex string'
    Require ([int]$ctxA.sha256_count-eq1) ('context must hash once, saw '+[string]$ctxA.sha256_count)
    Require ([long](Get-ReplayIoCounters).sha256_count-eq1) ('process sha256 counter must be 1, saw '+[string](Get-ReplayIoCounters).sha256_count)

    # the value must equal an independent hash of the same file
    $expect=(Get-FileHash -LiteralPath $savA.path -Algorithm SHA256).Hash.ToUpperInvariant()
    Require ($s1-eq$expect) 'context sha256 must equal Get-FileHash for the same path'

    # ---- 2. bytes requested twice -> ReadAllBytes once -----------------------
    $b1=Get-ReplayReadContextBytes $ctxA
    $b2=Get-ReplayReadContextBytes $ctxA
    Require ($b1.Length-eq$savA.bytes.Length) 'context bytes must match the file size'
    Require ([object]::ReferenceEquals($b1,$b2)) 'repeated byte requests must return the same buffer instance'
    Require ([int]$ctxA.read_all_bytes_count-eq1) ('context must read bytes once, saw '+[string]$ctxA.read_all_bytes_count)

    # ---- 3. context isolation across replays -------------------------------
    $ctxB=New-ReplayReadContext -Path $savB.path
    $sB=Get-ReplayReadContextSha256 $ctxB
    Require ($sB-ne$s1) 'different replays must have different identity'
    Require ([int]$ctxB.sha256_count-eq1) 'second context hashes independently'
    Require ($null-eq$ctxB.bytes) 'second context must not inherit the first context bytes'
    Require ((Get-ReplayReadContextStats $ctxB).has_bytes -eq $false) 'second context bytes must still be lazy'
    Require ([long]$ctxA.file_size-ne[long]$ctxB.file_size -or $savA.count-ne$savB.count) 'contexts must describe their own file'
    # materialise B: buffers must be independent, and this is the second real read
    $bytesB=Get-ReplayReadContextBytes $ctxB
    Require (-not[object]::ReferenceEquals($bytesB,$b1)) 'two contexts must not share a buffer'
    Require ($bytesB.Length-eq$savB.bytes.Length) 'second context buffer must match its own file size'
    Require ([int]$ctxB.read_all_bytes_count-eq1) 'second context reads its own bytes once'

    # ---- 4. ActionEvent with -Data must not re-read the file ---------------
    $bytesA=Get-ReplayReadContextBytes $ctxA
    $t1=Get-ReplayNativeActionEventTable -Data $bytesA
    Require ([bool]$t1.available) 'action event table must decode from provided bytes'
    Require ([int]$t1.event_count-eq$savA.count) ('event count mismatch: '+[string]$t1.event_count)
    # Remove the file: a decoder that ignored -Data and re-opened the path must now fail.
    Remove-Item -LiteralPath $savA.path -Force
    $t2=Get-ReplayNativeActionEventTable -Data $bytesA
    Require ([bool]$t2.available) 'action event table must still decode after the file is gone (proves no second file read)'
    Require ([string]$t2.status-eq'validated') 'status must stay validated'
    Require ([string]$t2.histogram['8']-eq[string]$t1.histogram['8']) 'histogram must be identical'
    $t3=Get-ReplayNativeActionEventTable -ReplayPath $savA.path
    Require (-not[bool]$t3.available) 'path-based decode must now report unavailable (control)'
    Require ([string]$t3.reason-eq'replay_not_found') ('expected replay_not_found, saw '+[string]$t3.reason)

    # ---- 5. counters aggregate what actually happened ----------------------
    $c=Get-ReplayIoCounters
    Require ([long]$c.sha256_count-eq2) ('process sha256 count must be 2, saw '+[string]$c.sha256_count)
    Require ([long]$c.read_all_bytes_count-eq2) ('process read count must be 2, saw '+[string]$c.read_all_bytes_count)
    Require ([long]$c.total_bytes_read-eq([long]($savA.bytes.Length+$savB.bytes.Length))) ('total bytes read mismatch: '+[string]$c.total_bytes_read)

    # ---- 6. a known identity can be seeded without re-hashing --------------
    Reset-ReplayIoCounters
    $ctxC=New-ReplayReadContext -Path $savB.path -KnownSha256 $sB
    $sC=Get-ReplayReadContextSha256 $ctxC
    Require ($sC-eq$sB) 'seeded identity must be returned unchanged'
    Require ([long](Get-ReplayIoCounters).sha256_count-eq0) 'seeded identity must not hash again'
    $bad=New-ReplayReadContext -Path $savB.path -KnownSha256 'not-a-sha'
    Require ([int]$bad.sha256_count-eq0-and[string]::IsNullOrWhiteSpace([string]$bad.sha256)) 'malformed seed must be ignored'

    Write-Host ('[OK] ReplayReadContext smoke passed. contract='+$script:ReplayReadContextContract+' sha-reuse=1 read-reuse=1 isolation=2-contexts actionevent-data=no-second-read counters=sha2/read2/bytes'+[string]$c.total_bytes_read+' fail-closed=path-unavailable-after-delete')
    exit 0
} finally {
    if(Test-Path -LiteralPath $sandbox){ Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    if(Test-Path -LiteralPath $dev){ if(@(Get-ChildItem $dev -Force).Count -eq 0){ Remove-Item $dev -Force -ErrorAction SilentlyContinue } }
}
