# Native Driving Sections v1 contract / detector revision 3
# Observed driving sections are DERIVED analysis over production telemetry in the official
# map.nif world-XY coordinate system. They never redefine map identity, native actions,
# lap boundaries, or any game-native semantic state.

function NDA-ReadJson([string]$Path) {
    try { if(Test-Path -LiteralPath $Path -PathType Leaf){return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json} } catch {}
    return $null
}
function NDA-RelPath([string]$Root,[string]$Full) {
    try {
        $r=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
        $f=[IO.Path]::GetFullPath($Full)
        if($f.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)){return $f.Substring($r.Length)}
    } catch {}
    return $Full
}
function NDA-ToDouble($Value,[double]$Fallback=[double]::NaN) {
    if($null-eq$Value){return $Fallback}
    if($Value -is [double] -or $Value -is [float] -or $Value -is [int] -or $Value -is [long]){return [double]$Value}
    $d=0.0
    if([double]::TryParse([string]$Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$d)){return $d}
    return $Fallback
}
function NDA-ToBool($Value) {
    if($Value -is [bool]){return [bool]$Value}
    $s=([string]$Value).Trim()
    return ($s -ieq 'true' -or $s -eq '1')
}
function NDA-Clamp01([double]$V) { if($V-lt0){return 0.0};if($V-gt1){return 1.0};return $V }
function NDA-AngleDeltaDeg([double]$Ax,[double]$Ay,[double]$Bx,[double]$By) {
    $la=[Math]::Sqrt($Ax*$Ax+$Ay*$Ay);$lb=[Math]::Sqrt($Bx*$Bx+$By*$By)
    if($la-lt1e-9 -or $lb-lt1e-9){return 0.0}
    $cross=$Ax*$By-$Ay*$Bx;$dot=$Ax*$Bx+$Ay*$By
    return [Math]::Atan2($cross,$dot)*180.0/[Math]::PI
}
function NDA-Percentile([double[]]$Values,[double]$P) {
    $a=@($Values|Where-Object{-not[double]::IsNaN($_)-and-not[double]::IsInfinity($_)}|Sort-Object)
    if($a.Count-eq0){return [double]::NaN};if($a.Count-eq1){return [double]$a[0]}
    $x=[Math]::Max(0.0,[Math]::Min(1.0,$P))*($a.Count-1);$lo=[int][Math]::Floor($x);$hi=[int][Math]::Ceiling($x)
    if($lo-eq$hi){return [double]$a[$lo]};$f=$x-$lo;return [double]$a[$lo]*(1.0-$f)+[double]$a[$hi]*$f
}
function NDA-AverageEdgeSpeed([object[]]$Rows,[int]$Start,[int]$End,[bool]$FromStart) {
    $vals=New-Object System.Collections.Generic.List[double]
    if($FromStart){$lo=$Start;$hi=[Math]::Min($End,$Start+7)}else{$lo=[Math]::Max($Start,$End-7);$hi=$End}
    for($i=$lo;$i-le$hi;$i++){if([bool]$Rows[$i].pose_valid){$v=[double]$Rows[$i].speed;if(-not[double]::IsNaN($v)-and$v-ge0){$vals.Add($v)}}}
    if($vals.Count-eq0){return [double]::NaN};return [double](($vals.ToArray()|Measure-Object -Average).Average)
}
# Stable instantaneous speed at a semantic boundary. The old 8-sample one-sided edge average
# intentionally smoothed derived training windows, but it biased a fast-changing native Drift
# boundary by roughly 0.12 s at ~58.8 Hz. For UI comparison anchors we instead use the median of
# the boundary sample and its immediate neighbours. Invalid pose/speed samples are ignored; the
# caller supplies the legal row window so the probe never crosses a lap/stream boundary.
function NDA-MedianBoundarySpeed([object[]]$Rows,[int]$Center,[int]$Low,[int]$High) {
    if($null-eq$Rows-or$Rows.Count-eq0-or$Center-lt$Low-or$Center-gt$High){return [double]::NaN}
    $lo=[Math]::Max($Low,$Center-1);$hi=[Math]::Min($High,$Center+1)
    $vals=New-Object System.Collections.Generic.List[double]
    for($i=$lo;$i-le$hi;$i++){
        if($i-lt0-or$i-ge$Rows.Count-or-not[bool]$Rows[$i].pose_valid){continue}
        $v=[double]$Rows[$i].speed
        if(-not[double]::IsNaN($v)-and-not[double]::IsInfinity($v)-and$v-ge0){$vals.Add($v)}
    }
    if($vals.Count-eq0){return [double]::NaN}
    return [double](NDA-Percentile ([double[]]$vals.ToArray()) 0.5)
}
function Initialize-NativeDrivingGeometryCore {
    if('QQNativeDrivingSurfaceIndex' -as [type]){return}
    $cs=Join-Path $PSScriptRoot 'NativeDrivingGeometry.Core.cs'
    if(-not(Test-Path -LiteralPath $cs -PathType Leaf)){throw ('Native driving geometry core missing: '+$cs)}
    # Windows PowerShell 5.1 Add-Type source compilation only references System.dll and
    # System.Management.Automation.dll by default. This core uses System.Xml.XmlDocument,
    # so make the dependency explicit instead of relying on an already-loaded assembly.
    Add-Type -Path $cs -ReferencedAssemblies 'System.Xml.dll' | Out-Null
}
# Telemetry rows for the derived driving analyses.
#
# The production logical telemetry CSV has 6.4k-9k rows and is needed by more than one derived
# analysis per run. Row materialisation is delegated to the typed C# reader
# (`QQNativeDrivingGeometry.Core.cs` -> QQNativeDrivingCsv.Load) because building one PowerShell
# PSCustomObject per row cost ~2.3-2.8 s per stream and dominated the warm path. The field set and
# the fallbacks are unchanged: i/t/x/y/z/speed/distance/lap_index/pose_valid/break_before, with
# speed and distance falling back to 0.0 and every other numeric field to NaN.
function NDA-LoadRows([string]$CsvPath) {
    Initialize-NativeDrivingGeometryCore
    return [QQNativeDrivingCsv]::Load($CsvPath)
}
# One telemetry CSV may be needed by several derived analyses in the same run. The cache is keyed by
# the csv path and is owned by the caller (the analyze orchestration).
function NDA-LoadRowsCached($Cache,[string]$CsvPath) {
    if($null-ne$Cache-and$Cache.ContainsKey($CsvPath)){return $Cache[$CsvPath]}
    $rows=NDA-LoadRows $CsvPath
    if($null-ne$Cache){$Cache[$CsvPath]=$rows}
    return $rows
}
function NDA-NearestTimeIndex([object[]]$Rows,[int]$Start,[int]$End,[double]$T) {
    if($End-le$Start){return $Start};$lo=$Start;$hi=$End
    while(($hi-$lo)-gt1){$m=[int](($lo+$hi)/2);if([double]$Rows[$m].t-le$T){$lo=$m}else{$hi=$m}}
    if([Math]::Abs([double]$Rows[$lo].t-$T)-le[Math]::Abs([double]$Rows[$hi].t-$T)){return $lo};return $hi
}
function NDA-ExpandByDistance([object[]]$Rows,[int]$Index,[int]$LapStart,[int]$LapEnd,[double]$Meters,[bool]$Backward) {
    $target=[double]$Rows[$Index].distance + $(if($Backward){-$Meters}else{$Meters})
    $j=$Index
    if($Backward){while($j-gt$LapStart -and [double]$Rows[$j].distance-gt$target){$j--}}else{while($j-lt$LapEnd -and [double]$Rows[$j].distance-lt$target){$j++}}
    return $j
}
function NDA-SectionHeadingDelta([object[]]$Rows,[int]$Start,[int]$End) {
    if(($End-$Start)-lt4){return 0.0}
    $a2=[Math]::Min($End,$Start+4);$b1=[Math]::Max($Start,$End-4)
    $ax=[double]$Rows[$a2].x-[double]$Rows[$Start].x;$ay=[double]$Rows[$a2].y-[double]$Rows[$Start].y
    $bx=[double]$Rows[$End].x-[double]$Rows[$b1].x;$by=[double]$Rows[$End].y-[double]$Rows[$b1].y
    return NDA-AngleDeltaDeg $ax $ay $bx $by
}
function NDA-BuildSignals([object[]]$Rows,[int]$Start,[int]$End,[double]$HalfWindowM=4.0) {
    $sig=New-Object double[] $Rows.Count
    $left=$Start;$right=$Start
    for($i=$Start;$i-le$End;$i++){
        if($i-le$Start+1 -or $i-ge$End-1 -or -not[bool]$Rows[$i].pose_valid){continue}
        $targetL=[double]$Rows[$i].distance-$HalfWindowM
        if($left-ge$i){$left=[Math]::Max($Start,$i-1)}
        while(($left+1)-lt$i -and [double]$Rows[$left+1].distance-le$targetL){$left++}
        if($right-le$i){$right=$i+1}
        $targetR=[double]$Rows[$i].distance+$HalfWindowM
        while($right-lt$End -and [double]$Rows[$right].distance-lt$targetR){$right++}
        if($left-ge$i -or $right-le$i){continue}
        if([bool]$Rows[$left].break_before -or [bool]$Rows[$i].break_before -or [bool]$Rows[$right].break_before){continue}
        $ax=[double]$Rows[$i].x-[double]$Rows[$left].x;$ay=[double]$Rows[$i].y-[double]$Rows[$left].y
        $bx=[double]$Rows[$right].x-[double]$Rows[$i].x;$by=[double]$Rows[$right].y-[double]$Rows[$i].y
        $sig[$i]=NDA-AngleDeltaDeg $ax $ay $bx $by
    }
    return $sig
}
function NDA-BuildDistanceSamples([object[]]$Rows,[int]$Start,[int]$End,[double]$StepM=1.0) {
    $samples=New-Object System.Collections.Generic.List[object]
    if($End-le$Start -or $StepM-le0){return $samples.ToArray()}
    $startD=[double]$Rows[$Start].distance;$endD=[double]$Rows[$End].distance
    if($endD-le$startD){return $samples.ToArray()}
    $j=$Start;$target=$startD
    while($target-le($endD+1e-6)){
        while(($j+1)-le$End -and [double]$Rows[$j+1].distance-lt$target){$j++}
        if(($j+1)-gt$End){break}
        $r0=$Rows[$j];$r1=$Rows[$j+1];$d0=[double]$r0.distance;$d1=[double]$r1.distance;$span=$d1-$d0
        if($span-le1e-8){$target+=$StepM;continue}
        $f=($target-$d0)/$span;if($f-lt0){$f=0.0}elseif($f-gt1){$f=1.0}
        $valid=([bool]$r0.pose_valid -and [bool]$r1.pose_valid -and -not[bool]$r1.break_before)
        $ri=$(if($f-le0.5){$j}else{$j+1})
        $samples.Add([pscustomobject]@{d=$target;t=([double]$r0.t+([double]$r1.t-[double]$r0.t)*$f);x=([double]$r0.x+([double]$r1.x-[double]$r0.x)*$f);y=([double]$r0.y+([double]$r1.y-[double]$r0.y)*$f);row_i=$ri;valid=$valid})
        $target+=$StepM
    }
    return $samples.ToArray()
}
function NDA-BuildDistanceSignalModel([object[]]$Rows,[int]$Start,[int]$End) {
    $samples=@(NDA-BuildDistanceSamples $Rows $Start $End 1.0)
    $rowSig=New-Object double[] $Rows.Count
    if($samples.Count-lt18){return [pscustomobject]@{samples=$samples;signals=(New-Object double[] 0);row_signals=$rowSig}}
    $raw=New-Object double[] $samples.Count
    for($i=8;$i-lt($samples.Count-8);$i++){
        if(-not[bool]$samples[$i].valid){continue}
        $s4=0.0;$ok4=$false;$s8=0.0;$ok8=$false
        if([bool]$samples[$i-4].valid -and [bool]$samples[$i+4].valid){$s4=NDA-AngleDeltaDeg ([double]$samples[$i].x-[double]$samples[$i-4].x) ([double]$samples[$i].y-[double]$samples[$i-4].y) ([double]$samples[$i+4].x-[double]$samples[$i].x) ([double]$samples[$i+4].y-[double]$samples[$i].y);$ok4=$true}
        if([bool]$samples[$i-8].valid -and [bool]$samples[$i+8].valid){$s8=(NDA-AngleDeltaDeg ([double]$samples[$i].x-[double]$samples[$i-8].x) ([double]$samples[$i].y-[double]$samples[$i-8].y) ([double]$samples[$i+8].x-[double]$samples[$i].x) ([double]$samples[$i+8].y-[double]$samples[$i].y))*0.5;$ok8=$true}
        if($ok4-and$ok8){$raw[$i]=0.70*$s4+0.30*$s8}elseif($ok4){$raw[$i]=$s4}elseif($ok8){$raw[$i]=$s8}
    }
    $smooth=New-Object double[] $samples.Count
    for($i=2;$i-lt($samples.Count-2);$i++){
        $smooth[$i]=($raw[$i-2]+2.0*$raw[$i-1]+3.0*$raw[$i]+2.0*$raw[$i+1]+$raw[$i+2])/9.0
        $ri=[int]$samples[$i].row_i
        if($ri-ge0-and$ri-lt$rowSig.Count-and[Math]::Abs($smooth[$i])-gt[Math]::Abs($rowSig[$ri])){$rowSig[$ri]=$smooth[$i]}
    }
    return [pscustomobject]@{samples=$samples;signals=$smooth;row_signals=$rowSig}
}
function NDA-DirectionHint([double[]]$Signals,[int]$Start,[int]$End) {
    $best=0.0
    for($i=$Start;$i-le$End;$i++){if([Math]::Abs($Signals[$i])-gt[Math]::Abs($best)){$best=$Signals[$i]}}
    if($best-gt0){return 'left'}elseif($best-lt0){return 'right'};return 'neutral'
}
function NDA-NewCandidate([object[]]$Rows,[double[]]$Signals,[int]$ActiveStart,[int]$ActiveEnd,[int]$LapStart,[int]$LapEnd,[bool]$ForcedDrift=$false,[double]$PeakOverride=[double]::NaN,[string]$DirectionHint='') {
    if($ActiveStart-lt$LapStart -or $ActiveEnd-gt$LapEnd -or $ActiveEnd-le$ActiveStart){return $null}
    $s=NDA-ExpandByDistance $Rows $ActiveStart $LapStart $LapEnd 3.5 $true;$e=NDA-ExpandByDistance $Rows $ActiveEnd $LapStart $LapEnd 3.5 $false
    $peak=0.0;for($i=$ActiveStart;$i-le$ActiveEnd;$i++){$a=[Math]::Abs([double]$Signals[$i]);if($a-gt$peak){$peak=$a}}
    if(-not[double]::IsNaN($PeakOverride)-and$PeakOverride-gt$peak){$peak=$PeakOverride}
    $delta=NDA-SectionHeadingDelta $Rows $s $e;$len=[double]$Rows[$e].distance-[double]$Rows[$s].distance
    if(-not$ForcedDrift -and $len-lt5.0 -and [Math]::Abs($delta)-lt12.0 -and $peak-lt12.0){return $null}
    return [pscustomobject]@{start_i=$s;end_i=$e;forced_drift=$ForcedDrift;peak_signal_deg=$peak;direction_hint=$DirectionHint}
}
function NDA-BuildCandidates([object[]]$Rows,$Lap,[object[]]$Drifts) {
    $ls=[Math]::Max(0,[int]$Lap.start_i);$le=[Math]::Min($Rows.Count-1,[int]$Lap.end_i)
    $diag=[ordered]@{
        resampled_samples=0;valid_resampled_samples=0;invalid_resampled_samples=0
        entry_samples=0;hold_samples=0;abs_signal_p50_deg=$null;abs_signal_p90_deg=$null;abs_signal_p95_deg=$null;abs_signal_p99_deg=$null
        curvature_runs_raw=0;curvature_candidates_accepted=0;curvature_candidates_rejected=0
        native_drift_segments_in_lap=0;native_drift_overlapping_geometry=0;native_drift_near_geometry=0;native_drift_outside_geometry=0;native_drift_topology_mutations=0
        native_drift_attached=0;native_drift_created=0
        premerge_candidates=0;postmerge_candidates=0;merge_reductions=0
    }
    if(($le-$ls)-lt12){return [pscustomobject]@{signals=(New-Object double[] $Rows.Count);candidates=@();diagnostics=[pscustomobject]$diag}}
    $model=NDA-BuildDistanceSignalModel $Rows $ls $le;$samples=@($model.samples);$det=[double[]]$model.signals;$signals=[double[]]$model.row_signals
    $diag.resampled_samples=$samples.Count
    $absValues=New-Object System.Collections.Generic.List[double]
    $cand=New-Object System.Collections.Generic.List[object];$activeStart=-1;$lastHold=-1;$entry=6.5;$hold=4.0;$bridge=4.0
    for($si=0;$si-lt$samples.Count;$si++){
        if(-not[bool]$samples[$si].valid){$diag.invalid_resampled_samples++;continue}
        $diag.valid_resampled_samples++
        $a=[Math]::Abs([double]$det[$si]);$absValues.Add($a)
        if($a-ge$entry){$diag.entry_samples++};if($a-ge$hold){$diag.hold_samples++}
        if($activeStart-lt0){if($a-ge$entry){$activeStart=$si;$lastHold=$si};continue}
        if($a-ge$hold){$lastHold=$si;continue}
        if($lastHold-ge0 -and ([double]$samples[$si].d-[double]$samples[$lastHold].d)-gt$bridge){
            $diag.curvature_runs_raw++
            $row0=[int]$samples[$activeStart].row_i;$row1=[int]$samples[$lastHold].row_i;$peak=0.0
            for($k=$activeStart;$k-le$lastHold;$k++){$av=[Math]::Abs([double]$det[$k]);if($av-gt$peak){$peak=$av}}
            $c=NDA-NewCandidate $Rows $signals $row0 $row1 $ls $le $false $peak (NDA-DirectionHint $det $activeStart $lastHold)
            if($null-ne$c){$cand.Add($c);$diag.curvature_candidates_accepted++}else{$diag.curvature_candidates_rejected++}
            $activeStart=-1;$lastHold=-1
        }
    }
    if($activeStart-ge0-and$lastHold-ge$activeStart){
        $diag.curvature_runs_raw++
        $row0=[int]$samples[$activeStart].row_i;$row1=[int]$samples[$lastHold].row_i;$peak=0.0
        for($k=$activeStart;$k-le$lastHold;$k++){$av=[Math]::Abs([double]$det[$k]);if($av-gt$peak){$peak=$av}}
        $c=NDA-NewCandidate $Rows $signals $row0 $row1 $ls $le $false $peak (NDA-DirectionHint $det $activeStart $lastHold)
        if($null-ne$c){$cand.Add($c);$diag.curvature_candidates_accepted++}else{$diag.curvature_candidates_rejected++}
    }
    if($absValues.Count-gt0){
        $arr=[double[]]$absValues.ToArray()
        $diag.abs_signal_p50_deg=[Math]::Round((NDA-Percentile $arr 0.50),3)
        $diag.abs_signal_p90_deg=[Math]::Round((NDA-Percentile $arr 0.90),3)
        $diag.abs_signal_p95_deg=[Math]::Round((NDA-Percentile $arr 0.95),3)
        $diag.abs_signal_p99_deg=[Math]::Round((NDA-Percentile $arr 0.99),3)
    }

    # Detector revision 3: topology is geometry-only. Native Drift is authoritative
    # action metadata, but action-table availability differs across replay streams
    # (e.g. local high-frequency vs network low-frequency). Therefore Drift must not
    # expand, create, merge, or otherwise mutate section topology.
    $diag.premerge_candidates=$cand.Count
    $sorted=@($cand.ToArray()|Sort-Object start_i,end_i);$mergedList=New-Object System.Collections.Generic.List[object]
    foreach($c in $sorted){
        if($mergedList.Count-eq0){$mergedList.Add($c);continue}
        $p=$mergedList[$mergedList.Count-1]
        $gap=[double]$Rows[[int]$c.start_i].distance-[double]$Rows[[int]$p.end_i].distance
        $ph=[string]$p.direction_hint;$ch=[string]$c.direction_hint
        $sameDirection=([string]::IsNullOrWhiteSpace($ph)-or[string]::IsNullOrWhiteSpace($ch)-or$ph-eq$ch-or$ph-eq'neutral'-or$ch-eq'neutral')
        if([int]$c.start_i-le[int]$p.end_i -or ($gap-le3.0-and$sameDirection)){
            $p.end_i=[Math]::Max([int]$p.end_i,[int]$c.end_i)
            $p.start_i=[Math]::Min([int]$p.start_i,[int]$c.start_i)
            $p.peak_signal_deg=[Math]::Max([double]$p.peak_signal_deg,[double]$c.peak_signal_deg)
            if([string]::IsNullOrWhiteSpace([string]$p.direction_hint)){$p.direction_hint=$c.direction_hint}
        }else{$mergedList.Add($c)}
    }
    $diag.postmerge_candidates=$mergedList.Count
    $diag.merge_reductions=[Math]::Max(0,$diag.premerge_candidates-$diag.postmerge_candidates)

    # Drift diagnostics are overlay-only. Section-level native action overlap is
    # computed later by NDA-BuildSection from the unchanged authoritative timelines.
    $lapT0=[double]$Rows[$ls].t;$lapT1=[double]$Rows[$le].t
    foreach($d in @($Drifts)){
        if($null-eq$d){continue}
        $ds=NDA-ToDouble $d.start_t;$de=NDA-ToDouble $d.end_t
        if([double]::IsNaN($ds)-or[double]::IsNaN($de)-or$de-lt$lapT0-or$ds-gt$lapT1){continue}
        $diag.native_drift_segments_in_lap++
        $di0=NDA-NearestTimeIndex $Rows $ls $le ([Math]::Max($lapT0,$ds))
        $di1=NDA-NearestTimeIndex $Rows $ls $le ([Math]::Min($lapT1,$de))
        $overlap=$false;$bestGap=[double]::PositiveInfinity
        foreach($c in $mergedList.ToArray()){
            if($di1-ge[int]$c.start_i -and $di0-le[int]$c.end_i){$overlap=$true;$bestGap=0.0;break}
            $gap=0.0
            if($di1-lt[int]$c.start_i){$gap=[double]$Rows[[int]$c.start_i].distance-[double]$Rows[$di1].distance}
            elseif($di0-gt[int]$c.end_i){$gap=[double]$Rows[$di0].distance-[double]$Rows[[int]$c.end_i].distance}
            if($gap-lt$bestGap){$bestGap=$gap}
        }
        if($overlap){$diag.native_drift_overlapping_geometry++}
        elseif($bestGap-le3.0){$diag.native_drift_near_geometry++}
        else{$diag.native_drift_outside_geometry++}
    }
    return [pscustomobject]@{signals=$signals;candidates=$mergedList.ToArray();diagnostics=[pscustomobject]$diag}
}
function NDA-SegmentOverlap([object[]]$Segments,[double]$StartT,[double]$EndT) {
    $count=0;$dur=0.0;$labels=New-Object System.Collections.Generic.List[string]
    foreach($s in @($Segments)){
        if($null-eq$s){continue};$a=NDA-ToDouble $s.start_t;$b=NDA-ToDouble $s.end_t
        if([double]::IsNaN($a)-or[double]::IsNaN($b)-or$b-lt$StartT-or$a-gt$EndT){continue}
        $count++;$dur+=[Math]::Max(0.0,[Math]::Min($EndT,$b)-[Math]::Max($StartT,$a))
        $lab='';if($null-ne$s.label){$lab=[string]$s.label}elseif($null-ne$s.semantic_type){$lab=[string]$s.semantic_type}
        if(-not[string]::IsNullOrWhiteSpace($lab)-and-not$labels.Contains($lab)){$labels.Add($lab)}
    }
    return [pscustomobject]@{count=$count;duration_s=$dur;labels=$labels.ToArray()}
}
function NDA-SurfaceCoverage($Surface,[object[]]$Rows,[int]$Start,[int]$End,[int]$MaxSamples=100) {
    if($null-eq$Surface -or $End-lt$Start){return $null}
    $n=$End-$Start+1;$step=[Math]::Max(1,[int][Math]::Ceiling($n/[double]$MaxSamples));$hit=0;$total=0
    for($i=$Start;$i-le$End;$i+=$step){if(-not[bool]$Rows[$i].pose_valid){continue};$total++;if($Surface.ContainsWorld([double]$Rows[$i].x,[double]$Rows[$i].y)){$hit++}}
    if($total-eq0){return $null};return [double]$hit/$total
}
function NDA-BuildSection([object[]]$Rows,[double[]]$Signals,$Candidate,$Lap,[int]$Ordinal,$Stream,$Surface) {
    $s=[int]$Candidate.start_i;$e=[int]$Candidate.end_i;if($e-le$s){return $null}
    $startT=[double]$Rows[$s].t;$endT=[double]$Rows[$e].t;$dur=[Math]::Max(0.0,$endT-$startT)
    $path=[Math]::Max(0.0,[double]$Rows[$e].distance-[double]$Rows[$s].distance)
    $delta=NDA-SectionHeadingDelta $Rows $s $e
    $peak=0.0;$peakPos=0.0;$peakNeg=0.0;$anchor=$s
    for($i=$s;$i-le$e;$i++){
        $sv=[double]$Signals[$i];$av=[Math]::Abs($sv)
        if($av-gt$peak){$peak=$av;$anchor=$i}
        if($sv-gt$peakPos){$peakPos=$sv};if($sv-lt$peakNeg){$peakNeg=$sv}
    }
    if($peak-lt0.001){$anchor=[int](($s+$e)/2)}
    $kind=if([Math]::Abs($delta)-ge10.0 -or $peak-ge8.0){'turn'}else{'drift_zone'}
    if([Math]::Abs($delta)-ge8.0){$direction=$(if($delta-gt0){'left'}else{'right'})}
    elseif($peakPos-ge8.0 -and [Math]::Abs($peakNeg)-ge8.0){$direction='mixed'}
    elseif($peakPos-ge8.0){$direction='left'}
    elseif([Math]::Abs($peakNeg)-ge8.0){$direction='right'}
    else{$direction='neutral'}

    $speeds=New-Object System.Collections.Generic.List[double]
    for($i=$s;$i-le$e;$i++){if([bool]$Rows[$i].pose_valid){$v=[double]$Rows[$i].speed;if(-not[double]::IsNaN($v)-and$v-ge0){$speeds.Add($v)}}}
    $entry=NDA-AverageEdgeSpeed $Rows $s $e $true;$exit=NDA-AverageEdgeSpeed $Rows $s $e $false
    $min=$null;$avg=$null;$p20=$null
    if($speeds.Count-gt0){$min=[double](($speeds.ToArray()|Measure-Object -Minimum).Minimum);$avg=[double](($speeds.ToArray()|Measure-Object -Average).Average);$p20=NDA-Percentile ([double[]]$speeds.ToArray()) 0.20}

    $dr=NDA-SegmentOverlap -Segments @($Stream.system_drift_segments) -StartT $startT -EndT $endT
    $nit=NDA-SegmentOverlap -Segments @($Stream.nitro_segments) -StartT $startT -EndT $endT
    $small=NDA-SegmentOverlap -Segments @($Stream.small_boost_segments) -StartT $startT -EndT $endT
    $air=NDA-SegmentOverlap -Segments @($Stream.air_boost_segments) -StartT $startT -EndT $endT
    $land=NDA-SegmentOverlap -Segments @($Stream.landing_boost_segments) -StartT $startT -EndT $endT
    $mapfx=NDA-SegmentOverlap -Segments @($Stream.map_propulsion_effect_segments) -StartT $startT -EndT $endT
    $combo=NDA-SegmentOverlap -Segments @($Stream.native_combo_segments) -StartT $startT -EndT $endT

    $eff=$null;$retMin=$null;$retAvg=$null;$retExit=$null
    if($dr.count-gt0 -and -not[double]::IsNaN($entry) -and $entry-gt1e-6 -and $null-ne$p20 -and $null-ne$avg -and -not[double]::IsNaN($exit)){
        $retMin=NDA-Clamp01 ([double]$p20/$entry);$retAvg=NDA-Clamp01 ([double]$avg/$entry);$retExit=NDA-Clamp01 ([double]$exit/$entry)
        $eff=0.45*$retMin+0.20*$retAvg+0.35*$retExit
    }
    $surfaceCoverage=NDA-SurfaceCoverage $Surface $Rows $s $e 80
    $anchorInside=$false;if($null-ne$Surface){$anchorInside=$Surface.ContainsWorld([double]$Rows[$anchor].x,[double]$Rows[$anchor].y)}

    return [ordered]@{
        id=('L{0}-S{1:D2}' -f [int]$Lap.lap,$Ordinal);lap=[int]$Lap.lap;ordinal=$Ordinal;kind=$kind;direction=$direction
        source='production_telemetry_distance_resampled_curvature_on_official_map_world_xy';authoritative=$false
        start_i=$s;end_i=$e;start_t=[Math]::Round($startT,4);end_t=[Math]::Round($endT,4);duration_s=[Math]::Round($dur,4);path_length=[Math]::Round($path,3)
        heading_change_deg=[Math]::Round($delta,2);peak_local_turn_deg=[Math]::Round($peak,2)
        anchor=[ordered]@{i=$anchor;t=[Math]::Round([double]$Rows[$anchor].t,4);x=[Math]::Round([double]$Rows[$anchor].x,4);y=[Math]::Round([double]$Rows[$anchor].y,4);z=[Math]::Round([double]$Rows[$anchor].z,4);official_surface_inside=$anchorInside}
        speed=[ordered]@{entry=$(if([double]::IsNaN($entry)){$null}else{[Math]::Round($entry,3)});min=$(if($null-eq$min){$null}else{[Math]::Round([double]$min,3)});p20=$(if($null-eq$p20-or[double]::IsNaN([double]$p20)){$null}else{[Math]::Round([double]$p20,3)});avg=$(if($null-eq$avg){$null}else{[Math]::Round([double]$avg,3)});exit=$(if([double]::IsNaN($exit)){$null}else{[Math]::Round($exit,3)})}
        native_actions=[ordered]@{drift_count=$dr.count;drift_duration_s=[Math]::Round($dr.duration_s,4);nitro_count=$nit.count;drift_small_boost_count=$small.count;air_boost_count=$air.count;landing_boost_count=$land.count;map_propulsion_count=$mapfx.count;combo_count=$combo.count;combo_labels=@($combo.labels)}
        drift_efficiency_index=$(if($null-eq$eff){$null}else{[Math]::Round([double]$eff,4)})
        drift_efficiency_components=$(if($null-eq$eff){[ordered]@{p20_speed_retention=[Math]::Round($retMin,4);average_speed_retention=[Math]::Round($retAvg,4);exit_speed_retention=[Math]::Round($retExit,4)}}else{$null})
        official_surface_sample_coverage=$(if($null-eq$surfaceCoverage){$null}else{[Math]::Round([double]$surfaceCoverage,4)})
    }
}
function NDA-BuildStream($Stream,[object[]]$Rows,$Surface,[string]$CsvRel) {
    if($null-eq$Stream){return $null}
    $laps=@($Stream.laps)
    if($laps.Count-eq0){return [ordered]@{id=[string]$Stream.id;status='unavailable_native_lap_index';source_csv=$CsvRel;sections=@();laps=@()}}
    if($Rows.Count-lt20){return [ordered]@{id=[string]$Stream.id;status='unavailable_insufficient_rows';source_csv=$CsvRel;sections=@();laps=@()}}
    $lapOut=New-Object System.Collections.Generic.List[object]
    $allSections=New-Object System.Collections.Generic.List[object]
    foreach($lap in $laps){
        $built=NDA-BuildCandidates -Rows $Rows -Lap $lap -Drifts @($Stream.system_drift_segments)
        $sections=New-Object System.Collections.Generic.List[object];$ordinal=1
        foreach($c in @($built.candidates)){$sec=NDA-BuildSection $Rows $built.signals $c $lap $ordinal $Stream $Surface;if($null-ne$sec){$sections.Add([pscustomobject]$sec);$allSections.Add([pscustomobject]$sec);$ordinal++}}
        $ls=[Math]::Max(0,[int]$lap.start_i);$le=[Math]::Min($Rows.Count-1,[int]$lap.end_i);$coverage=NDA-SurfaceCoverage $Surface $Rows $ls $le 300
        $lapOut.Add([ordered]@{lap=[int]$lap.lap;duration_s=[double]$lap.duration_s;distance=[double]$lap.distance;section_count=$sections.Count;official_surface_sample_coverage=$(if($null-eq$coverage){$null}else{[Math]::Round([double]$coverage,4)});detector_diagnostics=$built.diagnostics;sections=$sections.ToArray()})
    }
    $rep=$null
    foreach($l in $lapOut.ToArray()){
        if($l.section_count-le0){continue}
        if($null-eq$rep -or [int]$l.section_count-gt[int]$rep.section_count -or ([int]$l.section_count-eq[int]$rep.section_count -and [double]$l.duration_s-lt[double]$rep.duration_s)){$rep=$l}
    }
    $overall=NDA-SurfaceCoverage $Surface $Rows 0 ($Rows.Count-1) 1200
    return [ordered]@{
        id=[string]$Stream.id;role=[string]$Stream.role;status=$(if($allSections.Count-gt0){'ready'}else{'ready_no_turn_sections'});source_csv=$CsvRel
        section_count=$allSections.Count;lap_count=$lapOut.Count;representative_lap=$(if($null-ne$rep){[int]$rep.lap}else{$null});representative_sections=$(if($null-ne$rep){@($rep.sections)}else{@()})
        official_surface_sample_coverage=$(if($null-eq$overall){$null}else{[Math]::Round([double]$overall,4)});laps=$lapOut.ToArray()
    }
}
function New-NativeDrivingAnalysis {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$TelemetrySummaryPath,
        [Parameter(Mandatory=$true)][string]$MapMetadataPath,
        $RowsCache=$null
    )
    $telemetry=NDA-ReadJson $TelemetrySummaryPath;$map=NDA-ReadJson $MapMetadataPath
    if($null-eq$telemetry){return [ordered]@{schema_version=1;contract='native_driving_sections_v1';status='unavailable_telemetry';authoritative=$false;streams=@()}}
    if($null-eq$map -or [string]$map.contract-ne'native_map_v1' -or -not[bool]$map.official_source){return [ordered]@{schema_version=1;contract='native_driving_sections_v1';status='unavailable_official_map';authoritative=$false;streams=@()}}
    $svg=Join-Path (Split-Path -Parent $MapMetadataPath) ([string]$map.vector_minimap)
    try {
        Initialize-NativeDrivingGeometryCore
        $tr=$map.render_transform
        $surface=[QQNativeDrivingSurfaceIndex]::Load($svg,48,[double]$tr.canvas_width,[double]$tr.canvas_height,[double]$tr.world_min_x,[double]$tr.world_min_y,[double]$tr.scale,[double]$tr.offset_x,[double]$tr.offset_y,[bool]$tr.y_inverted)
    } catch {
        return [ordered]@{schema_version=1;contract='native_driving_sections_v1';status='unavailable_official_surface_index';authoritative=$false;error_type=$_.Exception.GetType().FullName;error=$_.Exception.Message;streams=@()}
    }
    $teleDir=Split-Path -Parent $TelemetrySummaryPath;$out=New-Object System.Collections.Generic.List[object]
    foreach($s in @($telemetry.streams)){
        if($null-eq$s -or [string]::IsNullOrWhiteSpace([string]$s.csv)){continue}
        $csv=Join-Path $teleDir ([string]$s.csv)
        if(-not(Test-Path -LiteralPath $csv -PathType Leaf)){$out.Add([ordered]@{id=[string]$s.id;status='unavailable_csv_missing';source_csv=[string]$s.csv;sections=@();laps=@()});continue}
        try {
            $rows=@(NDA-LoadRowsCached $RowsCache $csv)
            $out.Add((NDA-BuildStream -Stream $s -Rows $rows -Surface $surface -CsvRel (NDA-RelPath $ProjectRoot $csv)))
        } catch {
            $out.Add([ordered]@{id=[string]$s.id;status='failed_derived_analysis';source_csv=(NDA-RelPath $ProjectRoot $csv);error=$_.Exception.Message;sections=@();laps=@()})
        }
    }
    $ready=@($out.ToArray()|Where-Object{[string]$_.status -like 'ready*'}).Count
    return [ordered]@{
        schema_version=1;contract='native_driving_sections_v1';status=$(if($ready-gt0){'ready'}else{'unavailable_no_ready_stream'});authoritative=$false
        map_source='official_map.nif';surface_source='official_map.svg triangle projection';coordinate_rule='direct official world XY; no replay fit';surface_triangle_count=[int]$surface.TriangleCount
        section_basis='fixed-distance resampled production-telemetry curvature topology; authoritative native Drift is annotation only';native_action_semantics='read-only authoritative annotations; never mutate section topology or redefine native facts'
        detector_revision=3;detector=[ordered]@{name='distance_resampled_multiscale_hysteresis_geometry_topology_v3';sample_step_m=1.0;local_window_m=4.0;broad_window_m=8.0;broad_window_normalization=0.5;entry_threshold_deg=6.5;hold_threshold_deg=4.0;bridge_gap_m=4.0;section_expand_m=3.5;merge_gap_m=3.0;drift_topology_policy='annotation_only';validation_state='real_stream_native_drift_asymmetry_isolated_v1'}
        efficiency_semantics='derived 0..1 speed-retention index for native-Drift sections; not a game-native score and not an ideal-line score'
        ab_alignment='same-course section anchors in official world XY; frontend uses monotonic gap-tolerant DP matching; unmatched sections remain unmatched; descriptive and non-authoritative'
        streams=$out.ToArray()
    }
}
