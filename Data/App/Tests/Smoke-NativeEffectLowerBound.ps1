# Lower-bound termination regression smoke.
#
# Context: RNSE-LowerBoundTime (ReplayNativeSpeedEffects.ps1) computes a binary-search midpoint.
# Windows PowerShell's [int] cast rounds half to even, so [int](($lo+$hi)/2) can evaluate to exactly
# $hi (e.g. lo=549,hi=550 -> 550). The no-progress branch $hi=$m then spins forever, which stalled
# every real replay right after native Drift resolution, inside the speed-effect row-marking step.
# This smoke locks the integer-safe midpoint, the odd/even window behaviour, and the exact row range
# RNSE-MarkRows must mark. The sweep runs in a child process with a timeout so a regression fails
# loudly instead of hanging the composite.
param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)),
    [switch]$SelfTestLowerBound
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
function Require([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}

function Ref-LowerBound([object[]]$Rows,[double]$TimeS){
    # Independent linear reference: first index whose time_s >= TimeS, else Count.
    for($i=0;$i-lt$Rows.Count;$i++){if([double]$Rows[$i].time_s-ge$TimeS){return $i}}
    return $Rows.Count
}
function New-TestRows([int]$Count,[double]$Step){
    $rows=New-Object System.Collections.Generic.List[object]
    for($i=0;$i-lt$Count;$i++){
        $rows.Add([pscustomobject]@{
            time_s=($i*$Step);slip=0.02;speed=20.0;distance=($i*$Step*20.0);contact_state=5
            input_bool_candidate_64=$false;input_bool_candidate_65=$false
            nitro_active=$false;small_boost_active=$false;air_boost_active=$false;landing_boost_active=$false
            map_propulsion_active=$false;small_boost_class_active=$false
            system_drift_state='unknown';system_drift_state_source='unresolved_not_found'
        })
    }
    return $rows.ToArray()
}

if($SelfTestLowerBound){
    try{
        . (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeSpeedEffects.ps1')
        $rows=New-TestRows 600 0.017
        $checked=0
        # Query times exactly on samples and exactly between samples: the search window therefore
        # narrows to both even/odd and odd/even [lo,hi] pairs.
        for($k=0;$k-lt600;$k++){
            foreach($t in @(($k*0.017),(($k+0.5)*0.017))){
                $got=RNSE-LowerBoundTime -Rows $rows -TimeS $t
                $want=Ref-LowerBound -Rows $rows -TimeS $t
                if($got-ne$want){throw ('RNSE-LowerBoundTime mismatch at t='+[string]$t+': got='+[string]$got+' want='+[string]$want)}
                $checked++
            }
        }
        foreach($t in @(-10.0,0.0,1e6)){
            $got=RNSE-LowerBoundTime -Rows $rows -TimeS $t
            $want=Ref-LowerBound -Rows $rows -TimeS $t
            if($got-ne$want){throw ('out-of-range lower bound mismatch at t='+[string]$t+': got='+[string]$got+' want='+[string]$want)}
            $checked++
        }
        # Row marking must cover exactly the reference half-open window [lower(start), lower(end)).
        $intervals=0
        for($k=0;$k-lt600;$k+=7){
            $s=($k+0.5)*0.017;$e=($k+3.0)*0.017
            foreach($r in $rows){$r.map_propulsion_active=$false}
            RNSE-MarkRows -Rows $rows -StartS $s -EndS $e -Property 'map_propulsion_active'
            $wantLo=Ref-LowerBound -Rows $rows -TimeS $s
            $wantHi=Ref-LowerBound -Rows $rows -TimeS $e
            if($wantHi-le$wantLo){throw ('synthetic mark interval collapsed at k='+[string]$k)}
            for($i=0;$i-lt$rows.Count;$i++){
                $want=($i-ge$wantLo-and$i-lt$wantHi)
                if([bool]$rows[$i].map_propulsion_active-ne$want){throw ('RNSE-MarkRows marked row '+[string]$i+' incorrectly for interval k='+[string]$k)}
            }
            $intervals++
        }
        Write-Host ('[selftest] lower-bound sweep ok checked='+[string]$checked+' markrows_intervals='+[string]$intervals)
        exit 0
    }catch{
        Write-Host ('[selftest-FAILED] '+$_.Exception.Message)
        exit 2
    }
}

try{
    $modulePath=Join-Path $AppDir 'Modules\Telemetry\ReplayNativeSpeedEffects.ps1'
    Require (Test-Path -LiteralPath $modulePath -PathType Leaf) ('speed-effect module missing: '+$modulePath)
    $text=Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
    Require ($text.Contains('$m=[int][Math]::Floor(($lo+$hi)/2.0)')) 'RNSE-LowerBoundTime must compute its midpoint with the integer-safe Floor form'
    Require (-not $text.Contains('$m=[int](($lo+$hi)/2)')) 'the banker-rounding midpoint that can stall the marking loop must not return'
    Require ($text.Contains('Termination contract')) 'lower-bound termination contract comment missing'

    # Bounded, loop-free proof that the retired midpoint genuinely loses progress on odd windows.
    $noProgress=@()
    foreach($pair in @(@(549,550),@(1001,1002),@(551,552),@(1,2))){
        $lo=[int]$pair[0];$hi=[int]$pair[1]
        $legacy=[int](($lo+$hi)/2)
        if(-not($legacy-gt$lo-and$legacy-lt$hi)){$noProgress+=(('('+[string]$lo+','+[string]$hi+')->'+[string]$legacy))}
        $safe=$lo+[int](($hi-$lo)/2)
        Require ($safe-ge$lo-and$safe-lt$hi) ('integer-safe midpoint must always progress: ('+[string]$lo+','+[string]$hi+')')
    }
    Require ($noProgress.Count-ge1) 'expected at least one odd window where the retired midpoint makes no progress'

    $self=$MyInvocation.MyCommand.Path
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_LowerBound_'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $temp|Out-Null
    $sweepStatus='not-run'
    try{
        $outFile=Join-Path $temp 'child.out';$errFile=Join-Path $temp 'child.err'
        $proc=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$self+'"'),'-SelfTestLowerBound') -RedirectStandardOutput $outFile -RedirectStandardError $errFile -NoNewWindow -PassThru
        $exited=$proc.WaitForExit(180000)
        if(-not$exited){
            try{$proc.Kill()}catch{}
            throw 'lower-bound sweep did not terminate: odd lo/hi midpoint regression is back'
        }
        $childOut=$(if(Test-Path -LiteralPath $outFile){Get-Content -LiteralPath $outFile -Raw -Encoding UTF8}else{''})
        $childErr=$(if(Test-Path -LiteralPath $errFile){Get-Content -LiteralPath $errFile -Raw -Encoding UTF8}else{''})
        Require ([bool]$proc.HasExited) 'lower-bound sweep child did not exit cleanly'
        # Start-Process -PassThru does not always populate ExitCode for redirected children, so the
        # child's own success marker is the authoritative signal; ExitCode is only advisory.
        $childExit=$proc.ExitCode
        if($null-ne$childExit-and[int]$childExit-ne0){throw ('lower-bound sweep child failed: exit='+[string]$childExit+' out='+$childOut+' err='+$childErr)}
        Require ([string]$childOut -match '\[selftest\] lower-bound sweep ok') ('lower-bound sweep child did not report success: out='+$childOut+' err='+$childErr)
        $sweepStatus=([regex]::Match([string]$childOut,'checked=\d+ markrows_intervals=\d+')).Value
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $manifest=Get-Content -LiteralPath (Join-Path $AppDir 'app_manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Write-Host ('[OK] Native Speed-Effect Lower-Bound smoke passed. app='+[string]$manifest.app_version+' midpoint=floor odd-window-no-progress='+($noProgress -join ',')+' child-sweep='+$sweepStatus+' markrows=reference-exact')
    exit 0
}catch{
    Write-Host ('[FAILED] '+$_.Exception.Message)
    exit 2
}
