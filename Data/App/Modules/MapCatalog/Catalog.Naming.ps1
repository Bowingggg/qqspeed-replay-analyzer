# Shared map-name / path naming helpers for the map-catalog pipeline.
#
# Definition-only module. These functions were previously declared inline at the top of
# `QQSpeedMapCatalog.ps1` (an entry script), which made the map-identity resolver impossible to
# load in isolation and therefore made the tier-0/tier-1 resolution contract untestable.
# They are pure naming helpers: no file IO beyond the path string itself, no catalog access.

function Write-Utf8Bom([string]$Path,[string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path,$Text,$enc)
}

function Normalize-MapName([string]$Name) {
    if([string]::IsNullOrWhiteSpace($Name)){ return "" }
    $s=$Name.Normalize([System.Text.NormalizationForm]::FormKC).Trim()
    $s=[regex]::Replace($s,'\s+',' ')
    return $s
}

function ConvertTo-FlatObjectArray([object]$Value) {
    $list=New-Object System.Collections.Generic.List[object]
    if($null -eq $Value){ return $list.ToArray() }

    if($Value -is [System.Array]) {
        foreach($item in $Value) {
            if($item -is [System.Array]) {
                foreach($inner in $item) {
                    if($null -ne $inner){ $list.Add($inner) }
                }
            } elseif($null -ne $item) {
                $list.Add($item)
            }
        }
    } else {
        $list.Add($Value)
    }
    return $list.ToArray()
}

function Get-MapDisplayAlias([string]$Name) {
    $s=Normalize-MapName $Name
    if([string]::IsNullOrWhiteSpace($s)){ return "" }

    # Observed current-client convention: community/variant maps may append creator or mode
    # after "by-". Example:
    #   VANS机场by-ruoting
    #   VANS机场by-轮滑
    # The replay UI can use the shared visible prefix "VANS机场".
    # Only strip this explicit convention; do not strip generic "(R)" etc.
    $m=[regex]::Match($s,'^(?<base>.+?)\s*by[-_－—– ]+.+$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if($m.Success){ return (Normalize-MapName $m.Groups['base'].Value) }

    return $s
}

function Test-MapDeclaredNameUsable([string]$Name) {
    if([string]::IsNullOrWhiteSpace($Name)){ return $false }
    $s=Normalize-MapName $Name
    if([string]::IsNullOrWhiteSpace($s)){ return $false }

    # The client ships per-map records whose name field is an unresolved placeholder rather than
    # text (observed: one resource folder declares `mapName = "???"`). A placeholder must never be
    # treated as the map's identity name; the descriptor name stays the fallback for that folder.
    $stripped=$s.Replace('?','').Replace([string][char]0xFF1F,'').Trim()
    return (-not [string]::IsNullOrWhiteSpace($stripped))
}

function Get-MapHintFromReplayName([string]$Path) {
    $name=[System.IO.Path]::GetFileNameWithoutExtension($Path)
    $m=[regex]::Match($name,'^(?<map>.+?)-\d{8}-\d{6}-.+$')
    if($m.Success){ return $m.Groups['map'].Value }
    return ""
}

function Get-ReplayTimeFromName([string]$Path) {
    $name=[System.IO.Path]::GetFileNameWithoutExtension($Path)
    $m=[regex]::Match($name,'^.+?-(?<d>\d{8})-(?<t>\d{6})-.+$')
    if(-not $m.Success){ return $null }
    try {
        return [DateTime]::ParseExact(
            $m.Groups['d'].Value+$m.Groups['t'].Value,
            "yyyyMMddHHmmss",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    } catch { return $null }
}
