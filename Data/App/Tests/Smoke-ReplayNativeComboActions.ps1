param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('QQReplay_NativeCombo_'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
function Seg([double]$S,[double]$E,[string]$Type,[int]$DriftId){return [pscustomobject][ordered]@{start_t=$S;end_t=$E;semantic_type=$Type;source='synthetic_native_effect';drift_id=$DriftId}}
function Find-Replay([string]$Archive,[string]$Name){
    if(-not(Test-Path -LiteralPath $Archive -PathType Container)){return $null}
    $m=@(Get-ChildItem -LiteralPath $Archive -Recurse -File -Filter $Name -ErrorAction SilentlyContinue|Where-Object{$_.Name-eq$Name}|Select-Object -First 1)
    if($m.Count-eq0){return $null};return $m[0]
}
function Run-RealCombo([string]$Name,[hashtable]$Expected,[string]$Archive,[string]$Telemetry,[string]$TempRoot){
    $f=Find-Replay $Archive $Name
    if($null-eq$f){return 'not-present'}
    $safe=($Name -replace '[^0-9A-Za-z\u4e00-\u9fff]+','_');$out=Join-Path $TempRoot $safe
    $dataDir=Split-Path -Parent $Archive;$sha=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToUpperInvariant();$short=$sha.Substring(0,16);$physical=Join-Path $dataDir ('PhysicalTelemetryCache\'+$short)
    $child=@(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Telemetry -ReplayPath $f.FullName -OutDir $out -ReplaySha256 $sha -PhysicalCacheDir $physical -Force 2>&1);$ec=$LASTEXITCODE
    foreach($line in $child){Write-Host ([string]$line)}
    if($ec-ne0){throw ($Name+' telemetry exited '+$ec)}
    $sum=Get-Content -LiteralPath (Join-Path $out 'telemetry_summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $st=@($sum.streams|Where-Object{[bool]$_.combo_action_state_available}|Sort-Object {[int]$_.combo_action_count} -Descending|Select-Object -First 1)
    if($st.Count-eq0){throw ($Name+' did not expose combo actions.')};$s=$st[0]
    foreach($k in @($Expected.Keys)){if([int]$s.$k-ne[int]$Expected[$k]){throw ($Name+' expected '+$k+'='+$Expected[$k]+', got '+$s.$k)}}
    return 'ok'
}
try{
    . (Join-Path $AppDir 'Modules\Telemetry\ReplayNativeComboActions.ps1')
    # Three separated labeled signatures in one synthetic native-effect stream.
    $fx=[pscustomobject][ordered]@{
        available=$true
        nitro_segments=@(
            (Seg 10.000 10.900 'nitro' 0),
            (Seg 20.000 20.900 'nitro' 0),
            (Seg 30.000 30.900 'nitro' 0)
        )
        small_boost_segments=@(
            (Seg 9.250 9.900 'drift_small_boost' 1),(Seg 10.060 10.700 'drift_small_boost' 1),
            (Seg 20.600 21.100 'drift_small_boost' 2),(Seg 21.200 21.800 'drift_small_boost' 2),
            (Seg 30.070 30.700 'drift_small_boost' 3)
        )
    }
    $r=Resolve-ReplayNativeComboActions -SpeedEffects $fx
    if(-not[bool]$r.available-or[int]$r.wcw_count-ne1-or[int]$r.cww_count-ne1-or[int]$r.cw_count-ne1-or[int]$r.combo_count-ne3){throw ('Synthetic combo classifier mismatch CW/WCW/CWW='+$r.cw_count+'/'+$r.wcw_count+'/'+$r.cww_count)}
    $types=@($r.native_combo_segments|ForEach-Object{[string]$_.label})
    foreach($want in @('CW','WCW','CWW')){if($types-notcontains$want){throw ('Synthetic combo missing '+$want)}}
    if(@($r.native_combo_segments|Where-Object{$null-ne$_.native_drift_id}).Count-ne3){throw 'Combo sequence lost native Drift ID binding.'}
    if(@($r.native_combo_segments|Where-Object{-not[bool]$_.authoritative_sequence}).Count-ne0){throw 'Combo sequence labels lost native-effect authority marker.'}

    $manifest=Get-Content -LiteralPath (Join-Path $AppDir 'app_manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$manifest.app_version-ne'3.7.23'-or[int]$manifest.data_schemas.combo_action-ne2){throw ('Manifest combo contract mismatch: app='+$manifest.app_version+' combo='+$manifest.data_schemas.combo_action)}

    # Dedicated labeled recordings become automatic real regressions after import to ReplayArchive.
    $dataDir=Split-Path -Parent $AppDir;$archive=Join-Path $dataDir 'ReplayArchive';$tele=Join-Path $AppDir 'QQReplayTelemetry.ps1'
    $cw=Run-RealCombo '老街管道-CW.sav' @{cw_count=11;wcw_count=0;cww_count=0;combo_action_count=11} $archive $tele $temp
    $wcw=Run-RealCombo '老街管道-WCW.sav' @{cw_count=0;wcw_count=11;cww_count=0;combo_action_count=11} $archive $tele $temp
    $cww=Run-RealCombo '城市火炬-CWW.sav' @{cw_count=0;wcw_count=0;cww_count=14;combo_action_count=14} $archive $tele $temp
    Write-Host ('[OK] Replay-Native Combo Actions v2 smoke passed. app='+[string]$manifest.app_version+' synthetic=CW/WCW/CWW exact real-controls='+$cw+'/'+$wcw+'/'+$cww+' source=native-effect-sequence-v2 same-drift=required fallback=none')
    exit 0
}catch{
    Write-Host ('[FAILED] '+$_.Exception.Message)
    exit 2
}finally{
    try{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}catch{}
}
