function Get-TelemetryCSharpCoreSource {
    param([Parameter(Mandatory=$true)][string]$AppDir)
    $paths=@(
        (Join-Path $AppDir 'Modules\Telemetry\QQReplayTelemetry.Core.cs'),
        (Join-Path $AppDir 'Modules\Telemetry\Core\ReplayCore.Contracts.cs')
    )
    $parts=New-Object System.Collections.Generic.List[string]
    foreach($p in $paths){
        if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw ('Telemetry C# core source missing: '+$p)}
        $parts.Add((Get-Content -LiteralPath $p -Raw -Encoding UTF8))
    }
    return [string]::Join("`r`n`r`n",$parts.ToArray())
}
function Initialize-TelemetryCSharpCore {
    param([Parameter(Mandatory=$true)][string]$AppDir)
    $portable=('QQReplayPortable' -as [type])
    $schema=('QQReplaySchema2026' -as [type])
    if($portable -and $schema){return}
    if($portable -or $schema){throw 'A partial/older telemetry C# core is already loaded. Restart PowerShell before loading v3 Native-First.'}
    Add-Type -TypeDefinition (Get-TelemetryCSharpCoreSource -AppDir $AppDir) -Language CSharp
}
