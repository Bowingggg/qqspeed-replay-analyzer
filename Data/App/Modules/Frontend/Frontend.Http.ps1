function Send-Response($Stream,[int]$Status,[string]$ContentType,[byte[]]$Body) {
    $st=if($Status-eq 200){'OK'}elseif($Status-eq 400){'Bad Request'}elseif($Status-eq 404){'Not Found'}elseif($Status-eq 500){'Internal Server Error'}else{'Error'}
    $head="HTTP/1.1 $Status $st`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $hb=[Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb,0,$hb.Length)
    if($Body.Length-gt 0){$Stream.Write($Body,0,$Body.Length)}
    $Stream.Flush()
}
function Send-Text($Stream,[int]$Status,[string]$ContentType,[string]$Text) { Send-Response $Stream $Status $ContentType ([Text.Encoding]::UTF8.GetBytes($Text)) }
function Read-HttpRequest($Stream) {
    $headBytes=New-Object System.Collections.Generic.List[byte]
    $state=0
    while($true) {
        $v=$Stream.ReadByte()
        if($v -lt 0){ throw '连接在请求头完成前关闭。' }
        $b=[byte]$v; $headBytes.Add($b)
        if($headBytes.Count -gt 65536){ throw '请求头过大。' }
        if($state -eq 0 -and $b -eq 13){$state=1}
        elseif($state -eq 1 -and $b -eq 10){$state=2}
        elseif($state -eq 2 -and $b -eq 13){$state=3}
        elseif($state -eq 3 -and $b -eq 10){break}
        else {$state=0}
    }
    $head=[Text.Encoding]::ASCII.GetString($headBytes.ToArray())
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
    $body=New-Object byte[] $len
    $got=0
    while($got -lt $len) {
        $n=$Stream.Read($body,$got,$len-$got)
        if($n -le 0){ throw ('请求体不完整: '+$got+'/'+$len) }
        $got+=$n
    }
    return [pscustomobject]@{Line=$requestLine;Headers=$headers;Body=$body}
}
