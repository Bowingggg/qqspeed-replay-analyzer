function Start-AnalyzerTranscript {
    $dir=Join-Path $dataDir 'Diagnostics\Analyzer'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path=Join-Path $dir 'last_analyze.log'
    try {
        if(Test-Path -LiteralPath $path -PathType Leaf){ Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        Start-Transcript -LiteralPath $path -Force | Out-Null
        return $path
    } catch { return $null }
}

function Stop-AnalyzerTranscriptSafe {
    try { Stop-Transcript | Out-Null } catch {}
}

