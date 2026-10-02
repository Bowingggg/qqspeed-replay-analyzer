param(
    # Tools\Dev\<this file> -> Data\App
    [string]$AppDir='',
    # Comma-separated files to repair, relative to the app root. When omitted, every .ps1 under the
    # app that carries non-ASCII bytes but no UTF-8 BOM is repaired.
    [string]$Path='',
    [switch]$WhatIf
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}
if([string]::IsNullOrWhiteSpace($AppDir)){ $AppDir=Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

# =============================================================================================
# Windows PowerShell 5.1 reads a .ps1 WITHOUT a UTF-8 BOM as the active ANSI code page, so any
# non-ASCII source (Chinese comments, Chinese user-facing strings) is silently corrupted. Every
# out-of-PowerShell editing tool (including this agent's file writer) drops the BOM, and
# Tests/Validate-ModuleBoundaries.ps1 fails the build when that happens.
#
# This tool restores the BOM. It never rewrites content: the original bytes are preserved and the
# 3 BOM bytes are prepended. It is idempotent.
# =============================================================================================
$bomBytes=[byte[]](0xEF,0xBB,0xBF)
$targets=New-Object System.Collections.Generic.List[object]
$explicit=@($Path.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if($explicit.Count-gt0){
    foreach($p in $explicit){
        $full=$(if([IO.Path]::IsPathRooted($p)){ $p } else { Join-Path $AppDir $p })
        if(Test-Path -LiteralPath $full -PathType Leaf){ $targets.Add((Get-Item -LiteralPath $full)) }
        else { Write-Warning ('not found: '+$full) }
    }
} else {
    foreach($f in @(Get-ChildItem -LiteralPath $AppDir -Recurse -File -Filter '*.ps1')){
        $bytes=[IO.File]::ReadAllBytes($f.FullName)
        $hasBom=($bytes.Length-ge3-and$bytes[0]-eq0xEF-and$bytes[1]-eq0xBB-and$bytes[2]-eq0xBF)
        if($hasBom){ continue }
        $hasNonAscii=$false
        foreach($b in $bytes){ if($b-ge128){ $hasNonAscii=$true; break } }
        if($hasNonAscii){ $targets.Add($f) }
    }
}

$repaired=0
foreach($f in @($targets.ToArray())){
    $bytes=[IO.File]::ReadAllBytes($f.FullName)
    $hasBom=($bytes.Length-ge3-and$bytes[0]-eq0xEF-and$bytes[1]-eq0xBB-and$bytes[2]-eq0xBF)
    if($hasBom){ continue }
    $rel=$f.FullName
    if($f.FullName.StartsWith($AppDir,[System.StringComparison]::OrdinalIgnoreCase)){ $rel=$f.FullName.Substring($AppDir.Length).TrimStart('\') }
    if($WhatIf){ Write-Host ('[WhatIf] would restore the UTF-8 BOM: '+$rel); continue }
    $out=New-Object byte[] ($bytes.Length+3)
    [Array]::Copy($bomBytes,0,$out,0,3)
    [Array]::Copy($bytes,0,$out,3,$bytes.Length)
    [IO.File]::WriteAllBytes($f.FullName,$out)
    Write-Host ('[BOM] restored: '+$rel)
    $repaired++
}
Write-Host ('[OK] UTF-8 BOM repair complete. repaired='+[string]$repaired)
exit 0
