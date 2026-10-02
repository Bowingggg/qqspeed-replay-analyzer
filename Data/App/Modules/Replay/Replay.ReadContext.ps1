# ReplayReadContext -- small, lazy, single-replay binary/input IO context.
#
# Purpose: give one replay analysis a single place that owns "path / size /
# sha256 / optional bytes" so a hash or a full read is performed AT MOST ONCE per
# analysis and then reused, without every parser being rewritten.
#
# Scope rules (deliberately narrow):
#   * ONE replay, ONE analysis lifetime. Never a process-wide byte[] cache.
#   * lazy: sha256 and bytes are materialised on first request, then reused.
#   * binary/input IO only. No semantic state, no derived results, no authority.
#   * the cached bytes are the raw file bytes; source identity is unchanged.
#
# Definition-only module: no runtime actions at import scope.

$script:ReplayReadContextContract='replay_read_context_v1'

function Get-ReplayReadContextContract { return $script:ReplayReadContextContract }

# ---------------------------------------------------------------------------
# Process-scope IO instrumentation. Test/benchmark only; never surfaced in the
# user UI. The point is to be able to answer "who read what" in a report.
#
# The counter table is created lazily rather than at import scope: modules in this
# project are definition-only (Validate-ModuleBoundaries enforces it), so an
# [ordered]@{} literal cannot sit at import scope.
# ---------------------------------------------------------------------------
function Reset-ReplayIoCounters {
    $script:ReplayIoCounters=[ordered]@{
        sha256_count=0L
        read_all_bytes_count=0L
        native_tail_scan_count=0L
        physical_read_count=0L
        total_bytes_read=0L
    }
}

function Add-ReplayIoCounter {
    param([Parameter(Mandatory=$true)][string]$Name,[long]$Delta=1)
    if($null -eq $script:ReplayIoCounters){ Reset-ReplayIoCounters }
    if(-not $script:ReplayIoCounters.Contains($Name)){ $script:ReplayIoCounters[$Name]=0L }
    $script:ReplayIoCounters[$Name]=[long]$script:ReplayIoCounters[$Name]+[long]$Delta
}

function Get-ReplayIoCounters {
    if($null -eq $script:ReplayIoCounters){ Reset-ReplayIoCounters }
    $o=[ordered]@{}
    foreach($k in @($script:ReplayIoCounters.Keys)){ $o[$k]=[long]$script:ReplayIoCounters[$k] }
    return [pscustomobject]$o
}

# ---------------------------------------------------------------------------
# Context
# ---------------------------------------------------------------------------
function New-ReplayReadContext {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        # Optional already-known identity. Supplying it skips the first hash, and
        # is only appropriate when the caller computed it for this same path.
        [string]$KnownSha256=''
    )
    if([string]::IsNullOrWhiteSpace($Path)){throw 'Replay read context requires a path.'}
    $full=[IO.Path]::GetFullPath($Path)
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw ('Replay not found: '+$full)}
    $info=Get-Item -LiteralPath $full
    $seed=$(if($KnownSha256 -match '^[0-9A-Fa-f]{64}$'){$KnownSha256.ToUpperInvariant()}else{''})
    return [pscustomobject]@{
        contract=$script:ReplayReadContextContract
        path=$full
        file_name=[string]$info.Name
        file_size=[long]$info.Length
        # private lazy state (accessed through the accessors below)
        sha256=$seed
        bytes=$null
        # per-context counters
        sha256_count=0
        read_all_bytes_count=0
        total_bytes_read=0L
    }
}

function Get-ReplayReadContextSha256 {
    param([Parameter(Mandatory=$true)][object]$Context,[switch]$Force)
    if(-not [bool]$Force -and -not [string]::IsNullOrWhiteSpace([string]$Context.sha256)){
        return [string]$Context.sha256
    }
    # Reuse already-materialised bytes when present: hashing them costs no file read.
    if($null -ne $Context.bytes){
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $hash=$sha.ComputeHash($Context.bytes) } finally { $sha.Dispose() }
        $Context.sha256=([BitConverter]::ToString($hash)).Replace('-','').ToUpperInvariant()
        $Context.sha256_count=[int]$Context.sha256_count+1
        Add-ReplayIoCounter -Name 'sha256_count'
        return [string]$Context.sha256
    }
    $Context.sha256_count=[int]$Context.sha256_count+1
    Add-ReplayIoCounter -Name 'sha256_count'
    $Context.sha256=(Get-FileHash -LiteralPath $Context.path -Algorithm SHA256).Hash.ToUpperInvariant()
    return [string]$Context.sha256
}

function Get-ReplayReadContextBytes {
    param([Parameter(Mandatory=$true)][object]$Context)
    # -NoEnumerate is essential: a bare `return $bytes` makes PowerShell unroll the
    # array into the pipeline and re-collect it, returning a NEW array on every call
    # (defeating the cache and copying megabytes).
    if($null -ne $Context.bytes){ Write-Output -NoEnumerate $Context.bytes; return }
    $b=[IO.File]::ReadAllBytes($Context.path)
    $Context.bytes=$b
    $Context.read_all_bytes_count=[int]$Context.read_all_bytes_count+1
    $Context.total_bytes_read=[long]$Context.total_bytes_read+[long]$b.Length
    Add-ReplayIoCounter -Name 'read_all_bytes_count'
    Add-ReplayIoCounter -Name 'total_bytes_read' -Delta ([long]$b.Length)
    Write-Output -NoEnumerate $b
}

function Get-ReplayReadContextStats {
    param([Parameter(Mandatory=$true)][object]$Context)
    return [pscustomobject][ordered]@{
        path=[string]$Context.path
        file_size=[long]$Context.file_size
        sha256=[string]$Context.sha256
        sha256_count=[int]$Context.sha256_count
        read_all_bytes_count=[int]$Context.read_all_bytes_count
        total_bytes_read=[long]$Context.total_bytes_read
        has_sha256=(-not [string]::IsNullOrWhiteSpace([string]$Context.sha256))
        has_bytes=($null -ne $Context.bytes)
    }
}

# Releases the cached bytes. Keeps the context usable for path/size/sha only, so a
# long-running caller can drop the big buffer without losing identity.
function Clear-ReplayReadContextBytes {
    param([Parameter(Mandatory=$true)][object]$Context)
    $Context.bytes=$null
}
