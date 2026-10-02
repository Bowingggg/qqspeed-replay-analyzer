# Native combo actions derived only from already-authoritative replay-native effect intervals.
# Dedicated labeled recordings supplied on 2026-09-28 validate CW / WCW / CWW sequence windows.
# This module never inspects unknown offsets and never redefines the underlying native effects.

function RNCA-StartMs($Seg){ return [double]$Seg.start_t*1000.0 }
function RNCA-EndMs($Seg){ return [double]$Seg.end_t*1000.0 }
function RNCA-InWindow([double]$Value,[double]$Lo,[double]$Hi){ return ($Value-ge$Lo-and$Value-le$Hi) }
function RNCA-DriftId($Seg){
    if($null-eq$Seg-or$null-eq$Seg.drift_id-or[string]::IsNullOrWhiteSpace([string]$Seg.drift_id)){return $null}
    try{return [int]$Seg.drift_id}catch{return $null}
}
function RNCA-SameNativeDrift($A,$B){
    $da=RNCA-DriftId $A;$db=RNCA-DriftId $B
    return ($null-ne$da-and$null-ne$db-and[int]$da-eq[int]$db)
}

function Resolve-ReplayNativeComboActions {
    param([Parameter(Mandatory=$true)][object]$SpeedEffects)
    if($null-eq$SpeedEffects-or-not[bool]$SpeedEffects.available){
        return [pscustomobject][ordered]@{available=$false;status='native_speed_effects_unavailable';source='native_effect_sequence_v2';cw_segments=@();wcw_segments=@();cww_segments=@();native_combo_segments=@();cw_count=0;wcw_count=0;cww_count=0;combo_count=0}
    }
    $nitro=@($SpeedEffects.nitro_segments|Sort-Object start_t)
    # Only code2001 intervals already classified as drift_small_boost are eligible.
    $small=@($SpeedEffects.small_boost_segments|Sort-Object start_t)
    $cw=New-Object System.Collections.Generic.List[object]
    $wcw=New-Object System.Collections.Generic.List[object]
    $cww=New-Object System.Collections.Generic.List[object]
    $all=New-Object System.Collections.Generic.List[object]
    $used=New-Object 'System.Collections.Generic.HashSet[int]'
    $id=1
    foreach($n in $nitro){
        $nt=RNCA-StartMs $n
        $pre=New-Object System.Collections.Generic.List[object]
        $post=New-Object System.Collections.Generic.List[object]
        for($si=0;$si-lt$small.Count;$si++){
            if($used.Contains($si)){continue}
            $dt=(RNCA-StartMs $small[$si])-$nt
            if(RNCA-InWindow $dt -1000.0 -500.0){$pre.Add([pscustomobject]@{index=$si;seg=$small[$si];delta_ms=$dt})}
            if(RNCA-InWindow $dt 0.0 1500.0){$post.Add([pscustomobject]@{index=$si;seg=$small[$si];delta_ms=$dt})}
        }
        $preA=@($pre.ToArray()|Sort-Object delta_ms -Descending)
        $postA=@($post.ToArray()|Sort-Object delta_ms)
        $kind=$null;$chosen=New-Object System.Collections.Generic.List[object];$signature='';$driftId=$null

        # WCW labeled recording: S(-833..-684ms) -> N -> S(+34..+83ms), both S events on one native Drift ID.
        $wcwPairs=New-Object System.Collections.Generic.List[object]
        foreach($a in $preA){
            if(-not(RNCA-InWindow ([double]$a.delta_ms) -900.0 -600.0)){continue}
            foreach($b in $postA){
                if(-not(RNCA-InWindow ([double]$b.delta_ms) 20.0 120.0)){continue}
                $sameDrift=RNCA-SameNativeDrift $a.seg $b.seg
                if(-not$sameDrift){continue}
                $score=[Math]::Abs([double]$a.delta_ms+783.0)+[Math]::Abs([double]$b.delta_ms-67.0)
                $wcwPairs.Add([pscustomobject]@{a=$a;b=$b;score=$score;drift_id=(RNCA-DriftId $a.seg)})
            }
        }
        $wp=@($wcwPairs.ToArray()|Sort-Object score|Select-Object -First 1)
        if($wp.Count-gt0){
            $kind='WCW';$chosen.Add($wp[0].a);$chosen.Add($wp[0].b);$driftId=$wp[0].drift_id
            $signature='S(-900..-600ms) -> N -> S(+20..+120ms), same native Drift'
        }else{
            # CWW labeled recording: N -> S1(+117..817ms) -> S2(+667..1350ms), S2-S1=500..850ms; same native Drift.
            $pairs=New-Object System.Collections.Generic.List[object]
            for($a=0;$a-lt$postA.Count;$a++){
                for($b=$a+1;$b-lt$postA.Count;$b++){
                    $d1=[double]$postA[$a].delta_ms;$d2=[double]$postA[$b].delta_ms;$gap=$d2-$d1
                    $d1ok=RNCA-InWindow $d1 100.0 850.0;$d2ok=RNCA-InWindow $d2 600.0 1400.0;$gapOk=RNCA-InWindow $gap 450.0 900.0
                    if(-not($d1ok-and$d2ok-and$gapOk)){continue}
                    $sameDrift=RNCA-SameNativeDrift $postA[$a].seg $postA[$b].seg
                    if(-not$sameDrift){continue}
                    $score=[Math]::Abs($d1-684.0)+[Math]::Abs($d2-1242.0)+[Math]::Abs($gap-542.0)
                    $pairs.Add([pscustomobject]@{a=$postA[$a];b=$postA[$b];score=$score;drift_id=(RNCA-DriftId $postA[$a].seg)})
                }
            }
            $pair=@($pairs.ToArray()|Sort-Object score|Select-Object -First 1)
            if($pair.Count-gt0){
                $kind='CWW';$chosen.Add($pair[0].a);$chosen.Add($pair[0].b);$driftId=$pair[0].drift_id
                $signature='N -> S(+100..+850ms) -> S(+600..+1400ms), gap +450..+900ms, same native Drift'
            }else{
                # CW labeled recording: N -> one drift-small-boost +50..84ms (production tolerance +20..+120ms).
                $short=@($postA|Where-Object{ (RNCA-InWindow ([double]$_.delta_ms) 20.0 120.0) -and ($null -ne (RNCA-DriftId $_.seg)) }|Sort-Object {[Math]::Abs([double]$_.delta_ms-67.0)}|Select-Object -First 1)
                if($short.Count-gt0){
                    $kind='CW';$chosen.Add($short[0]);$driftId=RNCA-DriftId $short[0].seg
                    $signature='N -> S(+20..+120ms), drift-small-boost on native Drift'
                }
            }
        }
        if($null-eq$kind){continue}
        foreach($c in $chosen){[void]$used.Add([int]$c.index)}
        $starts=New-Object System.Collections.Generic.List[double];$ends=New-Object System.Collections.Generic.List[double]
        $starts.Add([double]$n.start_t);$ends.Add([double]$n.end_t)
        foreach($c in $chosen){$starts.Add([double]$c.seg.start_t);$ends.Add([double]$c.seg.end_t)}
        $seg=[ordered]@{
            id=$id;semantic_type=$kind.ToLowerInvariant();label=$kind;source='native_effect_sequence_v2';authoritative_sequence=$true
            native_drift_id=$driftId;start_t=[Math]::Round(($starts|Measure-Object -Minimum).Minimum,4);end_t=[Math]::Round(($ends|Measure-Object -Maximum).Maximum,4)
            nitro_start_t=[Math]::Round([double]$n.start_t,4);small_boost_start_t=@($chosen.ToArray()|Sort-Object delta_ms|ForEach-Object{[Math]::Round([double]$_.seg.start_t,4)})
            small_boost_delta_ms=@($chosen.ToArray()|Sort-Object delta_ms|ForEach-Object{[Math]::Round([double]$_.delta_ms,3)})
            signature=$signature;validation='dedicated_labeled_replays_2026-09-28';rule='Derived sequence label composes authoritative native Nitro + drift-small-boost intervals and requires the validated same-Drift relationship where multiple small boosts are used.'
        }
        $all.Add($seg)
        switch($kind){'CW'{$cw.Add($seg)}'WCW'{$wcw.Add($seg)}'CWW'{$cww.Add($seg)}}
        $id++
    }
    return [pscustomobject][ordered]@{
        available=$true;status='native_combo_sequences_validated';source='native_effect_sequence_v2'
        cw_count=$cw.Count;wcw_count=$wcw.Count;cww_count=$cww.Count;combo_count=$all.Count
        cw_segments=$cw.ToArray();wcw_segments=$wcw.ToArray();cww_segments=$cww.ToArray();native_combo_segments=$all.ToArray()
        contract=[ordered]@{
            version=2;CW='N -> S(+20..+120ms)';WCW='S(-900..-600ms) -> N -> S(+20..+120ms), same native Drift';CWW='N -> S(+100..+850ms) -> S(+600..+1400ms), gap 450..900ms, same native Drift'
            observed_labeled_windows=[ordered]@{CW='post +50..+84ms';WCW='pre -833..-684ms, post +34..+83ms';CWW='first +117..+817ms, second +667..+1350ms, gap +500..+850ms'}
            priority=@('WCW','CWW','CW');input_dependency='none';native_effect_dependency='Nitro + drift_small_boost only';same_native_drift_required=$true
        }
    }
}
