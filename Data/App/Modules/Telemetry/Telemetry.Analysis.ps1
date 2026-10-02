# Atomic write: a unique temp file in the SAME directory, then a true atomic replace
# (ReplaceFile). A crash can never leave a half-written cache/summary, and - unlike
# "delete then move" - a concurrent reader can never observe a moment where the
# destination does not exist. The catalog writer (Modules/Replay/Replay.Catalog.ps1,
# Write-JsonFileAtomic) carries the identical contract.
function Write-JsonUtf8([string]$Path,[object]$Value,[int]$Depth=12) {
    $dir=Split-Path -Parent $Path
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $tmp=$Path+'.'+[string]$PID+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    $enc=New-Object System.Text.UTF8Encoding -ArgumentList $true
    try {
        [IO.File]::WriteAllText($tmp,($Value|ConvertTo-Json -Depth $Depth),$enc)
        if(-not[IO.File]::Exists($Path)){
            [IO.File]::Move($tmp,$Path)
            return
        }
        # [NullString]::Value: passing $null marshals to an empty string, which ReplaceFile rejects.
        $lastError=$null
        for($attempt=1;$attempt -le 6;$attempt++){
            try { [IO.File]::Replace($tmp,$Path,[NullString]::Value,$true); return }
            catch { $lastError=$_; Start-Sleep -Milliseconds 25 }
        }
        throw ('Atomic replace of '+$Path+' failed: '+$lastError.Exception.Message)
    } catch {
        if([IO.File]::Exists($tmp)){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
        throw
    }
}
function Safe-Number([double]$v,[double]$fallback=0.0) {
    if([double]::IsNaN($v) -or [double]::IsInfinity($v)){return $fallback}
    return $v
}
function Normalize-Angle([double]$a) {
    $pi=[Math]::PI
    while($a -gt $pi){$a-=2.0*$pi}
    while($a -lt -$pi){$a+=2.0*$pi}
    return $a
}
function Median-Value([double[]]$Values) {
    if($null -eq $Values -or $Values.Count -eq 0){ return 0.0 }
    $a=@($Values|Sort-Object);$n=$a.Count
    if(($n % 2)-eq 1){ return [double]$a[[int]($n/2)] }
    return ([double]$a[$n/2-1]+[double]$a[$n/2])/2.0
}

function Build-NativeLapSegments($Clean) {
    # v3: Lap segmentation is a replay-native fact (record +76), never inferred
    # from returning near the starting position.
    $rows=@($Clean)
    if($rows.Count-eq0){return @()}
    $valid=@($rows|Where-Object{$null-ne$_.lap_index})
    if($valid.Count-ne$rows.Count){return @()}
    $segments=New-Object System.Collections.Generic.List[object]
    $start=0;$current=[int]$rows[0].lap_index
    for($i=1;$i-lt$rows.Count;$i++){
        $v=[int]$rows[$i].lap_index
        if($v-eq$current){continue}
        $end=$i-1
        if($end-ge$start){
            $sd=[double]$rows[$start].distance;$ed=[double]$rows[$end].distance
            $segments.Add([ordered]@{lap=$current;start_i=$start;end_i=$end;start_t=[Math]::Round([double]$rows[$start].time_s,4);end_t=[Math]::Round([double]$rows[$end].time_s,4);duration_s=[Math]::Round(([double]$rows[$end].time_s-[double]$rows[$start].time_s),4);start_distance=[Math]::Round($sd,3);end_distance=[Math]::Round($ed,3);distance=[Math]::Round(($ed-$sd),3);source='replay_native_lap_index'})
        }
        $start=$i;$current=$v
    }
    $end=$rows.Count-1
    if($end-ge$start){
        $sd=[double]$rows[$start].distance;$ed=[double]$rows[$end].distance
        $segments.Add([ordered]@{lap=$current;start_i=$start;end_i=$end;start_t=[Math]::Round([double]$rows[$start].time_s,4);end_t=[Math]::Round([double]$rows[$end].time_s,4);duration_s=[Math]::Round(([double]$rows[$end].time_s-[double]$rows[$start].time_s),4);start_distance=[Math]::Round($sd,3);end_distance=[Math]::Round($ed,3);distance=[Math]::Round(($ed-$sd),3);source='replay_native_lap_index'})
    }
    return $segments.ToArray()
}
