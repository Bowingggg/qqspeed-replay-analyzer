param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){ if(-not $Ok){ throw $Message } }

# ---------------------------------------------------------------------------
# Multi-shadow physical stream regression -- real replay evidence.
#
# Belongs to the Real Regression gate. It runs the production telemetry pipeline over real
# multi-car replays and asserts the physical/logical stream contract:
#   * a real networked opponent is recovered as its own physical stream even when its clock
#     repeats milliseconds (the retired 5 ms step predicate shredded it below MIN_STREAM_RECORDS)
#   * one local + N network shadows, deterministic ordering, local is the high-frequency role
#   * a single-player replay never grows a network shadow
#   * an inactive/stationary slot never becomes a logical shadow
#   * the physical cache descriptor binds the detector contract, so a stale descriptor written
#     by an older detector is rejected and rebuilt without the user clearing derived data
#   * local native Drift/action authority is never copied onto a network shadow
#
# Replays are located by SHA256 and skipped explicitly when absent, so a machine without the
# archive degrades to "not-present" instead of failing.
# ---------------------------------------------------------------------------

$dataDir=Split-Path -Parent $AppDir
$root=Split-Path -Parent $dataDir
$archive=Join-Path $dataDir 'ReplayArchive'
$replayCorpus=Join-Path $root 'replay'
$telemetry=Join-Path $AppDir 'QQReplayTelemetry.ps1'
$stride=230   # QQReplaySchema2026.Stride: the physical record lane stride used by the census below

# Pinned real corpus identities. Names are deliberately not used: the SAV file name carries the
# player nickname, and stream semantics must never depend on a file name.
$shaVansNew  = '950FA2750397B196181AEA2C914136A12DFF4AED99176C7225EA32BE3DB30655'
$shaSnowLf   = '02758BC49389D09A28FFA44DB804B77B6025CD5B7148AA5E2FB4CE644CAC5995'
$shaVansOld  = '0A6C2D1AE550176FF5F0AA0854E97563A1456305EB2F986B9F8029DEB5EF15F4'
$shaMultiNet = '43067EE8573EA091EA728208BD41292CBD19A50E23C835C8CAD035A9391D4962'
$singlePlayerControls=@(
    @{tag='citytorch'; sha='3164A4F8AFA71A832B30E55A7228C6FA08A9DFCE683689BA33CE8A18CF6A3623'},
    @{tag='dreamflower'; sha='500BF26A9575A71CA7B3202DB2435D17AAD4C9B586D823934238DD60E375A694'},
    @{tag='elevencity'; sha='553FD0EF28D7BF04CEDEF5E853908995189074D0604157F3999AA9D2FB67FB9C'}
)

$scratch=Join-Path (Join-Path $dataDir 'Diagnostics\Dev') ('multishadow_smoke_'+[Guid]::NewGuid().ToString('N'))
$nac=Join-Path $scratch 'native_actions'
New-Item -ItemType Directory -Force -Path $scratch,$nac | Out-Null

function Find-ReplayBySha([string]$Sha256){
    foreach($base in @($replayCorpus,$archive)){
        if(-not(Test-Path -LiteralPath $base -PathType Container)){continue}
        foreach($f in @(Get-ChildItem -LiteralPath $base -Recurse -File -Filter '*.sav' -ErrorAction SilentlyContinue)){
            $sha=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
            if($sha-eq$Sha256){return $f}
        }
    }
    return $null
}

function Invoke-Analysis {
    param([string]$Path,[string]$Tag,[string]$PhysicalCacheDir,[switch]$ForceRaw)
    $sha=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    $out=Join-Path $scratch ('out_'+$Tag)
    $cliArgs=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$telemetry,
        '-ReplayPath',$Path,'-OutDir',$out,'-ReplaySha256',$sha,'-PhysicalCacheDir',$PhysicalCacheDir,'-NativeActionCacheRoot',$nac)
    if($ForceRaw){$cliArgs+='-ForceRaw'}
    $text=@(& powershell.exe @cliArgs 2>&1)
    $code=$LASTEXITCODE
    Require ($code-eq0) ($Tag+': telemetry pipeline exited '+$code+' :: '+((@($text)|Select-Object -Last 4) -join ' / '))
    $summary=Join-Path $out 'telemetry_summary.json'
    Require (Test-Path -LiteralPath $summary -PathType Leaf) ($Tag+': telemetry summary missing')
    return [pscustomobject]@{
        sha=$sha; out=$out; text=($text -join "`n")
        summary=Get-Content -LiteralPath $summary -Raw -Encoding UTF8|ConvertFrom-Json
        physical=Get-Content -LiteralPath (Join-Path $PhysicalCacheDir 'manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    }
}

function Get-Shadows($Result){
    return @($Result.summary.streams)
}
function Get-PhysicalStream($Result,[string]$StreamId){
    return @(@($Result.physical.replays)[0].streams | Where-Object{[string]$_.stream_id -eq $StreamId})[0]
}

# Dense byte-level walk of one physical record lane, so the repeated/forward/backward step counts
# asserted here come from the replay bytes and not from a resampled preview.
function Read-StreamClock([string]$Path,[int]$ByteStart,[int]$Records){
    $fs=[IO.File]::OpenRead($Path); $buf=New-Object byte[] 4; $prev=-1L
    $pos=0;$zero=0;$neg=0;$first=-1L;$last=-1L
    try{
        for($i=0;$i-lt$Records;$i++){
            $fs.Position=[long]$ByteStart+[long]$i*$stride
            if($fs.Read($buf,0,4)-ne4){throw ('short read at record '+$i)}
            $v=[long][BitConverter]::ToUInt32($buf,0)
            if($i-eq0){$first=$v}
            if($prev-ge0){ $d=$v-$prev; if($d-gt0){$pos++} elseif($d-eq0){$zero++} else {$neg++} }
            $prev=$v;$last=$v
        }
    } finally { $fs.Dispose() }
    return [pscustomobject]@{pos=$pos;zero=$zero;neg=$neg;steps=($Records-1);t0=$first;t1=$last}
}

function Assert-MultiShadowShape {
    param($Result,[string]$Tag,[int]$ExpectedPhysical,[int]$ExpectedLogical)
    # Always wrap: a single JSON stream deserialises to a scalar whose .Count is $null.
    $s=@(Get-Shadows $Result)
    Require ([int]$Result.summary.physical_stream_count -eq $ExpectedPhysical) ($Tag+': physical stream count '+[string]$Result.summary.physical_stream_count+' != '+$ExpectedPhysical)
    Require ([int]$Result.summary.logical_stream_count -eq $ExpectedLogical) ($Tag+': logical shadow count '+[string]$Result.summary.logical_stream_count+' != '+$ExpectedLogical)
    Require ($s.Count -eq $ExpectedLogical) ($Tag+': logical shadow array does not match logical_stream_count')
    Require ([string]$s[0].id -eq 'shadow_local') ($Tag+': the first logical shadow must be shadow_local')
    Require ([string]$s[0].role -eq 'local_high_frequency') ($Tag+': the first logical shadow must carry the local_high_frequency role')
    Require ([string]$Result.summary.physical_detector_contract -eq 'physical_streams_v2_nondec_ts') ($Tag+': the summary must publish the physical detector contract')
    for($i=1;$i-lt$s.Count;$i++){
        Require ([string]$s[$i].id -eq ('shadow_network_'+('{0:D2}' -f $i))) ($Tag+': network shadow id is not deterministic at index '+$i)
        Require ([string]$s[$i].role -eq 'network_low_frequency') ($Tag+': non-local shadow must carry the network_low_frequency role')
        Require ([double]$s[0].sample_hz -gt [double]$s[$i].sample_hz) ($Tag+': the local shadow must stay the high-frequency one')
        Require ([int]$s[$i].records -ge 80) ($Tag+': network shadow has too few records to be a stream')
        Require ([double]$s[$i].distance -gt 50.0) ($Tag+': network shadow shows no real movement (inactive/stationary slot promoted)')
    }
}

$ran=New-Object System.Collections.Generic.List[string]

try {
    # -----------------------------------------------------------------------------------------
    # 1. Regular low-frequency network (near-strictly-increasing quantised clock).
    # -----------------------------------------------------------------------------------------
    $f=Find-ReplayBySha $shaSnowLf
    if($null-eq$f){ Write-Host '  [snow-lf] not-present (skipped)' } else {
        $r=Invoke-Analysis -Path $f.FullName -Tag 'snow_lf' -PhysicalCacheDir (Join-Path $scratch 'pc_snow')
        Assert-MultiShadowShape -Result $r -Tag 'snow-lf' -ExpectedPhysical 2 -ExpectedLogical 2
        $net=@(Get-Shadows $r)[1]
        Require ([int]$net.part_count -eq 1) 'snow-lf: the low-frequency opponent must be one physical stream, not fragments'
        $ps=Get-PhysicalStream $r ([string]$net.source_streams[0])
        Require ($null-ne$ps) 'snow-lf: the network shadow references a missing physical stream'
        $clock=Read-StreamClock -Path $f.FullName -ByteStart ([int]$ps.byte_start) -Records ([int]$ps.records)
        Require ([int]$ps.records -ge 2000) ('snow-lf: network physical stream is shredded: records='+[int]$ps.records)
        Require ($clock.neg -eq 0) 'snow-lf: accepted network stream contains a backward clock step'
        Require ($clock.steps -eq ([int]$ps.records-1)) 'snow-lf: clock census did not cover every physical record'
        Require (($clock.pos/[double]$clock.steps) -ge 0.30) 'snow-lf: accepted network stream is not driven by forward steps'
        Require (($clock.zero/[double]$clock.steps) -le 0.05) 'snow-lf: this replay is expected to have an almost strictly increasing network clock'
        Require (([double]$net.sample_hz -ge 20.0) -and ([double]$net.sample_hz -le 35.0)) ('snow-lf: network cadence outside the observed low-frequency band: '+[string]$net.sample_hz)
        $ran.Add('snow-lf'); Write-Host ('  [snow-lf] physical=2 logical=2 network_records='+[int]$ps.records+' hz='+[string]$net.sample_hz+' zero_steps='+$clock.zero+'/'+$clock.steps)
    }

    # -----------------------------------------------------------------------------------------
    # 2. Repeated-timestamp low-frequency network (the exact historical miss).
    # -----------------------------------------------------------------------------------------
    $f=Find-ReplayBySha $shaVansNew
    if($null-eq$f){ Write-Host '  [vans-repeated] not-present (skipped)' } else {
        $r=Invoke-Analysis -Path $f.FullName -Tag 'vans_new' -PhysicalCacheDir (Join-Path $scratch 'pc_vans_new')
        Assert-MultiShadowShape -Result $r -Tag 'vans-repeated' -ExpectedPhysical 2 -ExpectedLogical 2
        $s=Get-Shadows $r
        $net=@($s)[1]
        Require ([int]$net.part_count -eq 1) 'vans-repeated: zero-millisecond transitions must not split the network stream'
        $ps=Get-PhysicalStream $r ([string]$net.source_streams[0])
        Require ($null-ne$ps) 'vans-repeated: the network shadow references a missing physical stream'
        $clock=Read-StreamClock -Path $f.FullName -ByteStart ([int]$ps.byte_start) -Records ([int]$ps.records)
        Require ([int]$ps.records -ge 2000) ('vans-repeated: network physical stream is shredded: records='+[int]$ps.records)
        Require ($clock.neg -eq 0) 'vans-repeated: accepted network stream contains a backward clock step'
        Require ($clock.zero -ge 1) 'vans-repeated: this replay must expose at least one legitimate repeated timestamp'
        Require (($clock.zero/[double]$clock.steps) -le 0.90) 'vans-repeated: repeated timestamps dominate the stream (frozen-clock candidate)'
        Require (($clock.pos/[double]$clock.steps) -ge 0.30) 'vans-repeated: accepted network stream is not driven by forward steps'
        # Owner boundary: the local action authority must not be copied onto the network shadow.
        $local=@($s)[0]
        Require ([int]$local.native_drift_timeline_validation.count_offset -ne [int]$net.native_drift_timeline_validation.count_offset) 'vans-repeated: local and network shadows claim the same native action object'
        Require ([bool]$local.production_actions.air_boost.game_facing) 'vans-repeated: the local shadow lost its game-facing native action authority'
        Require ([int]$local.production_actions.air_boost.count -gt 0) 'vans-repeated: the local shadow lost its native action counts'
        Require (-not [bool]$net.production_actions.air_boost.game_facing) 'vans-repeated: the network shadow was given game-facing local action authority'
        Require ([string]::IsNullOrWhiteSpace([string]$net.production_actions.air_boost.count)) 'vans-repeated: the network shadow inherited local native action counts'
        # The replay-global native action event table has no per-vehicle owner, so it must only be
        # published on the local authoritative shadow.
        Require ([bool]$local.native_action_event_available) 'vans-repeated: the local shadow stopped publishing the replay-native action event table'
        Require (@($local.native_action_event_timeline).Count -gt 0) 'vans-repeated: the local shadow lost its native action event timeline'
        Require (-not [bool]$net.native_action_event_available) 'vans-repeated: the network shadow published the replay-global action event table'
        Require ([string]$net.native_action_event_ownership -eq 'unavailable_non_local_shadow') 'vans-repeated: the network shadow does not declare its native action authority unavailable'
        Require (@($net.native_action_event_timeline).Count -eq 0) 'vans-repeated: the local native action timeline leaked onto the network shadow'
        $ran.Add('vans-repeated'); Write-Host ('  [vans-repeated] physical=2 logical=2 network_records='+[int]$ps.records+' zero_steps='+$clock.zero+'/'+$clock.steps+' owner_boundary=local-only')
    }

    # -----------------------------------------------------------------------------------------
    # 3. Historical miss regression: this replay reported ONE stream before the detector contract
    #    accepted a non-decreasing clock.
    # -----------------------------------------------------------------------------------------
    $f=Find-ReplayBySha $shaVansOld
    if($null-eq$f){ Write-Host '  [vans-historical-miss] not-present (skipped)' } else {
        $pcd=Join-Path $scratch 'pc_vans_old'
        $r=Invoke-Analysis -Path $f.FullName -Tag 'vans_old' -PhysicalCacheDir $pcd
        Assert-MultiShadowShape -Result $r -Tag 'vans-historical-miss' -ExpectedPhysical 2 -ExpectedLogical 2
        $ran.Add('vans-historical-miss')
        Write-Host ('  [vans-historical-miss] physical=2 logical=2 (was 1/1 before the non-decreasing detector contract)')

        # -------------------------------------------------------------------------------------
        # 3b. Cache contract: a descriptor written by the previous detector (no detector_contract,
        #     stale one-stream manifest) must be rejected and rebuilt, not reused.
        # -------------------------------------------------------------------------------------
        $descPath=Join-Path $pcd 'source_cache.json'
        Require (Test-Path -LiteralPath $descPath -PathType Leaf) 'cache-contract: physical cache descriptor missing'
        $desc=Get-Content -LiteralPath $descPath -Raw -Encoding UTF8|ConvertFrom-Json
        Require ([string]$desc.detector_contract -eq 'physical_streams_v2_nondec_ts') 'cache-contract: the written descriptor does not bind the detector contract'
        $keep=@{}
        foreach($p in @($desc.PSObject.Properties)){ if($p.Name -ne 'detector_contract'){ $keep[$p.Name]=$p.Value } }
        # The previous detector's descriptor identity, and no detector binding at all.
        $keep['contract']='qpf_v1_2026schema1_fastpipe1'
        $stale=New-Object psobject -Property $keep
        [IO.File]::WriteAllText($descPath,($stale|ConvertTo-Json -Depth 10),(New-Object System.Text.UTF8Encoding($false)))
        # Simulate the old cached answer: only the local stream exists in the manifest and on disk.
        $mfPath=Join-Path $pcd 'manifest.json'
        $mf=Get-Content -LiteralPath $mfPath -Raw -Encoding UTF8|ConvertFrom-Json
        $rep=@($mf.replays)[0]
        $localOnly=@(@($rep.streams)[0])
        foreach($ms in @($rep.streams)){ if([string]$ms.stream_id -ne [string]$localOnly[0].stream_id){ Remove-Item -LiteralPath (Join-Path $pcd ([string]$ms.fastbin).Replace('/','\')) -Force -ErrorAction SilentlyContinue } }
        $rep.streams=$localOnly; $rep.stream_count=1
        $mf.replays=@($rep)
        [IO.File]::WriteAllText($mfPath,($mf|ConvertTo-Json -Depth 20),(New-Object System.Text.UTF8Encoding($false)))

        $r2=Invoke-Analysis -Path $f.FullName -Tag 'vans_old_stale' -PhysicalCacheDir $pcd
        Require ($r2.text.Contains('rebuilt')) 'cache-contract: a stale detector descriptor was not rebuilt'
        Assert-MultiShadowShape -Result $r2 -Tag 'cache-contract' -ExpectedPhysical 2 -ExpectedLogical 2
        Write-Host '  [cache-contract] stale descriptor (no detector binding, 1-stream manifest) -> rebuilt to 2 streams without manual cache clearing'

        # Warm reuse must reproduce the same identity.
        $r3=Invoke-Analysis -Path $f.FullName -Tag 'vans_old_warm' -PhysicalCacheDir $pcd
        Require ($r3.text.Contains('hit')) 'cache-contract: warm run did not reuse the rebuilt physical cache'
        Assert-MultiShadowShape -Result $r3 -Tag 'cache-contract-warm' -ExpectedPhysical 2 -ExpectedLogical 2
        $idA=@(Get-Shadows $r2)|ForEach-Object{ [string]$_.role+':'+[int]$_.records+':'+((@($_.source_streams)) -join '+') }
        $idB=@(Get-Shadows $r3)|ForEach-Object{ [string]$_.role+':'+[int]$_.records+':'+((@($_.source_streams)) -join '+') }
        Require (($idA -join '|') -eq ($idB -join '|')) 'cache-contract: warm reuse changed stream identity, role or ordering'
        $ran.Add('cache-contract')
        Write-Host '  [cache-contract] warm reuse reproduced identical stream count, role, ordering and identity'
    }

    # -----------------------------------------------------------------------------------------
    # 4. Multi-network: 1 local + N network shadows, and no inactive slot promoted.
    # -----------------------------------------------------------------------------------------
    $f=Find-ReplayBySha $shaMultiNet
    if($null-eq $f){ Write-Host '  [multi-network] not-present (skipped)' } else {
        $r=Invoke-Analysis -Path $f.FullName -Tag 'multi_net' -PhysicalCacheDir (Join-Path $scratch 'pc_multi')
        $phys=[int]$r.summary.physical_stream_count
        $log=[int]$r.summary.logical_stream_count
        Require ($phys -ge 6) ('multi-network: expected at least 6 physical streams, got '+$phys)
        Require ($log -ge 6) ('multi-network: expected at least 6 logical shadows, got '+$log)
        Assert-MultiShadowShape -Result $r -Tag 'multi-network' -ExpectedPhysical $phys -ExpectedLogical $log
        $netCount=0
        foreach($s in @(Get-Shadows $r)){ if([string]$s.role -eq 'network_low_frequency'){$netCount++} }
        Require ($netCount -ge 5) ('multi-network: expected at least 5 network shadows, got '+$netCount)
        $ran.Add('multi-network'); Write-Host ('  [multi-network] physical='+$phys+' logical='+$log+' network='+$netCount+' (no inactive slot promoted)')
    }

    # -----------------------------------------------------------------------------------------
    # 5. Single-player controls: a single-car replay must never grow a network shadow.
    # -----------------------------------------------------------------------------------------
    foreach($c in $singlePlayerControls){
        $f=Find-ReplayBySha ([string]$c.sha)
        if($null-eq$f){ Write-Host ('  ['+[string]$c.tag+'] not-present (skipped)'); continue }
        $r=Invoke-Analysis -Path $f.FullName -Tag ([string]$c.tag) -PhysicalCacheDir (Join-Path $scratch ('pc_'+[string]$c.tag))
        Assert-MultiShadowShape -Result $r -Tag ([string]$c.tag) -ExpectedPhysical 1 -ExpectedLogical 1
        $ran.Add([string]$c.tag); Write-Host ('  ['+[string]$c.tag+'] physical=1 logical=1 (no false network shadow)')
    }

    if($ran.Count -eq 0){
        Write-Host '[OK] Multi-Shadow physical stream regression: no real replay corpus on this machine (all cases not-present).'
        exit 0
    }
    Write-Host ('[OK] Multi-Shadow physical stream regression passed. real_cases='+$ran.Count+' cases='+($ran -join ',')+' detector=physical_streams_v2_nondec_ts contract=physical_streams_v2_nondec_ts')
    exit 0
}catch{
    Write-Host ('[FAILED] '+$_.Exception.Message)
    try { Write-Host ('位置: '+$_.InvocationInfo.PositionMessage) } catch {}
    exit 2
}finally{
    try { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
