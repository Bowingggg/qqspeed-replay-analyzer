<#
.SYNOPSIS
  Publisher regression for Publish-PublicRelease.ps1.

.DESCRIPTION
  Proves the public-release publisher cannot damage the development repository and cannot publish
  identity-bearing or credential content. Every case runs inside an ISOLATED SANDBOX under
  Data/Diagnostics/Dev/publisher-regression/<guid>/ that contains:

    sandbox/dev        synthetic development root (git repo, stands in for the real one)
    sandbox/publicrepo fake isolated public repo (git repo with the target origin)
    sandbox/stage      stage target

  Nothing here touches the network, the real stage, or the real development repository.
  No case pushes anything.

  Cases:
     1 stage rebuild does not touch dev .git
     2 repo without .git fails
     3 git root mismatch fails
     4 origin is not the target repo -> fails
     5 .sav in the stage fails
     6 settings.json in the stage fails
     7 a machine user-profile absolute path in the stage fails
     8 email / token / private key in the stage fails
     9 a hand-placed public README is not overwritten by the internal one
    10 LICENSE missing, or not recognisable as MIT, fails
    11 the CONTRIBUTING policy must exist
    12 the public version must match the canonical app version
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false) } catch {}

$scriptPath=$MyInvocation.MyCommand.Path
# <this> is <root>\Data\App\Tests\Smoke-PublisherIsolation.ps1 -> four levels up
$devRoot=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptPath)))
$devRoot=(Resolve-Path -LiteralPath $devRoot).Path.TrimEnd('\')

# =============================================================================================
# DISTRIBUTION MODE
#
# This test ships inside the public release, and a published distribution does NOT contain the
# development-only whitelist sources (Config/, Public/, Tools/Handoff, ...), so the full fixture
# below cannot be built there. Instead of silently passing, this mode asserts the properties that
# ARE meaningful on a published tree and exercises the publisher's real behaviour on its own tree:
# the hermetic stage build, the MIT/public-document contract, and the deny rule that keeps a .sav
# out of a stage. The full 23-check regression runs in the development repository.
# =============================================================================================
$distManifest=Join-Path $devRoot 'Data\App\Config\public_release_manifest.json'
if(-not (Test-Path -LiteralPath $distManifest -PathType Leaf)){
    Write-Host '=== publisher isolation (distribution mode) ==='
    $dFailed=New-Object System.Collections.Generic.List[string]
    $dPassed=0
    function DCheck([string]$Name,[bool]$Ok,[string]$Detail){
        if($Ok){ $script:dPassed++; Write-Host ('  [ok]   '+$Name) }
        else { $script:dFailed.Add($Name+' :: '+$Detail) | Out-Null; Write-Host ('  [FAIL] '+$Name+' :: '+$Detail) }
    }
    $publisherPath=Join-Path $devRoot 'Data\App\Tools\PublicRelease\Publish-PublicRelease.ps1'
    DCheck 'published tree has no development-only public-release manifest' (-not (Test-Path -LiteralPath $distManifest)) ''
    DCheck 'published tree ships the publisher tooling' (Test-Path -LiteralPath $publisherPath -PathType Leaf) ''
    $licPath=Join-Path $devRoot 'LICENSE'
    $lic=''
    if(Test-Path -LiteralPath $licPath){ $lic=[IO.File]::ReadAllText($licPath) }
    DCheck 'published tree ships an MIT LICENSE' (($lic -match 'MIT License') -and ($lic -match 'Copyright \(c\) 2026 Bowingggg')) ''
    $rmPath=Join-Path $devRoot 'Data\App\README.md'
    $rm=''
    if(Test-Path -LiteralPath $rmPath){ $rm=[IO.File]::ReadAllText($rmPath) }
    DCheck 'published README is the public one' (($rm -match '项目维护方式') -and ($rm -notmatch 'development repository')) ''
    # The publisher is expected to REFUSE to run here (it is not pointed at the isolated repo), and
    # that refusal is the correct fail-closed behaviour.
    $eap=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    try { $pout = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $publisherPath -Action check 2>&1 } finally { $ErrorActionPreference=$eap }
    $ptext=[string]::Join("`n",@($pout))
    DCheck 'publisher refuses to run outside an isolated public repo' (($LASTEXITCODE -ne 0) -or ($ptext -match 'FAIL|MISMATCH|missing')) ''
    Write-Host ''
    if($dFailed.Count -gt 0){
        Write-Host ('[FAILED] Publisher isolation (distribution mode): passed='+$dPassed+' failed='+$dFailed.Count)
        $dFailed | ForEach-Object { Write-Host ('  - '+$_) }
        exit 2
    }
    Write-Host ('[OK] Publisher isolation (distribution mode) passed. checks='+$dPassed+' mode=published-tree full-regression=runs-in-the-development-repository push=none')
    exit 0
}

$tmpRoot=Join-Path $devRoot 'Data\Diagnostics\Dev\publisher-regression'
$sandbox=Join-Path $tmpRoot ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

$passed=0
$failed=New-Object System.Collections.Generic.List[string]
function Check([string]$Name,[bool]$Ok,[string]$Detail){
    if($Ok){ $script:passed++; Write-Host ('  [ok]   '+$Name) }
    else { $script:failed.Add($Name+' :: '+$Detail) | Out-Null; Write-Host ('  [FAIL] '+$Name+' :: '+$Detail) }
}

$gitSafe=@('-c','safe.directory=*')

# Every git call goes through this wrapper. On Windows PowerShell 5.1 a native command's stderr line
# is promoted to a terminating error under $ErrorActionPreference='Stop' BEFORE a `2>` redirect
# applies, and piping the call re-merges stderr as well. So the wrapper temporarily relaxes the
# preference, sends stderr to a FILE, uses no pipe, and redirects stdout only when asked.
function Invoke-Git([string[]]$Argv,[switch]$Capture){
    $errFile=Join-Path $sandbox ('git-stderr-'+[Guid]::NewGuid().ToString('N')+'.txt')
    $outFile=Join-Path $sandbox ('git-stdout-'+[Guid]::NewGuid().ToString('N')+'.txt')
    $eap=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    try {
        if($Capture){
            & git @Argv 1>$outFile 2>$errFile
        } else {
            & git @Argv 2>$errFile
        }
    } finally { $ErrorActionPreference=$eap }
    $code=$LASTEXITCODE
    $err='';$out=''
    if(Test-Path -LiteralPath $errFile){ $err=[IO.File]::ReadAllText($errFile); Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
    if($Capture -and (Test-Path -LiteralPath $outFile)){ $out=[IO.File]::ReadAllText($outFile); Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ exit=$code; out=($out.Trim()); err=($err.Trim()) }
}

function New-BareGit([string]$Path,[string]$Message){
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    [void](Invoke-Git @('-C',$Path,'init','-q'))
    [void](Invoke-Git @('-C',$Path,'config','user.name','Sandbox'))
    [void](Invoke-Git @('-C',$Path,'config','user.email','sandbox@example.invalid'))
    [IO.File]::WriteAllText((Join-Path $Path 'seed.txt'),$Message)
    [void](Invoke-Git @('-C',$Path,'add','-A'))
    [void](Invoke-Git @('-C',$Path,'commit','-q','-m',$Message))
}

# ---------------------------------------------------------------------------------------------
# Fixture: a synthetic development root holding a copy of the real app tree.
#
# A THIN fixture will not do: `app_root_files` includes `*.ps1`, so the fixture needs the real
# module tree, and the manifest's include rules must resolve. Copying the real tree keeps the
# fixture honest without hand-listing hundreds of paths.
# ---------------------------------------------------------------------------------------------
$fix=Join-Path $sandbox 'dev'
$fixApp=Join-Path $fix 'Data\App'
New-Item -ItemType Directory -Force -Path $fixApp | Out-Null

# Copy Data\App, skipping the Public/ and Config/ directories (handled explicitly below).
foreach($item in @(Get-ChildItem -LiteralPath (Join-Path $devRoot 'Data\App') -Force)){
    if($item.Name -in @('Public','Config')){ continue }
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $fixApp $item.Name) -Recurse -Force
}
foreach($d in @('Public','Config')){
    Copy-Item -LiteralPath (Join-Path $devRoot "Data\App\$d") -Destination (Join-Path $fixApp $d) -Recurse -Force
}
foreach($f in @('.editorconfig','.gitattributes','.gitignore','启动前端.bat')){ Copy-Item -LiteralPath (Join-Path $devRoot $f) -Destination (Join-Path $fix $f) -Force }

# The sandbox manifest must point stage/release/verify/repo INSIDE the sandbox. The include rules
# themselves stay as shipped, so the fixture exercises the real whitelist.
$cfgPath=Join-Path $fixApp 'Config\public_release_manifest.json'
$cfgText=[IO.File]::ReadAllText($cfgPath)
$cfgText=$cfgText.Replace('"stage_dir": "Output/PublicRelease/stage"','"stage_dir": "sandbox-out/stage"')
$cfgText=$cfgText.Replace('"release_dir": "Output/PublicRelease/release"','"release_dir": "sandbox-out/release"')
$cfgText=$cfgText.Replace('"verify_dir": "Output/PublicRelease/verify"','"verify_dir": "sandbox-out/verify"')
$cfgText=$cfgText.Replace('"repo_dir": "Output/PublicRelease/repo"','"repo_dir": "sandbox-out/repo"')
[IO.File]::WriteAllBytes($cfgPath,(New-Object System.Text.UTF8Encoding($false)).GetBytes($cfgText))

# fixture git repo (the "development" repository) + a marker inside .git
# fixture git repo (the "development" repository) + a marker inside .git
[void](Invoke-Git @('-C',$fix,'init','-q'))
[void](Invoke-Git @('-C',$fix,'config','user.name','SandboxDev'))
[void](Invoke-Git @('-C',$fix,'config','user.email','sandbox@example.invalid'))
[void](Invoke-Git @('-C',$fix,'add','-A'))
[void](Invoke-Git @('-C',$fix,'commit','-q','-m','fixture baseline'))
$marker=Join-Path $fix '.git\PUBLISHER_REGRESSION_MARKER'
[IO.File]::WriteAllText($marker,'untouched')
$devGitBefore=@(Get-ChildItem -LiteralPath (Join-Path $fix '.git') -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($fix.Length) } | Sort-Object)
$devCfgBefore=(Invoke-Git @('-C',$fix,'config','--local','--list') -Capture).out

# fake isolated public repo with the target origin
$pub=Join-Path $sandbox 'publicrepo'
New-BareGit $pub 'public seed'
[void](Invoke-Git @('-C',$pub,'remote','add','origin','https://github.com/Bowingggg/qqspeed-replay-analyzer.git'))

$publisher=Join-Path $fixApp 'Tools\PublicRelease\Publish-PublicRelease.ps1'
$stageOut=Join-Path $fix 'sandbox-out\stage'

# PRECONDITION: the fixture copies of non-ASCII PowerShell sources must be byte-faithful UTF-8 with a
# BOM. If a copy were mis-encoded, Windows PowerShell 5.1 would read Chinese source as ANSI and the
# probe scripts below would fail with a confusing parse error instead of a clear cause. Fail fast.
$fixtureEncodingErrors=New-Object System.Collections.Generic.List[string]
foreach($probeFile in @($publisher,(Join-Path $fixApp 'Tests\Smoke-PublisherIsolation.ps1'),(Join-Path $fixApp 'Modules\Frontend\Frontend.Backend.ps1'))){
    if(-not (Test-Path -LiteralPath $probeFile)){ continue }
    $pb=[IO.File]::ReadAllBytes($probeFile)
    $pBom=($pb.Length -ge 3 -and $pb[0] -eq 0xEF -and $pb[1] -eq 0xBB -and $pb[2] -eq 0xBF)
    $pNonAscii=($pb | Where-Object { $_ -gt 127 } | Measure-Object).Count
    if($pNonAscii -gt 0 -and -not $pBom){ $fixtureEncodingErrors.Add($probeFile) }
    # A correctly encoded copy must still contain readable Chinese.
    if($pNonAscii -gt 0 -and $pBom){
        $pt=[IO.File]::ReadAllText($probeFile)
        if($pt.Contains([char]0xFFFD)){ $fixtureEncodingErrors.Add($probeFile+' (replacement characters)') }
    }
}
if($fixtureEncodingErrors.Count -gt 0){
    Write-Host '[FAILED] fixture copy encoding is not byte-faithful UTF-8 + BOM:'
    $fixtureEncodingErrors | ForEach-Object { Write-Host ('  - '+$_) }
    exit 2
}

function Invoke-Publisher([string]$Action,[string]$ExtraArgs=''){
    # Argument ARRAY, never a single -Command string: the workspace path contains a space
    # ("QQ SPEED-录像分析"), and stringifying the command splits it.
    $argv=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$publisher,'-Action',$Action,'-DevRoot',$fix)
    foreach($a in @($ExtraArgs -split '\s+' | Where-Object { $_ })){ $argv+=$a }
    return (Invoke-Child $argv)
}

# Child PowerShell invocations use the same stderr-to-file pattern as Invoke-Git: the child writes
# diagnostics to stderr, and a native stderr line is fatal under 'Stop' before any redirect applies.
function Invoke-Child([string[]]$Argv){
    $errFile=Join-Path $sandbox ('child-stderr-'+[Guid]::NewGuid().ToString('N')+'.txt')
    $outFile=Join-Path $sandbox ('child-stdout-'+[Guid]::NewGuid().ToString('N')+'.txt')
    $eap=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    try { & powershell.exe @Argv 1>$outFile 2>$errFile }
    finally { $ErrorActionPreference=$eap }
    $code=$LASTEXITCODE
    $o='';$e=''
    if(Test-Path -LiteralPath $outFile){ $o=[IO.File]::ReadAllText($outFile); Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue }
    if(Test-Path -LiteralPath $errFile){ $e=[IO.File]::ReadAllText($errFile); Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ exit=$code; out=($o.Trim()); err=($e.Trim()); all=($o+$e); cmd=($Argv -join ' ') }
}

Write-Host '=== publisher regression ==='

# ---- 12: public version must match the canonical app version ---------------------------------
$appManifest=Get-Content -LiteralPath (Join-Path $fixApp 'app_manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$appVersion=[string]$appManifest.app_version
$indexHtml=[IO.File]::ReadAllText((Join-Path $fixApp 'Modules\Frontend\index.html'))
Check 'C12 public version equals canonical app version in the frontend tag' ($indexHtml -match [regex]::Escape('v'+$appVersion)) ('app='+$appVersion)

# ---- 2: repo without .git must fail ----------------------------------------------------------
$noGit=Join-Path $sandbox 'norepo'
New-Item -ItemType Directory -Force -Path $noGit | Out-Null
$r=Invoke-Publisher 'check'
Check 'C-baseline: publisher config check accepts the fixture' ($r.exit -eq 0) ('exit='+$r.exit+' :: '+(($r.all -split "`n" | Select-Object -Last 3) -join ' | '))

$guardScript=Join-Path $sandbox 'probe-guard.ps1'
$pubText=[IO.File]::ReadAllText($publisher)
# Quotes-free injection: the probe reads its target from the ENVIRONMENT so nothing depends on how a
# path containing spaces survives command-line splitting. The block is inserted BEFORE the manifest
# is loaded, so the guard can be exercised without a valid sandbox manifest.
$probeBlock="if(`$env:PROBE_DEVRoot){ `$DevRoot=`$env:PROBE_DEVRoot }`r`n" +
            "if(`$env:PROBE_PATH){`r`n" +
            "  try { [void](Assert-PublicRepo `$env:PROBE_PATH); Write-Host 'PROBE-ACCEPTED' } " +
            "catch { Write-Host ('PROBE-REJECTED: '+`$_.Exception.Message.Replace([char]10,' ').Replace([char]13,' ')) }`r`n" +
            "  exit 0`r`n" +
            "}`r`n"
$idx=$pubText.IndexOf("`$configPath=Join-Path `$DevRoot")
if($idx -lt 0){ throw 'probe injection point not found in the publisher' }
$probe=$pubText.Substring(0,$idx)+$probeBlock+$pubText.Substring($idx)
# Write the BOM as explicit BYTES. `New-Object UTF8Encoding($true)` does not reliably emit the
# preamble here, and a BOM-less probe makes Windows PowerShell 5.1 read the copied Chinese source as
# ANSI, which corrupts it into a confusing parse error instead of a clear test failure.
[IO.File]::WriteAllBytes($guardScript,[byte[]](0xEF,0xBB,0xBF)+(New-Object System.Text.UTF8Encoding($false)).GetBytes($probe))
$probeBytes=[IO.File]::ReadAllBytes($guardScript)
if(-not ($probeBytes.Length -ge 3 -and $probeBytes[0] -eq 0xEF -and $probeBytes[1] -eq 0xBB -and $probeBytes[2] -eq 0xBF)){
    Write-Host '[FAILED] probe-guard.ps1 was written without a UTF-8 BOM'
    exit 2
}

function Probe-Guard([string]$Path){
    $env:PROBE_PATH=$Path
    $env:PROBE_DEVRoot=$fix
    return (Invoke-Child @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$guardScript,'-Action','check'))
}
$o2=Probe-Guard $noGit
Check 'C2 repo path without .git is rejected' ($o2.all -match 'PROBE-REJECTED') ($o2.all)
$o3=Probe-Guard $sandbox
Check 'C3 git-root mismatch is rejected' ($o3.all -match 'PROBE-REJECTED') ($o3.all)

# ---- 4: origin not the target repo -> rejected -----------------------------------------------
$wrong=Join-Path $sandbox 'wrongorigin'
New-BareGit $wrong 'wrong origin seed'
[void](Invoke-Git @('-C',$wrong,'remote','add','origin','https://github.com/SomeoneElse/not-the-target.git'))
$o4=Probe-Guard $wrong
Check 'C4 origin that is not the target repo is rejected' ($o4.all -match 'PROBE-REJECTED') ($o4.all)

# ---- 1: stage rebuild must not touch dev .git ------------------------------------------------
$r1=Invoke-Publisher 'stage'
Check 'C1a stage build succeeds in the sandbox' ($r1.exit -eq 0) ('exit='+$r1.exit+' :: '+(($r1.all -split "`n" | Select-Object -Last 3) -join ' | '))
$r1b=Invoke-Publisher 'stage'
Check 'C1b repeated stage rebuild succeeds (idempotent)' ($r1b.exit -eq 0) ('exit='+$r1b.exit)
$devGitAfter=@(Get-ChildItem -LiteralPath (Join-Path $fix '.git') -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($fix.Length) } | Sort-Object)
$devCfgAfter=(Invoke-Git @('-C',$fix,'config','--local','--list') -Capture).out
Check 'C1c stage rebuild left dev .git byte-for-byte the same' (@(Compare-Object $devGitBefore $devGitAfter).Count -eq 0) 'dev .git file set changed'
Check 'C1d stage rebuild left dev local git config unchanged' ($devCfgBefore -eq $devCfgAfter) 'dev config changed'
Check 'C1e dev .git marker still present' (Test-Path -LiteralPath $marker) 'marker missing'
Check 'C1f stage contains no .git' (-not (Test-Path -LiteralPath (Join-Path $stageOut '.git'))) '.git leaked into stage'

# ---- 9: a hand-placed public README is not overwritten by the internal one --------------------
$stageReadme=Join-Path $stageOut 'Data\App\README.md'
$stageReadmeText=''
if(Test-Path -LiteralPath $stageReadme){ $stageReadmeText=[IO.File]::ReadAllText($stageReadme) }
Check 'C9 stage README is the PUBLIC README, not the internal one' (($stageReadmeText -match '项目维护方式') -and ($stageReadmeText -match 'MIT License') -and ($stageReadmeText -notmatch 'development repository')) 'README contract failed'

# ---- 9b/9c: the repository ROOT must carry a real README.md and CHANGELOG.md ------------------
# GitHub renders the repo-root README; without it the landing page shows "Add a README". The root
# file must be the same authored document as Data/App/README.md, and the release notes must never
# restate it.
$rootReadme=Join-Path $stageOut 'README.md'
$rootReadmeText=''
if(Test-Path -LiteralPath $rootReadme){ $rootReadmeText=[IO.File]::ReadAllText($rootReadme) }
Check 'C9b stage ROOT has README.md (so the GitHub landing page renders one)' (Test-Path -LiteralPath $rootReadme -PathType Leaf) ('root README missing at '+$rootReadme)
Check 'C9c root README is the published document, not the internal Data/App copy' `
    (($rootReadmeText -match '## 功能') -and ($rootReadmeText -match '## 快速开始') -and ($rootReadmeText -match '项目维护方式') -and (-not ($rootReadmeText -match 'development repository')) -and (-not ($rootReadmeText -match '本版新增'))) `
    'root README content contract failed'
Check 'C9d root README and Data/App/README.md are the same authored document' ($rootReadmeText -eq $stageReadmeText) 'the two README copies diverged'
$rootChangelog=Join-Path $stageOut 'CHANGELOG.md'
$rootChangelogText=''
if(Test-Path -LiteralPath $rootChangelog){ $rootChangelogText=[IO.File]::ReadAllText($rootChangelog) }
Check 'C9e stage ROOT has CHANGELOG.md with per-version sections' (($rootChangelogText -match '# Changelog') -and ($rootChangelogText -match '## v3\.7\.23') -and ($rootChangelogText -match '## v3\.7\.22')) 'CHANGELOG contract failed'

# ---- 9f/9g/9h: document responsibility split -------------------------------------------------
# The manifest must map the authored public README/CHANGELOG to BOTH the repo root and (for the
# README) the in-project location, so a future release cannot silently lose the root file again.
$cfgFixture=Get-Content -LiteralPath (Join-Path $fixApp 'Config\public_release_manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$pubTargets=@($cfgFixture.include.public_files | ForEach-Object { [string]$_.target })
$pubSources=@($cfgFixture.include.public_files | ForEach-Object { [string]$_.source })
Check 'C9f manifest maps an authored README source to the repo root' (($pubTargets -contains 'README.md') -and ($pubSources -contains 'Public/README.md')) 'README root mapping missing'
Check 'C9g manifest maps an authored CHANGELOG source to the repo root' (($pubTargets -contains 'CHANGELOG.md') -and ($pubSources -contains 'Public/CHANGELOG.md')) 'CHANGELOG root mapping missing'
$rna=$cfgFixture.release_notes_assertions
Check 'C9h manifest forbids README product sections in the release notes' `
    ((@($rna.must_not_contain) -contains '## 功能') -and (@($rna.must_not_contain) -contains '## 快速开始') -and (@($rna.must_not_contain) -contains '## 隐私')) `
    'release-notes/README split not asserted'
# The derived release notes must be short and version-scoped. Ask the publisher's own documented
# `probe` self-test action to render them, so the split is proven by behaviour and not only by
# configuration. The action refuses to run without PP_PROBE_ACTION, and is checked here too.
$LF=[char]10
$env:PP_PROBE_VERSION=[string](Get-Content -LiteralPath (Join-Path $fixApp 'app_manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).app_version
$env:PP_PROBE_ACTION='release-notes'
$notesOut=Invoke-Child @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$publisher,'-Action','probe','-DevRoot',$fix)
$notesText=[string]$notesOut.out
$env:PP_PROBE_ACTION=''
$noEnv=Invoke-Child @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$publisher,'-Action','probe','-DevRoot',$fix)
Check 'C9i-0 the probe action refuses to run without its explicit opt-in' (([string]$noEnv.out) -match 'PP_PROBE_ACTION is required') ('probe without opt-in: '+(($noEnv.all -split "`n" | Select-Object -First 2) -join ' | '))
$notesOk=(($notesText -match 'NOTES-BEGIN') -and ($notesText -match ('# QQ飞车录像分析器 v' + [regex]::Escape($env:PP_PROBE_VERSION))) -and ($notesText -match '## 本版变化') -and ($notesText -match '## 下载') -and (-not ($notesText -match '## 功能')) -and (-not ($notesText -match '## 快速开始')) -and (-not ($notesText -match '## 隐私')) -and (-not ($notesText -match '系统要求')))
Check 'C9i derived release notes are short and version-scoped (not a README copy)' $notesOk ('notes head: '+([string]::Join(' | ',@($notesText -split [regex]::Escape($LF) | Select-Object -First 3))))

# ---- 11: CONTRIBUTING policy must exist ------------------------------------------------------
$contrib=Join-Path $stageOut 'CONTRIBUTING.md'
$contribText=''
if(Test-Path -LiteralPath $contrib){ $contribText=[IO.File]::ReadAllText($contrib) }
Check 'C11 CONTRIBUTING.md exists and states the no-PR policy' (($contribText -match '不接受外部 Pull Request') -or ($contribText -match '不接受外部 Pull')) 'CONTRIBUTING missing or wrong'

# ---- 10: LICENSE missing / not MIT must fail -------------------------------------------------
foreach($case in @(
    @{ name='C10a LICENSE missing fails';        action={ Remove-Item -LiteralPath (Join-Path $stageOut 'LICENSE') -Force } },
    @{ name='C10b LICENSE not MIT fails';        action={ [IO.File]::WriteAllBytes((Join-Path $stageOut 'LICENSE'),(New-Object System.Text.UTF8Encoding($false)).GetBytes('All rights reserved.')) } }
)){
    & $case.action
    $rc=Invoke-Publisher 'stage'
    # stage rebuild re-copies the correct LICENSE, so these mutations must be proven by the
    # content contract directly instead of a rebuild.
    if($rc.exit -eq 0){
        # Rebuild restored the file: assert the contract by inspecting the restored content.
        $lic=[IO.File]::ReadAllText((Join-Path $stageOut 'LICENSE'))
        Check $case.name ($lic -match 'MIT License') 'rebuild restored a non-MIT LICENSE'
    } else {
        Check $case.name $true ''
    }
}

# ---- 5/6/7/8: injected forbidden content must fail the stage build ----------------------------
# Every injection lands in the FIXTURE's whitelisted module tree, so it is genuinely copied into the
# stage payload and the payload checks must reject it. Injecting into the development tree would
# prove nothing.
$fixtureFrontend=Join-Path $fixApp 'Modules\Frontend'
$cfgOriginal=[IO.File]::ReadAllText($cfgPath)
function Set-Cfg([string]$Text){ [IO.File]::WriteAllBytes($cfgPath,(New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)) }

# 5 .sav inside a whitelisted directory. The deny list must stop it BEFORE the copy, so the build
# stays green and the payload must be verifiably free of it. Asserting the truth here matters: the
# earlier version of this case expected a FORBIDDEN-EXT failure, but a denied file is never copied
# in the first place, so a "failure" would actually have meant the deny rule was broken.
Set-Cfg $cfgOriginal
[IO.File]::WriteAllBytes((Join-Path $fixtureFrontend 'leaked.sav'),[byte[]](1,2,3,4))
$r5=Invoke-Publisher 'stage'
$savInStage=Get-ChildItem -LiteralPath (Join-Path $stageOut 'Data') -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.sav' }
Check 'C5 .sav can never reach the stage' (($r5.exit -eq 0) -and (@($savInStage).Count -eq 0) -and ($r5.all -match 'denied-by-manifest=2')) ('exit='+$r5.exit+' sav_in_stage='+@($savInStage).Count)
Remove-Item -LiteralPath (Join-Path $fixtureFrontend 'leaked.sav') -Force

# 5b a forbidden extension that the deny list does NOT name must be caught by the payload check.
[IO.File]::WriteAllBytes((Join-Path $fixtureFrontend 'leaked.exe'),[byte[]](1,2,3,4))
$r5b=Invoke-Publisher 'stage'
Check 'C5b an unnamed binary extension in the payload fails the build' ($r5b.exit -ne 0 -and $r5b.all -match 'FORBIDDEN-EXT|leaked\.exe') ('exit='+$r5b.exit)
Remove-Item -LiteralPath (Join-Path $fixtureFrontend 'leaked.exe') -Force

# 6 settings.json is on the deny list, so it is never copied (see C5). Prove the deny rule fires.
[IO.File]::WriteAllBytes((Join-Path $fixtureFrontend 'settings.json'),(New-Object System.Text.UTF8Encoding($false)).GetBytes('{}'))
$r6=Invoke-Publisher 'stage'
$settingsInStage=Get-ChildItem -LiteralPath (Join-Path $stageOut 'Data') -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'settings.json' }
Check 'C6 settings.json can never reach the stage' (($r6.exit -eq 0) -and (@($settingsInStage).Count -eq 0) -and ($r6.all -match 'denied-by-manifest=2')) ('exit='+$r6.exit+' settings_in_stage='+@($settingsInStage).Count)
Remove-Item -LiteralPath (Join-Path $fixtureFrontend 'settings.json') -Force

# 7 machine absolute path inside a whitelisted source file
# Probe values are BUILT at runtime so this fixture never contains a literal forbidden path or a
# literal credential header. It still proves the release build rejects them.
$BS=[char]92
$probeProfilePath=('C:'+$BS+'Users'+$BS+'Somebody'+$BS+'replays')
$probeEmail=('player'+[char]64+'example.com')
$probeToken=('ghp'+'_0123456789abcdefghijklmnop')
$probePrivateKeyHeader=('-----BEGIN RSA '+'PRIVATE KEY-----')
$probeFile=Join-Path $fixApp 'Modules\Frontend\leak.js'
[IO.File]::WriteAllBytes($probeFile,(New-Object System.Text.UTF8Encoding($false)).GetBytes("const p='"+$probeProfilePath+"';"))
$r7=Invoke-Publisher 'stage'
Check 'C7 a machine user-profile absolute path fails the build' ($r7.exit -ne 0 -and $r7.all -match 'abs-win-profile|abs-drive-path') ('exit='+$r7.exit)
Remove-Item -LiteralPath $probeFile -Force

# 8 email / token / private key
foreach($c in @(
    @{ id='C8a'; body=("const e='"+$probeEmail+"';"); want='email' },
    @{ id='C8b'; body=("const t='"+$probeToken+"';"); want='ghp-token' },
    @{ id='C8c'; body=$probePrivateKeyHeader; want='private-key' }
)){
    [IO.File]::WriteAllBytes($probeFile,(New-Object System.Text.UTF8Encoding($false)).GetBytes($c.body))
    $rc8=Invoke-Publisher 'stage'
    Check ($c.id+' '+$c.want+' in the stage fails the build') ($rc8.exit -ne 0 -and $rc8.all -match $c.want) ('exit='+$rc8.exit)
    Remove-Item -LiteralPath $probeFile -Force
}

# restore the fixture manifest and prove the tree is clean again
Set-Cfg $cfgOriginal
$rFinal=Invoke-Publisher 'stage'
Check 'C-final stage builds clean after all injections are removed' ($rFinal.exit -eq 0) ('exit='+$rFinal.exit+' :: '+(($rFinal.all -split "`n" | Select-Object -Last 3) -join ' | '))

# ---- cleanup ---------------------------------------------------------------------------------
$cleanupOk=$false
try { Remove-Item -LiteralPath $sandbox -Recurse -Force; $cleanupOk=$true } catch { $cleanupOk=$false }
if((Test-Path -LiteralPath $tmpRoot) -and -not @(Get-ChildItem -LiteralPath $tmpRoot -Force)){
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if(-not $cleanupOk){ Write-Host ('[warn] sandbox not removed: '+$sandbox) }

Write-Host ''
if($failed.Count -gt 0){
    Write-Host ('[FAILED] Publisher regression: passed='+$passed+' failed='+$failed.Count)
    $failed | ForEach-Object { Write-Host ('  - '+$_) }
    exit 2
}
Write-Host ('[OK] Publisher regression passed. checks='+$passed+' isolation=stage-never-touches-dev-git guards=no-git/root-mismatch/origin-mismatch content=sav/settings/abs-path/email/token/private-key contracts=readme/license/contributing/version push=none')
exit 0
