param(
    [string]$AppDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

$ErrorActionPreference='Stop'
$moduleRoot=Join-Path $AppDir 'Modules'
if(-not (Test-Path -LiteralPath $moduleRoot -PathType Container)){ throw ('Modules directory not found: '+$moduleRoot) }

$bad=New-Object System.Collections.Generic.List[object]
$parseErrors=New-Object System.Collections.Generic.List[object]
$encodingErrors=New-Object System.Collections.Generic.List[object]
foreach($ps1 in @(Get-ChildItem -LiteralPath $AppDir -Recurse -File -Filter '*.ps1')) {
    $bytes=[IO.File]::ReadAllBytes($ps1.FullName)
    $hasNonAscii=$false
    foreach($b in $bytes){if($b -ge 128){$hasNonAscii=$true;break}}
    if($hasNonAscii){
        $hasUtf8Bom=($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if(-not $hasUtf8Bom){$encodingErrors.Add([pscustomobject]@{file=$ps1.FullName;message='Windows PowerShell 5.1 requires UTF-8 BOM for non-ASCII .ps1 source.'})}
    }
}
foreach($f in @(Get-ChildItem -LiteralPath $moduleRoot -Recurse -File -Filter '*.ps1')) {
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$errors)
    foreach($e in @($errors)) { $parseErrors.Add([pscustomobject]@{file=$f.FullName;message=$e.Message}) }
    foreach($stmt in @($ast.EndBlock.Statements)) {
        if($stmt -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }

        # A module may declare immutable-by-convention script-scope scalar literals at import
        # scope. These are configuration constants, not orchestration. Keep this whitelist
        # deliberately narrow: single-quoted strings, numbers, $true/$false/$null only.
        # Anything capable of invoking a command, expanding a string, reading a file, or
        # performing control flow must remain inside a function.
        $stmtText=$stmt.Extent.Text.Trim()
        $literalAssignmentPattern='^\$script:[A-Za-z_][A-Za-z0-9_]*\s*=\s*(?:''(?:[^'']|'''')*''|[-+]?\d+(?:\.\d+)?|\$(?:true|false|null))\s*$'
        if($stmtText -match $literalAssignmentPattern) { continue }

        # Modules are otherwise deliberately definition-only. Runtime orchestration belongs
        # in entry scripts.
        $bad.Add([pscustomobject]@{file=$f.FullName;line=$stmt.Extent.StartLineNumber;text=$stmt.Extent.Text})
    }
}

if($encodingErrors.Count -gt 0) {
    Write-Host '[FAILED] PowerShell source encoding errors:'
    $encodingErrors | Format-Table -AutoSize
    exit 4
}
if($parseErrors.Count -gt 0) {
    Write-Host '[FAILED] PowerShell parse errors:'
    $parseErrors | Format-Table -AutoSize
    exit 2
}
if($bad.Count -gt 0) {
    Write-Host '[FAILED] Runtime statements were found at module import scope:'
    $bad | Select-Object file,line,text | Format-Table -Wrap -AutoSize
    exit 3
}
Write-Host ('[OK] '+@(Get-ChildItem -LiteralPath $moduleRoot -Recurse -File -Filter '*.ps1').Count+' modules are definition-only and parse cleanly.')
exit 0
