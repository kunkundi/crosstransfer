param([string]$Bundle = '', [string]$MakeNsis = 'makensis')
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
if (!$Bundle) { $Bundle = Join-Path $Root 'app/build/windows/x64/runner/Release' }
$Bundle = (Resolve-Path $Bundle).Path
python "$Root/tools/check_flutter_legal_bundle.py" "$Bundle/data/flutter_assets"
if ($LASTEXITCODE -ne 0) { throw 'Bundled legal assets are missing or stale' }
foreach ($Name in @('crosstransfer.exe', 'crosstransfer_native.dll', 'flutter_windows.dll')) {
    if (!(Test-Path (Join-Path $Bundle $Name))) { throw "Missing bundle file: $Name" }
}
$Version = ((Get-Content "$Root/app/pubspec.yaml" | Select-String '^version:').ToString() -split '\s+')[1].Split('+')[0]
New-Item -ItemType Directory -Force "$Root/dist", "$Bundle/legal" | Out-Null
Copy-Item "$Root/LICENSE", "$Root/THIRD_PARTY_NOTICES.md" "$Bundle/legal/" -Force
Copy-Item "$Root/minirtc/thirdparty/webrtc/LICENSE" "$Bundle/legal/WebRTC-LICENSE" -Force
Copy-Item "$Root/minirtc/thirdparty/webrtc/PATENTS" "$Bundle/legal/WebRTC-PATENTS" -Force
Copy-Item "$Root/app/assets/legal/libjuice-1.7.2-ct1.tar.gz", "$Root/docs/licenses/libjuice.txt" "$Bundle/legal/" -Force
# Flutter's runner and plugins use the dynamic MSVC runtime. Ship the permitted
# app-local CRT files so a clean machine does not require a separate installer.
$VsWhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$Vs = & $VsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$Vs) { throw 'Visual Studio C++ toolchain not found' }
$Redist = Get-ChildItem "$Vs/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT" -Directory | Sort-Object FullName -Descending | Select-Object -First 1
if (!$Redist) { throw 'MSVC redistributable CRT directory not found' }
Copy-Item "$($Redist.FullName)/*.dll" $Bundle -Force
$Output = "$Root/dist/CrossTransfer-$Version-windows-x64-setup.exe"
& $MakeNsis "/DBUNDLE=$Bundle" "/DVERSION=$Version" "/DOUTPUT=$Output" "$Root/packaging/windows/crosstransfer.nsi"
if ($LASTEXITCODE -ne 0) { throw 'NSIS packaging failed' }
"$((Get-FileHash $Output -Algorithm SHA256).Hash.ToLower())  $(Split-Path $Output -Leaf)" | Set-Content "$Output.sha256" -Encoding utf8
Write-Output $Output
