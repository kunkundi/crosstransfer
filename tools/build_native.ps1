# Run on Windows with Visual Studio's Desktop development with C++ workload.
param([ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
      [ValidateSet('release', 'debug')][string]$Mode = 'release',
      [ValidateRange(1, 7200)][int]$BuildTimeoutSeconds = 1200)
$ErrorActionPreference = 'Stop'
function Invoke-Xmake([string[]]$Arguments) {
    $process = Start-Process -FilePath (Get-Command xmake).Source -ArgumentList $Arguments -NoNewWindow -PassThru
    if (-not $process.WaitForExit($BuildTimeoutSeconds * 1000)) {
        # A failed dependency can leave child processes holding xmake's pipes.
        # End the whole tree so CI can retain diagnostics instead of timing out.
        & taskkill /PID $process.Id /T /F | Out-Null
        throw "xmake exceeded $BuildTimeoutSeconds seconds"
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "xmake failed with exit code $($process.ExitCode)" }
}
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    Invoke-Xmake -Arguments @('f', '-p', 'windows', '-a', $Arch, '-m', $Mode, '--ct_native=y', '-y')
    Invoke-Xmake -Arguments @('build', '-y', 'crosstransfer_native')
    New-Item -ItemType Directory -Force app/windows/native | Out-Null
    Copy-Item "build/windows/$Arch/$Mode/crosstransfer_native.dll" app/windows/native/ -Force
} finally { Pop-Location }
