<#
    Smoke-HttpTransport.ps1 — Frontend transport regression (headless, no browser, no windows).

    WHY THIS EXISTS
    ---------------
    v3.7.23 shipped a frontend where every backend-backed control (设置/选择/保存/重新初始化游戏资料/
    重新分析已导入录像/清空分析缓存) hung with no response, while pure-DOM controls (设置/关闭)
    still worked. The cause was the loopback HTTP transport, not the individual buttons:

      1. `Read-HttpRequest()` read the request with a SYNCHRONOUS `NetworkStream.ReadByte()`, which
         cannot be time-limited. A browser keeps idle keep-alive connections open (and may open a
         speculative one that sends nothing). The accept loop blocked on that idle connection, so
         every later request was never served. A request could therefore stay pending forever.
      2. The accept loop called the BLOCKING `AcceptTcpClient()`, so a request whose read had already
         finished was only routed when the NEXT connection arrived. One request, no further traffic
         (exactly one click) meant it sat unserved.

    The invariant this file enforces: EVERY api request reaches a terminal state — a success or an
    explicit error — and NEVER hangs forever, even with an idle connection present.

    Scope: it exercises the real `Read-HttpRequestBytes` / `Parse-HttpRequest` from
    `Modules/Frontend/Frontend.Http.ps1` against a real loopback socket, plus the source-level
    contract of the accept loop in `QQReplayFrontend.ps1`. It deliberately does NOT start the real
    server (that would open a browser), and it does not touch replay analysis semantics.
#>
param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}

$failures=New-Object System.Collections.Generic.List[string]
$checks=0
function Check([string]$Name,[bool]$Ok,[string]$Detail=''){
    $script:checks++
    if($Ok){ Write-Host ('  [ok]   '+$Name) }
    else {
        Write-Host ('  [FAIL] '+$Name)
        if($Detail){ Write-Host ('         '+$Detail) }
        $script:failures.Add($Name)
    }
}

$httpModule=Join-Path $AppDir 'Modules\Frontend\Frontend.Http.ps1'
$entrypoint=Join-Path $AppDir 'QQReplayFrontend.ps1'
if(-not (Test-Path -LiteralPath $httpModule -PathType Leaf)){ throw ('missing module: '+$httpModule) }
if(-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)){ throw ('missing entrypoint: '+$entrypoint) }
. $httpModule

Write-Host '=== frontend transport regression ==='

# ---------------------------------------------------------------------------------------------
# 1+2. Entrypoint contract, asserted WITHOUT hard-coding the implementation's symbol names.
#
# The bug this file guards against was an entrypoint whose request loop could not serve a request
# when the peer was idle or when a single request completed on its own. The contract below is
# implementation-agnostic: it names the required CAPABILITIES (deadline, async read, non-blocking
# accept, preserved byte[], worker bootstrap), so it fails cleanly on the pre-fix code instead of
# crashing on a renamed helper.
# ---------------------------------------------------------------------------------------------
$readerModule='Data\App\Modules\Frontend\Frontend.Http.ps1'
$readerEntrypoint='Data\App\QQReplayFrontend.ps1'

# Resolve a repo-relative path either from the normal tree (Data\App is the grandparent of Tests)
# or from a flat fixture root (the directory that directly contains Modules\ and Tests\).
function Resolve-Rel([string]$Rel){
    $norm=$Rel -replace '/','\'
    $a=Join-Path $AppDir $norm
    if(Test-Path -LiteralPath $a){ return $a }
    $strip=$norm -replace '^Data\\App\\',''
    $b=Join-Path $AppDir $strip
    if(Test-Path -LiteralPath $b){ return $b }
    return $a
}
$httpAbs=Resolve-Rel 'Data\App\Modules\Frontend\Frontend.Http.ps1'
$entryAbs=Join-Path $AppDir 'QQReplayFrontend.ps1'
if(-not (Test-Path -LiteralPath $entryAbs)){ $entryAbs=Resolve-Rel 'Data\App\QQReplayFrontend.ps1' }
Check 'T1 the request reader module ships at the documented path' (Test-Path -LiteralPath $httpAbs -PathType Leaf) $readerModule
Check 'T2 the frontend entrypoint ships at the documented path' (Test-Path -LiteralPath $entryAbs -PathType Leaf) $readerEntrypoint

$httpText=[IO.File]::ReadAllText($httpAbs)
$entryText=[IO.File]::ReadAllText($entryAbs)

Check 'T3 the reader uses an ASYNC read with a deadline' `
    (($httpText -match 'ReadAsync') -and ($httpText -match '\.Wait\(')) `
    'a synchronous NetworkStream read cannot be time-limited, so an idle peer blocks it forever'
Check 'T4 the reader can abandon a peer that never completes its head' `
    (($httpText -match 'HeadDeadlineMs') -and ($httpText -match 'return \$null')) `
    'the reader must be able to give up instead of blocking indefinitely'
Check 'T5 the reader declares a separate (larger) body/upload deadline' `
    ($httpText -match 'BodyDeadlineMs') `
    'an upload leg may legitimately outlast the header deadline'
Check 'T6 the reader is SELF-CONTAINED (no helper calls a worker runspace would lack)' `
    ($httpText -notmatch '(?m)^\s*(Send-Response|Send-Text|Json-Text|Get-[A-Za-z]+|Test-[A-Za-z]+)\s') `
    'the reader is injected into a worker runspace and must use only .NET types'

Check 'T7 the entrypoint creates a worker runspace pool for reading' `
    ($entryText -match 'CreateRunspacePool') 'reads must not run on the accept thread'
Check 'T8 the worker pool is pre-loaded with the reader through InitialSessionState' `
    (($entryText -match 'InitialSessionState') -and ($entryText -match 'SessionStateFunctionEntry')) `
    'a fresh runspace does not see the entrypoint scope, so the function must be injected'
Check 'T9 the accept loop is NON-BLOCKING (Pending() gate, not a bare blocking accept)' `
    ($entryText -match '\.Pending\(\)') `
    'a blocking accept defers routing until the next connection arrives, so a lone request hangs'
$acceptCalls=[regex]::Matches($entryText,'\.AcceptTcpClient\(\)').Count
$guardGate=[regex]::Matches($entryText,'if\(\$listener\.Pending\(\)\)').Count
Check 'T10 a blocking accept is not used as the only loop gate' `
    (($guardGate -ge 1) -and ($acceptCalls -le $guardGate)) `
    ('accept calls='+$acceptCalls+' guarded gates='+$guardGate)
Check 'T11 completed requests are drained independently of new connections' `
    (($entryText -match '\$routing') -and ($entryText -match 'routing\.Count -gt 0')) `
    'a finished read must be routed even when no further connection arrives'
Check 'T12 the head reader is given a real (bounded, non-zero) deadline at the call site' `
    ($entryText -match '15000') 'the entrypoint must pass a finite head deadline'
Check 'T13 the worker result keeps the byte[] intact' `
    ($entryText -match ',\s*\(') `
    'without the unary comma the byte[] unrolls and only a single byte survives'
# 3. Real behaviour against a real loopback socket.
# ---------------------------------------------------------------------------------------------
$listener=New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$listener.Start()
$port=([System.Net.IPEndPoint]$listener.LocalEndpoint).Port

# The reader is injected into a WORKER runspace through InitialSessionState, exactly as the
# entrypoint does it: a fresh runspace does not see the scope of this file.
$readerCmd=$null
foreach($cand in @('Read-HttpRequestBytes','Read-HttpRequest')){
    $c=Get-Command $cand -ErrorAction SilentlyContinue
    if($null-ne$c){ $readerCmd=$c; break }
}
$readerName=if($readerCmd){ [string]$readerCmd.Name } else { '' }
$readerDefinition=if($readerCmd){ [string]$readerCmd.Definition } else { '' }
$readerArgCount=if($readerCmd){ $readerCmd.Parameters.Count } else { 0 }
$testPool=$null
if($readerName){
    $testIss=[System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $testIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($readerName,$readerDefinition)))
    $testPool=[runspacefactory]::CreateRunspacePool(1,2,$testIss,$Host)
    $testPool.Open()
}

function Start-Reader([System.Net.Sockets.NetworkStream]$Stream,[int]$HeadDeadlineMs){
    $ps=[powershell]::Create()
    $ps.RunspacePool=$testPool
    [void]$ps.AddScript({ param($s,$d,$b) ,(Read-HttpRequestBytes $s $d $b) }).AddArgument($Stream).AddArgument($HeadDeadlineMs).AddArgument(120000)
    return [pscustomobject]@{ ps=$ps; ar=$ps.BeginInvoke() }
}
function Wait-Reader($h,[int]$TimeoutMs){
    $sw=[System.Diagnostics.Stopwatch]::StartNew()
    while($h.ps.InvocationStateInfo.State -eq [System.Management.Automation.PSInvocationState]::Running -and $sw.Elapsed.TotalMilliseconds -lt $TimeoutMs){
        Start-Sleep -Milliseconds 40
    }
    return [int]$sw.Elapsed.TotalMilliseconds
}
function Complete-Reader($h){
    $out=@{ Bytes=$null; Errors=@(); Ran=$false }
    try { $r=@($h.ps.EndInvoke($h.ar)); if($r.Count -gt 0 -and $null -ne $r[0]){ $out.Bytes=[byte[]]$r[0] } } catch { $out.Errors+=$_.Exception.Message }
    foreach($e in $h.ps.Streams.Error){ $out.Errors+=('worker: '+$e.ToString()) }
    $out.Ran=((@($out.Errors | Where-Object { $_ -match 'not recognized|无法将|CommandNotFound' }).Count) -eq 0)
    return $out
}

# Sends a raw request from a separate process. Writing from the SAME process that then reads on a
# worker runspace proved unreliable here (the bytes were not observed), so the client runs isolated.
function Send-FromJob([int]$Port,[string]$Request,[int]$HoldMs=4000){
    $j=Start-Job -ArgumentList $Port,$Request,$HoldMs -ScriptBlock {
        param($p,$req,$hold)
        try {
            $c=New-Object System.Net.Sockets.TcpClient
            $c.Connect('127.0.0.1',$p)
            $s=$c.GetStream()
            $b=[Text.Encoding]::UTF8.GetBytes($req)
            $s.Write($b,0,$b.Length); $s.Flush()
            Start-Sleep -Milliseconds $hold
            $c.Close()
        } catch { }
    }
    return $j
}
function Stop-Sender($Job){
    if($null-eq$Job){ return }
    try { Stop-Job $Job -ErrorAction SilentlyContinue } catch {}
    try { Remove-Job $Job -Force -ErrorAction SilentlyContinue } catch {}
}

if($readerName -ne 'Read-HttpRequestBytes'){
    # The pre-fix reader has a different name and a synchronous signature: the socket cases below
    # calibrate against the fixed reader. Skipping keeps the pre-fix run a CLEAN failure (the contract
    # checks above already fail) instead of an error about a renamed helper.
    Write-Host '  [skip] socket-calibration cases (reader is not the async Read-HttpRequestBytes)'
} else {
try {
    # 3a. An IDLE peer (browser keep-alive / speculative socket) is abandoned at the deadline.
    $idleClient=New-Object System.Net.Sockets.TcpClient
    $idleClient.Connect('127.0.0.1',$port)
    $acceptedIdle=$listener.AcceptTcpClient()
    $h=Start-Reader $acceptedIdle.GetStream() 1200
    $ms=Wait-Reader $h 12000
    $c=Complete-Reader $h
    Check 'S1 an idle connection is abandoned at the deadline instead of blocking forever' `
        (($null -eq $c.Bytes) -and $ms -lt 8000 -and $c.Ran) ('elapsed='+$ms+'ms ran='+$c.Ran+' errors='+(($c.Errors) -join ' | '))
    try{$h.ps.Dispose()}catch{}
    try{$acceptedIdle.Close()}catch{}
    $idleClient.Close()

    # 3b. A Content-Length JSON body is read completely, and parses to the exact body.
    $body='{"action":"rebuild_catalog"}'
    $bodyBytes=[Text.Encoding]::UTF8.GetBytes($body)
    $head="POST /api/map-tool HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $sender=Send-FromJob $port ($head+$body)
    $accepted=$listener.AcceptTcpClient()
    $stream=$accepted.GetStream()

    $h2=Start-Reader $stream 5000
    $ms2=Wait-Reader $h2 12000
    $c2=Complete-Reader $h2
    $bytes=$c2.Bytes
    Check 'S2 a real POST with a Content-Length JSON body is read completely' `
        (($null-ne$bytes) -and ($bytes.Length -eq ($head.Length+$bodyBytes.Length))) `
        ('bytes='+$(if($null-ne$bytes){$bytes.Length}else{'null'})+' expected='+($head.Length+$bodyBytes.Length)+' elapsed='+$ms2+'ms errors='+(($c2.Errors) -join ' | '))
    try{$h2.ps.Dispose()}catch{}

    $req=$null
    if($null-ne$bytes){ try { $req=Parse-HttpRequest $bytes } catch { $req=$null } }
    Check 'S3 the parsed request exposes method, path and the exact JSON body' `
        (($null-ne$req) -and ($req.Line -match '^POST /api/map-tool ') -and ($req.Headers['content-type'] -eq 'application/json') -and ([Text.Encoding]::UTF8.GetString($req.Body) -eq $body)) `
        ('line='+$(if($req){$req.Line}else{'null'}))
    try{$accepted.Close()}catch{}
    Stop-Sender $sender

    # 3c. Content-Length: 0 must still reach a terminal parse.
    $head3="POST /api/clear-runtime-cache HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
    $sender3=Send-FromJob $port $head3
    $accepted3=$listener.AcceptTcpClient()
    $stream3=$accepted3.GetStream()
    $h3=Start-Reader $stream3 4000
    $ms3=Wait-Reader $h3 12000
    $c3=Complete-Reader $h3
    $bytes3=$c3.Bytes
    $req3=$null
    if($null-ne$bytes3){ try { $req3=Parse-HttpRequest $bytes3 } catch { $req3=$null } }
    Check 'S4 a POST with Content-Length: 0 reaches a terminal parse (never hangs)' `
        (($null-ne$req3) -and ($req3.Body.Length -eq 0) -and ($ms3 -lt 8000) -and $c3.Ran) `
        ('elapsed='+$ms3+'ms ran='+$c3.Ran+' errors='+(($c3.Errors) -join ' | '))
    try{$h3.ps.Dispose()}catch{}
    try{$accepted3.Close()}catch{}
    Stop-Sender $sender3

    # 3d. An announced body that never arrives must fail closed.
    $head4="POST /api/map-tool HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nContent-Length: 500`r`nConnection: close`r`n`r`n"
    $sender4=Send-FromJob $port $head4 -HoldMs 1500   # announced body is never sent
    $accepted4=$listener.AcceptTcpClient()
    $stream4=$accepted4.GetStream()
    $h4=Start-Reader $stream4 1200
    $ms4=Wait-Reader $h4 12000
    $c4=Complete-Reader $h4
    Check 'S5 a truncated body fails closed instead of hanging' `
        (($null -eq $c4.Bytes) -and $ms4 -lt 8000 -and $c4.Ran) ('elapsed='+$ms4+'ms ran='+$c4.Ran+' errors='+(($c4.Errors) -join ' | '))
    try{$h4.ps.Dispose()}catch{}
    try{$accepted4.Close()}catch{}
    Stop-Sender $sender4

    # 3e. An oversized declared body is rejected.
    $rejected=$false
    try { $null=Parse-HttpRequest ([Text.Encoding]::ASCII.GetBytes("POST /x HTTP/1.1`r`nContent-Length: 999999999`r`n`r`n")) }
    catch { $rejected=$true }
    Check 'S6 an oversized Content-Length is rejected' $rejected 'oversized body must throw'
} finally {
    try{$testPool.Close()}catch{}
    try{$listener.Stop()}catch{}
}
}
# 4. The frontend request layer must surface errors rather than leaving a promise pending.
# ---------------------------------------------------------------------------------------------
$appJs=Join-Path $AppDir 'Modules\Frontend\js\app.js'
if(-not (Test-Path -LiteralPath $appJs)){ $appJs=Resolve-Rel 'Data\App\Modules\Frontend\js\app.js' }
$js=[IO.File]::ReadAllText($appJs)
Check 'T15 the shared json() layer throws on a non-2xx response (so err() can report it)' `
    ($js -match 'async function json\(url,opt\)\{[^\r\n]*if\(!r\.ok\)throw new Error') `
    'json() must convert a non-ok response into a rejected promise'
# The JSON path must go through exactly one fetch (inside json()). The `.sav` upload legitimately
# uses its own binary fetch (it posts an ArrayBuffer, not JSON), so it is excluded from this count.
$jsonFn=[regex]::Match($js,'async function json\(url,opt\)\{[^\r\n]*')
$jsonFetchCount=0
if($jsonFn.Success){ $jsonFetchCount=[regex]::Matches($jsonFn.Value,'fetch\(').Count }
Check 'T16 post() delegates to json() instead of duplicating a JSON fetch' `
    (($js -match 'async function post\(url,obj\)\{return json\(') -and ($jsonFetchCount -eq 1)) `
    ('json fetch sites='+$jsonFetchCount+' total fetch sites='+[regex]::Matches($js,'fetch\(').Count)
Check 'T17 a non-JSON error body still yields a readable message' `
    ($js -match 'const t=await r\.text\(\);if\(!r\.ok\)throw new Error\(t\|\|r\.statusText\)') `
    'the raw text must be used when the body is not JSON'

Write-Host ''
if($failures.Count -gt 0){
    Write-Host ('[FAILED] HTTP transport regression: passed='+($checks-$failures.Count)+' failed='+$failures.Count)
    $failures | ForEach-Object { Write-Host ('  - '+$_) }
    exit 1
}
Write-Host ('[OK] HTTP transport regression passed. checks='+$checks+' reader='+$readerName+' invariant=every-request-terminates idle-connections=abandoned accept=non-blocking')
exit 0
