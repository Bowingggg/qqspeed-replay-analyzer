function Send-Response($Stream,[int]$Status,[string]$ContentType,[byte[]]$Body) {
    $st=if($Status-eq 200){'OK'}elseif($Status-eq 400){'Bad Request'}elseif($Status-eq 404){'Not Found'}elseif($Status-eq 500){'Internal Server Error'}else{'Error'}
    $head="HTTP/1.1 $Status $st`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $hb=[Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb,0,$hb.Length)
    if($Body.Length-gt 0){$Stream.Write($Body,0,$Body.Length)}
    $Stream.Flush()
}
function Send-Text($Stream,[int]$Status,[string]$ContentType,[string]$Text) { Send-Response $Stream $Status $ContentType ([Text.Encoding]::UTF8.GetBytes($Text)) }

# ---------------------------------------------------------------------------------------------
# Request reading.
#
# WHY THIS IS AN ASYNC READ. A browser keeps idle keep-alive connections open, and it may open a
# speculative connection and send nothing at all. A synchronous `NetworkStream.ReadByte()` cannot be
# time-limited (`Stream.ReadTimeout` does not apply to it), so a read that starts on an idle
# connection blocks forever. If that read runs on the accept thread, EVERY later request - the whole
# settings / clear-cache / refresh UI - stops being served. That was the regression first reported against the v3.7.23 release,
# and fixed in v3.7.24.
#
# `ReadAsync` + a bounded wait gives a real deadline: an idle connection is abandoned and the accept
# loop moves on. This returns the whole raw message (head + body) for `Parse-HttpRequest`.
#
# The frontend runs this on a worker thread, so `BodyDeadlineMs` is the UPLOAD deadline rather than
# the request deadline: a large `.sav` post legitimately takes a while.
#
# NOTE: this function is injected into the worker runspace by QQReplayFrontend.ps1. It must stay
# SELF-CONTAINED - no helper calls, only .NET types - or the worker cannot see it.
# ---------------------------------------------------------------------------------------------
function Read-HttpRequestBytes($Stream,[int]$HeadDeadlineMs=15000,[int]$BodyDeadlineMs=120000) {
    try {
        $buf=New-Object byte[] 65536
        $t=$Stream.ReadAsync($buf,0,$buf.Length)
        if(-not $t.Wait($HeadDeadlineMs)){ return $null }
        $n=$t.Result
        if($n -le 0){ return $null }
        $ms=New-Object System.IO.MemoryStream
        $ms.Write($buf,0,$n)
        $text=[Text.Encoding]::ASCII.GetString($ms.ToArray())
        $sep=$text.IndexOf("`r`n`r`n")
        while($sep -lt 0){
            if($ms.Length -gt 65536){ return $null }
            $t=$Stream.ReadAsync($buf,0,$buf.Length)
            if(-not $t.Wait($HeadDeadlineMs)){ return $null }
            $n=$t.Result
            if($n -le 0){ break }
            $ms.Write($buf,0,$n)
            $text=[Text.Encoding]::ASCII.GetString($ms.ToArray())
            $sep=$text.IndexOf("`r`n`r`n")
        }
        if($sep -lt 0){ return $null }
        $head=$text.Substring(0,$sep)
        $len=0
        foreach($l in @($head -split "`r`n")){
            $c=$l.IndexOf(':')
            if($c -gt 0 -and $l.Substring(0,$c).Trim().ToLowerInvariant() -eq 'content-length'){
                [void][int]::TryParse($l.Substring($c+1).Trim(),[ref]$len)
            }
        }
        if($len -lt 0 -or $len -gt 100663296){ return $null }
        $have=$ms.ToArray()
        $bodyStart=$sep+4
        if($len -le 0){ return $have }
        # Full message = head (already terminated) + body. `Parse-HttpRequest` reads Content-Length
        # from the head and slices the body at the terminator, so both parts must be present.
        $full=New-Object byte[] ($bodyStart+$len)
        [Array]::Copy($have,0,$full,0,$have.Length)
        $copied=[Math]::Max(0,$have.Length-$bodyStart)
        while($copied -lt $len){
            $t2=$Stream.ReadAsync($buf,0,[Math]::Min($buf.Length,$len-$copied))
            if(-not $t2.Wait($BodyDeadlineMs)){ return $null }
            $n2=$t2.Result
            if($n2 -le 0){ return $null }
            [Array]::Copy($buf,0,$full,$bodyStart+$copied,$n2)
            $copied+=$n2
        }
        return $full
    } catch { return $null }
}

# Parse a raw request (head + body) into line / headers / body bytes. Runs on the accept thread.
function Parse-HttpRequest([byte[]]$Bytes) {
    if($null-eq$Bytes -or $Bytes.Length -eq 0){ return $null }
    $sep=-1
    for($i=0;$i-lt($Bytes.Length-3);$i++){
        if($Bytes[$i]-eq13-and$Bytes[$i+1]-eq10-and$Bytes[$i+2]-eq13-and$Bytes[$i+3]-eq10){ $sep=$i; break }
    }
    if($sep -lt 0){ return $null }
    $head=[Text.Encoding]::ASCII.GetString($Bytes,0,$sep)
    $lines=$head -split "`r`n"
    $requestLine=[string]$lines[0]
    $headers=@{}
    for($i=1;$i-lt$lines.Count;$i++) {
        $h=[string]$lines[$i]
        if([string]::IsNullOrEmpty($h)){continue}
        $c=$h.IndexOf(':')
        if($c -gt 0){$headers[$h.Substring(0,$c).Trim().ToLowerInvariant()]=$h.Substring($c+1).Trim()}
    }
    $len=0
    if($headers.ContainsKey('content-length')) {
        if(-not [int]::TryParse([string]$headers['content-length'],[ref]$len)){ throw 'Content-Length 无效。' }
    }
    if($len -lt 0 -or $len -gt 100663296){ throw '请求体过大。' }
    $bodyStart=$sep+4
    $avail=$Bytes.Length-$bodyStart
    if($len -gt 0 -and $avail -lt $len){ throw ('请求体不完整: '+$avail+'/'+$len) }
    $body=New-Object byte[] $len
    if($len -gt 0){ [Array]::Copy($Bytes,$bodyStart,$body,0,$len) }
    return [pscustomobject]@{Line=$requestLine;Headers=$headers;Body=$body}
}
