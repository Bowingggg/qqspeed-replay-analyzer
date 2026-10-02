<#
.SYNOPSIS
  Canonical public-release publisher for QQ飞车录像分析器.

.DESCRIPTION
  One script that performs every public-release step, each one hard-guarded:

    manifest --check     validate the manifest, isolate a PUBLIC repo, verify it, sync the stage
    manifest --stage     build the public stage from the manifest whitelist
    manifest --release   build the release ZIP + SHA256SUMS from the committed stage tree
    manifest --verify    verify the manifest, license/readme/CONTRIBUTING contract and guard logic

  Git isolation rule enforced by Assert-PublicRepo / Assert-PublicTarget:
    * every public git command MUST run as `git -C <repoPath> ...`
    * <repoPath> MUST normalize-satisfy exactly `Output\PublicRelease\repo`
    * origin MUST be exactly the manifest's public repo
  Any violation aborts (exit 2) before a single ref, index or config value is touched.

  Deliberately NOT implemented here: `git add`, `git commit`, `git push`, `git tag`.
  Those are performed as separate, explicit steps by the release operator so that the destructive
  part of publication is always a consciously separate action.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File Data\App\Tools\PublicRelease\Publish-PublicRelease.ps1 -Action stage
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('check','stage','release','verify')]
    [string]$Action,

    # Development root. Defaults to the repository root this script lives in.
    [string]$DevRoot = '',

    # Override the stage directory (used by the publisher regression tests in an isolated temp tree).
    [string]$StageDir = ''
)

$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}

# ---------------------------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------------------------
$scriptPath=$MyInvocation.MyCommand.Path
if([string]::IsNullOrWhiteSpace($DevRoot)){
    # <this> is <root>\Data\App\Tools\PublicRelease\Publish-PublicRelease.ps1 -> five levels up
    $DevRoot=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptPath))))
}
$DevRoot=(Resolve-Path -LiteralPath $DevRoot).Path.TrimEnd('\')
$configPath=Join-Path $DevRoot 'Data\App\Config\public_release_manifest.json'
if(-not (Test-Path -LiteralPath $configPath -PathType Leaf)){ throw ('public release manifest missing: '+$configPath) }
$cfg=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-CfgPath([string]$Rel){
    if([string]::IsNullOrWhiteSpace($Rel)){ return '' }
    return (Join-Path $DevRoot ($Rel -replace '/','\'))
}
$stagePath=$(if([string]::IsNullOrWhiteSpace($StageDir)){ (Get-CfgPath $cfg.stage_dir) } else { (Resolve-Path -LiteralPath $StageDir -ErrorAction SilentlyContinue).Path })
if([string]::IsNullOrWhiteSpace($stagePath)){ $stagePath=Join-Path $DevRoot ($StageDir -replace '/','\') }
$releasePath=Get-CfgPath $cfg.release_dir
$verifyPath=Get-CfgPath $cfg.verify_dir
$repoPath=Get-CfgPath $cfg.repo_dir
$originUrl=[string]$cfg.public_git.url
$originSlug=[string]$cfg.public_git.slug

$failures=New-Object System.Collections.Generic.List[string]
function Fail([string]$m){ $script:failures.Add($m) | Out-Null; Write-Host ('[FAIL] '+$m) }
function Pass([string]$m){ Write-Host ('[ok]   '+$m) }

# ---------------------------------------------------------------------------------------------
# Git isolation guards
# ---------------------------------------------------------------------------------------------
function Get-GitRoot([string]$Path){
    $out = & git -C $Path rev-parse --show-toplevel 2>&1
    if($LASTEXITCODE -ne 0){ return $null }
    return ([string]$out).Trim()
}
function Normalize-RepoPath([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)){ return '' }
    return ((Resolve-Path -LiteralPath $Path).Path.TrimEnd('\') -replace '/','\')
}

# The ONE place that decides whether a path may be treated as the public repository.
function Assert-PublicRepo([string]$Path){
    if(-not (Test-Path -LiteralPath $Path -PathType Container)){ throw ('PUBLIC REPO MISSING: '+$Path) }
    if(-not (Test-Path -LiteralPath (Join-Path $Path '.git'))){ throw ('PUBLIC REPO HAS NO .git (refusing to let git walk up to an enclosing repository): '+$Path) }
    $expected=Normalize-RepoPath $repoPath
    $actual=Normalize-RepoPath $Path
    if($actual -ne $expected){ throw ('PUBLIC REPO PATH MISMATCH: expected '+$expected+' actual '+$actual) }
    $root=Get-GitRoot $Path
    if([string]::IsNullOrWhiteSpace($root)){ throw ('not a git work tree: '+$Path) }
    $rootN=Normalize-RepoPath $root
    if($rootN -ne $expected){ throw ('PUBLIC REPO GIT ROOT MISMATCH (a git command here would escape to '+$rootN+'): expected '+$expected) }
    $url=''
    $o = & git -C $Path remote get-url origin 2>&1
    if($LASTEXITCODE -eq 0){ $url=([string]$o).Trim() }
    if($url -notmatch [regex]::Escape($originSlug)){
        throw ('PUBLIC REPO ORIGIN MISMATCH: expected '+$originUrl+' (slug '+$originSlug+') actual "'+$url+'"')
    }
    return $expected
}

function Assert-PublicTarget([string]$TargetPath){
    if(-not (Test-Path -LiteralPath $TargetPath)){ throw ('publish target does not exist: '+$TargetPath) }
    $expected=Normalize-RepoPath $repoPath
    $actual=Normalize-RepoPath $TargetPath
    if($actual -ne $expected){
        # A target that is only a CHILD of the repo is acceptable; anything else is not.
        if(-not $actual.StartsWith($expected+'\',[System.StringComparison]::OrdinalIgnoreCase)){
            throw ('PUBLISH TARGET OUTSIDE THE ISOLATED PUBLIC REPO: expected under '+$expected+' actual '+$actual)
        }
        # And the repo it belongs to must itself pass the guard.
        [void](Assert-PublicRepo $expected)
    }
    return $actual
}

# ---------------------------------------------------------------------------------------------
# Manifest matching
# ---------------------------------------------------------------------------------------------
function Convert-GlobToRegex([string]$Glob){
    $g=$Glob -replace '/','\'
    $sb=New-Object System.Text.StringBuilder
    [void]$sb.Append('^')
    for($i=0;$i-lt$g.Length;$i++){
        $c=$g[$i]
        if($c -eq '*'){
            if(($i+1) -lt $g.Length -and $g[$i+1] -eq '*'){
                [void]$sb.Append('.*'); $i++
            } else {
                [void]$sb.Append('[^\\]*')
            }
        } elseif($c -eq '?'){ [void]$sb.Append('[^\\]')
        } else { [void]$sb.Append([regex]::Escape([string]$c)) }
    }
    [void]$sb.Append('$')
    return $sb.ToString()
}
function Test-Denied([string]$Rel,[string[]]$Deny){
    $r=$Rel -replace '/','\'
    foreach($d in $Deny){
        if(Test-PathMatch $r $d){ return $d }
    }
    return $null
}
function Test-PathMatch([string]$Rel,[string]$Glob){
    $rx=Convert-GlobToRegex $Glob
    if([regex]::IsMatch($Rel,$rx,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)){ return $true }
    # A directory rule also denies everything beneath it.
    if($Glob.EndsWith('/')){
        $rxDir=Convert-GlobToRegex ($Glob+'**')
        if([regex]::IsMatch($Rel,$rxDir,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)){ return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------------------------

function Invoke-ConfigCheck {
    Write-Host '=== public release manifest ==='
    Write-Host ('contract   = '+$cfg.manifest_contract)
    Write-Host ('dev root   = '+$DevRoot)
    Write-Host ('stage      = '+$stagePath)
    Write-Host ('release    = '+$releasePath)
    Write-Host ('verify     = '+$verifyPath)
    Write-Host ('repo       = '+$repoPath)
    Write-Host ('public     = '+$originSlug)

    # canonical app version
    $manifestPath=Join-Path $DevRoot 'Data\App\app_manifest.json'
    $appManifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $appVersion=[string]$appManifest.app_version
    Pass ('canonical app version = '+$appVersion)

    # every include source must exist
    foreach($f in @($cfg.include.root_files)){ if(-not (Test-Path -LiteralPath (Get-CfgPath $f) -PathType Leaf)){ Fail ('include.root_files missing: '+$f) } }
    foreach($d in @($cfg.include.app_dirs)){ if(-not (Test-Path -LiteralPath (Get-CfgPath ('Data/App/'+$d)) -PathType Container)){ Fail ('include.app_dirs missing: '+$d) } }
    foreach($f in @($cfg.include.app_files)){ if(-not (Test-Path -LiteralPath (Get-CfgPath ('Data/App/'+$f)) -PathType Leaf)){ Fail ('include.app_files missing: '+$f) } }
    foreach($f in @($cfg.include.tool_files)){ if(-not (Test-Path -LiteralPath (Get-CfgPath ('Data/App/'+$f)) -PathType Leaf)){ Fail ('include.tool_files missing: '+$f) } }
    foreach($p in @($cfg.include.public_files)){
        if(-not (Test-Path -LiteralPath (Get-CfgPath ('Data/App/'+$p.source)) -PathType Leaf)){ Fail ('include.public_files missing: '+$p.source) }
    }
    if($failures.Count -eq 0){ Pass 'every whitelisted source exists' }

    # isolation guard must reject a non-repo path (live self-test of the guard itself)
    try { [void](Assert-PublicRepo $DevRoot); Fail 'isolation guard accepted the DEVELOPMENT repo as the public repo' }
    catch { Pass 'isolation guard refuses the development repo' }
    try { [void](Assert-PublicRepo (Join-Path $DevRoot 'Data\App')); Fail 'isolation guard accepted a non-repo path' }
    catch { Pass 'isolation guard refuses a non-repo path' }

    if($failures.Count -gt 0){ Write-Host ('[check] FAILURES='+$failures.Count); exit 2 }
    Write-Host '[check] manifest and isolation guards OK'
    exit 0
}

function Invoke-StageBuild {
    Write-Host ('=== build public stage -> '+$stagePath+' ===')
    if(Test-Path -LiteralPath $stagePath){
        # Wipe stage content but NEVER a .git: deleting it would let a later `git` command run from
        # inside the stage walk up to the enclosing development repository and mutate it.
        foreach($child in @(Get-ChildItem -LiteralPath $stagePath -Force)){
            if($child.Name -eq '.git'){ continue }
            Remove-Item -LiteralPath $child.FullName -Recurse -Force
        }
    } else {
        New-Item -ItemType Directory -Force -Path $stagePath | Out-Null
    }

    $deny=@($cfg.deny)
    # Plain arrays + $script: scope: a nested function cannot see a caller-local generic List, and
    # `$script:x.Add(...)` on a caller-local List is a null-method call.
    $script:copied=@()
    $script:skipped=@()
    $script:stageRoot=$stagePath

    function Copy-One([string]$Full,[string]$RelInStage){
        $rel=$Full.Substring((Resolve-Path -LiteralPath $DevRoot).Path.Length).TrimStart('\')
        $d=Test-Denied $rel $deny
        if($d){ $script:skipped+=$rel+' <- '+$d; return }
        $dest=Join-Path $script:stageRoot ($RelInStage -replace '/','\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $Full -Destination $dest -Force
        $script:copied+=$RelInStage
    }

    foreach($f in @($cfg.include.root_files)){ Copy-One (Get-CfgPath $f) $f }
    foreach($f in @($cfg.include.app_root_files)){
        foreach($g in @(Get-ChildItem -LiteralPath (Get-CfgPath 'Data/App') -File -ErrorAction SilentlyContinue)){
            if($g.Name -like $f){ Copy-One $g.FullName ('Data/App/'+$g.Name) }
        }
    }
    foreach($d in @($cfg.include.app_dirs)){
        $src=Get-CfgPath ('Data/App/'+$d)
        foreach($f in @(Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue)){
            $relIn='Data/App/'+$d+$f.FullName.Substring($src.Length).TrimStart('\') -replace '\\','/'
            Copy-One $f.FullName $relIn
        }
    }
    foreach($f in @($cfg.include.app_files)){ Copy-One (Get-CfgPath ('Data/App/'+$f)) ('Data/App/'+$f) }
    foreach($f in @($cfg.include.tool_files)){ Copy-One (Get-CfgPath ('Data/App/'+$f)) ('Data/App/'+$f) }
    foreach($p in @($cfg.include.public_files)){
        $src=Get-CfgPath ('Data/App/'+$p.source)
        $rel=('Data/App/'+$p.source)
        $d=Test-Denied $rel $deny
        if($d){ throw ('public file is denied by the manifest (fix the manifest): '+$rel+' <- '+$d) }
        $dest=Join-Path $stagePath ($p.target -replace '/','\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dest -Force
        $script:copied+=[string]$p.target
    }

    # ---------- structural verification ----------
    # The PUBLISHABLE PAYLOAD is every stage entry EXCEPT the stage's own `.git`, which is the
    # isolated publication repository's metadata (created by `git init` in the repo, or inherited
    # from a previous release) and never part of what a user downloads.
    $stageGit=Join-Path $stagePath '.git'
    function Get-PayloadEntries([string]$Root){
        foreach($e in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue)){
            $rel=$e.FullName.Substring($Root.Length).TrimStart('\')
            if($rel -eq '.git'){ continue }
            if($rel -like '.git\*'){ continue }
            $e
        }
    }
    $violations=New-Object System.Collections.Generic.List[string]

    foreach($r in @($cfg.required_in_stage)){
        if(-not (Test-Path -LiteralPath (Join-Path $stagePath ($r -replace '/','\')))){ $violations.Add('REQUIRED-MISSING: '+$r) }
    }
    foreach($frag in @($cfg.forbidden_content.path_fragment_deny)){
        $fragSlash=($frag -replace '\\','/').TrimEnd('/')
        foreach($f in @(Get-PayloadEntries $stagePath)){
            $relPath=$f.FullName.Substring($stagePath.Length).TrimStart('\')
            $relSlash=$relPath -replace '\\','/'
            # Match a PATH COMPONENT, never a substring: a legitimate source file such as
            # `Modules/Telemetry/ReplayNativeActionCache.ps1` merely CONTAINS the forbidden cache
            # directory name and must not be denied by a substring test.
            $parts=@($relSlash -split '/')
            if($parts -contains $fragSlash){ $violations.Add('FORBIDDEN-PATH: '+$relPath) }
        }
    }
    $allowed=@($cfg.forbidden_content.allowed_extensions | ForEach-Object { $_.ToLowerInvariant() })
    foreach($f in @(Get-PayloadEntries $stagePath)){
        if($f.PSIsContainer){ continue }
        $relPath=$f.FullName.Substring($stagePath.Length).TrimStart('\') -replace '\\','/'
        $ext=$f.Extension.ToLowerInvariant()
        if($allowed -notcontains $ext){ $violations.Add('FORBIDDEN-EXT: '+$relPath) }
        if($f.Name -eq '.git'){ $violations.Add('FORBIDDEN: .git in stage payload') }
    }
    # content patterns
    foreach($f in @(Get-PayloadEntries $stagePath)){
        if($f.PSIsContainer){ continue }
        if($f.Length -gt 12MB){ continue }
        $relPath=$f.FullName.Substring($stagePath.Length).TrimStart('\') -replace '\\','/'
        $text=$null
        try { $text=[IO.File]::ReadAllText($f.FullName) } catch { continue }
        if([string]::IsNullOrEmpty($text)){ continue }
        foreach($p in @($cfg.forbidden_content.content_deny_regex)){
            $allowHit=$false
            foreach($a in @($cfg.forbidden_content.content_allow)){
                if([string]$a.id -ne [string]$p.id){ continue }
                $af=([string]$a.file -replace '\\','/').TrimStart('/')
                if($relPath -eq $af -or $relPath.EndsWith('/'+$af)){ $allowHit=$true }
            }
            if($allowHit){ continue }
            foreach($m in [regex]::Matches($text,$p.re)){
                if($p.id -eq 'email' -and $m.Value -like '*users.noreply.github.com'){ continue }
                $violations.Add('CONTENT-'+$p.id+': '+$relPath+' :: '+$m.Value)
                break
            }
        }
    }
    # README / LICENSE contract
    $ra=$cfg.readme_assertions
    $readmePath=Join-Path $stagePath ($ra.file -replace '/','\')
    $readme=''
    if(Test-Path -LiteralPath $readmePath){ $readme=[IO.File]::ReadAllText($readmePath) } else { $violations.Add('README missing: '+$ra.file) }
    foreach($s in @($ra.must_contain)){ if($readme -notmatch [regex]::Escape($s)){ $violations.Add('README-MISSING-TEXT: '+$s) } }
    foreach($s in @($ra.must_not_contain)){ if($readme -match [regex]::Escape($s)){ $violations.Add('README-FORBIDDEN-TEXT: '+$s) } }
    $la=$cfg.license_assertions
    $licensePath=Join-Path $stagePath ($la.file -replace '/','\')
    $license=''
    if(Test-Path -LiteralPath $licensePath){ $license=[IO.File]::ReadAllText($licensePath) } else { $violations.Add('LICENSE missing: '+$la.file) }
    foreach($s in @($la.must_contain)){ if($license -notmatch [regex]::Escape($s)){ $violations.Add('LICENSE-MISSING-TEXT: '+$s) } }
    # every .ps1 with non-ASCII must carry a UTF-8 BOM (Windows PowerShell 5.1 mis-parses otherwise)
    foreach($f in @(Get-ChildItem -LiteralPath $stagePath -Recurse -File -Filter '*.ps1' -Force -ErrorAction SilentlyContinue)){
        $bytes=[IO.File]::ReadAllBytes($f.FullName)
        $hasBom=($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if($hasBom){ continue }
        $nonAscii=$false
        foreach($b in $bytes){ if($b -ge 128){ $nonAscii=$true; break } }
        if($nonAscii){ $violations.Add('BOM-MISSING: '+(($f.FullName.Substring($stagePath.Length).TrimStart('\')) -replace '\\','/')) }
    }

    $all=@(Get-PayloadEntries $stagePath | Where-Object { -not $_.PSIsContainer })
    Write-Host ('[stage] payload files='+$all.Count+' bytes='+(($all | Measure-Object -Property Length -Sum).Sum))
    Write-Host ('[stage] copied='+@($script:copied).Count+' denied-by-manifest='+@($script:skipped).Count)
    if($violations.Count -gt 0){
        Write-Host ('[stage] FAILED with '+$violations.Count+' violation(s):')
        $violations | Select-Object -First 40 | ForEach-Object { Write-Host ('  - '+$_) }
        exit 2
    }
    Write-Host '[stage] whitelist, structural, content, README, LICENSE and BOM contracts OK'
    exit 0
}

function Invoke-ReleaseArtifact {
    Write-Host '=== build release artifact ==='
    if(-not (Test-Path -LiteralPath (Join-Path $stagePath '.git'))){ throw 'stage is not a git repository; commit the stage before building the artifact' }
    $appManifest=Get-Content -LiteralPath (Join-Path $DevRoot 'Data\App\app_manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $version=[string]$appManifest.app_version
    New-Item -ItemType Directory -Force -Path $releasePath | Out-Null
    $zipName='QQReplay-'+$version+'.zip'
    $zipPath=Join-Path $releasePath $zipName
    if(Test-Path -LiteralPath $zipPath){ Remove-Item -LiteralPath $zipPath -Force }
    Push-Location $stagePath
    try {
        $dirty=@(& git status --porcelain)
        if($dirty.Count -gt 0){ throw 'stage has uncommitted changes; commit before building the artifact' }
        & git archive --format=zip -o $zipPath HEAD
        if($LASTEXITCODE -ne 0){ throw 'git archive failed' }
    } finally { Pop-Location }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $bad=New-Object System.Collections.Generic.List[string]
    $zip=[System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $names=@($zip.Entries | ForEach-Object { $_.FullName })
        foreach($n in $names){
            if($n -like '*\*'){ $bad.Add('backslash entry: '+$n) }
            if($n -match '^QQReplay-'){ $bad.Add('artifact wrapped in an extra directory: '+$n) }
            if($n -like '*.sav' -or $n -like '*.git/*' -or $n -like '*/settings.json'){ $bad.Add('forbidden entry: '+$n) }
        }
        foreach($r in @($cfg.required_in_stage)){
            if($names -notcontains $r){ $bad.Add('required entry missing from artifact: '+$r) }
        }
    } finally { $zip.Dispose() }
    if($bad.Count -gt 0){
        Write-Host '[release] FAILED:'
        $bad | Select-Object -First 20 | ForEach-Object { Write-Host ('  - '+$_) }
        exit 2
    }
    $sha=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sums=Join-Path $releasePath 'SHA256SUMS.txt'
    [IO.File]::WriteAllBytes($sums,(New-Object System.Text.UTF8Encoding($false)).GetBytes($sha+'  '+$zipName+"`n"))
    Write-Host ('[release] artifact='+$zipName+' bytes='+(Get-Item -LiteralPath $zipPath).Length)
    Write-Host ('[release] sha256='+$sha)
    exit 0
}

function Invoke-Verify {
    Write-Host '=== publisher verification ==='
    Invoke-ConfigCheck | Out-Null
    # ConfigCheck exits; re-run its assertions inline so this action can also report.
    $appManifest=Get-Content -LiteralPath (Join-Path $DevRoot 'Data\App\app_manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $appVersion=[string]$appManifest.app_version
    $mi=Get-Content -LiteralPath (Join-Path $DevRoot 'Data\App\module_index.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if([string]$mi.app_version -eq $appVersion){ Pass ('module_index version matches: '+$appVersion) } else { Fail ('module_index version mismatch: '+$mi.app_version+' vs '+$appVersion) }
    $indexHtml=[IO.File]::ReadAllText((Join-Path $DevRoot 'Data\App\Modules\Frontend\index.html'))
    if($indexHtml -match [regex]::Escape('v'+$appVersion)){ Pass ('frontend tag shows v'+$appVersion) } else { Fail ('frontend tag does not show v'+$appVersion) }
    if($failures.Count -gt 0){ Write-Host ('[verify] FAILURES='+$failures.Count); exit 2 }
    Write-Host '[verify] OK'
    exit 0
}

switch($Action){
    'check'   { Invoke-ConfigCheck }
    'stage'   { Invoke-StageBuild }
    'release' { Invoke-ReleaseArtifact }
    'verify'  { Invoke-Verify }
}
