param([switch]$OpenBrowser)

$ErrorActionPreference = 'Stop'
$dashboardDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$url = 'http://127.0.0.1:4174/'
$statusUrl = "${url}api/status"
$runtimeDir = Join-Path $dashboardDir 'runtime'

function Test-Dashboard {
    try {
        $status = Invoke-RestMethod -Uri $statusUrl -TimeoutSec 2
        return $status.sample.mode -eq 'cpu-self-test' -and $status.sample.fpga -eq $null
    } catch {
        return $false
    }
}

if (-not (Test-Dashboard)) {
    $node = (Get-Command node.exe -ErrorAction Stop).Source
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    $dashboardProcess = Start-Process -FilePath $node -ArgumentList 'server.js' `
        -WorkingDirectory $dashboardDir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $runtimeDir 'server.stdout.log') `
        -RedirectStandardError (Join-Path $runtimeDir 'server.stderr.log')
    for ($attempt = 0; $attempt -lt 20 -and -not (Test-Dashboard); $attempt++) {
        if ($dashboardProcess.HasExited) {
            throw "Dashboard exited with code $($dashboardProcess.ExitCode). See runtime/server.stderr.log."
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Dashboard)) {
        throw 'Dashboard did not become ready. See runtime/server.stderr.log.'
    }
}

Write-Output $url
if ($OpenBrowser) { Start-Process $url }
