param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}
function Put-U32([byte[]]$D,[int]$O,[uint32]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}

. (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeActionEvents.ps1')

# ---------------------------------------------------------------------------
# Native Action Event Table -- gold regression + fail-closed contract.
#
# This belongs to the Real Regression gate: it asserts real replay truth.
# The Gold replays are content-addressed in Data/ReplayArchive and are pinned by
# SHA256, so the golden numbers cannot be satisfied by a different recording.
# ---------------------------------------------------------------------------

$syntheticCases=0

# --- 1. synthetic fail-closed contract (no real replay needed) --------------
# Records are passed as three FLAT arrays. Nested array literals such as
# @(@(1,2,3)) are flattened by PowerShell, which would silently turn a record
# into a scalar and zero out the code/reserved fields.
function New-EventBytes {
    param([long[]]$Times,[long[]]$Codes,[long[]]$Reserved,[int]$TrailerBytes=374)
    $Count=$Times.Count
    if($Codes.Count-ne$Count-or$Reserved.Count-ne$Count){throw 'synthetic record arrays must have equal length'}
    $len=$TrailerBytes+4+12*$Count
    [byte[]]$b=New-Object byte[] $len
    $co=$len-$TrailerBytes-4-12*$Count
    Put-U32 $b $co ([uint32]$Count)
    for($i=0;$i -lt $Count;$i++){
        $p=$co+4+12*$i
        Put-U32 $b $p ([uint32]$Times[$i])
        Put-U32 $b ($p+4) ([uint32]$Codes[$i])
        Put-U32 $b ($p+8) ([uint32]$Reserved[$i])
    }
    return ,$b
}
function Assert-Unavailable([byte[]]$Bytes,[string]$ExpectedReason,[string]$Label){
    $t=Get-ReplayNativeActionEventTable -Data $Bytes
    Require (-not[bool]$t.available) ($Label+': expected unavailable, got '+[string]$t.status)
    Require ([string]$t.status-eq'unavailable') ($Label+': status must be unavailable')
    Require ([string]$t.reason-eq$ExpectedReason) ($Label+': reason '+[string]$t.reason+' != '+$ExpectedReason)
    $script:syntheticCases++
}

# valid synthetic table
[byte[]]$valid=New-EventBytes -Times @(1000,2000,3000,4000,4100,6000) -Codes @(8,9,19,24,25,24) -Reserved @(0,0,0,0,0,0)
$tv=Get-ReplayNativeActionEventTable -Data $valid
Require ([bool]$tv.available) 'synthetic valid table must decode'
Require ([string]$tv.status-eq'validated') 'synthetic valid table status must be validated'
Require ([int]$tv.event_count-eq6) 'synthetic valid table event_count must be 6'
Require ([int]$tv.histogram['8']-eq1-and[int]$tv.histogram['9']-eq1-and[int]$tv.histogram['19']-eq1) 'synthetic valid histogram mismatch'
Require ([int]$tv.histogram['24']-eq2-and[int]$tv.histogram['25']-eq1) 'synthetic valid histogram mismatch (24/25)'
Require ([long]$tv.events[0].time_ms-eq1000-and[long]$tv.events[5].time_ms-eq6000) 'synthetic valid event order mismatch'
Require ([long]$tv.events[0].action_code-eq8-and[long]$tv.events[4].action_code-eq25) 'synthetic valid action_code mismatch'
Require ([long]$tv.events[0].record_offset-eq([long]$tv.count_offset+4)) 'synthetic record_offset mismatch'
$cv=Get-ReplayNativeActionEventComboCandidate -Table $tv
Require ([int]$cv.cw-eq1) 'synthetic candidate CW must be 1 (code25 paired with code24)'
Require ([int]$cv.wcw-eq1) 'synthetic candidate WCW must be 1'
Require ([int]$cv.cww-eq0) 'synthetic candidate CWW must be 0'
$syntheticCases++

Assert-Unavailable (New-EventBytes -Times @(1000) -Codes @(8) -Reserved @(5)) 'action_event_reserved_field_nonzero' 'reserved nonzero'
Assert-Unavailable (New-EventBytes -Times @(2000,1000) -Codes @(8,9) -Reserved @(0,0)) 'action_event_time_not_monotonic' 'non-monotonic time'
Assert-Unavailable (New-EventBytes -Times @(700000) -Codes @(8) -Reserved @(0)) 'action_event_time_out_of_range' 'time out of range'
# two self-consistent counts: record0 reserved field equals the smaller count
Assert-Unavailable (New-EventBytes -Times @(100,200,300) -Codes @(8,9,24) -Reserved @(2,0,0)) 'action_event_count_ambiguous' 'ambiguous count'
# no self-consistent count at all
Assert-Unavailable (New-Object byte[] 500) 'action_event_count_unresolved' 'unresolved count'
Assert-Unavailable (New-Object byte[] 100) 'file_smaller_than_container_trailer' 'file too small'

Write-Host ('[OK] native action event synthetic fail-closed contract: '+$syntheticCases+' case(s)')

# --- 2. Gold regressions ----------------------------------------------------
$dataDir=Split-Path -Parent $AppDir
$archive=Join-Path $dataDir 'ReplayArchive'

function Find-GoldReplay([string]$Stamp){
    if(-not(Test-Path -LiteralPath $archive -PathType Container)){return $null}
    $m=@(Get-ChildItem -LiteralPath $archive -Recurse -File -Filter ('*'+$Stamp+'*.sav') -ErrorAction SilentlyContinue)
    if($m.Count-eq0){return $null}
    return $m[0]
}
function Assert-Gold {
    param(
        [string]$Tag,[string]$Stamp,[string]$Sha256,[int]$Count,[hashtable]$Histogram,
        [long]$CountOffset,[long]$FirstTime,[long]$LastTime,[string[]]$Probes,
        [int]$Cw,[int]$Wcw,[int]$Cww,[int]$Air,[int]$Landing,[int]$Paired25,[int]$Unpaired25
    )
    $f=Find-GoldReplay $Stamp
    if($null-eq$f){ Write-Host ('  ['+$Tag+'] not-present (skipped)'); return $false }
    $sha=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    Require ($sha-eq$Sha256) ($Tag+': replay SHA256 mismatch, refusing to treat this file as the gold replay')

    $t=Get-ReplayNativeActionEventTable -ReplayPath $f.FullName
    Require ([bool]$t.available) ($Tag+': action event table is unavailable: '+[string]$t.reason)
    Require ([string]$t.status-eq'validated') ($Tag+': status must be validated')
    Require ([string]$t.contract-eq'native_action_event_table_v1') ($Tag+': contract mismatch')
    Require (-not[bool]$t.authoritative) ($Tag+': decoder must not claim authority')
    Require ([int]$t.count_solutions-eq1) ($Tag+': locator must be unambiguous')
    Require ([long]$t.count_offset-eq$CountOffset) ($Tag+': count_offset '+[string]$t.count_offset+' != '+[string]$CountOffset)

    # event total
    Require ([int]$t.event_count-eq$Count) ($Tag+': event_count '+[string]$t.event_count+' != '+[string]$Count)

    # full histogram: guards against a misaligned parser that coincidentally matches a total
    foreach($k in @($Histogram.Keys)){
        $actual=[int]$t.histogram[[string]$k]
        Require ($actual-eq[int]$Histogram[$k]) ($Tag+': code'+[string]$k+' count '+[string]$actual+' != '+[string]$Histogram[$k])
    }
    foreach($k in @($t.histogram.Keys)){
        Require ($Histogram.ContainsKey([string]$k)) ($Tag+': unexpected code '+[string]$k+' in histogram')
    }
    Require ([int]$t.distinct_code_count-eq$Histogram.Count) ($Tag+': distinct code count mismatch')

    # representative events: index:time_ms:action_code, plus reserved must be 0
    $eventCount=@($t.events).Count
    foreach($p in @($Probes)){
        $parts=[string]$p -split ':'
        Require ($parts.Count-eq3) ($Tag+': probe must be index:time_ms:action_code')
        $idx=[int]$parts[0]
        Require ($idx -lt $eventCount) ($Tag+': probe index out of range')
        $e=$t.events[$idx]
        Require ([long]$e.time_ms-eq[long]$parts[1]) ($Tag+': record '+[string]$idx+' time_ms '+[string]$e.time_ms+' != '+[string]$parts[1])
        Require ([long]$e.action_code-eq[long]$parts[2]) ($Tag+': record '+[string]$idx+' action_code '+[string]$e.action_code+' != '+[string]$parts[2])
        Require ([long]$e.reserved-eq0) ($Tag+': record '+[string]$idx+' reserved must be 0')
    }

    # time ordering and bounds
    $prev=-1L
    foreach($e in @($t.events)){
        Require ([long]$e.time_ms-ge$prev) ($Tag+': event times must be non-decreasing')
        $prev=[long]$e.time_ms
    }
    Require ([long]$t.first_time_ms-eq$FirstTime) ($Tag+': first_time_ms mismatch')
    Require ([long]$t.last_time_ms-eq$LastTime) ($Tag+': last_time_ms mismatch')

    # research candidate layer (explicitly non-authoritative)
    $c=Get-ReplayNativeActionEventComboCandidate -Table $t
    Require ([bool]$c.available) ($Tag+': combo candidate layer unavailable')
    Require (-not[bool]$c.authoritative) ($Tag+': combo candidate must not claim authority')
    Require ([int]$c.cw-eq$Cw) ($Tag+': candidate CW '+[string]$c.cw+' != '+[string]$Cw)
    Require ([int]$c.wcw-eq$Wcw) ($Tag+': candidate WCW '+[string]$c.wcw+' != '+[string]$Wcw)
    Require ([int]$c.cww-eq$Cww) ($Tag+': candidate CWW '+[string]$c.cww+' != '+[string]$Cww)
    Require ([int]$c.air_boost-eq$Air) ($Tag+': candidate air_boost '+[string]$c.air_boost+' != '+[string]$Air)
    Require ([int]$c.landing_boost-eq$Landing) ($Tag+': candidate landing_boost '+[string]$c.landing_boost+' != '+[string]$Landing)
    Require ([int]$c.code25_paired.Count-eq$Paired25) ($Tag+': paired code25 count mismatch')
    Require ([int]$c.code25_unpaired.Count-eq$Unpaired25) ($Tag+': unpaired code25 count mismatch')
    Require ([int]$c.combo_marker_count-eq([int]$t.histogram['24'])) ($Tag+': code24 must be the combo marker')
    Require ([int]$c.wcw-eq[int]$t.histogram['19']) ($Tag+': candidate WCW must equal the code19 count')

    Write-Host ('  ['+$Tag+'] validated count='+[string]$t.event_count+' count_offset='+[string]$t.count_offset+' codes='+[string]$t.distinct_code_count+' candidate CW/WCW/CWW='+[string]$c.cw+'/'+[string]$c.wcw+'/'+[string]$c.cww+' air='+[string]$c.air_boost+' landing='+[string]$c.landing_boost+' decoder_ms='+[string]$t.elapsed_ms)
    return $true
}

# Gold A -- Old Street Pipeline. Game truth: air=5 landing=4 CW=3 WCW=3 CWW=4 (no gems).
$goldA=Assert-Gold -Tag 'goldA' -Stamp '20260930-234714' `
    -Sha256 '50436400DE8FF37EA45363470EE8B06112628DABB2F33C22C3AA577FBA641253' `
    -Count 45 -Histogram @{'8'=5;'9'=4;'13'=1;'19'=3;'22'=7;'23'=12;'24'=10;'25'=3} `
    -CountOffset 1546217 -FirstTime 20001 -LastTime 107501 `
    -Probes @('0:20001:13','5:31884:24','7:36284:8','8:36284:9','19:54918:24','20:54918:19','44:107501:24') `
    -Cw 3 -Wcw 3 -Cww 4 -Air 5 -Landing 4 -Paired25 3 -Unpaired25 0

# Gold B -- City Torch. Game truth: air=3 landing=1; explicit human samples CW=5 WCW=6 CWW=8.
# NOTE: raw code25 count is 10, not 5. The expected "code25 = 5" corresponds to the code25
# events that are adjacent to a code24 (i.e. the CW confirmations); 5 further code25 events
# occur standalone. The pairing rule is asserted explicitly below.
$goldB=Assert-Gold -Tag 'goldB' -Stamp '20260930-225857' `
    -Sha256 '3164A4F8AFA71A832B30E55A7228C6FA08A9DFCE683689BA33CE8A18CF6A3623' `
    -Count 72 -Histogram @{'2'=1;'8'=3;'9'=1;'13'=1;'19'=6;'20'=2;'21'=8;'22'=4;'23'=15;'24'=19;'25'=10;'43'=1;'44'=1} `
    -CountOffset 1752923 -FirstTime 19753 -LastTime 122470 `
    -Probes @('0:19753:21','6:28553:24','7:28603:25','29:59437:19','43:78403:19','68:119137:20','71:122470:25') `
    -Cw 5 -Wcw 6 -Cww 8 -Air 3 -Landing 1 -Paired25 5 -Unpaired25 5

$manifest=Get-Content -LiteralPath (Join-Path $AppDir 'app_manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
$status='goldA='+$(if($goldA){'verified'}else{'not-present'})+' goldB='+$(if($goldB){'verified'}else{'not-present'})
Write-Host ('[OK] Native Action Event Table gold smoke passed. app='+[string]$manifest.app_version+' contract=native_action_event_table_v1 synthetic='+[string]$syntheticCases+' fail-closed cases '+$status+' locator=container-trailer-fixed-point(unambiguous) codes=preserved-verbatim authority=research-only legacy-combo-detector=untouched')
exit 0
