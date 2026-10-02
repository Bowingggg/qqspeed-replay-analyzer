# September-2026 replay acceptance corpus enumeration.
#
# Definition-only helper (functions only, no import-scope work). Dot-source this from the
# readiness gate and from the acceptance tooling so that both enumerate the SAME corpus.
#
# Contract:
#   * The mandatory corpus is every *.sav physically present in <PROJECT_ROOT>\replay.
#     It is enumerated from the real working tree; no hand-written file list is ever used.
#   * The extension set is every *.sav under Data\ReplayArchive whose recorded month matches.
#   * Entries are de-duplicated by SHA256; the mandatory copy wins over the archive copy.
#   * Test ids (R01, R02, ...) are assigned by sorted SHA16, so they are stable across
#     machines and never derived from a player name or a file name.
#   * `recorded_at` is decoded from the QQSpeed replay filename convention
#     `<map>-<yyyyMMdd>-<HHmmss>-<player>.sav`. That convention is display/external metadata:
#     it is used ONLY to select which replays belong to the month. No parser, decoder or
#     structural decision may depend on it (see AGENTS.md / ARCHITECTURE.md authority rules).
#     When a file does not carry the convention, recorded_at is $null and the file is still
#     analysed - it is never dropped silently.

function Get-SeptemberCorpusTestId {
    param([Parameter(Mandatory=$true)][int]$Index)
    return ('R{0:D2}' -f $Index)
}

function Get-ReplayFileSha256Hex {
    param([Parameter(Mandatory=$true)][string]$Path)
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try {
        $fs=[System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-','').ToUpperInvariant() }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

# `<map>-<yyyyMMdd>-<HHmmss>-<player>.sav` -> the recording instant. Returns $null when the
# name does not follow the convention.
function Get-SeptemberRecordedTimeFromName {
    param([Parameter(Mandatory=$true)][string]$Path)
    $name=[System.IO.Path]::GetFileNameWithoutExtension($Path)
    if([string]::IsNullOrWhiteSpace($name)){ return $null }
    $m=[regex]::Match($name,'-(?<d>\d{8})-(?<t>\d{6})-')
    if(-not $m.Success){ return $null }
    try {
        return [datetime]::ParseExact(
            ($m.Groups['d'].Value+$m.Groups['t'].Value),
            'yyyyMMddHHmmss',
            [System.Globalization.CultureInfo]::InvariantCulture)
    } catch { return $null }
}

function Get-September2026Corpus {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [string]$UserCorpusDir='',
        [string]$ArchiveDir='',
        [string]$YearMonth='2026-09'
    )
    if([string]::IsNullOrWhiteSpace($UserCorpusDir)){ $UserCorpusDir=Join-Path $ProjectRoot 'replay' }
    if([string]::IsNullOrWhiteSpace($ArchiveDir)){ $ArchiveDir=Join-Path $ProjectRoot 'Data\ReplayArchive' }

    $candidates=New-Object System.Collections.Generic.List[object]
    if(Test-Path -LiteralPath $UserCorpusDir -PathType Container) {
        foreach($f in @(Get-ChildItem -LiteralPath $UserCorpusDir -File -Filter '*.sav' -ErrorAction SilentlyContinue)) {
            $candidates.Add([pscustomobject]@{ path=$f.FullName; corpus='mandatory_user'; bytes=[long]$f.Length })
        }
    }
    if(Test-Path -LiteralPath $ArchiveDir -PathType Container) {
        foreach($f in @(Get-ChildItem -LiteralPath $ArchiveDir -Recurse -File -Filter '*.sav' -ErrorAction SilentlyContinue)) {
            $candidates.Add([pscustomobject]@{ path=$f.FullName; corpus='archive_extension'; bytes=[long]$f.Length })
        }
    }

    $bySha=@{}
    $order=New-Object System.Collections.Generic.List[string]
    foreach($c in @($candidates.ToArray()|Sort-Object @{Expression='corpus'},@{Expression='path'})) {
        $t=$null
        try { $t=Get-SeptemberRecordedTimeFromName $c.path } catch { $t=$null }
        $ym=$(if($null-ne$t){ $t.ToString('yyyy-MM') } else { $null })

        # Mandatory entries are never filtered out by the month rule; the flag is recorded so the
        # gate can report an unexpected file in replay\ instead of dropping it silently.
        $monthMatch=($null-ne$ym -and $ym -eq $YearMonth)
        if($c.corpus -ne 'mandatory_user' -and -not $monthMatch){ continue }

        $sha=Get-ReplayFileSha256Hex $c.path
        if($bySha.ContainsKey($sha)){
            $existing=$bySha[$sha]
            # Mandatory copy wins; otherwise the first archive copy wins.
            if($existing.corpus -eq 'mandatory_user'){ continue }
        } else {
            $order.Add($sha)
        }
        $bySha[$sha]=[pscustomobject][ordered]@{
            sha256=$sha
            sha16=$sha.Substring(0,16)
            size_bytes=[long]$c.bytes
            recorded_at=$(if($null-ne$t){ $t.ToString('s') } else { $null })
            recorded_month=$ym
            recorded_at_source=$(if($null-ne$t){ 'replay_filename_convention' } else { 'unavailable' })
            month_match=$monthMatch
            corpus=$c.corpus
            source_path=$c.path
        }
    }

    $rows=New-Object System.Collections.Generic.List[object]
    $i=0
    foreach($sha in @($order.ToArray()|Sort-Object)) {
        $i++
        $e=$bySha[$sha]
        $rows.Add([pscustomobject][ordered]@{
            test_id=Get-SeptemberCorpusTestId $i
            sha256=$e.sha256
            sha16=$e.sha16
            size_bytes=$e.size_bytes
            recorded_at=$e.recorded_at
            recorded_month=$e.recorded_month
            recorded_at_source=$e.recorded_at_source
            month_match=$e.month_match
            corpus=$e.corpus
            source_path=$e.source_path
        })
    }
    return @($rows.ToArray())
}

# Publishable view: no absolute paths and no file names (a QQSpeed file name carries the player
# nickname). This is the only shape allowed into documents, handoffs or the review ZIP.
function ConvertTo-SeptemberCorpusPublishable {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Corpus)
    $out=New-Object System.Collections.Generic.List[object]
    foreach($e in @($Corpus)) {
        $out.Add([pscustomobject][ordered]@{
            test_id=[string]$e.test_id
            sha16=[string]$e.sha16
            size_bytes=[long]$e.size_bytes
            recorded_at=$e.recorded_at
            recorded_at_source=[string]$e.recorded_at_source
            month_match=[bool]$e.month_match
            corpus=[string]$e.corpus
        })
    }
    return @($out.ToArray())
}
