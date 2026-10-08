param(
    [int]$Port = 17853
)

$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
$appDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir=Split-Path -Parent $appDir
$root=Split-Path -Parent $dataDir
$outputDir=Join-Path $root 'Output'
$analyzerScript=Join-Path $appDir 'QQReplay.ps1'
$refreshScript=Join-Path $appDir 'QQReplayRefresh.ps1'
$builderScript=Join-Path $appDir 'QQNativeMap.ps1'
$catalogScript=Join-Path $appDir 'QQSpeedMapCatalog.ps1'
$settingsPath=Join-Path $dataDir 'settings.json'
$tempUploadRoot=Join-Path $dataDir 'WebUpload'
$replayArchiveRoot=Join-Path $dataDir 'ReplayArchive'
$labelsPath=Join-Path $dataDir 'replay_labels.json'
$manualMapNamesPath=Join-Path $dataDir 'manual_map_names.json'
$frontendDiagDir=Join-Path $dataDir 'Diagnostics\Frontend'
$script:toolTasks=@{}
$script:firstRunBootstrapTaskId=''
New-Item -ItemType Directory -Force -Path $outputDir,$dataDir,$tempUploadRoot,$replayArchiveRoot,$frontendDiagDir | Out-Null

. (Join-Path $appDir 'Modules\Replay\Replay.DevRebuild.ps1')
. (Join-Path $appDir 'Modules\Replay\Replay.MapIdentityResolver.ps1')
. (Join-Path $appDir 'Modules\Replay\Replay.Catalog.ps1')
. (Join-Path $appDir 'Modules\Frontend\Frontend.Backend.ps1')
. (Join-Path $appDir 'Modules\Frontend\Frontend.Http.ps1')
# Analysis Closure v1: the segment / comparison contract modules. They are DEFINITION-ONLY, so
# loading them here costs a parse and no work; the typed telemetry row loader is only initialised
# when a comparison actually asks for rows.
. (Join-Path $appDir 'Modules\Native\NativeDrivingAnalysis.ps1')
. (Join-Path $appDir 'Modules\Native\NativeDrivingEpisodes.ps1')
. (Join-Path $appDir 'Modules\Native\NativeTrainingSections.ps1')
. (Join-Path $appDir 'Modules\Native\NativeTrainingTimeLoss.ps1')
. (Join-Path $appDir 'Modules\Native\NativeAnalysisSegments.ps1')
. (Join-Path $appDir 'Modules\Native\NativeSegmentComparison.ps1')

# Clean-install bootstrap is asynchronous: selecting the game directory is the only required setup.
# If a valid catalog/binding already exists this is a no-op, so ordinary startup stays fast.
try {
    $boot=Start-FirstRunBootstrapTask
    if([bool]$boot.started){ Write-Host '[初始化] 首次游戏资料初始化已在后台开始；网页会显示进度。' }
} catch {
    # Missing/invalid game path is normal on a first launch; the Settings dialog handles it.
}
$frontendHtmlPath=Join-Path $appDir 'Modules\Frontend\index.html'
if(-not (Test-Path -LiteralPath $frontendHtmlPath -PathType Leaf)){ throw ('Frontend HTML is missing: '+$frontendHtmlPath) }
$html=Get-Content -LiteralPath $frontendHtmlPath -Raw -Encoding UTF8

# The frontend is split into index.html + css/app.css + js/app.js. These are
# static assets of the frontend module, served from the loopback server so the
# UI keeps loading without a build step or framework.
$frontendDir=Join-Path $appDir 'Modules\Frontend'
function Send-FrontendAsset($Stream,[string]$Root,[string]$Rel,[string]$ContentType) {
    $full=Join-Path $Root $Rel
    if(-not (Test-Path -LiteralPath $full -PathType Leaf)) { Send-Text $Stream 404 'text/plain; charset=utf-8' 'Not found'; return }
    Send-Response $Stream 200 $ContentType ([IO.File]::ReadAllBytes($full))
}

# ---------------------------------------------------------------------------------------------
# One request = one route. Runs on the accept thread (the caller's runspace), so every helper
# defined by the dot-sourced modules is in scope.
# ---------------------------------------------------------------------------------------------
function Invoke-FrontendRouter($Stream,$Request,$Html,$FrontendDir,$Root) {
    $line=[string]$Request.Line
    $headers=$Request.Headers
    $bodyBytes=[byte[]]$Request.Body
    if([string]::IsNullOrWhiteSpace($line)){ return }
    $parts=$line.Split(' ')
    if($parts.Count-lt2){Send-Text $Stream 400 'text/plain; charset=utf-8' 'Bad request';return}
    $method=$parts[0].ToUpperInvariant();$target=$parts[1]
    $qpos=$target.IndexOf('?')
    if($qpos-ge0){$path=$target.Substring(0,$qpos);$query=$target.Substring($qpos+1)}else{$path=$target;$query=''}
    $params=@{}
    foreach($pair in @($query-split'&')) {
        if([string]::IsNullOrWhiteSpace($pair)){continue}
        $kv=$pair.Split('=',2);$k=[Uri]::UnescapeDataString($kv[0]);$v=if($kv.Count-gt1){[Uri]::UnescapeDataString($kv[1].Replace('+',' '))}else{''};$params[$k]=$v
    }
    if($method-eq'GET') {
        switch($path) {
            '/' { Send-Text $Stream 200 'text/html; charset=utf-8' $Html }
            '/css/app.css' { Send-FrontendAsset $Stream $FrontendDir 'css\app.css' 'text/css; charset=utf-8' }
            '/js/app.js' { Send-FrontendAsset $Stream $FrontendDir 'js\app.js' 'text/javascript; charset=utf-8' }
            '/api/analyses' { $arr=@(Get-AnalysisList); Send-Text $Stream 200 'application/json; charset=utf-8' (Json-Text $arr 8) }
            '/api/system-status' { Send-Text $Stream 200 'application/json; charset=utf-8' (Json-Text (Get-SystemStatusLocal) 5) }
            '/api/tool-task-status' { $res=Get-ToolTaskStatus ([string]$params['id']);Send-Text $Stream 200 'application/json; charset=utf-8' (Json-Text $res 6) }
            '/api/analysis' { $fp=Get-AnalysisPath ([string]$params['file']);if($null-eq$fp){Send-Text $Stream 404 'application/json; charset=utf-8' '{"error":"not found"}';break};Send-Response $Stream 200 'application/json; charset=utf-8' ([IO.File]::ReadAllBytes($fp)) }
            '/api/telemetry' { $fp=Get-TelemetryPathForAnalysis ([string]$params['file']);if($null-eq$fp){Send-Text $Stream 404 'application/json; charset=utf-8' '{"error":"telemetry not found"}';break};Send-Response $Stream 200 'application/json; charset=utf-8' ([IO.File]::ReadAllBytes($fp)) }
            '/api/map-meta' { $fp=Get-MapMetadataPath $params['map_id'];if($null-eq$fp){Send-Text $Stream 404 'application/json; charset=utf-8' '{"error":"map metadata not found"}';break};Send-Response $Stream 200 'application/json; charset=utf-8' ([IO.File]::ReadAllBytes($fp)) }
            '/asset' {
                $rel=[string]$params['path'];if([string]::IsNullOrWhiteSpace($rel)){Send-Text $Stream 404 'text/plain; charset=utf-8' 'Not found';break}
                $rel=$rel.Replace('/','\').TrimStart('\');$full=[IO.Path]::GetFullPath((Join-Path $Root $rel));$a1=[IO.Path]::GetFullPath((Join-Path $dataDir 'NativeMaps'));$a2=[IO.Path]::GetFullPath($outputDir)
                $p1=$a1.TrimEnd('\')+'\';$p2=$a2.TrimEnd('\')+'\'
                if(-not($full.StartsWith($p1,[StringComparison]::OrdinalIgnoreCase)-or$full.StartsWith($p2,[StringComparison]::OrdinalIgnoreCase))-or-not(Test-Path -LiteralPath $full -PathType Leaf)){Send-Text $Stream 404 'text/plain; charset=utf-8' 'Not found';break}
                Send-Response $Stream 200 (Get-ContentType $full) ([IO.File]::ReadAllBytes($full))
            }
            default { Send-Text $Stream 404 'text/plain; charset=utf-8' 'Not found' }
        }
    } elseif($method-eq'POST') {
        if($bodyBytes.Length-le0){Send-Text $Stream 400 'application/json; charset=utf-8' '{"ok":false,"error":"empty body"}';return}
        if($path-eq'/api/settings/game-path') {
            try{
                $req=[Text.Encoding]::UTF8.GetString($bodyBytes)|ConvertFrom-Json
                $g=Save-GamePathLocal ([string]$req.path)
                $boot=Start-FirstRunBootstrapTask
                Send-Text $Stream 200 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$true;game_path=$g;bootstrap=$boot}) 5)
            }catch{Send-Text $Stream 500 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$false;error=$_.Exception.Message}) 3)}
        } elseif($path-eq'/api/settings/select-game-path') {
            try{
                $g=Select-GamePathLocal
                if($null-eq$g){
                    Send-Text $Stream 200 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$true;cancelled=$true}) 3)
                }else{
                    $boot=Start-FirstRunBootstrapTask
                    Send-Text $Stream 200 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$true;cancelled=$false;game_path=$g;bootstrap=$boot}) 5)
                }
            }catch{Send-Text $Stream 500 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$false;error=$_.Exception.Message}) 3)}
        } elseif($path-eq'/api/map-tool') {
            try{$req=[Text.Encoding]::UTF8.GetString($bodyBytes)|ConvertFrom-Json;$result=Invoke-MapToolLocal $req;Send-Text $Stream $(if($result.ok){200}else{500}) 'application/json; charset=utf-8' (Json-Text $result 8)}catch{Send-Text $Stream 500 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$false;error=$_.Exception.Message;log=@()}) 4)}
        } elseif($path-eq'/api/analyze-upload') {
            $name=Decode-B64Utf8 ([string]$params['name_b64'])
            $safe=Safe-UploadFileName $name
            if($null-eq$safe){Send-Text $Stream 400 'application/json; charset=utf-8' '{"ok":false,"error":"只接受 .sav 录像"}';return}
            try{$result=Invoke-WebAnalysis $safe $bodyBytes;Send-Text $Stream $(if($result.ok){200}else{500}) 'application/json; charset=utf-8' (Json-Text $result 6)}catch{$err=[ordered]@{ok=$false;error=$_.Exception.Message;log_tail=@()};Send-Text $Stream 500 'application/json; charset=utf-8' (Json-Text $err 4)}
        } elseif($path-eq'/api/rename') {
            try {
                $req=[Text.Encoding]::UTF8.GetString($bodyBytes)|ConvertFrom-Json
                $file=Decode-B64Utf8 ([string]$req.file_b64)
                $display=Decode-B64Utf8 ([string]$req.display_name_b64)
                if($null-eq$file){throw '录像标识编码无效。'}
                if($null-eq$display){throw '显示名称编码无效。'}
                $saved=Set-ReplayLabel $file $display
                Send-Text $Stream 200 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$true;display_name=$saved}) 3)
            } catch {
                Send-Text $Stream 500 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$false;error=$_.Exception.Message}) 3)
            }
        } elseif($path-eq'/api/manual-map-name') {
            try {
                $req=[Text.Encoding]::UTF8.GetString($bodyBytes)|ConvertFrom-Json
                $file=Decode-B64Utf8 ([string]$req.file_b64)
                $mapName=Decode-B64Utf8 ([string]$req.map_name_b64)
                if($null-eq$file){throw '录像标识编码无效。'}
                if($null-eq$mapName){throw '地图名称编码无效。'}
                $saved=Set-ManualMapName $file $mapName
                Send-Text $Stream 200 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$true;manual_map_name=$saved}) 3)
            } catch {
                Send-Text $Stream 500 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$false;error=$_.Exception.Message}) 3)
            }
        } elseif($path-eq'/api/delete-analysis') {
            try {
                $req=[Text.Encoding]::UTF8.GetString($bodyBytes)|ConvertFrom-Json
                $file=Decode-B64Utf8 ([string]$req.file_b64)
                if($null-eq$file){throw '录像标识编码无效。'}
                $result=Remove-AnalysisLocal $file
                Send-Text $Stream 200 'application/json; charset=utf-8' (Json-Text $result 4)
            } catch {
                Send-Text $Stream 500 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$false;error=$_.Exception.Message}) 3)
            }
        } elseif($path-eq'/api/clear-analysis-data') {
            try {
                $result=Clear-AnalysisDataLocal
                Send-Text $Stream 200 'application/json; charset=utf-8' (Json-Text $result 4)
            } catch {
                Send-Text $Stream 500 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$false;error=$_.Exception.Message}) 3)
            }
        } elseif($path-eq'/api/clear-runtime-cache') {
            try {
                $result=Clear-RuntimeCacheLocal
                Send-Text $Stream 200 'application/json; charset=utf-8' (Json-Text $result 5)
            } catch {
                Send-Text $Stream 500 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$false;error=$_.Exception.Message}) 3)
            }
        } elseif($path-eq'/api/map-rebuild') {
            try{$req=[Text.Encoding]::UTF8.GetString($bodyBytes)|ConvertFrom-Json;$mid=[int]$req.map_id;$result=Invoke-MapRebuild $mid;Send-Text $Stream $(if($result.ok){200}else{500}) 'application/json; charset=utf-8' (Json-Text $result 6)}catch{$err=[ordered]@{ok=$false;error=$_.Exception.Message;log_tail=@()};Send-Text $Stream 500 'application/json; charset=utf-8' (Json-Text $err 4)}
        } elseif($path-eq'/api/refresh-data-start') {
            try{$result=Start-RefreshDataTask;Send-Text $Stream 200 'application/json; charset=utf-8' (Json-Text $result 4)}catch{Send-Text $Stream 500 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$false;error=$_.Exception.Message}) 3)}
        } elseif($path-eq'/api/segment-comparison') {
            # Analysis Closure v1: the authoritative symmetric A/B contract. Comparison semantics are
            # computed on demand; only parsed telemetry rows use the signature-invalidated process LRU,
            # so changed files, laps and custom intervals still yield current numbers.
            try{$req=[Text.Encoding]::UTF8.GetString($bodyBytes)|ConvertFrom-Json;$result=Invoke-SegmentComparisonLocal $req;Send-Text $Stream $(if($result.ok){200}else{500}) 'application/json; charset=utf-8' (Json-Text $result 16)}catch{$err=[ordered]@{ok=$false;error=$_.Exception.Message};Send-Text $Stream 500 'application/json; charset=utf-8' (Json-Text $err 4)}
        } else { Send-Text $Stream 404 'text/plain; charset=utf-8' 'Not found' }
    } else {
        Send-Text $Stream 404 'text/plain; charset=utf-8' 'Not found'
    }
}

$listener=$null;$chosen=$Port
for($p=$Port;$p-lt($Port+20);$p++) {
    try{$l=New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$p);$l.Start();$listener=$l;$chosen=$p;break}catch{}
}
if($null-eq$listener){throw '无法找到可用的本地前端端口。'}
$url="http://127.0.0.1:$chosen/"
Write-Host 'QQ Replay Web Frontend v3.7.24 · Native-First'
Write-Host ('URL: '+$url)
Write-Host '网页内可直接选择 .sav 分析；原始录像副本会存入 Data\ReplayArchive，供“重新分析已导入录像”按当前版本重新分析。'
Write-Host '关闭此窗口即可停止前端服务。'
try{Start-Process $url}catch{}

# ---------------------------------------------------------------------------------------------
# Accept loop.
#
# The loop must NEVER block on a single connection. A browser keeps idle keep-alive connections open
# (and may open a speculative one that sends nothing), so reading the request inline would stall
# every later request - including the UI's POST buttons, which then hang with no response.
#
# Only the raw read runs on a worker thread, and the deadline lives INSIDE the read
# (`Read-HttpRequestBytes` uses ReadAsync + a bounded wait, because a synchronous NetworkStream read
# cannot be time-limited). Parsing and routing stay on this thread, in this runspace, so every
# dot-sourced helper is in scope.
#
# The worker runspace is pre-loaded with `Read-HttpRequestBytes` via InitialSessionState: a fresh
# runspace does NOT see this script's functions.
# ---------------------------------------------------------------------------------------------
$readIss=[System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$readIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry('Read-HttpRequestBytes',(Get-Command Read-HttpRequestBytes).Definition)))
$readPool=[runspacefactory]::CreateRunspacePool(1,4,$readIss,$Host)
$readPool.Open()
$pending=New-Object System.Collections.Generic.List[object]
# Requests whose read finished and that are waiting to be routed. Routing runs here, on this thread,
# because that is the only runspace where the dot-sourced helpers exist.
$routing=New-Object System.Collections.Generic.Queue[object]
try {
    while($true) {
        # NON-BLOCKING accept, and this matters. A blocking `AcceptTcpClient()` only returns when the
        # NEXT connection arrives, so the completion checks below would never run for a request whose
        # read finished while no further connection was pending. A single browser request would then
        # sit unserved forever - exactly the reported "button hangs, no response" symptom. Poll
        # `Pending()` instead, and briefly sleep so this loop cannot spin a core.
        if($listener.Pending()){
            $client=$listener.AcceptTcpClient()
            try { $client.NoDelay=$true } catch {}
            $stream=$null
            try { $stream=$client.GetStream() } catch { try{$client.Close()}catch{} }
            if($null-ne$stream){
                try {
                    $ps=[powershell]::Create()
                    $ps.RunspacePool=$readPool
                    # The unary comma is REQUIRED: a bare `return $bytes` makes PowerShell unroll the
                    # byte[] into the output collection, so the collector would yield individual bytes
                    # (and `[0]` would be a single byte) instead of the whole request.
                    [void]$ps.AddScript({ param($s) ,(Read-HttpRequestBytes $s 15000 120000) }).AddArgument($stream)
                    $ar=$ps.BeginInvoke()
                    $pending.Add([pscustomobject]@{ps=$ps;ar=$ar;client=$client;stream=$stream})
                } catch {
                    try{$client.Close()}catch{}
                }
            }
        } else {
            # Idle: let the worker threads make progress without burning CPU.
            Start-Sleep -Milliseconds 15
        }

        # Drain finished reads AND route whatever is queued. The routing queue is checked
        # independently of `$pending`: a request can complete while no new connection arrives, and
        # waiting for another accept before routing it would stall that request indefinitely.
        if($pending.Count -gt 0 -or $routing.Count -gt 0){
            $still=New-Object System.Collections.Generic.List[object]
            foreach($d in $pending){
                if($d.ps.InvocationStateInfo.State -eq [System.Management.Automation.PSInvocationState]::Running){
                    $still.Add($d); continue
                }
                $bytes=$null
                try { $bytes=@($d.ps.EndInvoke($d.ar))[0] } catch { $bytes=$null }
                try { $d.ps.Dispose() } catch {}
                if($null-ne$bytes){
                    $request=$null
                    try { $request=Parse-HttpRequest ([byte[]]$bytes) }
                    catch {
                        try{Send-Text $d.stream 400 'application/json; charset=utf-8' (Json-Text ([ordered]@{ok=$false;error=$_.Exception.Message}) 3)}catch{}
                        try{$d.client.Close()}catch{}
                        continue
                    }
                    if($null-ne$request){ $routing.Enqueue([pscustomobject]@{stream=$d.stream;client=$d.client;request=$request}) }
                    else { try{$d.client.Close()}catch{} }
                } else {
                    # Idle peer, closed socket, or an unusable request: nothing to answer.
                    try{$d.client.Close()}catch{}
                }
            }
            $pending=$still
            # One route per pass keeps the completion checks above responsive even when a handler is
            # slow; queued requests are answered as soon as the current handler returns.
            if($routing.Count -gt 0){
                $r=$routing.Dequeue()
                try {
                    Invoke-FrontendRouter $r.stream $r.request $html $frontendDir $root
                } catch {
                    try{Send-Text $r.stream 500 'text/plain; charset=utf-8' $_.Exception.Message}catch{}
                } finally { try{$r.client.Close()}catch{} }
            }
        }
    }
} finally {
    foreach($d in $pending){ try{$d.ps.Dispose()}catch{}; try{$d.client.Close()}catch{} }
    try{$readPool.Close()}catch{}
    try{$listener.Stop()}catch{}
}
