; The NSIS installer for the Ziggy example on Windows. Built by package-windows.sh, which defines:
;   VERSION      the app's version
;   ARCH         x64 or arm64
;   SOURCE_DIR   the directory holding ziggy-example.exe, WebView2Loader.dll and the ui directory
;   OUTPUT_FILE  the installer to write
; The installer is unsigned and installs for the current user only, so it needs no administrator rights.

Unicode true
!include "MUI2.nsh"

Name "Ziggy example"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\Ziggy example"
InstallDirRegKey HKCU "Software\dev.ziggy.example" "InstallDir"
RequestExecutionLevel user

!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Section "Install"
    SetOutPath "$INSTDIR"
    File "${SOURCE_DIR}\ziggy-example.exe"
    File "${SOURCE_DIR}\WebView2Loader.dll"
    SetOutPath "$INSTDIR\ui"
    File /r "${SOURCE_DIR}\ui\*.*"
    WriteUninstaller "$INSTDIR\uninstall.exe"
    CreateShortcut "$SMPROGRAMS\Ziggy example.lnk" "$INSTDIR\ziggy-example.exe"
    WriteRegStr HKCU "Software\dev.ziggy.example" "InstallDir" "$INSTDIR"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\dev.ziggy.example" "DisplayName" "Ziggy example"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\dev.ziggy.example" "DisplayVersion" "${VERSION}"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\dev.ziggy.example" "UninstallString" "$INSTDIR\uninstall.exe"
SectionEnd

Section "Uninstall"
    Delete "$INSTDIR\ziggy-example.exe"
    Delete "$INSTDIR\WebView2Loader.dll"
    Delete "$INSTDIR\ui\index.html"
    Delete "$INSTDIR\ui\assets\main.js"
    RMDir "$INSTDIR\ui\assets"
    RMDir "$INSTDIR\ui"
    Delete "$INSTDIR\uninstall.exe"
    RMDir "$INSTDIR"
    Delete "$SMPROGRAMS\Ziggy example.lnk"
    DeleteRegKey HKCU "Software\dev.ziggy.example"
    DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\dev.ziggy.example"
SectionEnd
