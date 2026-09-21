# Run on Windows with Visual Studio's Desktop development with C++ workload.
param([ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
      [ValidateSet('release', 'debug')][string]$Mode = 'release')
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & xmake f -p windows -a $Arch -m $Mode --ct_native=y -y
    if ($LASTEXITCODE -ne 0) { throw 'xmake configure failed' }
    & xmake build -y crosstransfer_native
    if ($LASTEXITCODE -ne 0) { throw 'native build failed' }
    New-Item -ItemType Directory -Force app/windows/native | Out-Null
    Copy-Item "build/windows/$Arch/$Mode/crosstransfer_native.dll" app/windows/native/ -Force
} finally { Pop-Location }
