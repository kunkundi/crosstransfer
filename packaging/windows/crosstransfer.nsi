Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!ifndef BUNDLE
  !error "Pass /DBUNDLE=<Flutter Release directory>"
!endif
!ifndef VERSION
  !define VERSION "0.1.0"
!endif
!ifndef OUTPUT
  !define OUTPUT "CrossTransfer-${VERSION}-windows-x64-setup.exe"
!endif
Name "CrossTransfer"
OutFile "${OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\CrossTransfer"
InstallDirRegKey HKCU "Software\CrossTransfer" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

Function .onInit
  FindWindow $0 "FLUTTER_RUNNER_WIN32_WINDOW" "CrossTransfer"
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "Please quit CrossTransfer from the tray before installing." /SD IDOK
    Abort
  ${EndIf}
FunctionEnd

Section "CrossTransfer" SEC_MAIN
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /r "${BUNDLE}\*.*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\CrossTransfer"
  CreateShortcut "$SMPROGRAMS\CrossTransfer\CrossTransfer.lnk" "$INSTDIR\crosstransfer.exe"
  CreateShortcut "$SMPROGRAMS\CrossTransfer\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\CrossTransfer" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Classes\crosstransfer" "" "URL:CrossTransfer"
  WriteRegStr HKCU "Software\Classes\crosstransfer" "URL Protocol" ""
  WriteRegStr HKCU "Software\Classes\crosstransfer\DefaultIcon" "" '$"$INSTDIR\crosstransfer.exe$",0'
  WriteRegStr HKCU "Software\Classes\crosstransfer\shell\open\command" "" '$"$INSTDIR\crosstransfer.exe$" $"%1$"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\CrossTransfer" "DisplayName" "CrossTransfer"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\CrossTransfer" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\CrossTransfer" "Publisher" "DI JUNKUN"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\CrossTransfer" "UninstallString" '$"$INSTDIR\Uninstall.exe$"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\CrossTransfer" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\CrossTransfer" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\CrossTransfer" "NoRepair" 1
SectionEnd

Function un.onInit
  FindWindow $0 "FLUTTER_RUNNER_WIN32_WINDOW" "CrossTransfer"
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "Please quit CrossTransfer from the tray before uninstalling." /SD IDOK
    Abort
  ${EndIf}
FunctionEnd

Section "Uninstall"
  SetShellVarContext current
  ReadRegStr $0 HKCU "Software\Classes\crosstransfer\shell\open\command" ""
  ${If} $0 == '$"$INSTDIR\crosstransfer.exe$" $"%1$"'
    DeleteRegKey HKCU "Software\Classes\crosstransfer"
  ${EndIf}
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\CrossTransfer"
  DeleteRegKey HKCU "Software\CrossTransfer"
  RMDir /r "$SMPROGRAMS\CrossTransfer"
  ; Remove only shipped files. User configuration and received files stay intact.
  Delete "$INSTDIR\*.dll"
  Delete "$INSTDIR\crosstransfer.exe"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir /r "$INSTDIR\data"
  RMDir /r "$INSTDIR\legal"
  RMDir "$INSTDIR"
SectionEnd
