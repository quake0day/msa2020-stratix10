param(
    [string]$QuestaBin = 'H:\quartus\questa_fse\win64',
    [string]$CorundumRoot = 'H:\led_ctrl\05_corundum\corundum'
)

$ErrorActionPreference = 'Stop'
$simDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $simDir
$workDir = Join-Path $simDir 'work'

Push-Location $simDir
try {
    if (-not (Test-Path $workDir)) {
        & (Join-Path $QuestaBin 'vlib.exe') $workDir
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    & (Join-Path $QuestaBin 'vlog.exe') -sv -work $workDir `
        (Join-Path $CorundumRoot 'fpga\lib\pcie\rtl\dma_psdpram.v') `
        (Join-Path $projectDir 'rtl\dma_bench.v') `
        (Join-Path $simDir 'moments_tb.sv')
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed' }

    $log = Join-Path $simDir 'transcript.log'
    & (Join-Path $QuestaBin 'vsim.exe') -c -l $log -do 'run -all; quit -f' work.moments_tb
    if ($LASTEXITCODE -ne 0) { throw "vsim failed; see $log" }
    if (-not (Select-String -Path $log -Pattern 'ALL MOMENTS TESTS PASSED' -Quiet)) {
        throw "simulation did not report success; see $log"
    }
} finally {
    Pop-Location
}
