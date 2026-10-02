param(
    [ValidateSet("Build","Resolve","Detail","BuildGameResourceBindings","UserBinding")]
    [string]$Mode = "Build",
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$ReplayFiles,
    [int]$DetailMapId = -1,
    [string]$GamePath = "",
    # -Mode UserBinding: maintain the persistent user-confirmed Game -> Resource binding authority.
    [ValidateSet("list","confirm","revoke")]
    [string]$UserBindingAction = "list",
    [int]$GameMapId = -1,
    [int]$ResourceMapId = -1,
    [string]$Evidence = "",
    [string]$GameName = "",
    [string]$ResourceName = ""
)

$ErrorActionPreference = "Stop"

# Naming helpers were moved into a definition-only module so the map-identity resolver can be
# loaded without this entry script (required by the tier-0 resolution regression).
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Modules\MapCatalog\Catalog.Naming.ps1')

# No hardcoded game-install fallback: a developer machine path must never ship in a public release.
# An empty path means "not configured" and is resolved through the folder picker below.
if([string]::IsNullOrWhiteSpace($GamePath)) {
    $GamePath=""
}
if(-not (Test-Path -LiteralPath $GamePath -PathType Container)) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dlg=New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description="请选择 QQ飞车 游戏安装目录"
    $dlg.ShowNewFolderButton=$false
    if($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $GamePath=$dlg.SelectedPath
    }
}
if(-not (Test-Path -LiteralPath $GamePath -PathType Container)) {
    throw "Game directory not found or not selected."
}

$scriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir=Split-Path -Parent $scriptDir
$projectRoot=Split-Path -Parent $dataDir
$catalogDir=Join-Path $dataDir "MapCatalog"
$resolutionDir=Join-Path $dataDir "ReplayResolution"
$logDir=Join-Path $dataDir "Logs"
$descriptorCacheDir=Join-Path $catalogDir "DescriptorCache"
$manualAliasPath=Join-Path $catalogDir "display_aliases_manual.json"
New-Item -ItemType Directory -Force -Path $catalogDir,$resolutionDir,$logDir,$descriptorCacheDir | Out-Null
$logPath=Join-Path $logDir "MapCatalog.log"

function Log([string]$s) {
    Add-Content -LiteralPath $logPath -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$s) -Encoding UTF8
}

$coreSourcePath=Join-Path $scriptDir 'Modules\MapCatalog\QQSpeedMapCatalog.Core.cs'
if(-not (Test-Path -LiteralPath $coreSourcePath -PathType Leaf)){ throw ('Map catalog core is missing: '+$coreSourcePath) }
$cs=Get-Content -LiteralPath $coreSourcePath -Raw -Encoding UTF8

if(-not ("QQMapCatalogCore" -as [type])) {
    Write-Host "[1/5] Compiling VFS + Lua map catalog reader..."
    Add-Type -TypeDefinition $cs -Language CSharp
}

. (Join-Path $scriptDir 'Modules\MapCatalog\Catalog.Build.ps1')
. (Join-Path $scriptDir 'Modules\MapCatalog\Catalog.Resolve.ps1')
. (Join-Path $scriptDir 'Modules\MapCatalog\Catalog.ReplayResolver.ps1')
. (Join-Path $scriptDir 'Modules\Replay\Replay.MapIdentityResolver.ps1')
. (Join-Path $scriptDir 'Modules\MapCatalog\GameResourceBinding.ps1')

if($Mode -eq "Build") {
    [void](Build-MapCatalog)
} elseif($Mode -eq "Resolve") {
    Resolve-Replays
} elseif($Mode -eq "Detail") {
    if($DetailMapId -lt 0){throw "Detail mode requires -DetailMapId."}
    [void](Get-MapDetailOnDemand $DetailMapId)
} elseif($Mode -eq "BuildGameResourceBindings") {
    $catalog=@(Ensure-Catalog)
    [void](Invoke-GameResourceBindingBuild -DataDir $dataDir -CatalogOverride $catalog)
} elseif($Mode -eq "UserBinding") {
    # Persistent user-confirmed Game -> Resource binding. Nothing here is ever generated or
    # inferred: the only writer is an explicit human action, and the store survives cold resets.
    if($UserBindingAction -eq "list") {
        $store=Read-GRBUserConfirmedBindings $dataDir
        Write-Host ('[UserBinding] contract='+[string]$store.contract+' count='+@($store.bindings).Count)
        foreach($b in @($store.bindings)) {
            Write-Host ('  Game'+[string]$b.game_map_id+' ('+[string]$b.game_display_name+') -> Map'+[string]$b.resource_map_id+' ('+[string]$b.resource_display_name+') · '+[string]$b.provenance+' · '+[string]$b.confirmed_at)
        }
        Write-Host ('  store: '+(Get-GRBUserConfirmedBindingPath $dataDir))
    } elseif($UserBindingAction -eq "confirm") {
        if($GameMapId -le 0 -or $ResourceMapId -le 0){ throw 'confirm requires -GameMapId and -ResourceMapId.' }
        $catalog=@(Ensure-Catalog)
        $resource=@($catalog|Where-Object {[int]$_.map_id -eq $ResourceMapId})
        if($resource.Count -eq 0){ throw ('ResourceMapId '+[string]$ResourceMapId+' is not present in the current resource catalog; refusing to confirm a non-existent resource.') }
        $rn=$ResourceName; if([string]::IsNullOrWhiteSpace($rn)){$rn=[string]$resource[0].primary_name}
        $path=Set-GRBUserConfirmedBinding -DataDir $dataDir -GameMapId $GameMapId -ResourceMapId $ResourceMapId -GameDisplayName $GameName -ResourceDisplayName $rn -Evidence $Evidence
        Write-Host ('[UserBinding] confirmed Game'+[string]$GameMapId+' -> Map'+[string]$ResourceMapId+' ('+$rn+')')
        Write-Host ('  store: '+$path)
    } elseif($UserBindingAction -eq "revoke") {
        if($GameMapId -le 0){ throw 'revoke requires -GameMapId.' }
        $removed=Remove-GRBUserConfirmedBinding -DataDir $dataDir -GameMapId $GameMapId
        Write-Host ('[UserBinding] revoked '+[string]$removed+' binding(s) for Game'+[string]$GameMapId)
    }
}
