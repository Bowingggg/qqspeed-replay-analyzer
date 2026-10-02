# Atomic write: temp file in the SAME directory, then replace. A crash can never
# leave a half-written analysis JSON that a later run would misread.
#
# `-Depth` defaults to 24 rather than ConvertTo-Json's 2: the published analysis carries deeply
# nested derived blocks (per-lap record -> episode aggregates -> native action sub-objects), and a
# too-shallow depth silently serialises a nested object as its ToString() text instead of failing
# loudly. It stays an explicit parameter so a caller that wants a shallow document can say so.
function Write-JsonUtf8([string]$Path,[object]$Value,[int]$Depth=24) {
    $dir=Split-Path -Parent $Path
    if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $tmp=$Path+'.tmp'
    $enc=New-Object System.Text.UTF8Encoding -ArgumentList $true
    try {
        [System.IO.File]::WriteAllText($tmp,($Value|ConvertTo-Json -Depth $Depth),$enc)
        if(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Force}
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
        throw
    }
}

function Get-Settings {
    if(Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try { return Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    # "Not configured" is an EMPTY path, never a hardcoded developer install directory: the frontend
    # derives game_path_valid from this value and must show the setup prompt instead of silently
    # adopting a path from the machine the release was built on.
    return [pscustomobject]@{game_path=''}
}

function Save-GamePath([string]$Path) {
    Write-JsonUtf8 $settingsPath ([ordered]@{game_path=$Path})
}

function Select-GamePath {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dlg=New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description='请选择 QQ飞车 游戏安装目录'
    $dlg.ShowNewFolderButton=$false
    if($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Save-GamePath $dlg.SelectedPath
        return $dlg.SelectedPath
    }
    return $null
}

function Get-GamePath([switch]$AllowPrompt) {
    $s=Get-Settings
    $p=[string]$s.game_path
    if(-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p -PathType Container)) { return $p }
    if($AllowPrompt) { return Select-GamePath }
    return $p
}

function Invoke-PSChild([string]$Script,[string[]]$Arguments) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments
    return $LASTEXITCODE
}

function Invoke-PSChildVisible([string]$Script,[string[]]$Arguments,[string]$Title) {
    Write-Host ''
    Write-Host ('[开始] '+$Title)
    $sw=[System.Diagnostics.Stopwatch]::StartNew()
    $rc=1
    $parentEap=$ErrorActionPreference
    try {
        # child_error_stream_isolation_v1: under Windows PowerShell 5.1, redirected native stderr
        # may surface as ErrorRecord objects. It must remain diagnostic output and must never
        # terminate the parent before LASTEXITCODE can drive the explicit fallback contract.
        $ErrorActionPreference='Continue'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | ForEach-Object { Write-Host ([string]$_) }
        $rc=$LASTEXITCODE
    } finally {
        $ErrorActionPreference=$parentEap
        $sw.Stop()
    }
    if($rc -eq 0) {
        Write-Host ('[完成] '+$Title+'  用时 '+[Math]::Round($sw.Elapsed.TotalSeconds,1)+' 秒')
    } else {
        Write-Host ('[失败] '+$Title+'  ExitCode='+$rc)
    }
    return [int]$rc
}

function Select-Replays {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $ofd=New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter='QQ飞车录像 (*.sav)|*.sav'
    $ofd.Multiselect=$true
    if($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return @($ofd.FileNames) }
    return @()
}

function Get-ReplayFiles([string[]]$InputItems) {
    $files=@($InputItems | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) -and ([IO.Path]::GetExtension($_) -ieq '.sav') })
    if($files.Count -eq 0){ $files=@(Select-Replays) }
    return $files
}

function Get-MapEntry([int]$MapId) {
    $idx=Join-Path $dataDir 'MapCatalog\map_index.json'
    if(-not (Test-Path -LiteralPath $idx -PathType Leaf)){ return $null }
    try {
        $all=@(Get-Content -LiteralPath $idx -Raw -Encoding UTF8 | ConvertFrom-Json)
        return @($all|Where-Object {[int]$_.map_id -eq $MapId}|Select-Object -First 1)[0]
    } catch { return $null }
}


