# NativeActionCache v1 smoke.
#
# Locks the contract that lets later Analyze / -ForceTelemetry runs re-interpret native action
# semantics from PhysicalTelemetryCache + NativeActionCache without scanning the original .sav:
#   synthetic contract  : raw scan == cache replay == tail re-parse, including candidate/table
#                         values, effect codes, validation statuses and per-row action flags
#   saved evidence      : raw Drift records + intervals, effect records + codes + bit patterns,
#                         offsets/provenance, the exact tail window
#   fail-closed matrix  : contract/identity/scan-window/tamper/tail problems rebuild instead of
#                         silently producing different native action facts
#   real benchmark      : 月牙湾 rebuilt with -ForceNativeActions then reused with -ForceTelemetry,
#                         with cache files untouched on reuse and identical derived semantics
# No native action semantic, combo rule, Driving detector, A/B or NativeMap behaviour is changed.
param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}
function Put-U32([byte[]]$D,[int]$O,[uint32]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}
function Put-I32([byte[]]$D,[int]$O,[int]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}
function Put-F32([byte[]]$D,[int]$O,[single]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}
function Put-Marker([byte[]]$D,[int]$CountOffset){[Array]::Copy([byte[]](0x7E,0xA0,0x1E,0xC2),0,$D,$CountOffset-4,4)}
function Canon-Json([object]$Value){return ($Value|ConvertTo-Json -Depth 12)}
function Fingerprint([string]$Path){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return 'missing'}
    $sha=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ($sha+'@'+[string](Get-Item -LiteralPath $Path).LastWriteTimeUtc.Ticks)
}
function Find-Replay([string]$Archive,[string]$Name){
    if(-not(Test-Path -LiteralPath $Archive -PathType Container)){return $null}
    $m=@(Get-ChildItem -LiteralPath $Archive -Recurse -File -Filter $Name -ErrorAction SilentlyContinue|Where-Object{$_.Name-eq$Name}|Select-Object -First 1)
    if($m.Count-eq0){return $null};return $m[0]
}
function New-TableIndex([object[]]$Tables){
    $index=@{}
    foreach($t in @($Tables)){$index[[string]([long]$t.count_offset)]=$t}
    return $index
}
function New-SyntheticReplay([string]$Path){
    [byte[]]$bytes=New-Object byte[] 24000
    # 1) marker-linked Drift table: 3 native intervals.
    $drift=6000;Put-Marker $bytes $drift;Put-U32 $bytes $drift 6
    $dp=@(@(1000,1),@(2200,0),@(3000,1),@(4200,0),@(5000,1),@(6200,0))
    for($i=0;$i-lt$dp.Count;$i++){Put-U32 $bytes ($drift+4+5*$i) ([uint32]$dp[$i][0]);$bytes[$drift+8+5*$i]=[byte]$dp[$i][1]}
    # adjacent native speed-effect table: nitro 1.0, small-boost class 2001.0, unknown 7.5, map propulsion 2003.0
    $fx=$drift+4+5*$dp.Count;Put-U32 $bytes $fx 8
    $er=@(@(1100,1,2001.0),@(1750,0,2001.0),@(3000,1,1.0),@(4000,0,1.0),@(5000,1,7.5),@(5200,0,7.5),@(8000,1,2003.0),@(10050,0,2003.0))
    for($i=0;$i-lt$er.Count;$i++){$p=$fx+4+9*$i;Put-U32 $bytes $p ([uint32]$er[$i][0]);$bytes[$p+4]=[byte]$er[$i][1];Put-F32 $bytes ($p+5) ([single]$er[$i][2])}
    # 2) older unmarked action-object pair: structural Drift table + adjacent native effect table.
    $legacy=12000;Put-U32 $bytes $legacy 4
    $lp=@(@(1000,1),@(2000,0),@(2200,1),@(2800,0))
    for($i=0;$i-lt$lp.Count;$i++){Put-U32 $bytes ($legacy+4+5*$i) ([uint32]$lp[$i][0]);$bytes[$legacy+8+5*$i]=[byte]$lp[$i][1]}
    $lfx=$legacy+4+5*$lp.Count;Put-U32 $bytes $lfx 2
    Put-U32 $bytes ($lfx+4) 6500;$bytes[$lfx+8]=1;Put-F32 $bytes ($lfx+9) ([single]1.0)
    Put-U32 $bytes ($lfx+13) 7600;$bytes[$lfx+17]=0;Put-F32 $bytes ($lfx+18) ([single]1.0)
    # 3) authoritative empty marker-linked Drift table with a valid empty adjacent table.
    $empty=16000;Put-Marker $bytes $empty;Put-U32 $bytes $empty 0;Put-U32 $bytes ($empty+4) 0
    # 4) marker-linked empty Drift table whose adjacent table is structurally invalid (state 2).
    $bad=18000;Put-Marker $bytes $bad;Put-U32 $bytes $bad 0
    $bfx=$bad+4;Put-U32 $bytes $bfx 2
    Put-U32 $bytes ($bfx+4) 1000;$bytes[$bfx+8]=1;Put-F32 $bytes ($bfx+9) ([single]1.0)
    Put-U32 $bytes ($bfx+13) 2000;$bytes[$bfx+17]=2;Put-F32 $bytes ($bfx+18) ([single]1.0)
    [IO.File]::WriteAllBytes($Path,$bytes)
}
function New-SyntheticRows(){
    $rows=New-Object System.Collections.Generic.List[object]
    for($i=0;$i-le700;$i++){
        $t=$i*0.02
        $shift=$false;$ctrl=$false;$contact=5
        foreach($ms in @(1000,3000,5000)){if([Math]::Abs($t-($ms/1000.0))-lt0.0005){$shift=$true}}
        if([Math]::Abs($t-3.0)-lt0.0005){$ctrl=$true}
        if($t-ge4.0-and$t-lt4.5){$contact=0}
        $slip=$(if($t-ge1.0-and$t-lt6.2){0.55}else{0.02})
        $rows.Add([pscustomobject]@{
            time_s=$t;slip=$slip;speed=20.0;distance=($t*20.0);contact_state=$contact
            input_bool_candidate_64=$shift;input_bool_candidate_65=$ctrl
            nitro_active=$false;small_boost_active=$false;air_boost_active=$false;landing_boost_active=$false
            map_propulsion_active=$false;small_boost_class_active=$false
            system_drift_state='unknown';system_drift_state_source='unresolved_not_found'
        })
    }
    return $rows.ToArray()
}
function Get-RowFlags([object[]]$Rows){
    $sb=New-Object System.Text.StringBuilder
    foreach($r in @($Rows)){
        [void]$sb.Append($(if([bool]$r.nitro_active){'N'}else{'-'}))
        [void]$sb.Append($(if([bool]$r.small_boost_active){'S'}else{'-'}))
        [void]$sb.Append($(if([bool]$r.air_boost_active){'A'}else{'-'}))
        [void]$sb.Append($(if([bool]$r.landing_boost_active){'L'}else{'-'}))
        [void]$sb.Append($(if([bool]$r.map_propulsion_active){'P'}else{'-'}))
        [void]$sb.Append($(if([bool]$r.small_boost_class_active){'C'}else{'-'}))
        [void]$sb.Append($(if($r.system_drift_state-eq$true){'D'}elseif($r.system_drift_state-eq$false){'d'}else{'?'}))
    }
    return $sb.ToString()
}
function Get-ActionChain {
    param(
        [Parameter(Mandatory=$true)][object]$Scan,
        [Parameter(Mandatory=$true)][object[]]$Rows,
        [string]$ReplayPath=''
    )
    $resolved=Resolve-ReplayNativeDriftTimeline -Candidates @($Scan.candidates) -Rows $Rows
    $driftSegments=@()
    if([bool]$resolved.available){$driftSegments=@(Convert-ReplayNativeDriftTimelineToSegments -Resolved $resolved -Rows $Rows -TotalDistance 100.0 -Laps @())}
    $payload=$null
    if([bool]$resolved.available){$payload=Get-NativeActionEffectTable -Scan $Scan -CountOffset ([long]$resolved.candidate.end_exclusive)}
    if([string]::IsNullOrWhiteSpace($ReplayPath)){
        $effects=Resolve-ReplayNativeSpeedEffectTimeline -EffectTablePayload $payload -NativeDriftResolved $resolved -Rows $Rows
    } else {
        # production raw path: the resolver reads the adjacent table from the replay itself
        $effects=Resolve-ReplayNativeSpeedEffectTimeline -ReplayPath $ReplayPath -NativeDriftResolved $resolved -Rows $Rows
    }
    $segments=Convert-ReplayNativeSpeedEffectsToSegments -Resolved $effects -Rows $Rows -NativeDriftResolved $resolved
    $combos=Resolve-ReplayNativeComboActions -SpeedEffects $segments
    return [pscustomobject]@{
        drift_available=[bool]$resolved.available;drift_status=[string]$resolved.status
        chosen_offset=$(if([bool]$resolved.available){[long]$resolved.candidate.count_offset}else{$null})
        drift_segment_count=$driftSegments.Count
        drift=Canon-Json @($driftSegments)
        effect_available=[bool]$effects.available;effect_status=[string]$effects.status
        effect_total=[int]$segments.native_effect_interval_count
        effect_nitro=[int]$segments.nitro_count;effect_small=[int]$segments.small_boost_count
        effect_other=[int]$segments.other_small_boost_count;effect_unknown=[int]$segments.unknown_speed_effect_count
        effect_propulsion=[int]$segments.map_propulsion_effect_count
        effects=Canon-Json ([ordered]@{status=$effects.status;all=@($segments.native_speed_effect_segments)})
        combos=Canon-Json ([ordered]@{cw=$combos.cw_count;wcw=$combos.wcw_count;cww=$combos.cww_count;segments=@($combos.native_combo_segments)})
        row_flags=Get-RowFlags -Rows $Rows
    }
}
function Compare-Chain($A,$B,[string]$Label){
    foreach($k in @('drift_available','drift_status','chosen_offset','drift_segment_count','drift','effect_available','effect_status','effect_total','effect_nitro','effect_small','effect_other','effect_unknown','effect_propulsion','effects','combos','row_flags')){
        $a=$A.$k;$b=$B.$k
        if([string]$a-ne[string]$b){throw ($Label+' semantic mismatch on '+$k+': '+[string]$a+' != '+[string]$b)}
    }
}
function Get-StreamSemantics([object]$Summary){
    $out=New-Object System.Collections.Generic.List[object]
    foreach($s in @($Summary.streams)){
        $out.Add([ordered]@{
            id=[string]$s.id;role=[string]$s.role
            system_drift_state_available=[bool]$s.system_drift_state_available;system_drift_state_status=[string]$s.system_drift_state_status
            system_drift_segment_count=[int]$s.system_drift_segment_count;system_drift_segments=@($s.system_drift_segments)
            native_drift_timeline_validation=$s.native_drift_timeline_validation
            speed_effect_state_available=[bool]$s.speed_effect_state_available;speed_effect_state_status=[string]$s.speed_effect_state_status
            native_speed_effect_segment_count=[int]$s.native_speed_effect_segment_count;native_speed_effect_segments=@($s.native_speed_effect_segments)
            native_speed_effect_timeline_validation=$s.native_speed_effect_timeline_validation
            nitro_segments=@($s.nitro_segments);small_boost_segments=@($s.small_boost_segments)
            air_boost_segments=@($s.air_boost_segments);landing_boost_segments=@($s.landing_boost_segments)
            other_small_boost_segments=@($s.other_small_boost_segments);map_propulsion_effect_segments=@($s.map_propulsion_effect_segments)
            unknown_speed_effect_segments=@($s.unknown_speed_effect_segments)
            combo_action_state_available=[bool]$s.combo_action_state_available;combo_action_state_status=[string]$s.combo_action_state_status
            cw_count=[int]$s.cw_count;wcw_count=[int]$s.wcw_count;cww_count=[int]$s.cww_count;combo_action_count=[int]$s.combo_action_count
            native_combo_segments=@($s.native_combo_segments)
        })
    }
    return (Canon-Json @($out.ToArray()))
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_NativeActionCache_'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
$sav=Join-Path $temp 'synthetic_native_action_cache.sav'
$cacheRoot=Join-Path $temp 'cache'
$realStatus='not-present'
try{
    . (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeDriftTimeline.ps1')
    . (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeSpeedEffects.ps1')
    . (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeComboActions.ps1')
    . (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeActionCache.ps1')
    New-SyntheticReplay $sav
    $sha=(Get-FileHash -LiteralPath $sav -Algorithm SHA256).Hash.ToUpperInvariant()
    $size=[long](Get-Item -LiteralPath $sav).Length
    $source=[ordered]@{sha256=$sha;size_bytes=$size;last_write_utc=(Get-Item -LiteralPath $sav).LastWriteTimeUtc.ToString('o');file_name=[IO.Path]::GetFileName($sav)}

    # ---------- A. raw scan and raw semantic chain ----------
    $rawScan=New-NativeActionScan -ReplayPath $sav
    Require (@($rawScan.candidates).Count-eq4) ('synthetic scan must expose 4 native action-object candidates, got '+[string]@($rawScan.candidates).Count)
    Require (@($rawScan.effect_tables).Count-eq4) ('synthetic scan must persist one effect payload per candidate anchor, got '+[string]@($rawScan.effect_tables).Count)
    Require ([long]$rawScan.scan_start_offset-eq0) 'small synthetic replay must be scanned as a whole file window'
    Require ([int]$rawScan.tail.Length-eq[int]$size) 'synthetic raw tail must cover the whole file'
    $rawScan|Add-Member -NotePropertyName table_index -NotePropertyValue (New-TableIndex -Tables $rawScan.effect_tables) -Force
    $emptyCandidate=@($rawScan.candidates|Where-Object{[bool]$_.empty_table})[0]
    Require ($null-ne$emptyCandidate) 'authoritative empty Drift table candidate missing from scan'
    $legacyCandidate=@($rawScan.candidates|Where-Object{-not[bool]$_.native_object_marker_valid})[0]
    Require ($null-ne$legacyCandidate-and[bool]$legacyCandidate.adjacent_effect_table_valid) 'older unmarked Drift+effect pair candidate missing from scan'
    $invalidTables=@($rawScan.effect_tables|Where-Object{-not[bool]$_.valid})
    Require ($invalidTables.Count-ge1) 'invalid adjacent effect table payload missing from scan'
    Require ([string]$invalidTables[0].status-eq'invalid_state_value') ('invalid effect table status not preserved: '+[string]$invalidTables[0].status)

    $rowsRaw=New-SyntheticRows
    $rawChain=Get-ActionChain -Scan $rawScan -Rows $rowsRaw -ReplayPath $sav
    Require ([bool]$rawChain.drift_available) 'synthetic native Drift table was not validated'
    Require ([long]$rawChain.chosen_offset-eq6000) ('synthetic native Drift ranking changed: '+[string]$rawChain.chosen_offset)
    Require ([int]$rawChain.drift_segment_count-eq3) ('synthetic native Drift segments != 3: '+[string]$rawChain.drift_segment_count)
    Require ([int]$rawChain.effect_total-eq4) ('synthetic native effect intervals != 4: '+[string]$rawChain.effect_total)
    Require ([int]$rawChain.effect_nitro-eq1-and[int]$rawChain.effect_small-eq1-and[int]$rawChain.effect_propulsion-eq1-and[int]$rawChain.effect_unknown-eq1) ('synthetic native effect classification changed: nitro='+[string]$rawChain.effect_nitro+' small='+[string]$rawChain.effect_small+' propulsion='+[string]$rawChain.effect_propulsion+' unknown='+[string]$rawChain.effect_unknown)

    # ---------- B. persist the raw evidence ----------
    $written=Write-NativeActionCache -CacheRoot $cacheRoot -ReplaySha256 $sha -Source $source -Scan $rawScan -CacheScope 'telemetry_local' -ToolVersion 'smoke'
    foreach($f in @('manifest.json','native_actions.json','native_action_tail.bin')){
        Require (Test-Path -LiteralPath (Join-Path $written.dir $f) -PathType Leaf) ('native action cache artifact missing: '+$f)
    }
    Require ([long](Get-Item -LiteralPath (Join-Path $written.dir 'native_action_tail.bin')).Length-eq$size) 'persisted raw tail length must equal the scanned window'
    $manifest=Get-Content -LiteralPath (Join-Path $written.dir 'manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Require ([string]$manifest.contract-eq'native_action_cache_v1') 'cache contract marker missing'
    Require ([string]$manifest.scanner_contract-eq(Get-NativeActionScannerContract)) 'scanner contract marker missing'
    Require ([string]$manifest.source.sha256-eq$sha-and[long]$manifest.source.size_bytes-eq$size) 'cache source identity binding missing'
    Require ([long]$manifest.scan_window.file_length-eq$size-and[long]$manifest.scan_window.scan_start_offset-eq0) 'cache scan window provenance missing'
    Require ([int]$manifest.counts.drift_candidate_count-eq4-and[int]$manifest.counts.effect_table_count-eq4) 'cache manifest counts mismatch'
    Require ([int]$manifest.counts.valid_effect_table_count-eq3) ('cache manifest valid effect table count mismatch: '+[string]$manifest.counts.valid_effect_table_count)
    $document=Get-Content -LiteralPath (Join-Path $written.dir 'native_actions.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Require ([int]$document.drift_candidate_count-eq4) 'cache document candidate count mismatch'
    $docCandidate=@($document.drift_candidates|Where-Object{[long]$_.count_offset-eq6000})[0]
    Require ($null-ne$docCandidate) 'cache document lost the chosen native Drift candidate'
    Require (@($docCandidate.records).Count-eq6-and@($docCandidate.intervals).Count-eq3) 'cache document must keep Drift records and intervals'
    $docTable=@($document.effect_tables|Where-Object{[long]$_.count_offset-eq6034})[0]
    Require ($null-ne$docTable-and@($docTable.records).Count-eq8) 'cache document must keep raw effect records'
    $docBits=@($docTable.records|ForEach-Object{[int]$_.effect_code_bits}|Sort-Object -Unique)
    Require ($docBits.Count-eq4) 'cache document must keep distinct effect code bit patterns'
    Require (@($docTable.intervals).Count-eq4-and@($docTable.effect_codes).Count-eq4) 'cache document must keep effect intervals and code summary'
    $docText=Get-Content -LiteralPath (Join-Path $written.dir 'native_actions.json') -Raw -Encoding UTF8
    foreach($banned in @('semantic_type','drift_id','nitro_active','small_boost_active','small_boost_class_active','system_drift_state','combo_action')){
        Require (-not$docText.Contains($banned)) ('native action cache document must stay raw evidence, found semantic field: '+$banned)
    }

    # ---------- C. cache replay must equal the raw scan and the raw semantic chain ----------
    $read=Read-NativeActionCache -CacheRoot $cacheRoot -ReplaySha256 $sha -SourceSizeBytes $size -RequireTail
    Require ([bool]$read.ok) ('native action cache read failed: '+[string]$read.status+' '+[string]$read.reason)
    Require ([string]$read.status-eq'native_action_cache_validated') ('unexpected cache read status: '+[string]$read.status)
    Require ([string]$read.cache.tail_path_status-eq'verified') ('persisted raw tail did not verify: '+[string]$read.cache.tail_path_status)
    $rawWindow=[ordered]@{file_length=[long]$rawScan.file_length;tail_bytes=[int]$rawScan.tail_bytes;scan_start_offset=[long]$rawScan.scan_start_offset;scan_end_offset=[long]$rawScan.scan_end_offset}
    $rawDoc=Canon-Json (RAC-BuildDocument -Candidates $rawScan.candidates -EffectTables $rawScan.effect_tables -Source $source -ScanWindow $rawWindow -ScannerContract (Get-NativeActionScannerContract))
    $cacheDoc=Canon-Json (RAC-BuildDocument -Candidates $read.cache.candidates -EffectTables $read.cache.effect_tables -Source $read.cache.source -ScanWindow $read.cache.scan_window -ScannerContract (Get-NativeActionScannerContract))
    Require ($rawDoc-eq$cacheDoc) 'cached native action evidence differs from the raw scan evidence'

    $rowsCache=New-SyntheticRows
    $cacheChain=Get-ActionChain -Scan $read.cache -Rows $rowsCache
    Compare-Chain $rawChain $cacheChain 'cache replay'

    $tailScan=New-NativeActionScanFromTail -TailPath $read.cache.tail_path -ScanStartOffset ([long]$read.cache.scan_window.scan_start_offset) -FileLength ([long]$read.cache.scan_window.file_length)
    $tailWindow=[ordered]@{file_length=[long]$tailScan.file_length;tail_bytes=[int]$tailScan.tail_bytes;scan_start_offset=[long]$tailScan.scan_start_offset;scan_end_offset=[long]$tailScan.scan_end_offset}
    $tailDoc=Canon-Json (RAC-BuildDocument -Candidates $tailScan.candidates -EffectTables $tailScan.effect_tables -Source $source -ScanWindow $tailWindow -ScannerContract (Get-NativeActionScannerContract))
    Require ($rawDoc-eq$tailDoc) 're-parsing the persisted raw tail did not reproduce the original scan'
    $tailScan|Add-Member -NotePropertyName table_index -NotePropertyValue (New-TableIndex -Tables $tailScan.effect_tables) -Force
    Compare-Chain $rawChain (Get-ActionChain -Scan $tailScan -Rows (New-SyntheticRows) -ReplayPath $sav) 'tail re-parse'

    # ---------- D. scanner contract change must re-parse the persisted tail, not the SAV ----------
    function New-CacheCopy([string]$Name){
        $caseRoot=Join-Path $temp $Name
        $caseDir=Join-Path $caseRoot $sha.Substring(0,16)
        New-Item -ItemType Directory -Force -Path $caseDir|Out-Null
        Copy-Item -Path (Join-Path $written.dir '*') -Destination $caseDir -Recurse -Force
        return $caseRoot
    }
    $tailRoot=New-CacheCopy 'tail_rescan'
    $tailManifestPath=Join-Path (Join-Path $tailRoot $sha.Substring(0,16)) 'manifest.json'
    $tailManifest=Get-Content -LiteralPath $tailManifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    $tailManifest.scanner_contract='replay_native_action_suffix_scan_v0'
    [IO.File]::WriteAllText($tailManifestPath,($tailManifest|ConvertTo-Json -Depth 12),(New-Object System.Text.UTF8Encoding($true)))
    $staleRead=Read-NativeActionCache -CacheRoot $tailRoot -ReplaySha256 $sha -SourceSizeBytes $size
    Require (-not[bool]$staleRead.ok-and[string]$staleRead.status-eq'native_action_scanner_contract_mismatch') ('stale scanner contract must not validate: '+[string]$staleRead.status)
    $tailInfo=Get-NativeActionTailForRescan -CacheRoot $tailRoot -ReplaySha256 $sha -SourceSizeBytes $size
    Require ([bool]$tailInfo.ok) ('persisted tail must stay usable for a scanner contract change: '+[string]$tailInfo.status)
    $rescanScan=Resolve-NativeActionCacheScan -ReplayPath $sav -CacheRoot $tailRoot -ReplaySha256 $sha -SourceSizeBytes $size -CacheScope 'telemetry_local' -ToolVersion 'smoke' -Source $source
    Require ([string]$rescanScan.mode-eq'rebuilt_from_tail') ('scanner contract change must re-parse the raw tail: '+[string]$rescanScan.mode)
    Require ([bool]$rescanScan.tail_rescan-and-not[bool]$rescanScan.source_read) 'tail re-parse must not read the source replay'
    Compare-Chain $rawChain (Get-ActionChain -Scan $rescanScan -Rows (New-SyntheticRows)) 'tail re-parse'
    $reread=Read-NativeActionCache -CacheRoot $tailRoot -ReplaySha256 $sha -SourceSizeBytes $size -RequireTail
    Require ([bool]$reread.ok) ('re-parsed cache must validate again: '+[string]$reread.status)

    # ---------- E. fail-closed matrix ----------
    function New-TamperedCache([string]$Name,[scriptblock]$Mutate){
        $caseRoot=New-CacheCopy $Name
        & $Mutate (Join-Path $caseRoot $sha.Substring(0,16))
        return $caseRoot
    }
    $shaCase=New-TamperedCache 'fc_sha' {param($d) $m=Get-Content -LiteralPath (Join-Path $d 'manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json;$m.source.sha256=('0'*64);[IO.File]::WriteAllText((Join-Path $d 'manifest.json'),($m|ConvertTo-Json -Depth 12),(New-Object System.Text.UTF8Encoding($true)))}
    $r=Read-NativeActionCache -CacheRoot $shaCase -ReplaySha256 $sha -SourceSizeBytes $size
    Require (-not[bool]$r.ok-and[string]$r.status-eq'native_action_cache_source_sha_mismatch') ('source SHA mismatch must fail closed: '+[string]$r.status)
    $shaInfo=Get-NativeActionTailForRescan -CacheRoot $shaCase -ReplaySha256 $sha -SourceSizeBytes $size
    Require (-not[bool]$shaInfo.ok-and[string]$shaInfo.status-eq'native_action_cache_source_sha_mismatch') ('tail reuse must fail closed on a source SHA mismatch: '+[string]$shaInfo.status)

    $sizeCase=New-TamperedCache 'fc_size' {param($d) $m=Get-Content -LiteralPath (Join-Path $d 'manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json;$m.source.size_bytes=([long]$m.source.size_bytes+1);[IO.File]::WriteAllText((Join-Path $d 'manifest.json'),($m|ConvertTo-Json -Depth 12),(New-Object System.Text.UTF8Encoding($true)))}
    $r=Read-NativeActionCache -CacheRoot $sizeCase -ReplaySha256 $sha -SourceSizeBytes $size
    Require (-not[bool]$r.ok-and[string]$r.status-eq'native_action_cache_source_size_mismatch') ('source size mismatch must fail closed: '+[string]$r.status)

    $intervalCase=New-TamperedCache 'fc_interval' {param($d) $doc=Get-Content -LiteralPath (Join-Path $d 'native_actions.json') -Raw -Encoding UTF8|ConvertFrom-Json;$c=@($doc.drift_candidates|Where-Object{[long]$_.count_offset-eq6000})[0];$c.intervals[0].end_ms=([long]$c.intervals[0].end_ms+1);[IO.File]::WriteAllText((Join-Path $d 'native_actions.json'),($doc|ConvertTo-Json -Depth 12),(New-Object System.Text.UTF8Encoding($true)))}
    $r=Read-NativeActionCache -CacheRoot $intervalCase -ReplaySha256 $sha -SourceSizeBytes $size
    Require (-not[bool]$r.ok-and[string]$r.status-eq'native_action_cache_document_invalid') ('tampered interval must fail closed: '+[string]$r.status)

    $missingTableCase=New-TamperedCache 'fc_missing_table' {param($d) $doc=Get-Content -LiteralPath (Join-Path $d 'native_actions.json') -Raw -Encoding UTF8|ConvertFrom-Json;$doc.effect_tables=@($doc.effect_tables|Select-Object -First 3);[IO.File]::WriteAllText((Join-Path $d 'native_actions.json'),($doc|ConvertTo-Json -Depth 12),(New-Object System.Text.UTF8Encoding($true)))}
    $r=Read-NativeActionCache -CacheRoot $missingTableCase -ReplaySha256 $sha -SourceSizeBytes $size
    Require (-not[bool]$r.ok-and[string]$r.status-eq'native_action_cache_document_invalid') ('missing effect payload must fail closed: '+[string]$r.status)

    $truncateCase=New-TamperedCache 'fc_truncate' {param($d) $t=Get-Content -LiteralPath (Join-Path $d 'native_actions.json') -Raw -Encoding UTF8;[IO.File]::WriteAllText((Join-Path $d 'native_actions.json'),$t.Substring(0,120),(New-Object System.Text.UTF8Encoding($true)))}
    $r=Read-NativeActionCache -CacheRoot $truncateCase -ReplaySha256 $sha -SourceSizeBytes $size
    Require (-not[bool]$r.ok-and[string]$r.status-eq'native_action_cache_unreadable') ('truncated document must fail closed: '+[string]$r.status)

    $noTailCase=New-TamperedCache 'fc_no_tail' {param($d) Remove-Item -LiteralPath (Join-Path $d 'native_action_tail.bin') -Force}
    $r=Read-NativeActionCache -CacheRoot $noTailCase -ReplaySha256 $sha -SourceSizeBytes $size
    Require ([bool]$r.ok) 'a missing raw tail must not invalidate usable native action tables'
    Require ([string]$r.cache.tail_path_status-ne'verified') 'missing raw tail must be reported as degraded evidence'
    $r2=Read-NativeActionCache -CacheRoot $noTailCase -ReplaySha256 $sha -SourceSizeBytes $size -RequireTail
    Require (-not[bool]$r2.ok-and[string]$r2.status-eq'native_action_cache_tail_invalid') ('strict tail requirement must fail closed: '+[string]$r2.status)
    $noTailInfo=Get-NativeActionTailForRescan -CacheRoot $noTailCase -ReplaySha256 $sha -SourceSizeBytes $size
    Require (-not[bool]$noTailInfo.ok-and[string]$noTailInfo.status-eq'native_action_cache_tail_missing') ('tail re-parse must fail closed without the raw tail: '+[string]$noTailInfo.status)

    # ---------- F. reuse must not rewrite the cache ----------
    $before=@{}
    foreach($f in @('manifest.json','native_actions.json','native_action_tail.bin')){$before[$f]=Fingerprint (Join-Path $written.dir $f)}
    $reuseScan=Resolve-NativeActionCacheScan -ReplayPath $sav -CacheRoot $cacheRoot -ReplaySha256 $sha -SourceSizeBytes $size -CacheScope 'telemetry_local' -ToolVersion 'smoke' -Source $source
    Require ([string]$reuseScan.mode-eq'reuse') ('cache hit was not reported: '+[string]$reuseScan.mode)
    Require ([long]$reuseScan.scan_ms-eq0-and[long]$reuseScan.write_ms-eq0) 'cache reuse must not scan or rewrite'
    Require (-not[bool]$reuseScan.source_read) 'cache reuse must not read the replay source'
    foreach($f in @('manifest.json','native_actions.json','native_action_tail.bin')){
        Require ((Fingerprint (Join-Path $written.dir $f))-eq$before[$f]) ('cache reuse rewrote '+$f)
    }
    Compare-Chain $rawChain (Get-ActionChain -Scan $reuseScan -Rows (New-SyntheticRows)) 'reuse path'
    $audit=Test-NativeActionCacheAgainstSource -CacheRoot $cacheRoot -ReplaySha256 $sha -ReplayPath $sav
    Require ([bool]$audit.ok) ('cache audit against the source replay failed: '+(@($audit.problems)-join '; '))

    # ---------- G. the semantic layer must not need the replay file at all ----------
    $savCopy=Join-Path $temp 'deleted_source.sav'
    Copy-Item -LiteralPath $sav -Destination $savCopy
    Remove-Item -LiteralPath $sav -Force
    Require (-not(Test-Path -LiteralPath $sav)) 'synthetic replay removal failed'
    $readAfterDelete=Read-NativeActionCache -CacheRoot $cacheRoot -ReplaySha256 $sha -SourceSizeBytes $size -RequireTail
    Require ([bool]$readAfterDelete.ok) 'native action cache must stay readable without the replay file'
    Compare-Chain $rawChain (Get-ActionChain -Scan $readAfterDelete.cache -Rows (New-SyntheticRows)) 'cache-only replay without the source file'
    Copy-Item -LiteralPath $savCopy -Destination $sav -Force

    # ---------- H. real benchmark: rebuild with -ForceNativeActions, then reuse with -ForceTelemetry ----------
    $dataDir=Split-Path -Parent $AppDir
    $archive=Join-Path $dataDir 'ReplayArchive'
    $telemetry=Join-Path $AppDir 'QQReplayTelemetry.ps1'
    $bench=Find-Replay $archive '月牙湾-系统判定36次漂移.sav'
    if($null-ne$bench){
        $realSha=(Get-FileHash -LiteralPath $bench.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        $realShort=$realSha.Substring(0,16)
        $physicalRoot=Join-Path $dataDir ('PhysicalTelemetryCache\'+$realShort)
        $actionRoot=Join-Path $dataDir 'NativeActionCache'
        $actionDir=Join-Path $actionRoot $realShort
        $out1=Join-Path $temp 'real_rebuilt';$out2=Join-Path $temp 'real_reused'
        $child1=@(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $telemetry -ReplayPath $bench.FullName -OutDir $out1 -ReplaySha256 $realSha -PhysicalCacheDir $physicalRoot -NativeActionCacheRoot $actionRoot -Force -ForceNativeActions 2>&1)
        $exit1=$LASTEXITCODE
        foreach($line in $child1){Write-Host ([string]$line)}
        Require ($exit1-eq0) ('real benchmark rebuild exited '+[string]$exit1)
        $sum1=Get-Content -LiteralPath (Join-Path $out1 'telemetry_summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
        Require ([int]$sum1.schema_version-eq19) 'real benchmark telemetry schema changed'
        Require ([string]$sum1.native_action_cache_mode-eq'rebuilt') ('real benchmark action cache mode must be rebuilt: '+[string]$sum1.native_action_cache_mode)
        Require ([bool]$sum1.native_action_scan_read_source_sav) 'real benchmark rebuild must read the source replay'
        Require ([long]$sum1.native_action_scan_ms-gt0) 'real benchmark rebuild must report a native action scan time'
        Require ([string]$sum1.native_action_cache_contract-eq'native_action_cache_v1') 'real benchmark cache contract mismatch'
        Require ([string]$sum1.native_action_cache_scanner_contract-eq(Get-NativeActionScannerContract)) 'real benchmark scanner contract mismatch'
        Require ([string]$sum1.native_action_tail_status-eq'verified') ('real benchmark raw tail did not verify: '+[string]$sum1.native_action_tail_status)
        Require ([int]$sum1.native_action_candidate_count-eq4) ('real benchmark candidate count changed: '+[string]$sum1.native_action_candidate_count)
        $driftStreams=@($sum1.streams|Where-Object{[bool]$_.system_drift_state_available}|Sort-Object {[int]$_.system_drift_segment_count} -Descending)
        Require ($driftStreams.Count-ge1) 'real benchmark did not expose a validated replay-native drift timeline'
        $st1=$driftStreams[0]
        Require ([int]$st1.system_drift_segment_count-eq36) ('real benchmark native Drift count changed: '+[string]$st1.system_drift_segment_count)
        Require ([double]$st1.native_drift_timeline_validation.start_match_fraction-ge0.97) 'real benchmark Drift start-match fraction regressed'
        Require ([int]$st1.native_speed_effect_segment_count-eq54) ('real benchmark native effect count changed: '+[string]$st1.native_speed_effect_segment_count)
        Require ([int]$st1.map_propulsion_effect_segment_count-eq53) ('real benchmark code2003 count changed: '+[string]$st1.map_propulsion_effect_segment_count)
        Require ([int]$st1.other_small_boost_segment_count-eq1) ('real benchmark code2001 unclassified count changed: '+[string]$st1.other_small_boost_segment_count)
        Require ([int]$st1.unknown_speed_effect_segment_count-eq0) 'real benchmark must not promote unknown native codes'
        Require ([int]$st1.nitro_segment_count-eq0-and[int]$st1.small_boost_segment_count-eq0) 'real benchmark nitro/drift-small-boost counts changed'
        $realFingerprints=@{}
        foreach($f in @('manifest.json','native_actions.json','native_action_tail.bin')){$realFingerprints[$f]=Fingerprint (Join-Path $actionDir $f)}
        Require (-not($realFingerprints['manifest.json']-eq'missing')) 'real benchmark native action cache was not persisted'

        $child2=@(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $telemetry -ReplayPath $bench.FullName -OutDir $out2 -ReplaySha256 $realSha -PhysicalCacheDir $physicalRoot -NativeActionCacheRoot $actionRoot -Force 2>&1)
        $exit2=$LASTEXITCODE
        foreach($line in $child2){Write-Host ([string]$line)}
        Require ($exit2-eq0) ('real benchmark reuse exited '+[string]$exit2)
        $sum2=Get-Content -LiteralPath (Join-Path $out2 'telemetry_summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
        Require ([string]$sum2.native_action_cache_mode-eq'reuse') ('real -ForceTelemetry run must reuse the native action cache: '+[string]$sum2.native_action_cache_mode)
        Require ([long]$sum2.native_action_scan_ms-eq0) 'real reuse run must report 0 native action tail scan time'
        Require (-not[bool]$sum2.native_action_scan_read_source_sav) 'real reuse run must not read the source replay for native actions'
        foreach($f in @('manifest.json','native_actions.json','native_action_tail.bin')){
            Require ((Fingerprint (Join-Path $actionDir $f))-eq$realFingerprints[$f]) ('real cache reuse rewrote '+$f)
        }
        $sem1=Get-StreamSemantics $sum1;$sem2=Get-StreamSemantics $sum2
        Require ($sem1-eq$sem2) 'real benchmark rebuilt-vs-reused derived native action semantics differ'
        $ev1=Get-Content -LiteralPath (Join-Path $out1 'native_action_evidence_summary.json') -Raw -Encoding UTF8
        $ev2=Get-Content -LiteralPath (Join-Path $out2 'native_action_evidence_summary.json') -Raw -Encoding UTF8
        Require ($ev1-eq$ev2) 'real benchmark native action evidence index differs between rebuild and reuse'
        $realAudit=Test-NativeActionCacheAgainstSource -CacheRoot $actionRoot -ReplaySha256 $realSha -ReplayPath $bench.FullName
        Require ([bool]$realAudit.ok) ('real cache audit against the source replay failed: '+(@($realAudit.problems)-join '; '))
        # Real cut-window verification (synthetic fixtures use a whole-file window): the persisted raw
        # tail must re-parse into exactly the same native action evidence as a source scan, with no
        # replay read at all. This is the path a scanner contract change takes on a real replay.
        $realSize=[long](Get-Item -LiteralPath $bench.FullName).Length
        $realTailInfo=Get-NativeActionTailForRescan -CacheRoot $actionRoot -ReplaySha256 $realSha -SourceSizeBytes $realSize
        Require ([bool]$realTailInfo.ok) ('real cached raw tail must stay usable for rescan: '+[string]$realTailInfo.status)
        Require ([long]$realTailInfo.scan_start_offset-gt0) 'real benchmark tail window must be a cut window, not the whole file'
        $realTailScan=New-NativeActionScanFromTail -TailPath $realTailInfo.tail_path -ScanStartOffset ([long]$realTailInfo.scan_start_offset) -FileLength ([long]$realTailInfo.file_length)
        $realRead=Read-NativeActionCache -CacheRoot $actionRoot -ReplaySha256 $realSha -SourceSizeBytes $realSize -RequireTail
        Require ([bool]$realRead.ok) 'real cached native action evidence must validate for the tail comparison'
        $realDocCached=Canon-Json (RAC-BuildDocument -Candidates $realRead.cache.candidates -EffectTables $realRead.cache.effect_tables -Source $realRead.cache.source -ScanWindow $realRead.cache.scan_window -ScannerContract (Get-NativeActionScannerContract))
        $realWindow=[ordered]@{file_length=[long]$realTailScan.file_length;tail_bytes=[int]$realTailScan.tail_bytes;scan_start_offset=[long]$realTailScan.scan_start_offset;scan_end_offset=[long]$realTailScan.scan_end_offset}
        $realDocTail=Canon-Json (RAC-BuildDocument -Candidates $realTailScan.candidates -EffectTables $realTailScan.effect_tables -Source $realRead.cache.source -ScanWindow $realWindow -ScannerContract (Get-NativeActionScannerContract))
        Require ($realDocCached-eq$realDocTail) 'real cached raw tail did not re-parse into identical native action evidence'
        $realStatus='36/54/53 reused + cut-window tail-reparse exact'
    }

    $manifest=Get-Content -LiteralPath (Join-Path $AppDir 'app_manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Require ([int]$manifest.data_schemas.native_action_cache-eq1) 'installed manifest must expose native_action_cache schema 1'
    Write-Host ('[OK] NativeActionCache v1 smoke passed. app='+[string]$manifest.app_version+' synthetic=4candidates/3tables-invalid-preserved raw=cache=tail-reparse fail-closed=7/7 reuse=no-rewrite semanticafterdelete=exact real-benchmark='+$realStatus)
    exit 0
}catch{
    Write-Host ('[FAILED] '+$_.Exception.Message)
    Write-Host ('位置: '+$_.InvocationInfo.PositionMessage)
    exit 2
}finally{
    try{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}catch{}
}
