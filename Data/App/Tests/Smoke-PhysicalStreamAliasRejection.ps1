param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_StreamAlias_'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
function Put-U32([byte[]]$D,[int]$O,[uint32]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}
function Put-I32([byte[]]$D,[int]$O,[int]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}
function Put-F32([byte[]]$D,[int]$O,[single]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$D,$O,4)}
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}

# ---------------------------------------------------------------------------------------------
# Synthetic physical-stream contract cases.
#
# A synthetic SAV is a sequence of fixed-stride 230-byte 2026 records. Several regions share one
# lane phase (byte offset % 230) and each region begins with a timestamp drop, so every region is
# exactly one detector run - the same layout the real QQSpeed SAV uses for several cars.
# ---------------------------------------------------------------------------------------------
$stride=230
function New-RecordSpec([int]$Records,[int]$T0,[int]$StepMs,[double]$X0,[double]$XStep,[int]$ZeroEveryN,[string]$Kind){
    if([string]::IsNullOrWhiteSpace($Kind)){$Kind='move'}
    return [pscustomobject]@{records=$Records;t0=$T0;step=$StepMs;x0=$X0;xstep=$XStep;zeroEveryN=$ZeroEveryN;kind=$Kind}
}
function Build-Sav([string]$Path,[object[]]$Regions,[int]$StartOff){
    $total=0; foreach($r in $Regions){$total+=$r.records}
    $bytes=New-Object byte[] ($StartOff+$stride*$total+512)
    $block=0
    foreach($r in $Regions){
        for($i=0;$i-lt$r.records;$i++){
            $o=$StartOff+($block+$i)*$stride
            $tm=[int]$r.t0; for($k=0;$k-lt$i;$k++){ $d=$r.step; if($r.zeroEveryN -gt 0 -and ($k % $r.zeroEveryN) -eq 0){$d=0}; $tm+=$d }
            Put-U32 $bytes $o ([uint32]$tm)
            Put-F32 $bytes ($o+8) 0;Put-F32 $bytes ($o+12) 0;Put-F32 $bytes ($o+16) 0;Put-F32 $bytes ($o+20) 1
            if($r.kind -eq 'still'){
                # A placeholder slot whose clock advances but whose position never moves.
                Put-F32 $bytes ($o+24) 10;Put-F32 $bytes ($o+28) 20;Put-F32 $bytes ($o+32) 1
            } elseif($r.kind -eq 'jitter'){
                # A near-stationary slot: sub-unit position noise makes accumulated motion look large
                # while the real spatial excursion stays ~2 units.
                Put-F32 $bytes ($o+24) ([single](10.0+[Math]::Sin($i/3.0)));Put-F32 $bytes ($o+28) ([single](20.0+[Math]::Cos($i/5.0)));Put-F32 $bytes ($o+32) 1
            } else {
                Put-F32 $bytes ($o+24) ([single]($r.x0+$i*$r.xstep));Put-F32 $bytes ($o+28) ([single]([Math]::Sin($i/20.0)*5.0));Put-F32 $bytes ($o+32) 1
            }
            Put-I32 $bytes ($o+52) 5
            Put-I32 $bytes ($o+76) $(if($i -lt [int]($r.records/2)){1}else{2})
            Put-F32 $bytes ($o+173) 11.765;Put-F32 $bytes ($o+177) 0;Put-F32 $bytes ($o+181) 0
        }
        $block+=$r.records
    }
    [IO.File]::WriteAllBytes($Path,$bytes)
}
function Get-Streams([string]$SavPath,[string]$OutDir){
    [QQReplayPortable]::ExtractFastFromDelimited($SavPath,$OutDir)
    $m=Get-Content -LiteralPath (Join-Path $OutDir 'manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    return @(@($m.replays)[0].streams)
}

try {
    . (Join-Path $AppDir 'Modules\Telemetry\Telemetry.CSharpCore.ps1')
    Initialize-TelemetryCSharpCore -AppDir $AppDir

    # -----------------------------------------------------------------------------------------
    # Existing case: the +137 embedded native precise-pose alias must not become a second stream.
    # -----------------------------------------------------------------------------------------
    $sav=Join-Path $temp 'embedded_pose_alias.sav';$out=Join-Path $temp 'out'
    $start=1000;$n=500;$bytes=New-Object byte[] ($start+$stride*$n+512)
    for($i=0;$i-lt$n;$i++){
        $o=$start+$i*$stride;$tm=10000+$i*17
        Put-U32 $bytes $o ([uint32]$tm)
        Put-F32 $bytes ($o+8) 0;Put-F32 $bytes ($o+12) 0;Put-F32 $bytes ($o+16) 0;Put-F32 $bytes ($o+20) 1
        Put-F32 $bytes ($o+24) ([single]($i*0.10));Put-F32 $bytes ($o+28) ([single]([Math]::Sin($i/20.0)*5.0));Put-F32 $bytes ($o+32) 1
        Put-I32 $bytes ($o+52) 5;Put-I32 $bytes ($o+76) 1
        Put-F32 $bytes ($o+173) 5;Put-F32 $bytes ($o+177) 0;Put-F32 $bytes ($o+181) 0
        if($i-ge150-and$i-lt280){
            $j=$i-150
            # +137 timer + (+145 quaternion) + (+161 position) intentionally form a valid short alias.
            Put-U32 $bytes ($o+137) ([uint32]($j*20))
            Put-F32 $bytes ($o+145) 0;Put-F32 $bytes ($o+149) 0;Put-F32 $bytes ($o+153) 0;Put-F32 $bytes ($o+157) 1
            Put-F32 $bytes ($o+161) ([single](100+$j*0.2));Put-F32 $bytes ($o+165) 50;Put-F32 $bytes ($o+169) 2
        }
    }
    [IO.File]::WriteAllBytes($sav,$bytes)
    [QQReplayPortable]::ExtractFromDelimited($sav,$out)
    $m=Get-Content -LiteralPath (Join-Path $out 'manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $r=@($m.replays)[0];$streams=@($r.streams)
    if($streams.Count-ne1){throw ('Expected one physical stream after +137 embedded-pose alias rejection, got '+$streams.Count)}
    if([int]$streams[0].records-lt490){throw ('Primary stream was not preserved: records='+$streams[0].records)}
    $core=Get-Content -LiteralPath (Join-Path $AppDir 'Modules\Telemetry\QQReplayTelemetry.Core.cs') -Raw -Encoding UTF8
    if(-not$core.Contains('phase==137')){throw 'Extractor source no longer contains the +137 native subrecord alias guard.'}

    # -----------------------------------------------------------------------------------------
    # Detector contract source markers. The v1 predicate (every step 5..100 ms) is what shredded
    # a repeated-timestamp opponent, so it must not come back.
    # -----------------------------------------------------------------------------------------
    foreach($marker in @('physical_streams_v2_nondec_ts','MIN_ELAPSED_MS','MIN_POSITIVE_RATIO','MAX_ZERO_RATIO','MIN_MOVEMENT_SPAN','STEP_MAX_MS','PhysicalStreamDetectorContract')){
        Require ($core.Contains($marker)) ('physical stream detector contract marker missing: '+$marker)
    }
    Require (-not($core.Contains('diff >= 5'))) 'the retired strict 5 ms step predicate is back in the physical stream detector'

    # -----------------------------------------------------------------------------------------
    # Case A - regular low-frequency network (strictly increasing 33 ms clock).
    # The networked opponent must survive as its own physical stream and must not be shredded.
    # -----------------------------------------------------------------------------------------
    $caseA=Join-Path $temp 'caseA_regular_lf.sav'
    Build-Sav $caseA @(
        (New-RecordSpec 400 20000 17 0.0 0.5 0),
        (New-RecordSpec 400 21000 33 0.0 0.4 0)
    ) 1000
    $sa=@(Get-Streams $caseA (Join-Path $temp 'outA'))
    Require ($sa.Count -eq 2) ('Case A regular low-frequency: expected 2 physical streams, got '+$sa.Count)
    $aNet=@($sa|Where-Object{[int]$_.records -eq 400 -and [int]$_.time_start_s -gt 20})
    Require ($aNet.Count -ge 1) 'Case A regular low-frequency: the networked 400-record stream was not preserved whole'

    # -----------------------------------------------------------------------------------------
    # Case B - repeated-timestamp low-frequency network (25% of steps are 0 ms).
    # This is the exact shape that produced ONE stream before: every 0 ms step cut the run, the
    # fragments fell under MIN_STREAM_RECORDS and the second car disappeared.
    # -----------------------------------------------------------------------------------------
    $caseB=Join-Path $temp 'caseB_repeated_ts_lf.sav'
    Build-Sav $caseB @(
        (New-RecordSpec 400 20000 17 0.0 0.5 0),
        (New-RecordSpec 900 21000 33 0.0 0.4 4)
    ) 1000
    $sb=@(Get-Streams $caseB (Join-Path $temp 'outB'))
    Require ($sb.Count -eq 2) ('Case B repeated-timestamp: expected 2 physical streams, got '+$sb.Count)
    $bNet=@($sb|Where-Object{[int]$_.records -eq 900})
    Require ($bNet.Count -eq 1) 'Case B repeated-timestamp: the 900-record network stream was shredded or lost'
    $bHz=[double]$bNet[0].approx_sample_hz
    Require ($bHz -gt 15 -and $bHz -lt 45) ('Case B repeated-timestamp: network cadence out of the low-frequency band: '+$bHz)

    # -----------------------------------------------------------------------------------------
    # Case C/E - zero-time false candidate. The clock never advances (time_start == time_end,
    # positive transition ratio == 0), so the lane must fail closed and add no vehicle.
    # -----------------------------------------------------------------------------------------
    $caseC=Join-Path $temp 'caseC_zero_time.sav'
    Build-Sav $caseC @(
        (New-RecordSpec 400 20000 17 0.0 0.5 0),
        (New-RecordSpec 900 30000 1 0.0 0.4 1)
    ) 1000
    $sc=@(Get-Streams $caseC (Join-Path $temp 'outC'))
    Require ($sc.Count -eq 1) ('Case C zero-time: a frozen-clock lane was promoted to a vehicle (streams='+$sc.Count+')')

    # -----------------------------------------------------------------------------------------
    # Case D - multi-network. One local + one strict low-frequency opponent + one opponent whose
    # clock repeats milliseconds, plus two inactive slots whose clock advances (so they pass the
    # clock contract) but whose position does not: a constant slot and a sub-unit jitter slot.
    # The two real opponents must survive; both inactive slots must fail closed.
    # -----------------------------------------------------------------------------------------
    $caseD=Join-Path $temp 'caseD_multi_network.sav'
    Build-Sav $caseD @(
        (New-RecordSpec 400 20000 17 0.0 0.5 0),
        (New-RecordSpec 400 31000 33 0.0 0.4 0),
        (New-RecordSpec 400 10000 50 0.0 0.3 6),
        (New-RecordSpec 900 40000 33 0.0 0.0 0 'still'),
        (New-RecordSpec 900 50000 33 0.0 0.0 0 'jitter')
    ) 1000
    $sd=@(Get-Streams $caseD (Join-Path $temp 'outD'))
    Require ($sd.Count -eq 3) ('Case D multi-network: expected 3 physical streams (1 local + 2 moving network, both inactive slots rejected), got '+$sd.Count)
    Require (@($sd|Where-Object{[int]$_.records -eq 400}).Count -eq 3) 'Case D multi-network: a real 400-record vehicle stream is missing'

    # -----------------------------------------------------------------------------------------
    # Contract identity must be published by the core so the raw cache descriptor can bind it.
    # -----------------------------------------------------------------------------------------
    $contract=[string][QQReplayPortable]::PhysicalStreamDetectorContract
    Require ($contract -eq 'physical_streams_v2_nondec_ts') ('unexpected detector contract identity: '+$contract)

    Write-Host ('[OK] Physical Stream Alias Rejection smoke passed. physical=1 embedded-precise-pose=+137 rejected primary-records='+$streams[0].records+' detector='+$contract+' caseA_regular_lf=2 caseB_repeated_ts=2(+900 whole) caseC_zero_time=1 caseD_multi=3(placeholder rejected)')
    exit 0
}catch{
    Write-Host ('[FAILED] '+$_.Exception.Message)
    Write-Host ('位置: '+$_.InvocationInfo.PositionMessage)
    exit 2
}finally{
    try{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}catch{}
}
