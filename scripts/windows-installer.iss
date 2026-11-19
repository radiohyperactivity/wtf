; The installer of the Windows app, for Inno Setup (scripts/windows-installer.sh
; builds the app and runs this). It installs for the current user, without
; administrator rights, into %LOCALAPPDATA%\Programs\WtF, unless the user
; chooses everyone; a new version installs over the one there is.
;
; scripts/windows-installer.sh defines:
;   AppVersion  the app's version, from app/pubspec.yaml
;   SourceDir   the Flutter build, with the C++ runtime copied into it
;   OutputDir   where the installer goes

#ifndef AppVersion
  #error AppVersion is not defined; run scripts/windows-installer.sh
#endif

[Setup]
; Windows knows the app by this, so a new version replaces the old one. It
; must never change.
AppId={{4639457F-2634-4AC5-B94A-1B5860728FA9}
AppName=WtF
AppVersion={#AppVersion}
AppVerName=WtF {#AppVersion}
AppPublisher=Bård Bjerke Johannessen
AppPublisherURL=https://github.com/radiohyperactivity/wtf
AppCopyright=Copyright (C) 2026 Bård Bjerke Johannessen
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\WtF
DefaultGroupName=WtF
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\wtf-app.exe
UninstallDisplayName=WtF
OutputDir={#OutputDir}
OutputBaseFilename=wtf-app-{#AppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Asks to close a running app before replacing it.
CloseApplications=yes

[Tasks]
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; The files of an earlier version go first, so that one this version no
; longer has, such as an old plugin, isn't left to be loaded.
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\*.dll"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\WtF"; Filename: "{app}\wtf-app.exe"
Name: "{autodesktop}\WtF"; Filename: "{app}\wtf-app.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\wtf-app.exe"; Description: "{cm:LaunchProgram,WtF}"; Flags: nowait postinstall skipifsilent
